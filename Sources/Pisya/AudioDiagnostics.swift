import Foundation
import AVFoundation

enum AudioDiagnostics {
    static func run() throws {
        print("microphone_permission", AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
        print("input", AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisya/Audio")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.contains("-mic.") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for url in files.prefix(4) {
            guard let file = try? AVAudioFile(forReading: url) else { print("unreadable_track", url.lastPathComponent); continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { continue }
            var peak: Float = 0, sum: Double = 0; var count = 0
            while file.framePosition < file.length {
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                if let data = buffer.floatChannelData {
                    for c in 0..<Int(buffer.format.channelCount) { for f in 0..<Int(buffer.frameLength) {
                        let v = data[c][f * buffer.stride]; peak = max(peak, abs(v)); sum += Double(v*v); count += 1
                    } }
                }
            }
            print("track", url.lastPathComponent, "seconds", Double(file.length)/file.fileFormat.sampleRate, "peak",peak,"rms",sqrt(sum/Double(max(1,count))))
        }
    }
}
