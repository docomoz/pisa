import XCTest
@testable import PisyaCore

final class RecognitionContextTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, _ text: String, track: String = "remote") -> TranscriptSegment {
        var segment = TranscriptSegment(start: start, end: end, speaker: "Собеседник", text: text)
        segment.audioFile = "test-\(track).caf"
        return segment
    }

    func testUsesNearestTurnsAcrossTracksInChronologicalOrder() {
        let target = segment(100, 103, "Распознаваемый отрывок", track: "mic")
        let preceding = (1...7).map { segment(100 - Double($0 * 5), 101 - Double($0 * 5), "Предыдущая реплика \($0)", track: $0.isMultiple(of: 2) ? "mic" : "remote") }
        let following = (1...6).map { segment(103 + Double($0 * 5), 104 + Double($0 * 5), "Следующая реплика \($0)") }
        let neighbors = RecognitionContext(segments: following.reversed() + [target] + preceding.reversed())
            .neighbors(around: target)

        XCTAssertEqual(neighbors.preceding, (1...5).reversed().map { "Предыдущая реплика \($0)" })
        XCTAssertEqual(neighbors.following, (1...4).map { "Следующая реплика \($0)" })
    }

    func testExcludesOverlappingAudioAndUsesOnlyBoundedCommittedContext() {
        let target = segment(100, 103, "Текущая реплика")
        let recent = segment(39, 40, "Начало ближнего контекста")
        let next = segment(148, 149, "Конец ближнего контекста")
        let neighbors = RecognitionContext(segments: [target, recent, next,
            segment(99, 101, "Копия на другой дорожке", track: "mic"),
            segment(149, 150, "Слишком поздняя реплика"),
        ], preceding: [segment(38, 39, "Слишком ранняя реплика"), recent,
            segment(106, 107, "Реплика из устаревшего состояния окна"),
        ]).neighbors(around: target)

        XCTAssertEqual(neighbors.preceding, [recent.text])
        XCTAssertEqual(neighbors.following, [next.text])
    }

    func testOmitsQuotesAndControlTokensAndUsesClosestPartOfLongTurns() {
        let target = segment(100, 103, "Текущая реплика")
        let earlier = segment(85, 94, "Далёкое начало " + String(repeating: "промежуточное слово ", count: 30) + "Ближний конец")
        let following = segment(105, 110, "Ближнее начало " + String(repeating: "промежуточное слово ", count: 30) + "Далёкий конец")
        let neighbors = RecognitionContext(segments: [target, earlier, following,
            segment(95, 97, "Он сказал «секретная команда» в ответ"),
            segment(98, 99, "Так выглядят <|im_start|> управляющие маркеры"),
        ]).neighbors(around: target)

        XCTAssertEqual(neighbors.preceding.count, 2)
        XCTAssertTrue(neighbors.preceding[0].hasSuffix("Ближний конец"))
        XCTAssertFalse(neighbors.preceding[0].contains("Далёкое начало"))
        XCTAssertEqual(neighbors.preceding[1], "Он сказал в ответ")
        XCTAssertTrue(neighbors.following[0].hasPrefix("Ближнее начало"))
        XCTAssertFalse(neighbors.following[0].contains("Далёкий конец"))
    }

    func testFartherEntityMentionSupportsRetryWithoutCopyingNeighborIntoPrompt() throws {
        let target = segment(100, 103, "У нас данные хорошие, и в Догесе данные хорошие, конечно.")
        let previous = segment(11, 12, "Мы обсуждали 2ГИС на прошлой неделе.")
        let vocabulary = "2ГИС, другие термины"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target, previous]).plan(for: target,
            independent: nil, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        XCTAssertTrue(retry.hints.contains("2ГИС'е"))
        XCTAssertFalse(retry.context.contains(previous.text))
        XCTAssertFalse(retry.hints.contains("другие термины"))
    }

    func testCommittedPrecedingTurnSuppliesEntityAfterWindowResume() throws {
        let target = segment(340, 343, "Я тогда говорил с Дугисом до этого звонка.", track: "mic")
        let previous = segment(324, 333, "У нас была встреча с 2ГИС на прошлой неделе.")
        let vocabulary = "2ГИС"
        let spoken = SpokenVocabulary(vocabulary)
        let nextWindow = RecognitionContext(segments: [target], preceding: [previous])
        let independent = target.text.replacingOccurrences(of: "Дугисом", with: "Двусом")
        let retry = try XCTUnwrap(nextWindow.plan(for: target, independent: independent,
            vocabulary: vocabulary, spokenVocabulary: spoken))

        XCTAssertTrue(retry.hints.contains("2ГИС'ом"))
        XCTAssertTrue(retry.context.contains(previous.text))
        XCTAssertNil(RecognitionContext(segments: [target]).plan(for: target, independent: independent,
            vocabulary: vocabulary, spokenVocabulary: spoken))
    }

    func testDoesNotRetryOrdinaryWordBothDecodersAgreeOn() {
        let target = segment(100, 110, "Он спросил, если мы успеем всё проверить, что будем делать потом.")
        let previous = segment(80, 90, "Коллеги определили для SLI общий порог.")
        let vocabulary = "SLI"
        XCTAssertNil(RecognitionContext(segments: [previous, target]).plan(for: target,
            independent: target.text, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
    }

    func testComplementsNumeralAndAcronymStemWithoutNearbyMention() throws {
        let original = "Тогда ты говорил с ГИСом до этого дня."
        let target = segment(100, 109, original)
        let vocabulary = "2ГИС"
        let spoken = SpokenVocabulary(vocabulary)
        let context = RecognitionContext(segments: [target])
        let raw = original.replacingOccurrences(of: "ГИСом", with: "Дугисом")
        let candidate = original.replacingOccurrences(of: "ГИСом", with: "2ГИС'ом")
        let retry = try XCTUnwrap(context.plan(for: target, independent: raw, vocabulary: vocabulary, spokenVocabulary: spoken))

        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: raw,
            retry: retry, vocabulary: vocabulary), candidate)
        XCTAssertEqual(retry.targetSpans(in: original, corroboration: raw).map { String(original[$0]) }, ["ГИСом"])
        for heard in [original, original.replacingOccurrences(of: "ГИСом", with: "соседом"),
                      original.replacingOccurrences(of: "ГИСом", with: "Дагисом")] {
            XCTAssertNil(context.plan(for: target, independent: heard, vocabulary: vocabulary, spokenVocabulary: spoken))
            XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: heard,
                retry: retry, vocabulary: vocabulary))
        }
    }

    func testComplementsActualInstrumentalDecodesAndFindsOnlyTheSuspectWord() throws {
        let original = "Вот, слушай, круто. А расскажи ты, ты же пересекался с ГИСом до этого?"
        let raw = "Слушай, круто. А расскажи, ты же пересекался с Двугсом до этого?"
        let candidate = original.replacingOccurrences(of: "ГИСом", with: "2ГИС'ом")
        let target = segment(100, 109, original, track: "mic")
        let vocabulary = "2ГИС, Дубльгис"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(retry.targetSpans(in: original, corroboration: raw).map { String(original[$0]) }, ["ГИСом"])
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: raw, retry: retry, vocabulary: vocabulary), candidate)
    }

    func testFreshContractedNumeralAndVerifiersAgreeAtSameAcronym() throws {
        let original = "Вот, слушай, круто. А расскажи ты, ты же пересекался с ГИСом до этого?"
        let raw = "Слушай, круто. А расскажи, ты же пересекался с Двугсом до этого?"
        let candidate = original.replacingOccurrences(of: "ГИСом", with: "ДвГИСом")
        let revised = original.replacingOccurrences(of: "ГИСом", with: "2ГИС'ом")
        let target = segment(100, 109, original, track: "mic")
        let vocabulary = "2ГИС, 3ГИС, Дубльгис"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: raw, retry: retry, vocabulary: vocabulary), revised)
        for spelling in ["ТрГИСом", "ДВГИСом", "ДвГИСНЕТом", "ДвГИСПро", "ДвГИС'е", "«ДвГИСом»", "ГИСом"] {
            XCTAssertNil(RecognitionContext.revisedText(original: original,
                candidate: original.replacingOccurrences(of: "ГИСом", with: spelling),
                corroboration: raw, retry: retry, vocabulary: vocabulary), spelling)
        }
        for disagreement in ["ГИСом", "Трёхгисом", "Двугсе"] {
            XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
                corroboration: raw.replacingOccurrences(of: "Двугсом", with: disagreement), retry: retry, vocabulary: vocabulary))
        }
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: raw, retry: retry, vocabulary: vocabulary + ", ДвГИС"))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: raw, retry: retry, vocabulary: vocabulary, candidateIsAcoustic: false))
    }

    func testContractedNumeralIsDerivedFromVocabularyEntry() throws {
        let original = "Мы вчера поговорили с АБВом по этому вопросу."
        let raw = original.replacingOccurrences(of: "АБВом", with: "Семьабом")
        let candidate = original.replacingOccurrences(of: "АБВом", with: "СмьАБВом")
        let target = segment(100, 109, original)
        let vocabulary = "7АБВ"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: raw, retry: retry, vocabulary: vocabulary), "Мы вчера поговорили с 7АБВ'ом по этому вопросу.")
    }

    func testFindsMixedScriptInitialismWhenVerifierOmittedIt() throws {
        let original = "Изменения ну рабочих процессов вот AIМ? Насколько ты боишься этих перемен?"
        let raw = original.replacingOccurrences(of: " AIМ", with: "")
        let target = segment(100, 109, original)
        let vocabulary = "AI"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(retry.targetSpans(in: original, corroboration: raw).map { String(original[$0]) }, ["AIМ"])
    }

    func testAcceptsLocalizedNumericNameWithAcousticNearMiss() throws {
        let original = "Слушай, круто. А расскажи, ты же пересекался с Двусом до этого?"
        let revised = "Слушай, круто. А расскажи, ты же пересекался с 2ГИС'ом до этого?"
        let neighbor = "Первое моё пересечение было на собеседовании в 2ГИС в Новосибирске."
        let target = segment(100, 106, original, track: "mic")
        let vocabulary = "2ГИС, Кинопоиск"
        let context = RecognitionContext(segments: [target, segment(110, 116, neighbor)])
        let retry = try XCTUnwrap(context.plan(for: target, independent: nil, vocabulary: vocabulary,
            spokenVocabulary: SpokenVocabulary(vocabulary)))

        let raw = original.replacingOccurrences(of: "Двусом", with: "Дугисом")
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: revised,
            corroboration: raw, retry: retry, vocabulary: vocabulary), revised)
        XCTAssertEqual(RecognitionContext.revisedText(original: original.replacingOccurrences(of: "Двусом", with: "ГИСом"),
            candidate: revised, corroboration: original, retry: retry, vocabulary: vocabulary), revised)
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: revised,
            corroboration: nil, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: revised,
            corroboration: original.replacingOccurrences(of: "Двусом", with: "партнёром"), retry: retry, vocabulary: vocabulary))
        let ordinaryGIS = original.replacingOccurrences(of: "Двусом", with: "ГИСом")
        XCTAssertNil(RecognitionContext.revisedText(original: ordinaryGIS, candidate: revised,
            corroboration: ordinaryGIS, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: revised,
            corroboration: raw, retry: retry, vocabulary: vocabulary, candidateIsAcoustic: false))
        XCTAssertTrue(retry.isNeighborEcho("Да, первое моё пересечение было на собеседовании в 2ГИС в Новосибирске."))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: neighbor,
            corroboration: nil, retry: retry, vocabulary: vocabulary))
    }

    func testCompoundUsesAcousticEvidenceAndKeepsUnrelatedWords() throws {
        let original = "Данными избера это и создаём профиль, это и банковские транзакции."
        let raw = "Данными Сбера это и соцдемпрофиль, это и банковские транзакции."
        let candidate = "Данными Сбера это и соцдем-профиль, это и банковские транзакции."
        let vocabulary = "соцдем-профиль"
        let target = segment(100, 109, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        XCTAssertEqual(retry.targetSpans(in: original, corroboration: raw).map { String(original[$0]) }, ["создаём профиль"])
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: raw,
            retry: retry, vocabulary: vocabulary), "Данными избера это и соцдем-профиль, это и банковские транзакции.")
        XCTAssertNotNil(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: raw,
            retry: retry, vocabulary: vocabulary, candidateIsAcoustic: false))
    }

    func testProtectsEnglishQuotesNumbersAndCompetingAcronyms() throws {
        let vocabulary = "AI, AIM"
        let target = segment(100, 105, "Изменения рабочих процессов вот АИМ, насколько ты боишься?")
        let neighbors = [segment(92, 98, "Мы давно пробовали этот подход с AI и обсуждали последствия.")]
        let context = RecognitionContext(segments: neighbors + [target])
        let retry = try XCTUnwrap(context.plan(for: target, independent: "Изменения рабочих процессов вот АИМ, насколько ты боишься?",
            vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        for old in ["Мы начали с «AIM», насколько ты боишься?", "We often talk about AIM in our meetings.",
                    "Мы начинали со 100 AIM, насколько ты боишься?", "Мы точно не AIM, насколько ты боишься?"] {
            let changed = old.replacingOccurrences(of: "AIM", with: "AI'ем")
            XCTAssertNil(RecognitionContext.revisedText(original: old, candidate: changed,
                corroboration: changed, retry: retry, vocabulary: vocabulary))
        }
    }

    func testCanJoinFreshAcronymAndIndependentlyHeardPreposition() throws {
        let original = "У тебя есть примеры, где ты встроил AI-совые процессы? Насколько тебе это помогло?"
        let raw = "У тебя есть примеры, где ты встроил в свои процессы? Насколько тебе это помогло?"
        let candidate = "У тебя есть примеры, где ты встроил AI свои процессы? Насколько тебе это помогло?"
        let vocabulary = "AI"
        let target = segment(100, 109, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        XCTAssertEqual(retry.targetSpans(in: original, corroboration: raw).map { String(original[$0]) }, ["AI-совые"])
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: raw,
            retry: retry, vocabulary: vocabulary, candidateIsAcoustic: false), "У тебя есть примеры, где ты встроил AI в свои процессы? Насколько тебе это помогло?")
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: nil,
            retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: raw.replacingOccurrences(of: "в свои", with: "не свои"), retry: retry, vocabulary: vocabulary))
    }

    func testReconcilesObservedInitialismWithIndependentBoundary() throws {
        let original = "У тебя есть примеры, где ты встроил AI-совые процессы? Насколько тебе это помогло?"
        let heard = "где ты встроил в свои процессы насколько тебе это"
        let vocabulary = "AI"
        let target = segment(100, 109, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: heard, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        XCTAssertEqual(RecognitionContext.reconcileObservedInitialismBoundary(original: original, independent: heard,
            retry: retry, vocabulary: vocabulary), "У тебя есть примеры, где ты встроил AI в свои процессы? Насколько тебе это помогло?")
        for spelling in ["AIМ", "AIM", "AI'овым", "ai-совые", "AI - совые", "«AI-совые»", "AI-овые"] {
            XCTAssertNil(RecognitionContext.reconcileObservedInitialismBoundary(
                original: original.replacingOccurrences(of: "AI-совые", with: spelling), independent: heard,
                retry: retry, vocabulary: vocabulary), spelling)
        }
        for phrase in ["в новые", "не свои", "в очень свои", "в 37", "в свои37", "в-свои"] {
            XCTAssertNil(RecognitionContext.reconcileObservedInitialismBoundary(original: original,
                independent: heard.replacingOccurrences(of: "в свои", with: phrase), retry: retry, vocabulary: vocabulary), phrase)
        }
        XCTAssertNil(RecognitionContext.reconcileObservedInitialismBoundary(
            original: original.replacingOccurrences(of: "AI-совые", with: "AI-овые"),
            independent: heard.replacingOccurrences(of: "в свои", with: "в новые"), retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.reconcileObservedInitialismBoundary(original: original, independent: heard,
            retry: retry, vocabulary: vocabulary + ", AI-совые"))
        XCTAssertNil(RecognitionContext.reconcileObservedInitialismBoundary(original: original + " " + original,
            independent: heard, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.reconcileObservedInitialismBoundary(original: original,
            independent: heard + " " + heard, retry: retry, vocabulary: vocabulary))
    }

    func testDisambiguatesInstrumentalEndingFromLetterSequenceAndEstablishedTerm() throws {
        let original = "Как меняются рабочие процессы вот AIМ? Насколько ты замечаешь изменения?"
        let candidate = "Ну рабочие процессы вот AI'ем насколько ты замечаешь изменения"
        let unprompted = ["рабочие процессы вот A I M насколько ты замечаешь изменения",
                          "Ну рабочие процессы вот A I м насколько ты замечаешь изменения"]
        let target = segment(1524, 1534, original, track: "mic")
        let prior = segment(1390, 1392, "Насколько ты вообще используешь AI в своей работе?")
        let vocabulary = "AI"
        let spoken = SpokenVocabulary(vocabulary)
        let context = RecognitionContext(segments: [target], preceding: [prior])
        let retry = try XCTUnwrap(context.plan(for: target, independent: nil, vocabulary: vocabulary, spokenVocabulary: spoken))
        XCTAssertTrue(retry.canDisambiguateInitialismEnding(in: original))
        XCTAssertFalse(retry.context.contains(prior.text))
        XCTAssertEqual(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate,
            unprompted: unprompted, retry: retry, vocabulary: vocabulary),
            "Как меняются рабочие процессы вот AI'ем? Насколько ты замечаешь изменения?")

        for spelling in ["AIM", "АIМ", "AIН", "AIм", "«AIМ»", "`AIМ`"] {
            let other = original.replacingOccurrences(of: "AIМ", with: spelling)
            XCTAssertFalse(retry.canDisambiguateInitialismEnding(in: other), spelling)
            XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: other, candidate: candidate,
                unprompted: unprompted, retry: retry, vocabulary: vocabulary), spelling)
        }
        for letters in ["A I", "A I N", "A I M M", "AIM", "AI M", "A, I, M", "«A I M»"] {
            let wrong = unprompted[0].replacingOccurrences(of: "A I M", with: letters)
            XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate,
                unprompted: [wrong, unprompted[1]], retry: retry, vocabulary: vocabulary), letters)
        }
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate,
            unprompted: [unprompted[0]], retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate.replacingOccurrences(of: "AI'ем", with: "AI'ом"),
            unprompted: unprompted, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original + " " + original, candidate: candidate,
            unprompted: unprompted, retry: retry, vocabulary: vocabulary))

        for competing in ["AIM", "АIМ"] {
            XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate,
                unprompted: unprompted, retry: retry, vocabulary: vocabulary + ", " + competing))
            let other = segment(1510, 1515, "Мы обсуждали продукт «\(competing)» на встрече.")
            let guarded = try XCTUnwrap(RecognitionContext(segments: [target, other], preceding: [prior]).plan(for: target,
                independent: nil, vocabulary: vocabulary, spokenVocabulary: spoken))
            XCTAssertFalse(guarded.canDisambiguateInitialismEnding(in: original))
        }
        let withoutTerm = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: nil, vocabulary: vocabulary, spokenVocabulary: spoken))
        XCTAssertFalse(withoutTerm.canDisambiguateInitialismEnding(in: original))
        XCTAssertFalse(retry.canDisambiguateInitialismEnding(in: "Введи клавиши AIМ, потом нажми Enter."))
        for command in ["Сейчас введи AIМ, после этого продолжим работу.",
                        "Напечатай, пожалуйста, AIМ, после этого продолжим работу."] {
            let spelling = command.replacingOccurrences(of: "AIМ", with: "AI'ем")
            let readout = [command.replacingOccurrences(of: "AIМ", with: "A I M"),
                           command.replacingOccurrences(of: "AIМ", with: "A I м")]
            XCTAssertFalse(retry.canDisambiguateInitialismEnding(in: command))
            XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: command, candidate: spelling,
                unprompted: readout, retry: retry, vocabulary: vocabulary))
        }
        let namedBefore = "Мы обсуждали AIM раньше, это был отдельный проект. "
        let namedAfter = " Кстати, вспомнили про АIМ на прошлой встрече."
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: namedBefore + candidate,
            unprompted: unprompted, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate,
            unprompted: [namedBefore + unprompted[0], unprompted[1]], retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: original, candidate: candidate,
            unprompted: [unprompted[0], unprompted[1] + namedAfter], retry: retry, vocabulary: vocabulary))
        let dictation = segment(1510, 1515, "Сейчас введи эти буквы и нажми Enter.")
        let guarded = try XCTUnwrap(RecognitionContext(segments: [target, dictation], preceding: [prior]).plan(for: target,
            independent: nil, vocabulary: vocabulary, spokenVocabulary: spoken))
        XCTAssertFalse(guarded.canDisambiguateInitialismEnding(in: original))
    }

    func testDisambiguationIsNotSpecificToAI() throws {
        let original = "Как там дела с VRМ, насколько ты доволен результатом?"
        let target = segment(100, 109, original)
        let previous = segment(85, 90, "На предыдущей встрече обсуждали код и новые сценарии VR.")
        let vocabulary = "VR"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target], preceding: [previous]).plan(for: target,
            independent: nil, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.disambiguateInitialismEnding(original: original,
            candidate: "Дела с VR'ем насколько ты доволен результатом", unprompted: [
                "дела с V R M насколько ты доволен результатом", "там дела с V R м насколько ты доволен"], retry: retry, vocabulary: vocabulary),
            "Как там дела с VR'ем, насколько ты доволен результатом?")
    }

    func testDoesNotGuessCaseEndingOrDropMeaningfulTokens() throws {
        let original = "Тогда ты говорил с Дугисом до этого дня."
        let target = segment(100, 109, original)
        let other = segment(110, 115, "Мы тогда говорили про 2ГИС на работе.")
        let vocabulary = "2ГИС"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target, other]).plan(for: target,
            independent: nil, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))

        XCTAssertNil(RecognitionContext.revisedText(original: original,
            candidate: "Тогда ты говорил с 2ГИС'е до этого дня.", corroboration: original, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: "Тогда ты говорил с не Дугисом до этого дня.",
            candidate: "Тогда ты говорил с 2ГИС'ом до этого дня.", corroboration: original, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: "Тогда ты говорил с 37 Дугисом до этого дня.",
            candidate: "Тогда ты говорил с 2ГИС'ом до этого дня.", corroboration: original, retry: retry, vocabulary: vocabulary))
    }

    func testGluedProductSuffixSuppliesEntityContextButLongerInitialismDoesNot() throws {
        let original = "У нас данные хорошие, и в Дагестане данные хорошие тоже."
        let candidate = "У нас данные хорошие, и в 2ГИСе данные хорошие тоже."
        let raw = "У нас данные хорошие, и в Догесе данные хорошие тоже."
        let target = segment(100, 109, original)
        let vocabulary = "2ГИС"
        let spoken = SpokenVocabulary(vocabulary)
        let product = segment(115, 120, "Мы сейчас продаём лицензию 2ГИСпро, и эти данные тоже.")
        let retry = try XCTUnwrap(RecognitionContext(segments: [target, product]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: spoken))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate, corroboration: raw,
            retry: retry, vocabulary: vocabulary), "У нас данные хорошие, и в 2ГИС'е данные хорошие тоже.")

        let other = segment(115, 120, "Мы сейчас обсуждаем систему 2ГИСНЕТ и эти данные тоже.")
        XCTAssertNil(RecognitionContext(segments: [target, other]).plan(for: target,
            independent: raw, vocabulary: vocabulary, spokenVocabulary: spoken))
    }
}
