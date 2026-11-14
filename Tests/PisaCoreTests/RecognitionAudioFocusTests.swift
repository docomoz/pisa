import XCTest
@testable import PisaCore

final class RecognitionAudioFocusTests: XCTestCase {
    private func target(_ text: String, _ needle: String) -> Range<String.Index> { text.range(of: needle)! }
    private func words(_ values: [(String, Double, Double)]) -> [RecognitionTimedWord] {
        values.map { RecognitionTimedWord(text: $0.0, start: $0.1, end: $0.2) }
    }
    func testMissingTargetUsesSurroundingAudioAnchors() {
        let text = "один два три тайна четыре пять шесть"
        let timed = words([("один", 0.5, 0.8), ("два", 1, 1.2), ("три", 1.3, 1.6), ("четыре", 3, 3.3), ("пять", 3.4, 3.6), ("шесть", 3.7, 4)])
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "тайна")], words: timed, duration: 10), [0..<4.5])
    }
    func testInterveningWordsAndCaseFold() {
        let text = "одна две три Ёлка четыре пять шесть"
        let timed = words([("одна", 0, 0.1), ("две", 0.2, 0.4), ("три", 0.5, 0.7), ("другое", 1, 1.3), ("четыре", 2, 2.3), ("пять", 2.4, 2.6), ("шесть", 2.7, 2.9)])
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "Ёлка")], words: timed, duration: 3), [0..<3])
    }
    func testDuplicateAnchorsFailClosed() {
        let text = "раз два три буква четыре пять шесть"
        let timed = words([("раз", 0, 0.1), ("два", 0.2, 0.3), ("три", 0.4, 0.5), ("раз", 0.6, 0.7), ("два", 0.8, 0.9), ("три", 1, 1.1), ("четыре", 2, 2.2), ("пять", 2.3, 2.4), ("шесть", 2.5, 2.6)])
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "буква")], words: timed, duration: 3).isEmpty)
    }
    func testFallbackToTwoAndRejectLongOrInvalidAudio() {
        let text = "первая вторая цель третья четвёртая"
        let timed = words([("первая", 0, 0.2), ("вторая", 0.3, 0.4), ("третья", 0.5, 0.6), ("четвертая", 0.7, 0.8)])
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "цель")], words: timed, duration: 1), [0..<1])
        var long = timed; long[3] = RecognitionTimedWord(text: "четвертая", start: 13, end: 14)
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "цель")], words: long, duration: 15).isEmpty)
        var invalid = timed; invalid[1] = RecognitionTimedWord(text: "вторая", start: .nan, end: 0.4)
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "цель")], words: invalid, duration: 1).isEmpty)
    }

    func testBoundaryTargetsUseThreeUniqueWordsAndRealAudioEdges() {
        let text = "в названии мы обсуждали этот проект сегодня"
        let timed = words([("в", 0.2, 0.3), ("другом", 0.4, 0.8), ("мы", 1, 1.2),
            ("обсуждали", 1.3, 1.7), ("этот", 1.8, 2), ("проект", 2.1, 2.5), ("вчера", 3, 3.5)])
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "названии")], words: timed, duration: 6), [0..<2.5])
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "сегодня")], words: timed, duration: 6), [0.8..<6])
        let start = "название мы обсуждали этот проект сегодня"
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: start, targets: [target(start, "название")], words: Array(timed.dropFirst()), duration: 6), [0..<2.5])
    }

    func testBoundaryFocusRejectsMissingRepeatedDistantAndShortAnchors() {
        let text = "название мы обсуждали этот проект"
        let timed = words([("иное", 0, 0.4), ("мы", 1, 1.2), ("обсуждали", 1.3, 1.7), ("этот", 1.8, 2)])
        let duplicate = timed + words([("мы", 3, 3.2), ("обсуждали", 3.3, 3.7), ("этот", 3.8, 4)])
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "название")], words: duplicate, duration: 5).isEmpty)
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "название")], words: Array(timed.dropLast()), duration: 5).isEmpty)
        let distant = words((0..<5).map { ("слово", Double($0), Double($0) + 0.5) })
            + words([("мы", 6, 6.2), ("обсуждали", 6.3, 6.7), ("этот", 6.8, 7)])
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "название")], words: distant, duration: 8).isEmpty)
        let leading = "на название мы обсуждали этот проект"
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: leading, targets: [target(leading, "название")], words: timed, duration: 5).isEmpty)
    }

    func testAdjacentRecognitionErrorsCanUseNearbyUniqueAudioAnchors() {
        let text = "мы будем вместе обсуждать эту систему Сбераз название там с нашей командой"
        let timed = words([("мы", 0, 0.2), ("будем", 0.2, 0.4), ("вместе", 0.4, 0.6), ("обсуждать", 0.6, 1),
            ("экосистему", 1, 1.5), ("Сбера", 1.5, 1.8), ("с", 1.8, 2), ("другим", 2, 2.4),
            ("там", 2.4, 2.6), ("с", 2.6, 2.8), ("нашей", 2.8, 3), ("командой", 3, 3.5)])
        XCTAssertEqual(RecognitionAudioFocus.ranges(original: text, targets: [target(text, "название")], words: timed, duration: 5), [0..<3.5])
        let tooFar = "мы будем вместе обсуждать одну давно известную очень большую систему Сбераз название там с нашей командой"
        XCTAssertTrue(RecognitionAudioFocus.ranges(original: tooFar, targets: [target(tooFar, "название")], words: timed, duration: 5).isEmpty)
    }
}
