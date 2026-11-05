import XCTest
@testable import PisyaCore

final class RussianRecognitionTests: XCTestCase {
    func testOnlyRussianUtterancesWithDifferentWordsAreRechecked() {
        XCTAssertTrue(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Поговорили с Анной и Столей", alternative: "Поговорили с Анной и с Толей"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "English", duration: 4, original: "We talked about the launch", alternative: "Мы говорили о запуске"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 1, original: "Да", alternative: "Ну да"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Всё готово, да.", alternative: "Все готово — да!"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Обсудили сроки запуска", alternative: ""))
    }

    func testUnrelatedOrInvalidAlternativesDoNotBiasRecognition() {
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Обсудили сроки запуска проекта", alternative: "Да"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Обсудили сроки запуска проекта", alternative: "Обсудили сроки запуска 项目"))
    }

    func testRecheckPreservesRecognizedVocabularyPhrases() {
        let original = "Проверим Северный Атлас и Геопэй в четверг"
        XCTAssertFalse(RussianRecognition.accepts(candidate: "Проверим северный адрес и геопий в четверг", original: original, vocabulary: "Северный Атлас, Геопэй"))
        XCTAssertTrue(RussianRecognition.accepts(candidate: "Проверим Северный Атлас и Геопэй уже в четверг.", original: original, vocabulary: "Северный Атлас, Геопэй"))
        XCTAssertTrue(RussianRecognition.accepts(candidate: "Проверим сроки запуска уже в четверг.", original: "Проверим сроки запуска в четверг", vocabulary: "Северный Атлас, Геопэй"))
    }

    func testARecheckCannotReplaceSpeechWithEmptyForeignOrTruncatedText() {
        let original = "Мы договорились проверить показатели перед запуском нового проекта"
        for text in ["", "Мы договорились", "Мы договорились проверить показатели перед запуском 新项目"] {
            XCTAssertFalse(RussianRecognition.accepts(candidate: text, original: original, vocabulary: ""))
        }
    }

    func testVocabularyMatchingUsesWholeWordsAndPhrases() {
        XCTAssertTrue(RussianRecognition.accepts(candidate: "На улице уже наступила весна", original: "На улице уже наступила весна", vocabulary: "Ли, Нау"))
        XCTAssertFalse(RussianRecognition.accepts(candidate: "Проверим новый атлас сегодня", original: "Проверим Северный Атлас сегодня", vocabulary: "Северный Атлас\nГеопэй"))
    }
}
