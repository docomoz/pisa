import XCTest
@testable import PisyaCore

final class RussianRecognitionTests: XCTestCase {
    func testDictionaryGuidedRetryCannotRewriteTheWholeTurn() {
        let original = "Мы её знакомили с руководителем PRTS. Мы можем онлайн сделать встречу."
        let hypothesis = "Мы её знакомили с руководителем ЦРТС. Мы можем онлайн сделать встречу."
        let candidate = "Мы её познакомили с руководителем ЦРТС. Мы можем онлайн организовать встречу."
        XCTAssertEqual(RussianRecognition.revisedText(original: original, candidate: candidate, corroboration: original,
            hypothesis: hypothesis, vocabulary: "ЦРТС", usesCyrillicHints: true), hypothesis)
        XCTAssertNil(RussianRecognition.revisedText(original: original,
            candidate: "Мы её познакомили с новым руководителем ЦРТС. Завтра будем онлайн обсуждать новую встречу.",
            corroboration: original, hypothesis: hypothesis, vocabulary: "ЦРТС", usesCyrillicHints: true))
    }

    func testUnhintedAcousticRecheckRetainsExistingAcceptanceRules() {
        let original = "Мы обсудим сроки запуска в четверг."
        let candidate = "Мы обсудим сроки запуска уже в четверг."
        XCTAssertEqual(RussianRecognition.revisedText(original: original, candidate: candidate, corroboration: candidate,
            hypothesis: candidate, vocabulary: "", usesCyrillicHints: false), candidate)
    }

    func testUnhintedRetryPreservesAnIndependentlyRecognizedNameAndPreposition() {
        let original = "Вчера мы обсуждали это с B2C, с Анжелой допустим, или с Сергеем после встречи."
        let corroboration = "Вчера мы обсудили это с BTS, с Анжелой, допустим, или с Сергеем после встречи."
        for candidate in [
            "Вчера мы обсуждали это с B2C, Санджело допустим, или с Сергеенко после встречи.",
            "Вчера мы обсуждали это с B2C, Анжелой допустим, или с Сергеем после встречи.",
            "Вчера мы обсуждали это с B2C, допустим, или с Сергеем после встречи.",
            "Вчера мы обсуждали это с B2C, с Анжелой около офиса или с Сергеем после встречи.",
        ] {
            XCTAssertNil(RussianRecognition.revisedText(original: original, candidate: candidate, corroboration: corroboration,
                hypothesis: corroboration, vocabulary: "Анжела, B2C", usesCyrillicHints: false), candidate)
        }
        let improved = "Вчера мы обсудили это с B2C, с Анжелой, допустим, или с Сергеем после встречи."
        XCTAssertEqual(RussianRecognition.revisedText(original: original, candidate: improved, corroboration: corroboration,
            hypothesis: corroboration, vocabulary: "Анжела, B2C", usesCyrillicHints: false), improved)
    }

    func testUnhintedRetryPreservesEachConfirmedAcronymOccurrence() {
        let original = "Мы работали с отделом ЦРТС. Мы можем назвать итог. Вчера говорили с отделом ЦРТС. Мы можем повторить."
        let candidate = "Мы работали с отделом ЦРТС. Мы можем назвать итог. Вчера говорили с отделом PRTS. Мы можем повторить."
        XCTAssertNil(RussianRecognition.revisedText(original: original, candidate: candidate, corroboration: original,
            hypothesis: original, vocabulary: "", usesCyrillicHints: false))
    }

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

