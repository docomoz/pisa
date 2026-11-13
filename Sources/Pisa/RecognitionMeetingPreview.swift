import Foundation
import AVFoundation

/// Explicit, local diagnostics for one user-selected meeting. Reads originals;
/// emits a snapshot/optional bounded PCM clips to stdout without saving a meeting.
enum RecognitionMeetingPreview {
    private struct Request: Decodable {
        var meetingID: UUID?
        var title: String?
        var start: Double?
        var end: Double?
    }

    static func run() throws {
        let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard request.meetingID != nil || request.title?.isEmpty == false else { throw PisaError.message("Select one meeting") }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa")
        let library = try MeetingLibrary(root: root)
        // A bounded preview by ID must not read unrelated recordings.
        let matches = try request.meetingID.map { [try library.read($0)] }
            ?? library.all().filter { $0.title.localizedCaseInsensitiveContains(request.title!) }
        guard matches.count == 1, let meeting = matches.first else {
            throw PisaError.message("Expected one matching meeting, found \(matches.count)")
        }
        let preferences = try library.preferences()
        var output: [String: Any] = [
            "meeting": try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)),
            "vocabulary": preferences.vocabulary
        ]
        if let start = request.start, let end = request.end {
            guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 120 else {
                throw PisaError.message("Preview must contain at most 120 seconds")
            }
            var clips: [[String: Any]] = []
            for name in meeting.audioFiles {
                let url = try library.audioURL(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let offset = meeting.audioOffsets[name] ?? 0
                let samples = try read(url, start: start - offset, end: end - offset)
                guard !samples.isEmpty else { continue }
                clips.append(["name": name, "track": name.contains("-mic.") ? "mic" : "remote",
                              "processed": name.contains(".clean."), "start": max(start, offset), "samples": samples])
            }
            output["clips"] = clips
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static func read(_ url: URL, start: Double, end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let lower = min(file.length, max(0, AVAudioFramePosition(start * rate)))
        let upper = min(file.length, max(0, AVAudioFramePosition(end * rate)))
        guard upper > lower else { return [] }
        file.framePosition = lower
        let input = try PCMRead.exact(file, frames: AVAudioFrameCount(upper - lower))
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) / rate * 16000) + 64)) else {
            throw PisaError.message("Cannot read preview audio")
        }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .endOfStream; return nil }
            delivered = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
