enum SpeechCoverage {
    /// Combine adjacent VAD detections only while their span remains bounded.
    static func joinNearby(_ speech: [Range<Int>], maximumGap: Int, maximumLength: Int,
                           shortTurnLength: Int = 0, maximumShortTurnGap: Int? = nil) -> [Range<Int>] {
        let ranges = speech.filter { $0.lowerBound >= 0 && !$0.isEmpty }.sorted {
            $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound
        }
        let gapLimit = max(0, maximumGap)
        var result: [Range<Int>] = []
        var lastOriginal: Range<Int>?
        for range in ranges {
            defer { lastOriginal = range }
            if let last = result.last {
                let upper = max(last.upperBound, range.upperBound)
                let gap = max(0, range.lowerBound - last.upperBound)
                let shortPair = lastOriginal.map { $0.count <= shortTurnLength || range.count <= shortTurnLength } ?? false
                let allowedGap = shortPair ? min(gapLimit, max(0, maximumShortTurnGap ?? gapLimit)) : gapLimit
                if gap <= allowedGap && upper - last.lowerBound <= maximumLength {
                    result[result.count - 1] = last.lowerBound..<upper
                    continue
                }
            }
            result.append(range)
        }
        return result
    }

    /// Extend an existing decode window through no more than half a gap to
    /// neighboring speech. Preserve the existing padding even on overlaps.
    static func safeExpansion(region: Range<Int>, base: Range<Int>, previousEnd: Int, nextStart: Int,
                              sampleCount: Int, maximumPadding: Int) -> Range<Int>? {
        let padding = max(0, maximumPadding)
        let before = min(padding, max(0, region.lowerBound - previousEnd) / 2)
        let after = min(padding, max(0, nextStart - region.upperBound) / 2)
        let lower = min(base.lowerBound, max(0, region.lowerBound - before))
        let upper = max(base.upperBound, min(sampleCount, region.upperBound + after))
        guard lower < base.lowerBound || upper > base.upperBound else { return nil }
        return lower..<upper
    }

    /// Speech detected by VAD but not already covered by a speaker region.
    /// Preserve an isolated short answer, while discarding tiny remnants of
    /// partially covered ranges that may consist entirely of VAD padding.
    static func uncovered(speech: [Range<Int>], covered: [Range<Int>], sampleCount: Int,
                          minimumPartialLength: Int) -> [Range<Int>] {
        let activity = clippedUnion(speech, sampleCount: sampleCount)
        let occupied = clippedUnion(covered, sampleCount: sampleCount)
        let minimum = max(1, minimumPartialLength)
        var result: [Range<Int>] = []
        var firstOccupied = 0
        for region in activity {
            while firstOccupied < occupied.count && occupied[firstOccupied].upperBound <= region.lowerBound {
                firstOccupied += 1
            }
            let overlaps = occupied[firstOccupied...].prefix { $0.lowerBound < region.upperBound }
            if overlaps.isEmpty {
                result.append(region)
                continue
            }
            var cursor = region.lowerBound
            for block in overlaps {
                if block.lowerBound - cursor >= minimum {
                    result.append(cursor..<block.lowerBound)
                }
                cursor = max(cursor, block.upperBound)
            }
            if region.upperBound - cursor >= minimum {
                result.append(cursor..<region.upperBound)
            }
        }
        return result
    }

    private static func clippedUnion(_ ranges: [Range<Int>], sampleCount: Int) -> [Range<Int>] {
        let clipped = ranges.compactMap { range -> Range<Int>? in
            let lower = max(0, range.lowerBound)
            let upper = min(sampleCount, range.upperBound)
            return lower < upper ? lower..<upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in clipped {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
