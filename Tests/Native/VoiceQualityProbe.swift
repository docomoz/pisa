import Foundation
import AVFoundation

/// Private-corpus regression runner: all inputs are explicit; never opens a library.
@main enum VoiceQualityProbe {
    struct Reference: Codable { var meetingID: String; var segmentID: String; var start: Double; var end: Double; var expected: String; var audio: String; var confidence: String }
    struct Manifest: Codable { var root: String; var profiles: String; var references: [Reference]; var unconfirmed: [Reference]?; var allWindows: Bool?; var windowCache: String? }
    struct ProfileVector: Codable { var name: String; var meetingID: UUID; var segmentID: UUID; var file: String; var stored: [Float]; var extracted: [Float]? }
    struct Turn: Codable { var reference: Reference; var direct: [Float]?; var preview: [Float]?; var storedMatch: String?; var extractedMatch: String?; var regions: [Region] }
    struct Region: Codable { var start: Double; var end: Double; var embedding: [Float]?; var speaker: String; var identified: String? }
    struct Output: Codable { var profiles: [ProfileVector]; var turns: [Turn]; var meetings: [MeetingResult]; var elapsed: Double }
    struct CachedWindow: Codable { var key: String; var meetingID: String; var start: Double; var regions: [Region] }
    struct MeetingResult: Codable { var meetingID: String; var windows: Int; var regions: [Region] }
    static func read(_ path: String, start: Double = 0, end: Double? = nil) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let source = file.processingFormat
        let first = min(file.length, max(0, AVAudioFramePosition(start * source.sampleRate)))
        let last = min(file.length, end.map { AVAudioFramePosition(ceil($0 * source.sampleRate)) } ?? file.length)
        guard last > first else { return [] }
        file.framePosition = first
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(last - first))!
        try file.read(into: buffer)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: source, to: target) else { throw PisyaError.message("Audio conversion unavailable") }
        let result = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate) + 64))!
        var supplied = false, error: NSError?
        converter.convert(to: result, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
    }
    static func diarize(_ samples: [Float], engine: SpeakerEngine) -> [VoiceRegion] {
        engine.regions(samples).flatMap { region -> [VoiceRegion] in
            let lower = max(0, Int(region.start * 16000)), upper = min(samples.count, Int(region.end * 16000))
            guard upper > lower else { return [] }
            let chunks = SpeechChunking.ranges(in: samples, range: lower..<upper)
            return chunks.map { chunk in
                #if VOICE_QUALITY_LEGACY
                let embedding = region.embedding
                #else
                let embedding = chunks.count > 1 ? engine.vector(samples, in: chunk, excluding: region.embeddingExclusions) : region.embedding
                #endif
                return VoiceRegion(start: Double(chunk.lowerBound) / 16000, end: Double(chunk.upperBound) / 16000, embedding: embedding)
            }
        }
    }
    struct MatchingEvidence: Decodable { var profiles: [ProfileVector]; var turns: [Turn]; var meetings: [MeetingResult]? }
    struct MatchResult: Codable { var key: String; var expected: String?; var actual: String?; var cohortHasExpected: Bool; var source: String }
    static func matchingProfiles(_ samples: [ProfileVector], extracted: Bool) -> [VoiceProfile] {
        Dictionary(grouping: samples, by: \.name).map { name, samples in
            let usable = samples.filter { !extracted || $0.extracted != nil }
            var profile = VoiceProfile(name: name, samples: usable.map { extracted ? $0.extracted! : $0.stored })
            profile.examples = usable.map { sample in
                let vector = extracted ? sample.extracted! : sample.stored
                let example = VoiceExample(file: sample.file, meetingID: sample.meetingID, segmentID: sample.segmentID, embedding: vector)
                #if VOICE_QUALITY_LEGACY
                return example
                #else
                return extracted ? example.withCurrentEmbedding(vector) : example
                #endif
            }
            return profile
        }
    }
    static func matchEvidence(_ path: String, output: String) throws {
        let evidence = try JSONDecoder().decode(MatchingEvidence.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var results: [MatchResult] = []
        for turn in evidence.turns {
            let eligible = evidence.profiles.filter { $0.meetingID.uuidString != turn.reference.meetingID }
            let cohort = matchingProfiles(eligible, extracted: true)
            results.append(MatchResult(key: turn.reference.segmentID, expected: turn.reference.confidence == "user-confirmed" ? turn.reference.expected : nil,
                actual: turn.preview.flatMap { VoiceMatcher.identify($0, profiles: cohort) },
                cohortHasExpected: cohort.contains { $0.name == turn.reference.expected }, source: "confirmed-preview"))
        }
        for sample in evidence.profiles {
            guard let vector = sample.extracted else { continue }
            // Hold out an entire source meeting, including all clips from it.
            let cohort = matchingProfiles(evidence.profiles.filter { $0.meetingID != sample.meetingID }, extracted: true)
            results.append(MatchResult(key: sample.file, expected: sample.name,
                actual: VoiceMatcher.identify(vector, profiles: cohort), cohortHasExpected: cohort.contains { $0.name == sample.name }, source: "saved-label-holdout"))
            let unknown = cohort.filter { $0.name != sample.name }
            results.append(MatchResult(key: sample.file, expected: nil,
                actual: VoiceMatcher.identify(vector, profiles: unknown), cohortHasExpected: false, source: "unknown-holdout"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    struct ReplayReference: Codable { var segmentID: String; var expected: String; var confidence: String; var labels: [String: Double] }
    struct ReplayResult: Codable { var meetingID: String; var threshold: Float; var withProfiles: Bool; var regionCount: Int; var speakerCount: Int; var unknownSeconds: Double; var elapsed: Double; var references: [ReplayReference]; var labels: [String] }
    static func replayEvidence(_ path: String, output: String) throws {
        let evidence = try JSONDecoder().decode(MatchingEvidence.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var results: [ReplayResult] = []
        for meetingID in Set(evidence.turns.map { $0.reference.meetingID }).sorted() {
            let turns = evidence.turns.filter { $0.reference.meetingID == meetingID }
            var regions = evidence.meetings?.first { $0.meetingID == meetingID }?.regions ?? turns.flatMap(\.regions)
            var seen = Set<String>()
            regions = regions.filter { seen.insert("\($0.start):\($0.end)").inserted }.sorted { $0.start < $1.start }
            let segments = regions.map { region -> TranscriptSegment in
                var segment = TranscriptSegment(start: region.start, end: region.end, speaker: TranscriptSegment.unidentifiedSpeaker, text: "fixture")
                segment.embedding = region.embedding; return segment
            }
            let profiles = matchingProfiles(evidence.profiles.filter { $0.meetingID.uuidString != meetingID }, extracted: true)
            for threshold: Float in [0.55, 0.60, 0.65] {
                for withProfiles in [false, true] {
                    let began = Date()
                    let assigned = SpeakerClustering.assign(segments, profiles: withProfiles ? profiles : [], threshold: threshold)
                    let elapsed = Date().timeIntervalSince(began)
                    let refs = turns.map { turn -> ReplayReference in
                        let ref = turn.reference
                        var labels: [String: Double] = [:]
                        for segment in assigned {
                            let duration = min(segment.end, min(ref.end, ref.start + 8)) - max(segment.start, ref.start)
                            if duration > 0 { labels[segment.speaker, default: 0] += duration }
                        }
                        return ReplayReference(segmentID: ref.segmentID, expected: ref.expected, confidence: ref.confidence, labels: labels)
                    }
                    results.append(ReplayResult(meetingID: meetingID, threshold: threshold, withProfiles: withProfiles,
                        regionCount: assigned.count, speakerCount: Set(assigned.filter { $0.speaker != TranscriptSegment.unidentifiedSpeaker }.map(\.speaker)).count,
                        unknownSeconds: assigned.filter { $0.speaker == TranscriptSegment.unidentifiedSpeaker }.reduce(0) { $0 + $1.end - $1.start }, elapsed: elapsed,
                        references: refs, labels: assigned.map(\.speaker)))
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw PisyaError.message("Usage: probe manifest.json speaker-model-directory output.json") }
        if CommandLine.arguments[1] == "--replay" {
            try replayEvidence(CommandLine.arguments[2], output: CommandLine.arguments[3]); return
        }
        if CommandLine.arguments[1] == "--match" {
            try matchEvidence(CommandLine.arguments[2], output: CommandLine.arguments[3]); return
        }
        let began = Date()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = URL(fileURLWithPath: manifest.root)
        let engine = try SpeakerEngine(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        let profiles = try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: root.appendingPathComponent(manifest.profiles)))
        var extracted: [ProfileVector] = []
        for profile in profiles {
            for example in profile.examples ?? [] {
                let samples = try read(root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file).path)
                extracted.append(ProfileVector(name: profile.name, meetingID: example.meetingID, segmentID: example.segmentID, file: example.file, stored: example.embedding, extracted: engine.vector(samples)))
            }
        }
        try JSONEncoder().encode(extracted).write(to: URL(fileURLWithPath: CommandLine.arguments[3] + ".profiles.json"), options: .atomic)
        var turns: [Turn] = []
        var windows: [String: [VoiceRegion]] = [:]
        var windowStarts: [String: Double] = [:]
        var windowMeetings: [String: String] = [:]
        if let path = manifest.windowCache {
            let cached = try JSONDecoder().decode([CachedWindow].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for row in cached {
                windows[row.key] = row.regions.map { VoiceRegion(start: $0.start, end: $0.end, embedding: $0.embedding) }
                windowStarts[row.key] = row.start; windowMeetings[row.key] = row.meetingID
            }
        }
        func checkpoint() throws {
            let rows = windows.keys.sorted().map { key in CachedWindow(key: key, meetingID: windowMeetings[key]!, start: windowStarts[key]!,
                regions: windows[key]!.map { Region(start: $0.start, end: $0.end, embedding: $0.embedding, speaker: "") }) }
            try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: CommandLine.arguments[3] + ".windows.json"), options: .atomic)
        }
        if manifest.allWindows == true {
            for group in Dictionary(grouping: manifest.references, by: \.meetingID).values {
                let ref = group[0]
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: ref.audio))
                let duration = Double(file.length) / file.processingFormat.sampleRate
                for start in stride(from: 0.0, to: duration, by: 60) {
                    let key = ref.audio + ":" + String(start)
                    if windows[key] != nil { continue }
                    windows[key] = diarize(try read(ref.audio, start: start, end: min(duration, start + 60)), engine: engine)
                    windowStarts[key] = start; windowMeetings[key] = ref.meetingID
                    if windows.count % 10 == 0 { try checkpoint() }
                    FileHandle.standardError.write(Data("Extracted window \(windows.count)\n".utf8))
                }
            }
        }
        try checkpoint()
        for ref in manifest.references + (manifest.unconfirmed ?? []) {
            let direct = engine.vector(try read(ref.audio, start: ref.start, end: ref.end))
            let window = floor(ref.start / 60) * 60
            let key = ref.audio + ":" + String(window)
            if windows[key] == nil { windows[key] = diarize(try read(ref.audio, start: window, end: window + 60), engine: engine) }
            windowStarts[key] = window; windowMeetings[key] = ref.meetingID
            let regions = windows[key]!.filter { $0.end + window > ref.start && $0.start + window < ref.end }.map {
                Region(start: $0.start + window, end: $0.end + window, embedding: $0.embedding, speaker: "")
            }
            let preview = engine.vector(try read(ref.audio, start: ref.start, end: min(ref.end, ref.start + 8)))
            // Exclude every example from the evaluated meeting, not only the
            // reference segment, so enrollment cannot leak into recognition.
            let eligible = extracted.filter { $0.meetingID.uuidString != ref.meetingID }
            let storedProfiles = matchingProfiles(eligible, extracted: false)
            let extractedProfiles = matchingProfiles(eligible, extracted: true)
            turns.append(Turn(reference: ref, direct: direct, preview: preview,
                storedMatch: preview.flatMap { VoiceMatcher.identify($0, profiles: storedProfiles) },
                extractedMatch: preview.flatMap { VoiceMatcher.identify($0, profiles: extractedProfiles) }, regions: regions))
            FileHandle.standardError.write(Data("Extracted reference \(turns.count)\n".utf8))
        }
        try checkpoint()
        var meetingResults: [MeetingResult] = []
        // Each physical region contributes once, even when multiple references
        // overlap it. All windows of one meeting share the production clustering.
        for meetingID in Set(turns.map { $0.reference.meetingID }).sorted() {
            let keys = windows.keys.filter { windowMeetings[$0] == meetingID }.sorted { windowStarts[$0]! < windowStarts[$1]! }
            var segments: [TranscriptSegment] = []
            for key in keys { for region in windows[key]! {
                let start = windowStarts[key]!
                var segment = TranscriptSegment(start: start + region.start, end: start + region.end, speaker: TranscriptSegment.unidentifiedSpeaker, text: "fixture")
                segment.embedding = region.embedding; segments.append(segment)
            } }
            let labeled = SpeakerClustering.assign(segments, profiles: [])
            let regions = labeled.map { Region(start: $0.start, end: $0.end, embedding: $0.embedding, speaker: $0.speaker) }
            meetingResults.append(MeetingResult(meetingID: meetingID, windows: keys.count, regions: regions))
            for t in turns.indices where turns[t].reference.meetingID == meetingID {
                let ref = turns[t].reference
                let eligible = extracted.filter { $0.meetingID.uuidString != ref.meetingID }
                let cohort = matchingProfiles(eligible, extracted: true)
                turns[t].regions = regions.filter { $0.end > ref.start && $0.start < ref.end }.map { region in
                    var labeled = region
                    labeled.identified = region.embedding.flatMap { VoiceMatcher.identify($0, profiles: cohort) }
                    return labeled
                }
            }
        }
        let output = Output(profiles: extracted, turns: turns, meetings: meetingResults, elapsed: Date().timeIntervalSince(began))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    }
}
