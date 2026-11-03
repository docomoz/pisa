import Foundation

/// Conservative duplicate gate, not acoustic echo cancellation. Raw tracks are retained.
/// Input is mono 16 kHz; reference starts 350 ms before the microphone region.
public enum EchoDetector {
    public static func sameWords(_ microphone: String, _ reference: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let mic = words(microphone), ref = words(reference)
        guard mic.count >= 4 else { return false }
        // Exact contiguous words: never discard a new word or an overlapping response.
        guard ref.count >= mic.count else { return false }
        return (0...(ref.count - mic.count)).contains { Array(ref[$0..<$0 + mic.count]) == mic }
    }
    public static func isEcho(microphone: [Float], reference: [Float]) -> Bool {
        func reduce(_ input: [Float]) -> [Double] {
            stride(from: 0, to: input.count - 3, by: 4).map { i in
                (Double(input[i]) + Double(input[i+1]) + Double(input[i+2]) + Double(input[i+3])) / 4
            }
        }
        guard microphone.count >= 16000, reference.count >= microphone.count + 5600 else { return false }
        let mic = reduce(microphone), ref = reduce(reference)
        let block = 2000 // Every half-second must match; protect double-talk.
        var activeBlocks = 0
        for start in stride(from: 0, to: mic.count, by: block) {
            let count = min(block, mic.count - start)
            guard count >= 800 else { continue }
            let energy = mic[start..<start+count].reduce(0) { $0 + $1 * $1 }
            guard energy / Double(count) > 0.000001 else { continue }
            var best = 0.0
            for lag in 0...1400 {
                var dot = 0.0, referenceEnergy = 0.0
                for i in 0..<count {
                    let r = ref[start + lag + i]
                    dot += mic[start + i] * r
                    referenceEnergy += r * r
                }
                if referenceEnergy > 0.000001 {
                    best = max(best, abs(dot) / sqrt(energy * referenceEnergy))
                }
            }
            guard best >= 0.94 else { return false }
            activeBlocks += 1
        }
        return activeBlocks >= 2
    }
}
