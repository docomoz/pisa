import NaturalLanguage
import XCTest
@testable import PisaCore

final class RecognitionConsensusTests: XCTestCase {
    func testBoundaryConsensusRepairsOnlyWordsBothDecodersHear() {
        let original = "Вот и вот с этого всё началось Сумный город Новосипок."
        let independent = "Вот. И вот с этого всё началось. Умный город Новосиб."
        let candidate = "Вот и вот с этого всё началось. Сумный город Новосиб."
        XCTAssertTrue(RecognitionConsensus.hasBoundaryDisagreement(original: original, corroboration: independent, vocabulary: ""))
        XCTAssertEqual(RecognitionConsensus.revisedBoundaryText(original: original, candidate: candidate,
            corroboration: independent, vocabulary: ""), "Вот и вот с этого всё началось Сумный город Новосиб.")
        XCTAssertNil(RecognitionConsensus.revisedBoundaryText(original: original, candidate: original,
            corroboration: independent, vocabulary: ""))
    }

    func testRepeatedPhraseAndSecondAudioReadingCanResolveDuplicatedBoundaryConsonant() {
        let original = "Вот и вот с этого всё началось Сумный город Новосипок."
        let independent = "Вот. И вот с этого всё началось. Умный город Новосиб."
        let candidate = "Вот и вот с этого всё началось. Сумный город Новосиб."
        let expanded = "Наша аудитория огромная. " + independent + " Беда в чём?"
        let phrases: Set<String> = ["умный город"]
        XCTAssertTrue(RecognitionConsensus.needsBoundaryOnsetVerification(original: original, corroboration: independent,
            vocabulary: "", establishedPhrases: phrases))
        XCTAssertEqual(RecognitionConsensus.revisedBoundaryText(original: original, candidate: candidate,
            corroboration: independent, vocabulary: "", establishedPhrases: phrases, expandedCorroboration: expanded),
            "Вот и вот с этого всё началось Умный город Новосиб.")
        for unsupported in ["", expanded.replacingOccurrences(of: "Умный", with: "Сумный"),
                            "«" + independent + "»", independent + " " + independent] {
            XCTAssertEqual(RecognitionConsensus.revisedBoundaryText(original: original, candidate: candidate,
                corroboration: independent, vocabulary: "", establishedPhrases: phrases, expandedCorroboration: unsupported),
                "Вот и вот с этого всё началось Сумный город Новосиб.")
        }
        XCTAssertEqual(RecognitionConsensus.revisedBoundaryText(original: original, candidate: candidate,
            corroboration: independent, vocabulary: "", expandedCorroboration: expanded),
            "Вот и вот с этого всё началось Сумный город Новосиб.")
    }

    func testBoundaryOnsetRuleIsDerivedFromAdjacentSounds() {
        let original = "Мы решили что предстоит Точный формат встречи."
        let evidence = "Мы решили что предстоит очный формат встречи."
        XCTAssertEqual(RecognitionConsensus.revisedBoundaryText(original: original, candidate: original,
            corroboration: evidence, vocabulary: "", establishedPhrases: ["очный формат"], expandedCorroboration: evidence), evidence)
        XCTAssertNil(RecognitionConsensus.revisedBoundaryText(original: original.replacingOccurrences(of: "предстоит", with: "нужен"),
            candidate: original.replacingOccurrences(of: "предстоит", with: "нужен"),
            corroboration: evidence.replacingOccurrences(of: "предстоит", with: "нужен"), vocabulary: "",
            establishedPhrases: ["очный формат"], expandedCorroboration: evidence.replacingOccurrences(of: "предстоит", with: "нужен")))
    }

    func testBoundaryConsensusProtectsQuantitiesNegationLiteralsAndKnownNames() {
        for (before, after, glossary) in [
            ("Семь тысяч человек придут утром", "Восемь тысяч человек придут утром", ""),
            ("Третьего числа мы увидимся снова", "Четвёртого числа мы увидимся снова", ""),
            ("Пригоден этот образец для эксперимента", "Непригоден этот образец для эксперимента", ""),
            ("Мы решили что готов Северный Атлас", "Мы решили что готов Северный Адрес", "Северный Атлас"),
            ("В Контуре вчера обсуждали важные правки", "В Конторе вчера обсуждали важные правки", "Контур"),
            ("Мы решили что готов «Северный Атлас»", "Мы решили что готов «Северный Адрес»", ""),
            ("We will send our report tomorrow", "We will send our reports tomorrow", ""),
            ("Мы ожидаем ровно 17 человек", "Мы ожидаем ровно 18 человек", ""),
        ] {
            XCTAssertFalse(RecognitionConsensus.hasBoundaryDisagreement(original: before, corroboration: after, vocabulary: glossary), before)
            XCTAssertNil(RecognitionConsensus.revisedBoundaryText(original: before, candidate: after, corroboration: after, vocabulary: glossary), before)
        }
    }

