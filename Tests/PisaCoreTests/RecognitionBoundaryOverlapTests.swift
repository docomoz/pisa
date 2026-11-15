import XCTest
@testable import PisaCore

final class RecognitionBoundaryOverlapTests: XCTestCase {
    private let left = [RecognitionTimedWord(text: "эти", start: 1.5, end: 1.9),
                        RecognitionTimedWord(text: "данные", start: 1.9, end: 2.15)]
    private let right = [RecognitionTimedWord(text: "данные", start: 2.0, end: 2.4),
                         RecognitionTimedWord(text: "уже", start: 2.4, end: 2.6)]
    private let whole = [RecognitionTimedWord(text: "эти", start: 1.5, end: 1.95),
                         RecognitionTimedWord(text: "данные", start: 1.95, end: 2.3),
                         RecognitionTimedWord(text: "уже", start: 2.3, end: 2.6)]

    private func resolve(_ words: [RecognitionTimedWord], leftText: String = "Все эти данные",
                         rightText: String = "Данные, уже готовы", shared: Range<Double> = 1.88..<2.12,
                         leftWords: [RecognitionTimedWord]? = nil, rightWords: [RecognitionTimedWord]? = nil) -> String? {
        RecognitionBoundaryOverlap.revisedRight(left: leftText, right: rightText,
            leftWords: leftWords ?? left, rightWords: rightWords ?? right, unionWords: words,
            cut: 2, sharedAudio: shared)
    }

    func testOnePhysicalWordCrossingTheCutIsRetainedOnce() {
        XCTAssertEqual(resolve(whole), "уже готовы")
    }

    func testTwoRealRepeatedWordsArePreserved() {
        let repeated = [whole[0], RecognitionTimedWord(text: "данные", start: 1.85, end: 2.05),
                        RecognitionTimedWord(text: "данные", start: 2.05, end: 2.3), whole[2]]
        XCTAssertNil(resolve(repeated))
        XCTAssertNil(RecognitionBoundaryOverlap.candidate(left: "Ну да", right: "Да, всё верно"))
    }

    func testASeparateLaterOccurrenceIsNotRemoved() {
        let later = whole + [RecognitionTimedWord(text: "данные", start: 4, end: 4.5)]
        XCTAssertEqual(resolve(later, rightText: "Данные, уже готовы, данные проверены"), "уже готовы, данные проверены")
    }

    func testPunctuationAndCaseDoNotBecomePartOfTheWord() {
        XCTAssertEqual(resolve(whole, leftText: "Все эти «данные»", rightText: "«ДАННЫЕ», уже готовы"), "уже готовы")
        XCTAssertNil(resolve(whole, rightText: "Данных уже достаточно"))
    }

    func testCanonicalUnicodeFormsMatchWithoutFuzzySpelling() {
        XCTAssertEqual(RecognitionBoundaryOverlap.candidate(left: "Наш объём", right: "Объе\u{0308}м уже известен"), "объём")
        XCTAssertNil(RecognitionBoundaryOverlap.candidate(left: "Самым первым", right: "Первоу у нас нет"))
    }

    func testMissingOrContradictoryAcousticEvidencePreservesText() {
        XCTAssertNil(resolve([]))
        XCTAssertNil(resolve(whole, leftWords: []))
        XCTAssertNil(resolve(whole, rightWords: [RecognitionTimedWord(text: "другие", start: 2, end: 2.4), right[1]]))
        var changed = whole
        changed[2] = RecognitionTimedWord(text: "ещё", start: 2.3, end: 2.6)
        XCTAssertNil(resolve(changed))
    }

    func testNoSharedAudioOrWordNotCrossingTheCutCannotTriggerRemoval() {
        XCTAssertNil(resolve(whole, shared: 3..<4))
        var changed = whole
        changed[1] = RecognitionTimedWord(text: "данные", start: 2.01, end: 2.3)
        XCTAssertNil(resolve(changed))
    }

    func testNumbersAndAttachedCompoundPartsAreNeverRemoved() {
        XCTAssertNil(RecognitionBoundaryOverlap.candidate(left: "Выросло до 2026", right: "2026% уже много"))
        XCTAssertNil(RecognitionBoundaryOverlap.candidate(left: "Город Санкт", right: "Санкт-Петербург уже подключён"))
        XCTAssertNil(RecognitionBoundaryOverlap.candidate(left: "Город Санкт-Петербург", right: "Петербург уже подключён"))
    }

    func testMultiwordQuotesAndBracketsKeepTheirOpeningPunctuation() {
        XCTAssertNil(resolve(whole, rightText: "«Данные уже готовы»"))
        XCTAssertNil(resolve(whole, rightText: "(Данные уже готовы)"))
        XCTAssertEqual(resolve(whole, rightText: "(Данные), уже готовы"), "уже готовы")
        XCTAssertEqual(resolve(whole, rightText: "\"Данные\", уже готовы"), "уже готовы")
    }

    func testSingleWordRepliesCannotDisappear() {
        XCTAssertNil(resolve(whole, rightText: "Данные"))
        XCTAssertNil(resolve(whole, leftText: "Данные"))
    }
}
