import Foundation

/// Bound recognition work without cutting a turn at an arbitrary sample.
/// The last four seconds before a limit are searched for a quiet 100 ms gap.
enum SpeechChunking {
    static func ranges(in samples: [Float], range: Range<Int>, sampleRate: Int = 16000,
                       maximumDuration: Double = 24) -> [Range<Int>] {
        guard sampleRate > 0, maximumDuration.isFinite, maximumDuration >= 1,
              range.lowerBound >= 0, range.upperBound <= samples.count, !range.isEmpty else { return [] }
        let limit = Int(maximumDuration * Double(sampleRate))
        var cursor = range.lowerBound
        var result: [Range<Int>] = []
        // A one-second grace keeps an almost complete utterance together. In
        // particular, splitting a trailing year/number destroys its context.
        while range.upperBound - cursor > limit + sampleRate {
            // Do not strand a tiny final fragment that loses its linguistic context.
            let latest = min(cursor + limit, range.upperBound - sampleRate)
            let earliest = max(cursor + sampleRate, latest - 4 * sampleRate)
            let cut = quietBoundary(in: samples, search: earliest..<latest, sampleRate: sampleRate)
            result.append(cursor..<cut)
            cursor = cut
        }
        if cursor < range.upperBound { result.append(cursor..<range.upperBound) }
        return result
    }

    static func quietBoundary(in samples: [Float], search: Range<Int>, sampleRate: Int) -> Int {
        let width = max(1, sampleRate / 10)
        guard search.count >= width else { return search.upperBound }
        let step = max(1, sampleRate / 100)
        var energy = samples[search.lowerBound..<(search.lowerBound + width)].reduce(0.0) { $0 + Double($1) * Double($1) }
        var bestEnergy = energy
        var best = search.lowerBound + width / 2
        var position = search.lowerBound
        for next in stride(from: search.lowerBound + step, through: search.upperBound - width, by: step) {
            for index in position..<next {
                energy -= Double(samples[index]) * Double(samples[index])
                energy += Double(samples[index + width]) * Double(samples[index + width])
            }
            position = next
            // Prefer the later cut when several positions share the same silence.
            if energy <= bestEnergy + 1e-12 {
                bestEnergy = energy; best = next + width / 2
            }
        }
        return best
    }
}
