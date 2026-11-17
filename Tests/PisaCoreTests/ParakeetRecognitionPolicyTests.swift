import XCTest
@testable import PisaCore

final class ParakeetRecognitionPolicyTests: XCTestCase {
    func testRussianEvidenceDoesNotComeFromDecoderLanguageDefault() {
        for text in ["Проверим LLM'ки завтра", "Серёжа встретился со Сбером", "угу", "Да, вылазию", "Мы с Євгеном обсудили два ГИСа и выпустили новый релиз"] {
            XCTAssertTrue(ParakeetRecognitionPolicy.hasRussianTextEvidence(text), text)
        }
        for text in ["Let's review the API tomorrow", "OK, sure", "123", "", "перевіримо зміни завтра", "Καλημέρα"] {
            XCTAssertFalse(ParakeetRecognitionPolicy.hasRussianTextEvidence(text), text)
        }
    }

    func testCustomPrimaryDoesNotRedirectManagedVerifier() {
        let speakers = URL(fileURLWithPath: "/managed/Models/Speakers")
        XCTAssertEqual(ParakeetRecognitionPolicy.verifierDirectory(explicit: nil, speakerDirectory: speakers).path,
                       "/managed/Models/Qwen3-ASR")
        let custom = URL(fileURLWithPath: "/custom/verification")
        XCTAssertEqual(ParakeetRecognitionPolicy.verifierDirectory(explicit: custom, speakerDirectory: speakers), custom)
    }

    func testEngineIdentityDistinguishesPrimaryAndVerifierRoles() {
        XCTAssertEqual(ParakeetRecognitionPolicy.checkpointVariants["primary"], ["parakeet-tdt-v3", "weights-float32", "audio-float32"])
        XCTAssertEqual(ParakeetRecognitionPolicy.checkpointVariants["verifier"], ["qwen-selective"])
    }

    func testCheckpointRejectsOldEngineAndChangedVerifierWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.caf")
        let verifier = root.appendingPathComponent("verifier.safetensors")
        try Data([1]).write(to: audio)
        try Data([2]).write(to: verifier)
        func inputs(_ variants: [String: [String]]) throws -> BatchTranscriptionCheckpoint.Inputs {
            try BatchTranscriptionCheckpoint.Inputs(files: [(audio, 0)], model: root,
                vocabulary: "Сбер", variants: variants, supportingModels: [verifier])
        }
        let old = try inputs([:])
        let current = try inputs(ParakeetRecognitionPolicy.checkpointVariants)
        XCTAssertNotEqual(old, current)
        try Data([2, 3]).write(to: verifier)
        XCTAssertNotEqual(current, try inputs(ParakeetRecognitionPolicy.checkpointVariants))
    }


    func testManagedDerivedTokenizerKeepsCheckpointButSourcesAndCustomTokenizerInvalidateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("Qwen3-ASR")
        let custom = root.appendingPathComponent("Custom")
        let speakers = root.appendingPathComponent("Speakers")
        for url in [managed, custom] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.caf")
        try Data([1]).write(to: audio)
        func inputs(_ directory: URL) throws -> BatchTranscriptionCheckpoint.Inputs {
            try BatchTranscriptionCheckpoint.Inputs(files: [(audio, 0)], model: root,
                vocabulary: "", variants: ParakeetRecognitionPolicy.checkpointVariants,
                supportingModels: ParakeetRecognitionPolicy.verifierCheckpointFiles(directory: directory, speakerDirectory: speakers))
        }
        let vocab = managed.appendingPathComponent("vocab.json")
        try Data([2]).write(to: vocab)
        let beforeLoad = try inputs(managed)
        try Data([3]).write(to: managed.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(beforeLoad, try inputs(managed))
        try Data([2, 4]).write(to: vocab)
        XCTAssertNotEqual(beforeLoad, try inputs(managed))

        let authored = custom.appendingPathComponent("tokenizer.json")
        try Data([5]).write(to: authored)
        let originalCustom = try inputs(custom)
        try Data([5, 6]).write(to: authored)
        XCTAssertNotEqual(originalCustom, try inputs(custom))
    }

}
