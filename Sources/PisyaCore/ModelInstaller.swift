import Foundation
import CryptoKit

public struct ModelAsset: Codable, Sendable {
    public let path: String
    public let url: URL
    public let sha256: String
    public let bytes: Int64?
    public init(path: String, url: URL, sha256: String, bytes: Int64? = nil) {
        self.path = path; self.url = url; self.sha256 = sha256; self.bytes = bytes
    }
}

public enum ModelInstallError: LocalizedError {
    case invalidManifest, checksum(String), http(Int), insufficientSpace
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Не удалось прочитать список моделей. Установите свежую версию Pisya"
        case .checksum(let name): return "Файл \(name) загрузился с ошибкой. Повторите загрузку"
        case .http(let code): return "Сервер моделей ответил с ошибкой \(code). Попробуйте позже"
        case .insufficientSpace: return "Для моделей нужно около 3 ГБ свободного места. Освободите место на Mac и повторите загрузку"
        }
    }
}

public struct ModelInstallProgress: Sendable {
    public let path: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let downloadedBytes: Int64
    public let expectedBytes: Int64
    public let verifying: Bool
    public var fraction: Double {
        expectedBytes > 0 ? min(1, Double(downloadedBytes) / Double(expectedBytes)) : Double(completedFiles) / Double(max(1, totalFiles))
    }
}

/// Installs only authenticated files, replacing each destination atomically after validation.
/// The caller owns the task, so canceling it also cancels the current network request.
public struct ModelInstaller: Sendable {
    public typealias Download = @Sendable (ModelAsset, URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void
    public let root: URL
    public let assets: [ModelAsset]
    private let download: Download
    public init(root: URL, assets: [ModelAsset], download: @escaping Download = { asset, destination, progress in
        try await NativeModelDownload.fetch(asset.url, to: destination, progress: progress)
    }) { self.root = root; self.assets = assets; self.download = download }

    public func isReady() async throws -> Bool {
        try validateManifest()
        for asset in assets {
            try Task.checkCancellation()
            guard try verified(root.appendingPathComponent(asset.path), asset: asset) else { return false }
        }
        return true
    }

    public func install(progress: @escaping @Sendable (ModelInstallProgress) -> Void = { _ in }) async throws {
        try validateManifest()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A temporary replacement needs space alongside an existing corrupt model.
        let missing = try assets.filter { try !verified(root.appendingPathComponent($0.path), asset: $0) }
        let missingPaths = Set(missing.map(\.path))
        let needed = missing.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, needed > 0, capacity < needed || capacity - needed < 200_000_000 { throw ModelInstallError.insufficientSpace }
        let expected = assets.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        var completedBytes: Int64 = 0
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(asset.path)
            let baseBytes = completedBytes
            if missingPaths.contains(asset.path) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pisya-download-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await download(asset, temporary) { received, total in
                    progress(ModelInstallProgress(path: asset.path, completedFiles: index, totalFiles: assets.count, downloadedBytes: baseBytes + received, expectedBytes: expected > 0 ? expected : total, verifying: false))
                }
                try Task.checkCancellation()
                progress(ModelInstallProgress(path: asset.path, completedFiles: index, totalFiles: assets.count, downloadedBytes: baseBytes + (asset.bytes ?? 0), expectedBytes: expected, verifying: true))
                guard try verified(temporary, asset: asset) else { throw ModelInstallError.checksum(asset.path) }
                try Task.checkCancellation()
                // POSIX rename atomically replaces files on the same volume and preserves the old
                // destination until the complete, verified replacement is available.
                guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            completedBytes += asset.bytes ?? 0
            progress(ModelInstallProgress(path: asset.path, completedFiles: index + 1, totalFiles: assets.count, downloadedBytes: completedBytes, expectedBytes: expected, verifying: false))
        }
    }

    private func validateManifest() throws {
        guard !assets.isEmpty, Set(assets.map(\.path)).count == assets.count else { throw ModelInstallError.invalidManifest }
        for asset in assets {
            let components = asset.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  asset.url.scheme == "https", asset.url.host != nil,
                  asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit }), (asset.bytes ?? 1) > 0 else { throw ModelInstallError.invalidManifest }
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let parent = root.appendingPathComponent(asset.path).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard parent.hasPrefix(canonicalRoot) else { throw ModelInstallError.invalidManifest }
        }
    }
    private func verified(_ url: URL, asset: ModelAsset) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { return false }
        if let expected = asset.bytes, Int64(info.fileSize ?? -1) != expected { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256.lowercased()
    }
}

/// A download delegate keeps large files off the heap and reports actual byte progress.
public final class NativeModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.destination = destination; self.progress = progress }
    public static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let transfer = NativeModelDownload(destination: destination, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 24 * 60 * 60
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.lock.lock()
                transfer.continuation = continuation
                let task = session.downloadTask(with: url)
                transfer.task = task
                let cancelled = transfer.cancelled
                transfer.lock.unlock()
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: { transfer.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else { throw ModelInstallError.http(response.statusCode) }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch { result = .failure(error) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let cancelled = cancelled; lock.unlock()
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(with: result ?? .failure(URLError(.badServerResponse))) }
    }
}
