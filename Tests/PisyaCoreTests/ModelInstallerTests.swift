import XCTest
import CryptoKit
@testable import PisyaCore

final class ModelInstallerTests: XCTestCase {
    private let payload = Data("verified model fixture".utf8)
    private func fixture() throws -> (URL, ModelAsset) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let asset = ModelAsset(path: "Qwen3-ASR/model.safetensors", url: URL(string: "https://example.com/model")!, sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        return (root, asset)
    }
    func testInstallsVerifiedFileAndDoesNotRedownloadExistingValidModel() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = payload
        let installer = ModelInstaller(root: root, assets: [asset]) { _, destination, progress in
            try data.write(to: destination); progress(Int64(data.count), Int64(data.count))
        }
        let ready = try await installer.isReady(); XCTAssertFalse(ready)
        try await installer.install()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(asset.path)), payload)
        let existing = ModelInstaller(root: root, assets: [asset]) { _, _, _ in XCTFail("Valid models must be reused") }
        try await existing.install()
        let readyAfter = try await existing.isReady(); XCTAssertTrue(readyAfter)
    }
    func testCorruptDownloadNeverReplacesExistingFileAndRetryRepairsIt() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(asset.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("old incomplete model".utf8); try original.write(to: destination)
        let broken = ModelInstaller(root: root, assets: [asset]) { _, temporary, _ in try Data("corrupt".utf8).write(to: temporary) }
        do { try await broken.install(); XCTFail("Corrupt file accepted") } catch { XCTAssertTrue(error is ModelInstallError) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let ready = try await broken.isReady(); XCTAssertFalse(ready)
        let data = payload
        try await ModelInstaller(root: root, assets: [asset]) { _, temporary, _ in try data.write(to: temporary) }.install()
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [destination.lastPathComponent])
    }
    func testCancellationRemovesPartialFileAndRetainsCompletedFilesForRetry() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let second = ModelAsset(path: "Speakers/model.onnx", url: asset.url, sha256: asset.sha256)
        let data = payload
        let task = Task {
            try await ModelInstaller(root: root, assets: [asset, second]) { item, temporary, _ in
                try data.write(to: temporary)
                if item.path == second.path { throw CancellationError() }
            }.install()
        }
        do { try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(asset.path)), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.path).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Speakers").path), [])
        try await ModelInstaller(root: root, assets: [asset, second]) { _, temporary, _ in try data.write(to: temporary) }.install()
    }
    func testRejectsManifestTraversalBeforeWritingOutsideModels() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let traversal = ModelAsset(path: "../escaped", url: asset.url, sha256: asset.sha256)
        let installer = ModelInstaller(root: root, assets: [traversal]) { _, _, _ in XCTFail("Unsafe manifest reached network") }
        do { try await installer.install(); XCTFail("Traversal accepted") } catch { XCTAssertTrue(error is ModelInstallError) }
    }
    func testReadinessRejectsMissingOrChangedFiles() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let data = payload
        let installer = ModelInstaller(root: root, assets: [asset]) { _, temporary, _ in try data.write(to: temporary) }
        try await installer.install()
        try Data(repeating: 0, count: payload.count).write(to: root.appendingPathComponent(asset.path))
        let readyChanged = try await installer.isReady(); XCTAssertFalse(readyChanged)
        try await installer.install()
        try FileManager.default.removeItem(at: root.appendingPathComponent(asset.path))
        let readyMissing = try await installer.isReady(); XCTAssertFalse(readyMissing)
    }
    func testNetworkFailureCleansPartialAndCanRetry() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let broken = ModelInstaller(root: root, assets: [asset]) { _, temporary, _ in
            try Data("partial".utf8).write(to: temporary); throw URLError(.networkConnectionLost)
        }
        do { try await broken.install(); XCTFail("Network failure ignored") } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Qwen3-ASR").path), [])
        let data = payload
        try await ModelInstaller(root: root, assets: [asset]) { _, temporary, _ in try data.write(to: temporary) }.install()
    }
    func testChecksFreeSpaceBeforeStartingDownload() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let huge = ModelAsset(path: asset.path, url: asset.url, sha256: asset.sha256, bytes: 1_000_000_000_000_000)
        do {
            try await ModelInstaller(root: root, assets: [huge]) { _, _, _ in XCTFail("Download started without enough free space") }.install()
            XCTFail("Capacity check ignored")
        } catch { guard case ModelInstallError.insufficientSpace = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    func testRejectsSymlinkedDestinationDirectory() async throws {
        let (root, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Qwen3-ASR"), withDestinationURL: outside)
        do {
            try await ModelInstaller(root: root, assets: [asset]) { _, _, _ in XCTFail("Symlink escaped model directory") }.install()
            XCTFail("Directory symlink accepted")
        } catch { XCTAssertTrue(error is ModelInstallError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

}
