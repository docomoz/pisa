import AVFoundation
import Foundation

struct EchoAlignment {
    struct Point { var time: Double; var delay: Double }
    let points: [Point]
    func delay(at time: Double) -> Double {
        points.last(where: { $0.time <= time })?.delay ?? points.first?.delay ?? 0
    }
    /// Positive acoustic delay means that earlier playback explains the current mic.
    static func referencePosition(microphonePosition: Int64, offset: Double, referenceOffset: Double, delay: Double, margin: Double = 0.1) -> Int64 {
        microphonePosition + Int64(((offset - referenceOffset - delay + margin) * 16000).rounded())
    }
    static func estimate(microphone: AVAudioFile, reference: AVAudioFile, offset: Double, referenceOffset: Double,
                         denseProbes: Bool = false,
                         progress: @escaping @Sendable (Double, String) async -> Void) async throws -> EchoAlignment {
        let length = Double(microphone.length) / 16000
        var probes: [(time: Double, evidence: EchoAnalysis.Evidence)] = []
        func probe(_ t: Double, duration: Double = 3) throws -> EchoAnalysis.Evidence {
            let m = try AcousticEcho.frame(microphone, at: Int64(t * 16000), count: Int(duration * 16000))
            let r = try AcousticEcho.frame(reference, at: Int64((t + offset - referenceOffset - 2) * 16000), count: Int((duration + 4) * 16000))
            return EchoAnalysis.measure(EchoAnalysis.downsample(m), EchoAnalysis.downsample(r))
        }
        // Live transcription ordinarily supplies only 15 seconds at a time.
        // Probe adjacent, non-overlapping windows there so a quiet opening
        // does not consume the evidence needed for the entire window.
        let probeInterval = denseProbes || length <= 30 ? 3.0 : 5.0
        for t in stride(from: 0.0, to: max(0, length - 1), by: probeInterval) {
            try Task.checkCancellation()
            let evidence = try probe(t, duration: min(3, length - t))
            if evidence.possibleAlignment { probes.append((t + 1.5, evidence)) }
            if Int(t) % 30 == 0 { await progress(t / max(1, length), "Выравниваю дорожки · \(timecode(t))") }
        }
        var points: [Point] = []
        // A weak peak alone can be chance correlation during double-talk. A
        // stable lag in three disjoint windows can still align the AEC render
        // reference, including when the playback clock runs behind the mic.
        var supported = Set(probes.indices.filter { probes[$0].evidence.reliableAlignment })
        for index in probes.indices.dropFirst(2) {
            let triple = probes[(index - 2)...index]
            let delays = triple.map(\.evidence.delay)
            if probes[index].time - probes[index - 2].time <= 15,
               delays.max()! - delays.min()! <= 0.06 {
                supported.formUnion(triple.indices)
            }
        }
        var previous: (time: Double, evidence: EchoAnalysis.Evidence)?
        for index in probes.indices where supported.contains(index) {
            let candidate = probes[index]
            defer { previous = candidate }
            guard let prior = previous, candidate.time - prior.time <= 15,
                  abs(candidate.evidence.delay - prior.evidence.delay) <= 0.04 else { continue }
            let newDelay = (candidate.evidence.delay + prior.evidence.delay) / 2
            guard let last = points.last else { points.append(Point(time: 0, delay: newDelay)); continue }
            if abs(newDelay - last.delay) < 0.025 { continue }
            if abs(newDelay - last.delay) > 0.08 {
                // Locate a real discontinuity; mixed/uncertain windows are not evidence.
                let lower = max(last.time, prior.time - 7)
                var boundary = prior.time
                for t in stride(from: max(0, lower), through: prior.time, by: 0.25) {
                    try Task.checkCancellation()
                    let e = try probe(t, duration: 1)
                    if e.reliableAlignment && abs(e.delay - newDelay) < 0.04 { boundary = t; break }
                }
                // Large windows establish that a jump is real. A short comparison
                // of the two already-known lags locates its actual sample boundary.
                func score(_ t: Double, _ d: Double) throws -> Float {
                    let m = try AcousticEcho.frame(microphone, at: Int64(t * 16000), count: 1920)
                    let r = try AcousticEcho.frame(reference, at: Int64((t + offset - referenceOffset - d - 0.01) * 16000), count: 2240)
                    return EchoAnalysis.measure(EchoAnalysis.downsample(m), EchoAnalysis.downsample(r), margin: 0.01).correlation
                }
                var newEvidence: Double?
                for t in stride(from: max(0, boundary - 1), through: min(length - 0.12, boundary + 1), by: 0.02) {
                    try Task.checkCancellation()
                    let oldScore = try score(t, last.delay), newScore = try score(t, newDelay)
                    if newScore >= 0.28 && newScore > oldScore + 0.15 {
                        if let first = newEvidence { boundary = first + 0.06; break }
                        newEvidence = t
                    } else { newEvidence = nil }
                }
                points.append(Point(time: max(last.time + 0.02, boundary), delay: newDelay))
            } else { points.append(Point(time: prior.time, delay: newDelay)) }
        }
        return EchoAlignment(points: points)
    }
}
