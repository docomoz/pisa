import XCTest
@testable import PisaCore

final class SpeechModelFilesTests: XCTestCase {
    private func folder(config: [String: Any], files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        for name in files { try Data([1]).write(to: root.appendingPathComponent(name)) }
        return root
    }

    func testLegacyQwenDoesNotMakeParakeetReady() throws {
        let url = try folder(config: ["model_type": "qwen3_asr"],
            files: ["model.safetensors", "tokenizer_config.json", "vocab.json", "merges.txt"])
        XCTAssertTrue(SpeechModelFiles.isUsable(at: url, kind: .qwen))
        XCTAssertFalse(SpeechModelFiles.isUsable(at: url, kind: .parakeet))
    }

    func testParakeetRequiresRussianVocabularyAndWeights() throws {
        var config: [String: Any] = [
            "target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel",
            "decoding": ["model_type": "tdt"],
            "preprocessor": ["sample_rate": 16000, "features": 128],
            "joint": ["vocabulary": ["▁hello", "▁Привет"]],
        ]
        let url = try folder(config: config, files: ["model.safetensors"])
        XCTAssertTrue(SpeechModelFiles.isUsable(at: url, kind: .parakeet))
        XCTAssertFalse(SpeechModelFiles.isUsable(at: url, kind: .qwen))
        config["joint"] = ["vocabulary": ["▁hello"]]
        try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        XCTAssertFalse(SpeechModelFiles.isUsable(at: url, kind: .parakeet))
        config["joint"] = ["vocabulary": ["▁hello", "▁Привет"]]
        try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(SpeechModelFiles.isUsable(at: url, kind: .parakeet))
    }

    func testOldVerifierPreferenceDoesNotSelectPrimaryModel() throws {
        var previous = Preferences()
        previous.modelBookmark = Data([1, 2, 3])
        previous.modelDisplayPath = "/custom/Qwen"
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(previous))
        XCTAssertEqual(decoded.modelBookmark, previous.modelBookmark)
        XCTAssertEqual(decoded.modelDisplayPath, previous.modelDisplayPath)
        XCTAssertNil(decoded.parakeetModelBookmark)
        XCTAssertNil(decoded.parakeetModelDisplayPath)
    }

    func testPrimaryAndVerifierPreferencesRoundTripIndependently() throws {
        var preferences = Preferences()
        preferences.modelBookmark = Data([1])
        preferences.modelDisplayPath = "/custom/Qwen"
        preferences.parakeetModelBookmark = Data([2])
        preferences.parakeetModelDisplayPath = "/custom/Parakeet"
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.modelBookmark, Data([1]))
        XCTAssertEqual(decoded.parakeetModelBookmark, Data([2]))
        XCTAssertEqual(decoded.modelDisplayPath, "/custom/Qwen")
        XCTAssertEqual(decoded.parakeetModelDisplayPath, "/custom/Parakeet")
    }
}
