import Foundation
import AVFoundation

/// Metadata captured atomically on AudioCapture's writer queue. `frames` is an
/// upper bound published only after writes succeed, not a CAF header estimate.
struct CaptureTrackBoundary: Sendable {
    let url: URL
    let offset: Double
    let frames: Int64
    let sampleRate: Double
}

struct CaptureWindowFile: Sendable {
    let url: URL
    let original: URL
    let offset: Double
}

enum CaptureWindow {
    /// Copies only the already-written prefix. Called off the capture queue;
    /// an incomplete or unreadable snapshot fails without advancing the cursor.
    static func copy(_ tracks: [CaptureTrackBoundary], start: Double, end: Double, directory: URL) throws -> [CaptureWindowFile] {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw PisaError.message("Некорректный диапазон аудио") }
        var outputs: [CaptureWindowFile] = []
        do {
            for track in tracks {
                guard track.offset.isFinite, track.offset >= 0, track.sampleRate.isFinite, track.sampleRate > 0, track.frames >= 0 else { throw PisaError.message("Некорректная граница аудио") }
                let lower = min(track.frames, max(0, Int64(floor((start - track.offset) * track.sampleRate))))
                let upper = min(track.frames, max(0, Int64(ceil((end - track.offset) * track.sampleRate))))
                guard upper > lower else { continue }
                let reader = try AVAudioFile(forReading: track.url)
                guard reader.processingFormat.sampleRate == track.sampleRate, reader.length >= upper else { throw PisaError.message("Аудио ещё не готово для чтения") }
                reader.framePosition = lower
                let originalName = track.url.lastPathComponent
                let suffix = originalName.contains("-mic.") ? "-mic.caf" : "-remote.caf"
                let destination = directory.appendingPathComponent(UUID().uuidString + suffix)
                let format = reader.processingFormat
                outputs.append(CaptureWindowFile(url: destination, original: track.url, offset: track.offset + Double(lower) / track.sampleRate))
                let writer = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                defer { writer.close() }
                var remaining = upper - lower
                while remaining > 0 {
                    let count = AVAudioFrameCount(min(remaining, 4096))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw PisaError.message("Не удалось подготовить аудио") }
                    try reader.read(into: buffer, frameCount: count)
                    guard buffer.frameLength > 0 else { throw PisaError.message("Аудио ещё не готово для чтения") }
                    try writer.write(from: buffer)
                    remaining -= Int64(buffer.frameLength)
                }
            }
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output.url) }
            throw error
        }
    }
}
