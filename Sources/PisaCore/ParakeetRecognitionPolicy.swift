import Foundation

/// Text evidence routes conservative Russian repairs; it is not an ASR
/// language label. Foreign sentences are never translated by this policy.
enum ParakeetRecognitionPolicy {
    static func hasRussianTextEvidence(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Distinct Ukrainian/Belarusian letters are positive evidence against
        // treating a supported foreign utterance as Russian.
        if lower.contains(where: { "іїєґў".contains($0) }) {
            // A minority foreign name must not veto clear Russian evidence in
            // the surrounding turn. Without that evidence, abstain.
            let words = lower.split(whereSeparator: { !$0.isLetter })
            guard words.contains(where: { word in
                !word.contains(where: { "іїєґў".contains($0) })
                    && word.contains(where: { "ыэъё".contains($0) })
            }) else { return false }
        }
        return lower.unicodeScalars.contains { (0x430...0x44F).contains($0.value) || $0.value == 0x451 }
    }

    static func verifierDirectory(explicit: URL?, speakerDirectory: URL) -> URL {
        explicit ?? speakerDirectory.deletingLastPathComponent().appendingPathComponent(SpeechModelFiles.verifierDirectoryName)
    }

    static func verifierCheckpointFiles(directory: URL, speakerDirectory: URL) -> [URL] {
        let managed = verifierDirectory(explicit: nil, speakerDirectory: speakerDirectory)
        var names = ["config.json", "model.safetensors", "tokenizer_config.json", "vocab.json", "merges.txt"]
        // Managed Qwen ships the pinned tokenizer sources. Its loader creates
        // tokenizer.json lazily; that derived file must not invalidate resume.
        // A custom folder can contain an authored tokenizer, which stays part
        // of its identity even when source vocab/merges are also supplied.
        if directory.standardizedFileURL != managed.standardizedFileURL { names.append("tokenizer.json") }
        return names.map { directory.appendingPathComponent($0) }
    }

    static let checkpointVariants = [
        "primary": ["parakeet-tdt-v3", "weights-float32", "audio-float32"],
        "verifier": ["qwen-selective"]
    ]
}
