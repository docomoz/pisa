import XCTest
@testable import PisyaCore

final class MeetingPhrasesTests: XCTestCase {
    func testGeneratedPhrasesAreNonemptyAndDoNotRepeatImmediately() {
        var generator = MeetingPhraseGenerator()
        var previous = generator.next()
        XCTAssertFalse(previous.isEmpty)
        for _ in 0..<1_000 {
            let current = generator.next()
            XCTAssertFalse(current.isEmpty)
            XCTAssertNotEqual(current, previous)
            previous = current
        }
    }

    func testCatalogueRetainsOriginalsAndExpandsEachPart() {
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.openings.count, 72)
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.actions.count, 66)
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.objects.count, 72)
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.endings.count, 63)
        XCTAssertTrue(MeetingPhraseGenerator.openings.contains("Если зумнуть аут,"))
        XCTAssertTrue(MeetingPhraseGenerator.actions.contains("нам надо зачелленджить"))
        XCTAssertTrue(MeetingPhraseGenerator.objects.contains("стратегию стратегии"))
        XCTAssertTrue(MeetingPhraseGenerator.endings.contains("и вернуться с этим на следующей синке."))
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.asides.count, 102)
        XCTAssertTrue(MeetingPhraseGenerator.asides.contains("Я хочу домой. Я дома."))
    }

    func testDisplayPunctuationForSingleAndMultipleSentences() {
        XCTAssertEqual(MeetingPhraseGenerator.displayText("Сейчас бы в отпуск."), "Сейчас бы в отпуск")
        XCTAssertEqual(MeetingPhraseGenerator.displayText("Я хочу домой. Я дома."), "Я хочу домой. Я дома.")
    }
}
