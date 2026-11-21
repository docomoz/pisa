import XCTest
@testable import PisaCore

final class RecognitionTrailingFragmentTests: XCTestCase {
    private func proposal(source: String = "Сегодня не", last: String = "носим",
                          start: Double = 0.74, end: Double = 0.96) -> RecognitionTrailingFragment? {
        let evidence = RecognitionAcousticResult(text: "Сегодня " + last + ".", words: [
            RecognitionTimedWord(text: "Сегодня", start: 0.05, end: start),
            RecognitionTimedWord(text: last, start: start, end: end)])
        return RecognitionTrailingFragment(source: source, acoustic: evidence, core: 2000..<13440, sampleCount: 16000)
    }

    func testOnlyTheRightPaddingIntroducesTheDisputedWord() throws {
        let fragment = try XCTUnwrap(proposal())
        XCTAssertTrue(fragment.matchesCore("Сегодня."))
        XCTAssertFalse(fragment.matchesCore(nil))
        XCTAssertEqual(fragment.confirmedText(padded: "сегодня носим", paddedLanguage: "Russian",
            exact: "сегодня.", exactLanguage: "Russian"), "Сегодня")
    }

    func testGenuineFinalNegationCountsAsSpeechInEitherModel() throws {
        XCTAssertNil(proposal(last: "не"))
        let fragment = try XCTUnwrap(proposal())
        XCTAssertFalse(fragment.matchesCore("Сегодня не"))
        XCTAssertNil(fragment.confirmedText(padded: "Сегодня не", paddedLanguage: "Russian",
            exact: "сегодня", exactLanguage: "Russian"))
        XCTAssertNil(fragment.confirmedText(padded: "Сегодня носим", paddedLanguage: "Russian",
            exact: "сегодня не", exactLanguage: "Russian"))
    }

    func testNoDeletionOnDistantWordOrUnreliableTimings() {
        XCTAssertNil(proposal(start: 0.25))
        XCTAssertNil(proposal(start: 0.76, end: 0.85))
        XCTAssertNil(proposal(start: 0.76, end: 1.5))
        XCTAssertNil(proposal(start: .nan))
        XCTAssertNil(proposal(source: "Завтра не"))
        XCTAssertNil(proposal(last: "ходим"))
        XCTAssertNil(proposal(source: "«Сегодня не»"))
    }
}
