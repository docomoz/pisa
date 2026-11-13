import Accelerate
import Foundation

/// Measurements on original microphone/playback signals, never on AEC output.
enum EchoAnalysis {
    struct Evidence {
        var correlation: Float
        var coherence: Float
        var delay: Double
        var peakRatio: Float = 0
        var reliableAlignment: Bool { correlation >= 0.28 && coherence >= 0.65 && peakRatio >= 1.12 }
    }
    static func downsample(_ input: [Float]) -> [Float] {
        guard input.count >= 8 else { return [] }
        let count = 64
        var taps = (0..<count).map { i -> Float in
            let t = Double(i) - Double(count - 1) / 2
            let sinc = abs(t) < 1e-9 ? 0.1125 : sin(2 * .pi * 0.05625 * t) / (.pi * t)
            return Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(count - 1))))
        }
        let sum = taps.reduce(0, +); taps = taps.map { $0 / sum }
        let padded = [Float](repeating: 0, count: 32) + input + [Float](repeating: 0, count: 64)
        var output = [Float](repeating: 0, count: input.count / 8)
        vDSP_desamp(padded, 8, taps, &output, vDSP_Length(output.count), vDSP_Length(taps.count))
        return output
    }
    /// Both inputs are 2 kHz; reference starts `margin` seconds before microphone.
    static func measure(_ mic: [Float], _ ref: [Float], margin: Double = 2) -> Evidence {
        guard mic.count >= 128, ref.count >= mic.count else { return Evidence(correlation: 0, coherence: 0, delay: 0) }
        var energy: Float = 0
        vDSP_dotpr(mic, 1, mic, 1, &energy, vDSP_Length(mic.count))
        var best: Float = 0, bestLag = 0
        var scores = [Float](repeating: 0, count: ref.count - mic.count + 1)
        mic.withUnsafeBufferPointer { m in ref.withUnsafeBufferPointer { r in
            // Prefix sums avoid recalculating the reference energy for every lag.
            var power = [Double](repeating: 0, count: ref.count + 1)
            for i in ref.indices { power[i + 1] = power[i] + Double(ref[i] * ref[i]) }
            func value(at lag: Int) -> Float {
                var dot: Float = 0
                vDSP_dotpr(m.baseAddress!, 1, r.baseAddress! + lag, 1, &dot, vDSP_Length(mic.count))
                return abs(dot) / sqrt(max(1e-20, energy * Float(power[lag + mic.count] - power[lag])))
            }
            for lag in stride(from: 0, through: ref.count - mic.count, by: 2) {
                let value = value(at: lag)
                scores[lag] = value
                if value > best { best = value; bestLag = lag }
            }
            for lag in max(0, bestLag - 2)...min(ref.count - mic.count, bestLag + 2) {
                let value = value(at: lag)
                if value > best { best = value; bestLag = lag }
            }
        } }
        let other = scores.enumerated().filter { abs($0.offset - bestLag) > 80 }.map(\.element).max() ?? 0
        return Evidence(correlation: best, coherence: coherence(mic, Array(ref[bestLag..<bestLag + mic.count])), delay: margin - Double(bestLag) / 2000, peakRatio: best / max(0.00001, other))
    }
    static func coherence(_ mic: [Float], _ ref: [Float]) -> Float {
        let n = 256, hop = 128
        guard mic.count >= n * 4, ref.count >= mic.count,
              let fft = vDSP_create_fftsetup(8, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(fft) }
        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var xx = [Float](repeating: 0, count: n / 2), yy = xx, crossR = xx, crossI = xx
        var frames: Float = 0
        func spectrum(_ samples: [Float], _ start: Int) -> ([Float], [Float]) {
            var real = (0..<n).map { samples[start + $0] * hann[$0] }, imag = [Float](repeating: 0, count: n)
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(fft, &split, 1, 8, FFTDirection(kFFTDirection_Forward))
            } }
            return (real, imag)
        }
        for start in stride(from: 0, through: mic.count - n, by: hop) {
            let (mr, mi) = spectrum(mic, start), (rr, ri) = spectrum(ref, start)
            for b in 12..<116 { // 94–906 Hz: robust speech-band evidence after downsampling.
                xx[b] += rr[b] * rr[b] + ri[b] * ri[b]
                yy[b] += mr[b] * mr[b] + mi[b] * mi[b]
                crossR[b] += rr[b] * mr[b] + ri[b] * mi[b]
                crossI[b] += rr[b] * mi[b] - ri[b] * mr[b]
            }
            frames += 1
        }
        var explained: Float = 0, total: Float = 0
        let floor = (xx.max() ?? 0) * 0.0001
        for b in 12..<116 where xx[b] > max(1e-12, floor) {
            // Remove the finite-sample chance-coherence bias.
            let predicted = (crossR[b] * crossR[b] + crossI[b] * crossI[b]) / xx[b]
            explained += max(0, predicted - yy[b] / max(1, frames))
            total += yy[b] * (1 - 1 / max(2, frames))
        }
        return min(1, explained / max(1e-12, total))
    }
}
