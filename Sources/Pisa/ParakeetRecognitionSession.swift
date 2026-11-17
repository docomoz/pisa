import Foundation
import MLX
import MLXAudioSTT

/// Actor-confined models for one meeting/live session. Parakeet always owns the
/// first pass; Qwen is loaded only after a concrete verification plan exists.
final class ParakeetRecognitionSession {
    let primary: ParakeetModel
    let primaryDirectory: URL
    let verifierDirectory: URL
    private let scopedVerifierDirectory: URL
    private let verifierScopeGranted: Bool
    private var loadedVerifier: Qwen3ASRModel?
    private(set) var verifierLoadCount = 0
    private(set) var verifierLoadSeconds: Double = 0
    let primaryLoadSeconds: Double
    private let verifierConfigured: Bool
    private(set) var verifierLoadFailures = 0
    private var verifierUnavailable = false
    struct VerifierUnavailable: Error {}
    var canVerify: Bool { verifierConfigured && !verifierUnavailable }

    init(primaryDirectory: URL, verifierDirectory: URL) throws {
        self.primaryDirectory = primaryDirectory.standardizedFileURL
        self.verifierDirectory = verifierDirectory.standardizedFileURL
        scopedVerifierDirectory = verifierDirectory
        let granted = verifierDirectory.startAccessingSecurityScopedResource()
        verifierScopeGranted = granted
        verifierConfigured = SpeechModelFiles.isUsable(at: verifierDirectory, kind: .qwen)
        let began = ProcessInfo.processInfo.systemUptime
        do {
            primary = try ParakeetModel.fromDirectory(primaryDirectory, computeDType: .float32)
        } catch {
            if granted { verifierDirectory.stopAccessingSecurityScopedResource() }
            throw error
        }
        primaryLoadSeconds = ProcessInfo.processInfo.systemUptime - began
    }

    deinit {
        if verifierScopeGranted { scopedVerifierDirectory.stopAccessingSecurityScopedResource() }
    }

    func verifier() async throws -> Qwen3ASRModel {
        try Task.checkCancellation()
        if let loadedVerifier { return loadedVerifier }
        guard canVerify else { throw VerifierUnavailable() }
        let began = ProcessInfo.processInfo.systemUptime
        verifierLoadCount += 1
        defer { verifierLoadSeconds += ProcessInfo.processInfo.systemUptime - began }
        let model: Qwen3ASRModel
        do {
            model = try await Qwen3ASRModel.fromModelDirectory(verifierDirectory)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A broken optional verifier must not discard a successful primary
            // pass, nor be loaded again for every remaining speech region.
            verifierUnavailable = true
            verifierLoadFailures += 1
            throw VerifierUnavailable()
        }
        loadedVerifier = model
        try Task.checkCancellation()
        return model
    }

    // Language is intentionally nil: Parakeet echoes this parameter without
    // detecting/conditioning language. Never treat its default "en" as evidence.
    static var primaryParameters: STTGenerateParameters {
        STTGenerateParameters(language: nil, chunkDuration: 30)
    }

    func generate(_ samples: [Float]) -> STTOutput {
        primary.generate(audio: MLXArray(samples),
                         generationParameters: Self.primaryParameters)
    }
}
