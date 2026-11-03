import Foundation

/// Preserve host-clock gaps in the PCM timeline so both tracks stay aligned.
public enum AudioTimeline {
    public static func adjustment(timestamp: Double, firstTimestamp: Double, framesWritten: Int64, sampleRate: Double) -> Int64 {
        guard timestamp.isFinite, firstTimestamp.isFinite, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let delta = (timestamp - firstTimestamp) * sampleRate - Double(framesWritten)
        guard delta.isFinite, abs(delta) < Double(Int64.max) else { return 0 }
        return abs(delta) >= sampleRate * 0.01 ? Int64(delta.rounded()) : 0
    }
}
