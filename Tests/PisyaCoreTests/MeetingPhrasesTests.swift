import XCTest
@testable import PisyaCore

final class MeetingPhrasesTests: XCTestCase {
    func testGeneratedPhrasesAreLongEnoughAndDoNotRepeatImmediately() {
        var generator = MeetingPhraseGenerator()
        var previous = generator.next()
        for _ in 0..<2_000 {
            let current = generator.next()
            XCTAssertGreaterThanOrEqual(current.count, 75, current)
            XCTAssertGreaterThanOrEqual(current.split(whereSeparator: \.isWhitespace).count, 10, current)
            XCTAssertNotEqual(current, previous)
            previous = current
        }
    }

    func testCuratedPhrasesAreLongAndDoNotRepeatUntilTheDeckIsExhausted() {
        var generator = MeetingPhraseGenerator()
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.curated.count, 100)
        var seen = Set<String>()
        var last = ""
        for _ in MeetingPhraseGenerator.curated {
            let phrase = generator.nextCurated()
            XCTAssertTrue(seen.insert(phrase).inserted, phrase)
            XCTAssertGreaterThanOrEqual(phrase.count, 75, phrase)
            XCTAssertGreaterThanOrEqual(phrase.split(whereSeparator: \.isWhitespace).count, 10, phrase)
            last = phrase
        }
        XCTAssertNotEqual(generator.nextCurated(), last)
    }

    func testDisplayedPhrasesUseReviewedCorpusAndDoNotRepeatWithinOneCycle() {
        var generator = MeetingPhraseGenerator()
        var seen = Set<String>()
        for _ in MeetingPhraseGenerator.curated {
            let phrase = generator.next()
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(phrase), phrase)
            XCTAssertTrue(seen.insert(phrase).inserted, phrase)
        }
        XCTAssertEqual(seen.count, MeetingPhraseGenerator.curated.count)
    }

    func testConsecutivePhrasesVaryTheirOpeningWhenPossible() {
        var generator = MeetingPhraseGenerator()
        var remaining = Set(MeetingPhraseGenerator.curated)
        var previousOpening: String?
        for _ in MeetingPhraseGenerator.curated {
            let phrase = generator.next()
            let opening = String(phrase.split(whereSeparator: \.isWhitespace).first ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let previousOpening, remaining.contains(where: { candidate in
                String(candidate.split(whereSeparator: \.isWhitespace).first ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters) != previousOpening
            }) {
                XCTAssertNotEqual(opening, previousOpening, phrase)
            }
            remaining.remove(phrase)
            previousOpening = opening
        }
    }

    func testReviewedPhrasesHaveNoTrailingFullStop() {
        for phrase in MeetingPhraseGenerator.curated {
            XCTAssertFalse(phrase.hasSuffix("."), phrase)
        }
    }
}
