import Foundation
import CryptoKit

/// Isolated setup and upgrade checks using a disposable library.
@MainActor
enum ModelSetupTests {
    static func run() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Pisa-Setup-Test-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let primaryName = SpeechModelFiles.primaryDirectoryName
        let verifierName = SpeechModelFiles.verifierDirectoryName
        let managedPrimary = root.appendingPathComponent(primaryName)
        let managedVerifier = root.appendingPathComponent(verifierName)
        let customPrimary = root.appendingPathComponent("CustomParakeet")
        let customVerifier = root.appendingPathComponent("CustomQwen")
        let manifest = root.appendingPathComponent("manifest.json")
        let weights = Data("model fixture".utf8)
        let primaryConfig = Data("""
            {
              "target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel",
              "decoding": {"model_type": "tdt"},
              "preprocessor": {"sample_rate": 16000, "features": 128},
              "joint": {"vocabulary": ["▁hello", "▁Привет"]}
            }
            """.utf8)
        let primaryFiles = [
            "config.json": primaryConfig,
            "model.safetensors": weights,
        ]
        let verifierFiles = [
            "config.json": Data(#"{"model_type":"qwen3_asr"}"#.utf8),
            "model.safetensors": weights,
            "tokenizer_config.json": Data("{}".utf8),
            "vocab.json": Data("{}".utf8),
            "merges.txt": Data("#version: 0.2".utf8),
        ]
        let speakerPath = "Speakers/test.onnx"
        let acousticVerifierPath = "GigaAM-v3/test.onnx"

        func write(_ data: Data, to file: URL) throws {
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        func writeModel(_ modelFiles: [String: Data], to folder: URL) throws {
            for (name, contents) in modelFiles {
                try write(contents, to: folder.appendingPathComponent(name))
            }
        }

        var fixtureFiles = [speakerPath: weights, acousticVerifierPath: weights]
        for (name, contents) in primaryFiles { fixtureFiles["\(primaryName)/\(name)"] = contents }
        for (name, contents) in verifierFiles { fixtureFiles["\(verifierName)/\(name)"] = contents }
        let fixtureURL = URL(string: "https://example.com/test")!
        let assets = try fixtureFiles.sorted { $0.key < $1.key }.map { path, contents in
            try write(contents, to: root.appendingPathComponent(path))
            let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            return ModelAsset(path: path, url: fixtureURL, sha256: hash, bytes: Int64(contents.count))
        }
        try JSONEncoder().encode(assets).write(to: manifest)

        func wait(_ setup: ModelSetup) async throws {
            for _ in 0..<500 {
                if !setup.busy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw PisaError.message("Setup operation did not finish")
        }

        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw PisaError.message(message) }
        }

        func makeSetup(primary: URL? = nil, verifier: URL? = nil) -> ModelSetup {
            ModelSetup(root: root, manifestURL: manifest, customModel: { primary }, usesCustomModel: { primary != nil },
                       customVerifier: { verifier }, usesCustomVerifier: { verifier != nil })
        }

        func refresh(_ setup: ModelSetup) async throws {
            setup.check(presentWhenNeeded: false)
            try await wait(setup)
        }

        let managed = makeSetup()
        try await refresh(managed)
        try check(managed.ready && !managed.installedUsingCustom && !managed.installedUsingCustomVerifier,
                  "Verified managed primary and verifier not ready")

        let unresolvedPrimary = ModelSetup(root: root, manifestURL: manifest, customModel: { nil }, usesCustomModel: { true })
        try await refresh(unresolvedPrimary)
        try check(unresolvedPrimary.phase == .available && !unresolvedPrimary.presented && !unresolvedPrimary.installedUsingCustom,
                  "Unresolved primary bookmark accepted the managed model or opened a conflicting sheet")

        let missingPrimary = makeSetup(primary: root.appendingPathComponent("MissingCustom"))
        try await refresh(missingPrimary)
        try check(missingPrimary.phase == .available && !missingPrimary.presented && !missingPrimary.installedUsingCustom,
                  "Missing custom primary became ready from unrelated defaults")

        try files.removeItem(at: managedPrimary)
        try await refresh(managed)
        try check(managed.phase == .available && !managed.presented, "Legacy managed Qwen became ready without Parakeet")
        let primaryBytes = primaryFiles.values.reduce(Int64(0)) { $0 + Int64($1.count) }
        let upgrade = makeSetup()
        upgrade.check()
        try await wait(upgrade)
        try check(upgrade.presented && upgrade.upgradeDownloadBytes == primaryBytes,
                  "An existing installation did not offer an upgrade sized to the missing Parakeet files")
        upgrade.dismiss()
        try check(!upgrade.presented && !upgrade.ready, "Postponing the upgrade enabled transcription")

        let speakerFile = root.appendingPathComponent(speakerPath)
        try files.removeItem(at: speakerFile)
        try write(primaryConfig, to: managedPrimary.appendingPathComponent("config.json"))
        try await refresh(upgrade)
        try check(upgrade.upgradeDownloadBytes == Int64(weights.count * 2),
                  "A partial upgrade counted installed files or omitted missing speaker files")
        try write(weights, to: speakerFile)

        let fresh = ModelSetup(root: root.appendingPathComponent("Empty"), manifestURL: manifest,
                               customModel: { nil }, usesCustomModel: { false })
        fresh.check()
        try await wait(fresh)
        try check(fresh.presented && fresh.phase == .available && fresh.upgradeDownloadBytes == nil,
                  "A fresh installation was presented as an upgrade")

        try writeModel(primaryFiles, to: customPrimary)
        try writeModel(verifierFiles, to: customVerifier)
        try Data("unmanaged primary weights".utf8).write(to: customPrimary.appendingPathComponent("model.safetensors"))
        try Data("unmanaged verifier weights".utf8).write(to: customVerifier.appendingPathComponent("model.safetensors"))

        let wrongPrimary = makeSetup(primary: customVerifier)
        try await refresh(wrongPrimary)
        try check(wrongPrimary.phase == .available && !wrongPrimary.installedUsingCustom,
                  "Legacy custom Qwen was accepted as the primary model")

        let selectedPrimary = makeSetup(primary: customPrimary)
        try await refresh(selectedPrimary)
        try check(selectedPrimary.ready && selectedPrimary.installedUsingCustom && !selectedPrimary.installedUsingCustomVerifier,
                  "Valid custom primary with the managed verifier was not honored")

        try files.removeItem(at: managedVerifier)
        try await refresh(selectedPrimary)
        try check(selectedPrimary.phase == .available, "A custom primary bypassed the managed verifier check")

        try writeModel(primaryFiles, to: managedPrimary)
        let selectedVerifier = makeSetup(verifier: customVerifier)
        try await refresh(selectedVerifier)
        try check(selectedVerifier.ready && !selectedVerifier.installedUsingCustom && selectedVerifier.installedUsingCustomVerifier,
                  "Valid legacy custom verifier with the managed primary was not honored")

        try files.removeItem(at: managedPrimary)
        try await refresh(selectedVerifier)
        try check(selectedVerifier.phase == .available && selectedVerifier.upgradeDownloadBytes == primaryBytes,
                  "A valid custom Qwen did not qualify for a Parakeet-only upgrade")

        let selectedBoth = makeSetup(primary: customPrimary, verifier: customVerifier)
        try await refresh(selectedBoth)
        try check(selectedBoth.ready && selectedBoth.installedUsingCustom && selectedBoth.installedUsingCustomVerifier,
                  "Primary and verifier custom selections were not applied independently")

        let acousticVerifier = root.appendingPathComponent(acousticVerifierPath)
        try files.removeItem(at: acousticVerifier)
        try await refresh(selectedBoth)
        try check(selectedBoth.phase == .available, "Custom models became ready without the Russian acoustic verifier")
        try write(weights, to: acousticVerifier)

        try files.removeItem(at: root.appendingPathComponent(speakerPath))
        try await refresh(selectedBoth)
        try check(selectedBoth.phase == .available, "Custom models became ready without speaker models")
        var completed = false
        selectedBoth.install(onReady: { completed = true })
        await selectedBoth.cancelAndWait()
        try await wait(selectedBoth)
        try check(selectedBoth.phase == .available && !completed, "Setup cancellation did not join the worker")
        print("MODEL_SETUP_TEST_OK managed legacy_qwen custom_primary custom_verifier invalid_bookmark speaker_readiness russian_readiness cancellation")
    }
}
