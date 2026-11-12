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

    func testPersonalizedPhrasesAreSpacedAndUseEachKnownTermOncePerCycle() {
        let terms = ["cOnFlUeNcE", "kpi", "ChatGPT"]
        let vocabulary = "  cOnFlUeNcE; kpi\nChatGPT, KPI"
        var generator = MeetingPhraseGenerator()
        var remaining = Set(terms)
        for index in 1...16 {
            let phrase = generator.next(vocabulary: vocabulary)
            if [4, 8, 12].contains(index) {
                XCTAssertFalse(MeetingPhraseGenerator.curated.contains(phrase), phrase)
                let matched = remaining.filter { phrase.contains($0) }
                XCTAssertEqual(matched.count, 1, phrase)
                remaining.subtract(matched)
            } else {
                XCTAssertTrue(MeetingPhraseGenerator.curated.contains(phrase), phrase)
            }
        }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testBuiltInUnknownAndPartialEntriesKeepTheStandardDeck() {
        let vocabulary = Preferences().vocabulary + ", КПРС-25; Confluence Next; KPI общий"
        var generator = MeetingPhraseGenerator()
        for _ in 0..<12 {
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(generator.next(vocabulary: vocabulary)))
        }
    }

    func testVocabularyChangesApplyToTheNextPhrase() {
        var generator = MeetingPhraseGenerator()
        for _ in 0..<3 { _ = generator.next(vocabulary: "Confluence") }
        XCTAssertTrue(MeetingPhraseGenerator.curated.contains(generator.next(vocabulary: "")))
        let next = generator.next(vocabulary: "ChatGPT")
        XCTAssertFalse(MeetingPhraseGenerator.curated.contains(next), next)
        XCTAssertTrue(next.contains("ChatGPT"), next)
    }

    func testAlternateSpellingsShareOneSlotAndReturnInTheNextCycle() {
        let vocabulary = "P&L, PNL"
        var generator = MeetingPhraseGenerator()
        let firstCycle = (0...MeetingPhraseGenerator.curated.count).map { _ in
            generator.next(vocabulary: vocabulary)
        }
        let personalized = firstCycle.filter { !MeetingPhraseGenerator.curated.contains($0) }
        XCTAssertEqual(personalized.count, 1)
        XCTAssertTrue(personalized.first?.contains("P&L") == true)

        let nextCycle = (0..<4).map { _ in generator.next(vocabulary: "PNL") }
        XCTAssertEqual(nextCycle.filter { $0.contains("PNL") }.count, 1)
    }
}