    func testShortTurnDoesNotRewriteQuotedOriginal() {
        XCTAssertNil(RecognitionConsensus.revisedText(original: "«Говори, Максим!»", candidate: "Говори, Максиму.",
            corroboration: "Говори, Максиму.", vocabulary: "", allowShortTurn: true))
    }

    func testShortTurnPreservesOriginalTerminalPunctuation() {
        XCTAssertEqual(RecognitionConsensus.revisedText(original: "Говорим, Макс!", candidate: "Говори, Максим.",
            corroboration: "Говори, Максим.", vocabulary: "", allowShortTurn: true), "Говори, Максим!")
    }

    func testExpandedAudioCannotAddOrRemoveWords() {
        for result in ["Говори, Максим, да.", "Говори."] {
            XCTAssertNil(RecognitionConsensus.revisedText(original: "Говорим, Максим.", candidate: result,
                corroboration: result, vocabulary: "", allowShortTurn: true, expandedAudio: true))
        }
        XCTAssertEqual(RecognitionConsensus.revisedText(original: "Говорим, Максим.", candidate: "Говори, Максим.",
            corroboration: "Говори, Максим.", vocabulary: "", allowShortTurn: true, expandedAudio: true), "Говори, Максим.")
    }

    func testExpandedAudioCannotChangeAnAffirmation() {
        XCTAssertNil(RecognitionConsensus.revisedText(original: "Говорим, Максим, да.", candidate: "Говори, Максим, ну.",
            corroboration: "Говори, Максим, ну.", vocabulary: "", allowShortTurn: true, expandedAudio: true))
    }
    func testRepairsOnlyAnAnchoredSplitAndItsSeparators() {
        let original = "Завтра обсудим AI-совые процессы с командой."
        let corroboration = "Завтра обсудим AI в свои процессы с командой."
        let candidate = "Сегодня проверим AI в свои процессы с руководителем."
        XCTAssertEqual(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: corroboration, vocabulary: "AI"), corroboration)
    }

    func testShortTurnNeedsExplicitPermissionAndAgreement() {
        let original = "Говорим, Макс."
        let candidate = "Говори, Максим."
        XCTAssertNil(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: candidate, vocabulary: ""))
        XCTAssertEqual(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: candidate, vocabulary: "", allowShortTurn: true), candidate)
        XCTAssertNil(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: "Говорим Максим.", vocabulary: "", allowShortTurn: true))
    }

    func testShortTurnKeepsAnUnchangedDictionaryNameButCannotReplaceIt() {
        let corrected = "Говори, Максим."
        XCTAssertEqual(RecognitionConsensus.revisedText(original: "Говорим, Максим.", candidate: corrected,
            corroboration: corrected, vocabulary: "Максим", allowShortTurn: true), corrected)
        XCTAssertNil(RecognitionConsensus.revisedText(original: "Говорим, Макс.", candidate: corrected,
            corroboration: corrected, vocabulary: "Макс", allowShortTurn: true))
    }

    func testLocalAgreementCanKeepOriginalGlossaryAtAnUnrelatedDisagreement() {
        let original = "Вчера мы обсуждали это с B2C, с Анжелой допустим, или с Сергеем после встречи."
        let corroboration = "Вчера мы обсудили это с BTS, с Анжелой, допустим, или с Сергеем после встречи."
        let candidate = "Вчера мы обсудили это с B2C, с Анжелой, допустим, или с Сергеем после встречи."
        XCTAssertEqual(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: corroboration, vocabulary: "Анжела, B2C"),
            "Вчера мы обсудили это с B2C, с Анжелой допустим, или с Сергеем после встречи.")
    }

    func testShortTurnCanDisregardOneAddedConjunctionBetweenPastTenseVerbs() {
        let original = "Наташке ну сказал да."
        let candidate = "Наташа кивнула и сказала да."
        let corroboration = "Наташа кивнула, сказала: «Да»."
        // Some macOS installations do not provide Russian verb lemmas.
        // The production fallback preserves the original when either is missing.
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = candidate
        tagger.setLanguage(.russian, range: candidate.startIndex..<candidate.endIndex)
        let hasVerbLemmas = ["кивнула", "сказала"].allSatisfy { word in
            guard let start = candidate.range(of: word)?.lowerBound,
                  let lemma = tagger.tag(at: start, unit: .word, scheme: .lemma).0?.rawValue else { return false }
            return lemma.hasSuffix("ть")
        }
        XCTAssertEqual(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: corroboration, vocabulary: "Наташа", allowShortTurn: true),
            hasVerbLemmas ? corroboration : nil)
        for unsafe in ["Наташа кивнула или сказала да.", "Наташа кивнула и не сказала да.",
                       "Наташа кивнула и сказала нет.", "Наташа кивнула и всё сказала да."] {
            XCTAssertNil(RecognitionConsensus.revisedText(original: original, candidate: unsafe,
                corroboration: corroboration, vocabulary: "Наташа", allowShortTurn: true), unsafe)
        }
        XCTAssertNil(RecognitionConsensus.revisedText(original: "Звонили Ивану Антону.",
            candidate: "Звонили Ивану и Анне.", corroboration: "Звонили Ивану Анне.",
            vocabulary: "", allowShortTurn: true))
        XCTAssertNil(RecognitionConsensus.revisedText(original: "Там лежали зеркало бокале.",
            candidate: "Там лежат зеркала и бокала.", corroboration: "Там лежат зеркала бокала.",
            vocabulary: "", allowShortTurn: true))
    }

    func testProtectsVocabularyNumbersNegationAndEnglish() {
        for (original, revised, vocabulary) in [
            ("Потом проверили Северный Атлас перед встречей.", "Потом проверили Северный Адрес перед встречей.", "Северный Атлас"),
            ("Мы вчера собрали 24 заявки на встрече.", "Мы вчера собрали 42 заявки на встрече.", ""),
            ("Сегодня мы не приняли предложение от коллег.", "Сегодня мы приняли предложение от коллег.", ""),
            ("Завтра обсудим AI решения перед встречей.", "Завтра обсудим новые решения перед встречей.", ""),
            ("We should send the notes tomorrow.", "We should send the report tomorrow.", ""),
            ("Давай.", "Давайте.", ""),
            ("Всё хорошо.", "Завтра уволят.", ""),
        ] {
            XCTAssertNil(RecognitionConsensus.revisedText(original: original, candidate: revised, corroboration: revised,
                vocabulary: vocabulary, allowShortTurn: true), original)
        }
    }

    func testRejectsUnconfirmedOrAmbiguouslyAnchoredSpans() {
        let original = "Мы проверили старый план до запуска."
        let evidence = "Мы проверили новый план до запуска."
        for candidate in ["Мы согласовали новый план до запуска.",
                          "Мы проверили новый план, проверили старый план до запуска.",
                          "Мы проверили свежий план до запуска."] {
            XCTAssertNil(RecognitionConsensus.revisedText(original: original, candidate: candidate,
                corroboration: evidence, vocabulary: ""), candidate)
        }
    }

    func testRejectsDisagreementLargerThanTheLocalRepairWindow() {
        let original = "Мы проверили старый запасный короткий рабочий черновик перед встречей."
        let candidate = "Мы проверили новый полный детальный итоговый отчёт перед встречей."
        XCTAssertNil(RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: candidate, vocabulary: ""))
    }
    func testLocalReplacementNeverUsesProtectedLiteralText() {
        let original = "Мы любим книги"
        let revised = "Мы читаем книги"
        XCTAssertEqual(RecognitionConsensus.revisedText(original: original, candidate: revised,
            corroboration: revised, vocabulary: ""), revised)
        for (source, candidate, evidence) in [
            ("«Мы любим книги»", "«Мы читаем книги»", "«Мы читаем книги»"),
            ("`Мы любим книги`", "`Мы читаем книги`", "`Мы читаем книги`"),
            ("https://пример.рф/Мы-любим-книги", "https://пример.рф/Мы-читаем-книги", "https://пример.рф/Мы-читаем-книги"),
            (original, "`Мы читаем книги`", revised),
            (original, revised, "`Мы читаем книги`")
        ] {
            XCTAssertNil(RecognitionConsensus.revisedText(original: source, candidate: candidate,
                corroboration: evidence, vocabulary: ""), source)
        }
    }

}
