import XCTest
@testable import PisaCore

final class SpokenVocabularyPerformanceTests: XCTestCase {
    func testPronunciationNormalizationPreservesOrdinarySpeechInLongMixedTurn() {
        let vocabulary = SpokenVocabulary("YClients, Retail Media, API", pronunciations: """
        clients K L AY1 AH0 N T S
        retail R IY1 T EY2 L
        media M IY1 D IY0 AH0
        """)
        let untouched = "Вчера весь день обсуждали расчёт и проверяли отчёт. Сегодня по дороге записали вопросы для коллег."
        let spoken = "На встрече обсудили ритейл медиа, согласовали эй пи ай и сохранили список в iклаинсе."
        let normalized = "На встрече обсудили Retail Media, согласовали API и сохранили список в YClients."
        XCTAssertEqual(vocabulary.apply(to: "\(untouched) \(spoken) \(untouched)"),
                       "\(untouched) \(normalized) \(untouched)")
    }
}
