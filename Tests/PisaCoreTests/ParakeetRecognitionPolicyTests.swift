import XCTest
@testable import PisaCore

final class ParakeetRecognitionPolicyTests: XCTestCase {
    func testMeetingLanguageMarksOnlyUnsupportedSpeech() {
        let cases = [
            ("Devět.", "Неразборчиво"),
            ("«Devět»", "Неразборчиво"),
            ("Дякую.", "Неразборчиво"),
            ("Muchas gracias.", "Неразборчиво"),
            ("Merci beaucoup.", "Неразборчиво"),
            ("Deve\u{030C}t.", "Неразборчиво"),
            ("Мы проверим ђак завтра.", "Мы проверим … завтра."),
            ("Потом ќе, дальше идём.", "Потом …, дальше идём."),
            ("Ответ 明天见 через API.", "Ответ … через API."),
            ("Готово.\nDeve\u{030C}t.\nPlease continue.", "Готово.\n…\nPlease continue."),
            ("Usaremos el calendario para preparar nuestra siguiente visita.", "Неразборчиво"),
            ("Договорились. Nous avons beaucoup de choses importantes en commun. До завтра.",
             "Договорились. … До завтра."),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(MeetingRecognitionLanguage.unclearText(for: source, vocabulary: ""), expected, source)
        }
    }

    func testMeetingLanguagePreservesEnglishRussianAndProtectedTerms() {
        for source in [
            "Please review the pull request before rolling back the deployment.",
            "Обсудим feature flag, Kubernetes, gRPC и rollout на встрече.",
            "Угу, ещё чуть-чуть. Серёжа идёт домой.", "И это всё".decomposedStringWithCanonicalMapping,
            "Let's meet at the café after our deployment.", "José García will review the patch.",
            "This is Jean-Luc Picard.", "Cherry Pick", "code review", "cache invalidation", "pull request", "API", "LLM'ки", "стендап и code review",
            "Передай Чеський проєкт в работу.", "Проверим https://example.org/devět и `очі` завтра.",
            "Открой src/devět_řádek и `再见`.",
        ] {
            XCTAssertNil(MeetingRecognitionLanguage.unclearText(for: source, vocabulary: "Чеський проєкт"), source)
        }
        XCTAssertEqual(MeetingRecognitionLanguage.unclearText(for: "Devět Číslo завтра.", vocabulary: "Devět"),
                       "Devět … завтра.")
        XCTAssertEqual(MeetingRecognitionLanguage.unclearText(for: "Проверим Devět.", vocabulary: "Devět++"),
                       "Проверим …")
    }

    func testMeetingLanguageRecoveryUsesIndependentWordsAndKeepsSurroundings() {
        func confirmed(_ text: String, _ check: String?, _ source: String = "Devět.", _ glossary: String = "") -> String? {
            MeetingRecognitionLanguage.confirmedText(text, corroboration: check, original: source, vocabulary: glossary)
        }
        XCTAssertEqual(confirmed("Привет.", "привет!"), "Привет.")
        XCTAssertEqual(confirmed("Договорились!", "договорились"), "Договорились!")
        XCTAssertEqual(confirmed("Roll back.", "roll back!"), "Roll back.")
        XCTAssertEqual(confirmed("Обсудим сроки за $37 завтра", "обсудим сроки за $37 завтра.",
                                 "Обсудим Devět за $37 завтра."), "Обсудим сроки за $37 завтра.")
        for (text, check) in [("", ""), ("Согласен", ""), ("Привет", "Ответ"),
                              ("Devět.", "devět"), ("−5%", "5%"), ("Девять", "9"), ("Бюджет $37", "Бюджет 37"),
                              ("Цена 2.5", "Цена 2 5"), ("Ждём −2%", "Ждём 2%")] {
            XCTAssertNil(confirmed(text, check), text)
        }
        XCTAssertNil(confirmed("Привет.", nil))
        XCTAssertNil(confirmed("Обсудим завтра", "обсудим завтра", "За $37 обсудим Devět завтра."))
        XCTAssertNil(confirmed("Мы готовы", "Мы готовы", "Мы Devět через `curl /api`."))
        XCTAssertNil(confirmed("Docker", nil, "Devět.", "Docker"))
        XCTAssertEqual(confirmed("Docker", "docker", "Devět.", "Docker"), "Docker")
        XCTAssertEqual(confirmed("Девять.", "девять"), "Девять.")
    }

