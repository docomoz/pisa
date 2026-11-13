// Read-only regression against an explicitly supplied private corpus.
// Inputs: voices.json, baseline.json (fresh vectors), purity-files.json, VoiceSamples/.
// Run through run-voice-quality-test.py --purity --manifest <root>/manifest.json.
import Foundation
struct Evidence: Decodable {
    struct Sample: Decodable { var file: String; var extracted: [Float]? }
    var profiles: [Sample]
}
@main enum SavedVoiceQualityProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = URL(fileURLWithPath: CommandLine.arguments[2])
        let files = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("purity-files.json"))))
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: root.appendingPathComponent("baseline.json")))
        let vectors = Dictionary(evidence.profiles.compactMap { sample in sample.extracted.map { (sample.file, $0) } }, uniquingKeysWith: { a, _ in a })
        var profiles = try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: root.appendingPathComponent("voices.json")))
        for index in profiles.indices {
            let examples = (profiles[index].examples ?? []).map { example -> VoiceExample in
                guard let vector = vectors[example.file] else { return example }
                var updated = example.withCurrentEmbedding(vector)
                if files.contains(example.file) { updated.embeddingRevision = 1 }
                return updated
            }
            profiles[index].examples = examples
            profiles[index].samples = examples.map(\.embedding)
        }
        let refreshed = SavedVoiceAudio.refreshedExamples(profiles, folder: root.appendingPathComponent("VoiceSamples"), model: model)
        let rows = refreshed.values.sorted { $0.file < $1.file }
        try JSONEncoder().encode(rows).write(to: root.appendingPathComponent("purity-production-results.json"))
        for example in rows { print(example.file, "excluded", example.excludedFromRecognition == true) }
        guard rows.count == files.count else { throw PisaError.message("Missing assessed clips") }
    }
}
