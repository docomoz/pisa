import Foundation
import CryptoKit

/// Isolated first-run state checks; never opens the real application library.
@MainActor
enum ModelSetupTests {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Setup-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("model fixture".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let assets = ["Qwen3-ASR/model.safetensors", "Speakers/test.onnx"].map {
            ModelAsset(path: $0, url: URL(string: "https://example.com/test")!, sha256: hash, bytes: Int64(data.count))
        }
        for asset in assets {
            let file = root.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(assets).write(to: manifest)
        func wait(_ setup: ModelSetup) async throws {
            for _ in 0..<500 {
                if !setup.busy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw PisyaError.message("Setup operation did not finish")
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw PisyaError.message(message) }
        }
        let managed = ModelSetup(root: root, manifestURL: manifest, customModel: { nil }, usesCustomModel: { false })
        managed.check(presentWhenNeeded: false); try await wait(managed)
        try check(managed.ready, "Verified managed models not ready")
        let missingCustom = root.appendingPathComponent("MissingCustom")
        let invalid = ModelSetup(root: root, manifestURL: manifest, customModel: { missingCustom }, usesCustomModel: { true })
        invalid.check(presentWhenNeeded: false); try await wait(invalid)
        try check(!invalid.ready && !invalid.presented, "Invalid custom model became ready from unrelated defaults or opened a conflicting sheet")
        let custom = root.appendingPathComponent("Custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        for name in ["config.json", "model.safetensors", "tokenizer_config.json", "vocab.json", "merges.txt"] {
            try data.write(to: custom.appendingPathComponent(name))
        }
        try Data("unusable managed model".utf8).write(to: root.appendingPathComponent(assets[0].path))
        let chosen = ModelSetup(root: root, manifestURL: manifest, customModel: { custom }, usesCustomModel: { true })
        chosen.check(presentWhenNeeded: false); try await wait(chosen)
        try check(chosen.ready && chosen.installedUsingCustom, "Usable custom model with verified speakers not honored")
        try FileManager.default.removeItem(at: root.appendingPathComponent(assets[1].path))
        chosen.check(presentWhenNeeded: false); try await wait(chosen)
        try check(!chosen.ready, "Custom model became ready without speaker models")
        chosen.install(onReady: { }); await chosen.cancelAndWait(); try await wait(chosen)
        try check(chosen.phase == .available && !chosen.ready, "Setup cancellation did not reach worker or became ready")
        print("MODEL_SETUP_TEST_OK managed custom invalid_bookmark speaker_readiness cancellation")
    }
}
