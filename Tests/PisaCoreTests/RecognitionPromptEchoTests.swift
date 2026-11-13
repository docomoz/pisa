import XCTest
@testable import PisaCore

final class RecognitionPromptEchoTests: XCTestCase {
    func testGeneratedCaseFormsCannotBecomeSpokenText() {
        let vocabulary = SpokenVocabulary("7АБВ, Команда").decodingVocabulary
        let copied = "Начали обсуждать 7АБВ, Команда, 7АБВ'а, 7АБВ'ом, 7АБВ'е, 7АБВ'у."
        var prompts: [String] = []
        let result = RecognitionPromptEcho.decode(context: vocabulary, vocabulary: vocabulary, text: { $0 }) { prompt in
            prompts.append(prompt)
            return prompt.isEmpty ? "Начали обсуждать команду." : copied
        }
        XCTAssertEqual(prompts, [vocabulary, ""])
        XCTAssertEqual(result, "Начали обсуждать команду.")
    }

    func testEveryPromptedPassRecoversFromAudioWithoutCopyingOrDeletingText() {
        let vocabulary = "Alpha, Beta, Gamma, Delta, Epsilon"
        for context in [vocabulary, vocabulary + "\nПервая акустическая версия", vocabulary + "\nс Анной"] {
            var prompts: [String] = []
            let recovered = RecognitionPromptEcho.decode(context: context, vocabulary: vocabulary, text: { $0 }) { prompt in
                prompts.append(prompt)
                return prompt.isEmpty ? "Мы продолжили обсуждать запуск." : "Начали с Alpha, Beta, Gamma, Delta, Epsilon."
            }
            XCTAssertEqual(prompts, [context, ""])
            XCTAssertEqual(recovered, "Мы продолжили обсуждать запуск.")
        }
    }

    func testUnpromptedRealEnumerationIsRetainedAndRetryIsBounded() {
        let vocabulary = "Alpha, Beta, Gamma, Delta, Epsilon"
        var prompts: [String] = []
        let result = RecognitionPromptEcho.decode(context: vocabulary, vocabulary: vocabulary, text: { $0 }) { prompt in
            prompts.append(prompt)
            return vocabulary
        }
        XCTAssertEqual(prompts, [vocabulary, ""])
        XCTAssertEqual(result, vocabulary)
        prompts = []
        _ = RecognitionPromptEcho.decode(context: "", vocabulary: vocabulary, text: { $0 }) { prompt in
            prompts.append(prompt)
            return vocabulary
        }
        XCTAssertEqual(prompts, [""])
    }

    func testRecognizesLongGlossaryTailAfterSpokenWords() {
        let vocabulary = "2ГИС, Яндекс, Айдар Саниахметов, iPhone, Confluence, мобилка, YClients, Sales Force, Retail Media, B2C, PNL, ЦРТС, Анжела"
        let text = "И вот здесь вот как вот у нас работа была ну выстроена в Айдар Саниахметов, iPhone, Confluence, мобилка, YClients, sales-force, Retail Media, B2C, PNL, ЦРТС, Анжела."
        XCTAssertTrue(RecognitionPromptEcho.isEcho(text, context: vocabulary, vocabulary: vocabulary))
    }

    func testRecoversWhenSpeechContinuesAfterTheCopiedGlossary() {
        let vocabulary = "Alpha, Beta, Gamma, Delta, Epsilon, Zeta"
        let contaminated = "Мы обсуждали Alpha, Beta, Gamma, Delta, Epsilon и затем вернулись к срокам."
        var prompts: [String] = []
        let text = RecognitionPromptEcho.decode(context: vocabulary, vocabulary: vocabulary, text: { $0 }) { prompt in
            prompts.append(prompt)
            return prompt.isEmpty ? "Мы обсуждали запуск и затем вернулись к срокам." : contaminated
        }
        XCTAssertEqual(prompts, [vocabulary, ""])
        XCTAssertEqual(text, "Мы обсуждали запуск и затем вернулись к срокам.")
    }

    func testRecognizesNormalizedWholePromptButNeverEmptyContext() {
        let vocabulary = "Ёлка; Retail Media"
        XCTAssertTrue(RecognitionPromptEcho.isEcho("елка, retail-media.", context: vocabulary, vocabulary: vocabulary))
        XCTAssertFalse(RecognitionPromptEcho.isEcho(vocabulary, context: "", vocabulary: vocabulary))
        XCTAssertFalse(RecognitionPromptEcho.isEcho("...", context: "...", vocabulary: "..."))
    }

    func testRecognizesGlossaryStartingWithClippedNumericTerm() {
        let vocabulary = "2ГИС, Сбер, Контур Толк, GR, Айдар Саниахметов, iPhone, Confluence, мобилка, YClients, sales-force, Retail Media, B2C, PNL, ЦРТС, Анжела"
        let text = "ГИС, Сбер, Контур Толк, GR, Айдар Саниахметов, iPhone, Confluence, мобилка, YClients, B2C, PNL, ЦРТС, Анжела."
        XCTAssertTrue(RecognitionPromptEcho.isEcho(text, context: vocabulary, vocabulary: vocabulary))
    }

    func testRecognizesAnOrderedTailWithSkippedEntriesAndClippedMultiwordEnds() {
        let vocabulary = "Проверка, Ёлка зимой, Alpha, Beta, Gamma, Delta, Упущенный термин, Epsilon, Retail Media, Финал"
        let text = "Рассказ заканчивается: зимой Alpha, Beta. Gamma; DELTA, Epsilon, Retail."
        XCTAssertTrue(RecognitionPromptEcho.isEcho(text, context: vocabulary, vocabulary: vocabulary))
    }

    func testKeepsOrdinarySentencesAndShortListsWithGlossaryTerms() {
        let vocabulary = "iPhone, Confluence, YClients, Sales Force, Retail Media, B2C, PNL"
        for text in [
            "Обсудили iPhone, Confluence и YClients. После Sales Force вернёмся к Retail Media.",
            "Нам пригодятся iPhone, Confluence, YClients.",
            "Мы перечислили PNL, B2C, Retail Media, YClients, Confluence и закончили встречу.",
            "В отчёте: Retail Media, Sales Force, YClients, Confluence, iPhone.",
        ] {
            XCTAssertFalse(RecognitionPromptEcho.isEcho(text, context: vocabulary, vocabulary: vocabulary), text)
        }
    }

    func testPartialDetectionDoesNotTreatAnAcousticHintAsGlossaryEntries() {
        let vocabulary = "2ГИС, Айдар"
        let context = vocabulary + "\nМы проверили, как они ответили, какой срок, что выбрать, где искать, когда вернуться"
        let text = "Позже повторили: как они ответили, какой срок, что выбрать, где искать, когда вернуться."
        XCTAssertFalse(RecognitionPromptEcho.isEcho(text, context: context, vocabulary: vocabulary))
    }

    func testAnExactAcousticAgreementWithoutGlossaryIsNotAnEcho() {
        let hypothesis = "Мы обсудили работу новой команды."
        XCTAssertFalse(RecognitionPromptEcho.isEcho(hypothesis, context: hypothesis, vocabulary: ""))
        var prompts: [String] = []
        let result = RecognitionPromptEcho.decode(context: hypothesis, vocabulary: "", text: { $0 }) { prompt in
            prompts.append(prompt)
            return hypothesis
        }
        XCTAssertEqual(result, hypothesis)
        XCTAssertEqual(prompts, [hypothesis])
    }
}
