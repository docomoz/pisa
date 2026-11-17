import XCTest
@testable import PisaCore

/// Positive regressions from the model comparison: a verifier's different
/// wording is not ground truth. Preserve primary words independently heard by
/// the acoustic recognizer, including when another local repair is useful.
final class PrimaryRecognitionPreservationTests: XCTestCase {
    func testCorroboratedPrimaryWinsSurviveWorseQwenCandidates() {
        let cases = [
            ("Мы обсудили план с Анжелой и вернёмся завтра.",
             "Мы обсудили план с ангелой и вернёмся завтра."),
            ("Он использовал анализ микровыражений для проверки людей.",
             "Он использовал анализ микро выражений для проверки людей."),
            ("Это воздействует на галактику в Стрельце уже сейчас.",
             "Это воздействует на галактику Стрельца уже сейчас."),
            ("Он был музыкантом, который играл в новоорлеанской группе.",
             "Он был музыкантом, которые играл в наварлянской группе.")
        ]
        for (primary, worse) in cases {
            XCTAssertEqual(RecognitionConsensus.revisedText(original: primary, candidate: worse,
                corroboration: primary, vocabulary: "") ?? primary, primary)
            XCTAssertEqual(RecognitionConsensus.revisedSplitText(original: primary, candidate: worse,
                corroboration: primary, vocabulary: "") ?? primary, primary)
            XCTAssertEqual(RecognitionConsensus.revisedBoundaryText(original: primary, candidate: worse,
                corroboration: primary, vocabulary: "") ?? primary, primary)
            XCTAssertEqual(RussianRecognition.revisedText(original: primary, candidate: worse,
                corroboration: primary, hypothesis: primary, vocabulary: "", usesCyrillicHints: false,
                rawCandidate: worse) ?? primary, primary)
        }
    }

    func testUsefulVerbRepairDoesNotImportVerifiersWorseNeighboringPhrase() {
        let primary = "Этот процесс воздействовать на галактику в Стрельце уже сейчас."
        let independent = "Этот процесс воздействует на галактику в Стрельце уже сейчас."
        let candidate = "Этот процесс воздействует на галактику Стрельца уже сейчас."
        XCTAssertEqual(RecognitionConsensus.revisedText(original: primary, candidate: candidate,
            corroboration: independent, vocabulary: ""), independent)
        let revised = RussianRecognition.revisedText(original: primary, candidate: candidate,
            corroboration: independent, hypothesis: independent, vocabulary: "", usesCyrillicHints: false,
            rawCandidate: candidate) ?? primary
        XCTAssertTrue(revised.contains("на галактику в Стрельце"))
        XCTAssertFalse(revised.contains("на галактику Стрельца"))
    }

    func testContextualDictionaryRepairPreservesAnotherCorroboratedName() throws {
        let primary = "Мы работали в Конторе и обсуждали результаты, а затем встретились с Анжелой."
        let independent = primary.replacingOccurrences(of: "Конторе", with: "Контуре")
        let candidate = independent.replacingOccurrences(of: "Анжелой", with: "ангелой")
        let previous = TranscriptSegment(start: 70, end: 80, speaker: "А", text: "Ранее мы обсуждали работу Контура.")
        let target = TranscriptSegment(start: 100, end: 110, speaker: "А", text: primary)
        let vocabulary = "Контур, Анжела"
        let retry = try XCTUnwrap(RecognitionContext(segments: [previous, target]).plan(for: target,
            independent: independent, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedText(original: primary, candidate: candidate,
            corroboration: independent, retry: retry, vocabulary: vocabulary), independent)
    }
    func testConsensusPreservesCurrencyAndPercentUnits() {
        let cases = [
            ("Мы платим за услуги 48 долларов. Из десяти заявок закрыли семь.", "Мы платим за услуги $48. Из десяти заявок закрыли семь."),
            ("Мы платим за услуги 65 рублей перед началом нового месяца.", "Мы платим за услуги 65 перед началом нового месяца."),
            ("Мы платим за услуги 81 евро перед началом нового месяца.", "Мы платим за услуги €81 перед началом нового месяца."),
            ("Мы платим за услуги $48 перед началом нового месяца.", "Мы платим за услуги 48 долларов перед началом нового месяца."),
            ("Наш бюджет составляет 12 процентов от суммы за прошлый месяц.", "Наш бюджет составляет 12% от суммы за прошлый месяц."),
            ("Наш бюджет составляет 12% от суммы за прошлый месяц.", "Наш бюджет составляет 12 из суммы за прошлый месяц."),
            ("Мы платим за услуги 48 американских долларов перед началом месяца.", "Мы платим за услуги 48 перед началом месяца.")
        ]
        for (primary, candidate) in cases {
            XCTAssertEqual(RecognitionConsensus.revisedText(original: primary, candidate: candidate,
                corroboration: candidate, vocabulary: "") ?? primary, primary)
            XCTAssertEqual(RussianRecognition.revisedText(original: primary, candidate: candidate,
                corroboration: candidate, hypothesis: candidate, vocabulary: "", usesCyrillicHints: false,
                rawCandidate: candidate) ?? primary, primary)
        }
    }

    func testQuantityDoesNotBlockAnUnrelatedConfirmedEdit() {
        let primary = "Мы платим за услуги $48, а у нас работают шлёзы каждый день."
        let candidate = primary.replacingOccurrences(of: "шлёзы", with: "шлюзы")
        XCTAssertEqual(RecognitionConsensus.revisedText(original: primary, candidate: candidate,
            corroboration: candidate, vocabulary: ""), candidate)
    }

}
