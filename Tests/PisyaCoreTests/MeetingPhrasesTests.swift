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
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.curated.count, 60)
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

    func testCuratedPartsFormACompleteSentence() {
        XCTAssertEqual(
            MeetingPhraseGenerator.compose(opening: "Если сделать шаг назад,", lead: "нам нужно", action: "обсудить", object: "воронку согласований", ending: "чтобы у всех сложилась единая картинка"),
            "Если сделать шаг назад, нам нужно обсудить воронку согласований, чтобы у всех сложилась единая картинка"
        )
    }

    func testOutputNeverUsesIncompatibleInterrogativeOpeningOrStandaloneAside() {
        var generator = MeetingPhraseGenerator()
        for _ in 0..<2_000 {
            let phrase = generator.next()
            XCTAssertFalse(phrase.hasPrefix("Я правильно понимаю, что"), phrase)
            XCTAssertFalse(phrase.hasPrefix("Есть ощущение, что"), phrase)
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(phrase) || MeetingPhraseGenerator.openings.contains { phrase.hasPrefix($0 + " ") }, phrase)
        }
    }

    func testPhrasesAreAssembledOnlyFromCuratedVerbAndObjectGroups() {
        var generator = MeetingPhraseGenerator()
        for _ in 0..<2_000 {
            let phrase = generator.next()
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(phrase) || MeetingPhraseGenerator.groups.contains { group in
                group.actions.contains { action in group.objects.contains { phrase.contains(" \(action) \($0), ") } }
            }, phrase)
        }
    }
}