    func testLocalRepairSplitsNameWithoutChangingVocabularyOrCopyingOverlappingSpeech() {
        let original = "Кто обсуждал это с B2C, Санджелой допустим или с Сергеем?"
        let candidate = "Кто обсудил это с BTUC, с Анжелой, допустим, или с Сергеем Петровым?"
        let corroboration = "Кто обсуждал это с BTUC, с Анжелой, допустим, или с Сергеем Петровым?"
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: "B2C"),
                       "Кто обсуждал это с B2C, с Анжелой допустим или с Сергеем?")
    }

    func testLocalRepairRestoresMissingPrepositionWithoutRepeatingIt() {
        let original = "Кто обсуждал это с B2C, Анжелой допустим, или с Сергеем?"
        let candidate = "Кто обсуждал это с BTUC, с Анжелой допустим, или с Сергеем?"
        let corroboration = "Кто обсудил это с BTUC, с Анжелой, допустим, или с Сергеем?"
        let corrected = "Кто обсуждал это с B2C, с Анжелой допустим, или с Сергеем?"
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: "B2C"), corrected)
        XCTAssertNil(RussianRecognition.localizedRepair(original: corrected, candidate: candidate, corroboration: corroboration, vocabulary: "B2C"))
    }

    func testLocalRepairKeepsExistingPrepositionsAndConjunctions() {
        let candidate = "Мы обсуждали вопрос с Анжелой и Сергеем перед встречей."
        for preceding in ["между", "перед", "над", "со", "и"] {
            let original = "Мы обсуждали вопрос \(preceding) Анжелой и Сергеем перед встречей."
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: ""), original)
        }
    }

    func testLocalRepairCorrectsAcronymWithoutCopyingAnExtraPrefix() {
        let original = "Вчера говорили с руководителем PRTS. Мы можем обсудить сроки."
        let candidate = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        let corroboration = "Вчера говорили с руководителем PR-ЦРТС. Мы можем обсудить сроки."
        let expected = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: ""), expected)
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: corroboration, corroboration: corroboration, vocabulary: ""), expected)
    }

    func testDictionaryRepairChangesOnlyExplicitAcronymAtConfirmedLocation() {
        let original = "Вчера говорили с руководителем PRTS. Мы можем обсудить сроки."
        let candidate = "Недавно встретились с руководителем ЦРТС. Мы можем обсудить другое."
        let hypothesis = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        XCTAssertEqual(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate, hypothesis: hypothesis, vocabulary: "B2C; ЦРТС"),
                       "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки.")

        for vocabulary in ["", "цртс", "ЦРТС Новгорода", "ЦРТС, PRTS"] {
            XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate, hypothesis: hypothesis, vocabulary: vocabulary))
        }
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
            hypothesis: "Вчера говорили с коллегой ЦРТС. Мы можем обсудить сроки.", vocabulary: "ЦРТС"))
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original + " " + original, candidate: candidate,
            hypothesis: hypothesis, vocabulary: "ЦРТС"))
    }

    func testDictionaryRepairDoesNotTreatPromptedNamesAsAcousticEvidence() {
        let original = "Вчера мы говорили Санджелой по этому вопросу."
        let candidate = "Вчера мы говорили с Анжелой по этому вопросу."
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
            hypothesis: candidate, vocabulary: "Анжела, с Анжелой"))
    }

    func testLocalRepairRequiresIndependentAgreementAtTheSameOccurrence() {
        let original = "Мы уже говорили с Анной и Столей по этому вопросу."
        let candidate = "Мы уже говорили с Анной и с Толей по этому вопросу."
        for corroboration in [
            "Мы уже говорили с Анной и с Колей по этому вопросу.",
            "С Толей разговаривали вчера. Мы уже говорили с Анной и Столей по этому вопросу.",
            "Мы уже говорили с Анной и с. Толей по этому вопросу.",
        ] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: ""))
        }
    }

    func testLocalRepairLeavesAmbiguousOccurrencesUnchanged() {
        let original = "Вчера говорили Столей по этому вопросу, сегодня говорили Столей по этому вопросу."
        let candidate = "Вчера говорили с Толей по этому вопросу, сегодня говорили с Толей по этому вопросу."
        XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: ""))
    }

    func testLocalRepairProtectsEachDictionaryOccurrence() {
        let original = "Мы уже говорили с Анной и Столей по этому вопросу. Это был Столей."
        let candidate = "Мы уже говорили с Анной и с Толей по этому вопросу. Это был Столей."
        XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: "Столей"))
    }

    func testLocalRepairLeavesEnglishAndUnrelatedAcronymsUnchanged() {
        for (original, candidate) in [
            ("We discussed PRTS in the report.", "We discussed ЦРТС in the report."),
            ("Мы обсуждали с командой NASA. Завтра будет новая встреча.", "Мы обсуждали с командой ЦРТС. Завтра будет новая встреча."),
            ("Мы обсуждали PRTS с командой вчера.", "Мы обсуждали PRTS с командой вчера. ЦРТС тоже присутствовали."),
        ] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: ""))
        }
    }
}