    func testSeparateFinalSentenceNeedsThreeUnpromptedReads() {
        func ending(_ reread: String, _ primary: String, _ acoustic: String?) -> String? {
            MeetingRecognitionLanguage.confirmedEnding(reread, primary: primary, acoustic: acoustic, original: "Devět.", vocabulary: "")
        }
        XCTAssertEqual(ending("Привет.", "Ну а дальше? Привет.", "Ну и дальше? Привет."), "… Привет.")
        XCTAssertEqual(ending("Спасибо!", "Ну что? Спасибо!", "Что? Спасибо."), "… Спасибо!")
        XCTAssertEqual(ending("Привет.", "Привет!", "привет"), "Привет.")
        XCTAssertEqual(ending("Хорошо.", "Договор подписали? Хорошо.", "Договор подписали. Хорошо."), "… Хорошо.")
        for (first, second) in [("Ну что? Привет.", "Ну что? Ответ."), ("Приветствие.", "Привет."),
                                ("Ну что привет.", "Привет."), ("Не привет.", "Привет."),
                                ("Пять процентов. Привет.", "Привет."), ("Наверное. Привет.", "Привет.")] {
            XCTAssertNil(ending("Привет.", first, second), first)
        }
        XCTAssertNil(ending("Спасибо!", "Ну что? Спасибо!", nil))
    }

    func testStandaloneClosingCardsRequireAudioEvidenceAndPreserveSpeech() {
        for card in ["Продолжение следует...", "Продолжение следует…", "Спасибо за просмотр!",
                     "Благодарим за просмотр", "To be continued.", "Thank you for watching!"] {
            XCTAssertTrue(RecognitionSubtitleCredit.needsVerification(card))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: card, primary: card,
                verifier: "", language: "None", acoustic: ""), .silence)
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: card, primary: card,
                verifier: "Встречаемся завтра.", language: "Russian", acoustic: "встречаемся завтра"), .speech("Встречаемся завтра."))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: card, primary: card,
                verifier: card.uppercased(), language: "Russian", acoustic: ""), .keep)
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: card, primary: card,
                verifier: nil, language: nil, acoustic: nil), .keep)
        }
        for speech in ["В титрах написано «Продолжение следует».", "Продолжение следует искать в следующем файле.",
                       "Продолжение наше.", "Thanks for watching over us."] {
            XCTAssertFalse(RecognitionSubtitleCredit.needsVerification(speech))
        }
    }

    func testClosingCardPreservesAgreedSpeechAndMarksDisputedOpening() {
        let card = "Продолжение следует..."
        let acoustic = "Продолжение наше. Тут рабочая группа уже за многие годы превратилась в отдельный отдел."
        let suffix = "тут рабочая группа уже за многие годы превратилась в отдельный отдел."
        func choose(_ checked: String) -> RecognitionSubtitleCredit.Decision {
            RecognitionSubtitleCredit.decision(for: card, primary: card, verifier: checked,
                language: "Russian", acoustic: acoustic)
        }
        XCTAssertEqual(choose("Предложения наши " + suffix), .speech("… Тут рабочая группа уже за многие годы превратилась в отдельный отдел."))
        XCTAssertEqual(choose("Якобы " + suffix), .unclear)
        XCTAssertEqual(choose("Совсем другая новость, объявили отдельный отдел."), .unclear)
        XCTAssertEqual(choose("Предложения наши " + suffix + " И тогда."), .unclear)
    }

    func testIsolatedSubtitleAttributionsCanBeFalseOnSilenceOrMaskRealSpeech() {
        for credit in ["Субтитры сделал DimaTorzok", "Редактор субтитров — Анна Смирнова.",
                       "Субтитры подготовила Команда Север", "Captions by River Studio"] {
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
                verifier: "", language: "None", acoustic: ""), .silence)
            // The first pass may instead have obtained the credit from the verifier.
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: "",
                verifier: credit, language: "Russian", acoustic: ""), .silence)
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
                verifier: "Вернёмся завтра.", language: "Russian", acoustic: "вернемся завтра"), .speech("Вернёмся завтра."))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: "Уже готово.",
                verifier: credit, language: "Russian", acoustic: "уже готово"), .speech("Уже готово."))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
                verifier: "Не успели.", language: "Russian", acoustic: "мы хотели"), .unclear)
        }
    }

    func testSpokenCreditsAndUnrelatedConversationSurvive() {
        let credit = "Субтитры сделал DimaTorzok"
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Субтитры сделал Дима Торзок.", language: "Russian", acoustic: "субтитры сделал дима торзок"), .keep)
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Субтитры сделал Михаил.", language: "Russian", acoustic: "субтитры сделал михаил"), .speech("Субтитры сделал Михаил."))
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Субтитры сделал Михаил.", language: "Russian", acoustic: "субтитры сделал иван"), .unclear)
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Включи субтитры.", language: "Russian", acoustic: "включи субтитры"), .speech("Включи субтитры."))
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: nil, language: nil, acoustic: nil), .keep)
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "", language: nil, acoustic: ""), .keep)
        for ordinary in ["Мы обсуждали, кто сделал субтитры.", "Субтитры включим позже.",
                         "Он процитировал: «Субтитры сделал DimaTorzok».", "Can you turn the captions on?"] {
            XCTAssertFalse(RecognitionSubtitleCredit.needsVerification(ordinary))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: ordinary, primary: ordinary,
                verifier: "", language: "None", acoustic: ""), .keep)
        }
    }

    func testIndependentWideReadingConfirmsTheEntireIsolatedTurnWithoutBorrowingItsEnding() {
        let credit = "Субтитры сделал NorthStudio"
        let acoustic = "Проверяют со стороны команды и"
        let verifier = "проверяют стороны команды и дальше"
        func decision(_ wide: String, check: String = "проверяют стороны команды и дальше") -> RecognitionSubtitleCredit.Decision {
            RecognitionSubtitleCredit.decision(for: credit, primary: credit, verifier: check, language: "Russian",
                acoustic: acoustic, expandedPrimary: { wide })
        }
        let wide = "Договорились, проверяют со стороны команды, и дальше всё пришлют."
        XCTAssertEqual(decision(wide), .speech(acoustic))
        for wrong in [
            "Договорились, проверяют со стороны отдела, и дальше всё пришлют.",
            "Договорились, проверяют со стороны команды. Дальше всё пришлют.", // missing the final word
            "Проверяют со стороны команды, и потом проверяют со стороны команды и снова приходят.",
            "Проверяют вчера, а сегодня проверяют со стороны команды, и дальше всё пришлют.",
            "Договорились, не проверяют со стороны команды, и дальше всё пришлют.",
        ] {
            XCTAssertEqual(decision(wrong), .unclear)
        }
        XCTAssertEqual(decision(wide, check: "Не " + verifier), .unclear)
        XCTAssertEqual(decision(wide, check: "Об этом поговорим завтра"), .unclear)
        var widerReads = 0
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit, verifier: credit,
            language: "Russian", acoustic: acoustic, expandedPrimary: { widerReads += 1; return wide }), .keep)
        XCTAssertEqual(widerReads, 0)
    }

    func testWideSubtitleEvidenceRespectsSentenceAndLiteralBoundaries() {
        let card = "Продолжение следует..."
        let narrow = "Планируем встречу с командой"
        func choose(_ wide: String) -> RecognitionSubtitleCredit.Decision {
            RecognitionSubtitleCredit.decision(for: card, primary: card, verifier: "Встречу перенесли, командой займётся Олег.",
                language: "Russian", acoustic: narrow, expandedPrimary: { wide })
        }
        for separator in [". ", "! ", "? ", "… ", "\n", ". — ", "», «", ": «", "; ", " — ", " / "] {
            XCTAssertEqual(choose("На завтра планируем встречу" + separator + "с командой работает Иван."), .unclear, separator)
        }
        XCTAssertEqual(choose("На завтра планируем встречу с командой, дальше отпишусь."), .speech(narrow))
        for previous in ["Не", "Нельзя", "Пять", "5", "Михаил"] {
            XCTAssertEqual(choose(previous + " планируем встречу с командой завтра."), .unclear, previous)
        }
        XCTAssertEqual(choose("Совещание назначил Михаил. Планируем встречу с командой завтра."), .speech(narrow))
    }

    func testDisputedOpeningCannotRemoveModalityAmountOrSubject() {
        let card = "Спасибо за просмотр."
        let ending = "подписывать новые договоры по правилам без согласования."
        func choose(_ acoustic: String, _ checked: String) -> RecognitionSubtitleCredit.Decision {
            RecognitionSubtitleCredit.decision(for: card, primary: card, verifier: checked, language: "Russian", acoustic: acoustic)
        }
        for (a,b) in [("Нельзя","Можно"), ("Михаил","Иван"), ("Пять","Сто"), ("Нельзя.","Можно"),
                      ("Михаил.","Иван"), ("Пять.","Сто"), ("Отдел","Предлагает")] {
            XCTAssertEqual(choose(a + " " + ending, b + " " + ending), .unclear)
        }
        XCTAssertEqual(choose("Показатель изменился на −5%.", "Показатель изменился на 5%."), .unclear)
        XCTAssertEqual(choose("Показатель изменился на 5%.", "Показатель изменился на 5."), .unclear)
        XCTAssertEqual(choose("Показатель изменился на −5,5%.", "Показатель изменился на -5.5%."),
            .speech("Показатель изменился на -5.5%."))
    }

    func testRussianEvidenceDoesNotComeFromDecoderLanguageDefault() {
        for text in ["Проверим LLM'ки завтра", "Серёжа встретился со Сбером", "угу", "Да, вылазию", "Мы с Євгеном обсудили два ГИСа и выпустили новый релиз"] {
            XCTAssertTrue(ParakeetRecognitionPolicy.hasRussianTextEvidence(text), text)
        }
        for text in ["Let's review the API tomorrow", "OK, sure", "123", "", "перевіримо зміни завтра", "Καλημέρα"] {
            XCTAssertFalse(ParakeetRecognitionPolicy.hasRussianTextEvidence(text), text)
        }
    }

    func testCustomPrimaryDoesNotRedirectManagedVerifier() {
        let speakers = URL(fileURLWithPath: "/managed/Models/Speakers")
        XCTAssertEqual(ParakeetRecognitionPolicy.verifierDirectory(explicit: nil, speakerDirectory: speakers).path,
                       "/managed/Models/Qwen3-ASR")
        let custom = URL(fileURLWithPath: "/custom/verification")
        XCTAssertEqual(ParakeetRecognitionPolicy.verifierDirectory(explicit: custom, speakerDirectory: speakers), custom)
    }

    func testEngineIdentityDistinguishesPrimaryAndVerifierRoles() {
        XCTAssertEqual(ParakeetRecognitionPolicy.checkpointVariants["primary"], ["parakeet-tdt-v3", "weights-float32", "audio-float32"])
        XCTAssertEqual(ParakeetRecognitionPolicy.checkpointVariants["verifier"], ["qwen-selective"])
    }

    func testCheckpointRejectsOldEngineAndChangedVerifierWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.caf")
        let verifier = root.appendingPathComponent("verifier.safetensors")
        try Data([1]).write(to: audio)
        try Data([2]).write(to: verifier)
        func inputs(_ variants: [String: [String]]) throws -> BatchTranscriptionCheckpoint.Inputs {
            try BatchTranscriptionCheckpoint.Inputs(files: [(audio, 0)], model: root,
                vocabulary: "Сбер", variants: variants, supportingModels: [verifier])
        }
        let old = try inputs([:])
        let current = try inputs(ParakeetRecognitionPolicy.checkpointVariants)
        XCTAssertNotEqual(old, current)
        try Data([2, 3]).write(to: verifier)
        XCTAssertNotEqual(current, try inputs(ParakeetRecognitionPolicy.checkpointVariants))
    }


    func testManagedDerivedTokenizerKeepsCheckpointButSourcesAndCustomTokenizerInvalidateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("Qwen3-ASR")
        let custom = root.appendingPathComponent("Custom")
        let speakers = root.appendingPathComponent("Speakers")
        for url in [managed, custom] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.caf")
        try Data([1]).write(to: audio)
        func inputs(_ directory: URL) throws -> BatchTranscriptionCheckpoint.Inputs {
            try BatchTranscriptionCheckpoint.Inputs(files: [(audio, 0)], model: root,
                vocabulary: "", variants: ParakeetRecognitionPolicy.checkpointVariants,
                supportingModels: ParakeetRecognitionPolicy.verifierCheckpointFiles(directory: directory, speakerDirectory: speakers))
        }
        let vocab = managed.appendingPathComponent("vocab.json")
        try Data([2]).write(to: vocab)
        let beforeLoad = try inputs(managed)
        try Data([3]).write(to: managed.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(beforeLoad, try inputs(managed))
        try Data([2, 4]).write(to: vocab)
        XCTAssertNotEqual(beforeLoad, try inputs(managed))

        let authored = custom.appendingPathComponent("tokenizer.json")
        try Data([5]).write(to: authored)
        let originalCustom = try inputs(custom)
        try Data([5, 6]).write(to: authored)
        XCTAssertNotEqual(originalCustom, try inputs(custom))
    }

}
