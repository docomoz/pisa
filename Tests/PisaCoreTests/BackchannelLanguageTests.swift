import XCTest
@testable import PisaCore

final class BackchannelLanguageTests: XCTestCase {
    func testLanguageCandidatesOnlyApplyToTheFirstPassWording() {
        let context = segment(0, "Сегодня мы обсуждаем этот проект.")
        let lexical = segment(2, "Ми вже погодили договір.")
        let backchannel = segment(3, "Right.")
        let disputed = segment(4, "Wait.")
        let evidence = BatchTranscriptionCheckpoint.FirstPass()
        evidence.segments = [lexical, backchannel, disputed]
        evidence.lexicalBackchannels = [lexical.id: "Мы уже согласовали договор."]
        evidence.backchannels = [backchannel.id: "Угу."]
        evidence.uncertainShortLanguage = [disputed.id]
        func resolve(_ segments: [TranscriptSegment]) -> [String] {
            BackchannelLanguage.resolve(segments, evidence: evidence, preceding: [context], vocabulary: "").map(\.text)
        }
        // Each disputed turn still uses its existing evidence when unchanged.
        XCTAssertEqual(resolve([lexical]), ["Мы уже согласовали договор."])
        XCTAssertEqual(resolve([backchannel]), ["Угу."])
        XCTAssertEqual(resolve([disputed]), ["Неразборчиво"])
        var later = lexical, laterSound = backchannel, laterWord = disputed
        later.text = "Ми вже погодили договори."
        laterSound.text = "Tomorrow."
        laterWord.text = "Ready."
        XCTAssertEqual(resolve([later]), [later.text])
        XCTAssertEqual(resolve([laterSound]), [laterSound.text])
        XCTAssertEqual(resolve([laterWord]), [laterWord.text])
        later.text = "Мы уже согласовали договоры."
        let next = segment(6, "Uh huh.")
        let withoutIndependentAnchor = BackchannelLanguage.resolve([later, next], evidence: evidence, preceding: [], vocabulary: "")
        XCTAssertEqual(withoutIndependentAnchor.map(\.text), [later.text, next.text])
        XCTAssertEqual(withoutIndependentAnchor[0].independentRecognitionLanguage, false)
    }

    func testIsolatedRereadCanOnlySkipAnAlreadyConfirmedLatinTurnWithMissingEvidence() {
        XCTAssertFalse(BackchannelLanguage.needsIsolatedLanguageRead(latin: true, paddedConfirmsSource: true, isolatedAcoustic: nil))
        XCTAssertTrue(BackchannelLanguage.needsIsolatedLanguageRead(latin: true, paddedConfirmsSource: false, isolatedAcoustic: nil))
        for available in ["", "русская речь"] {
            XCTAssertTrue(BackchannelLanguage.needsIsolatedLanguageRead(latin: true, paddedConfirmsSource: true, isolatedAcoustic: available))
        }
        XCTAssertFalse(BackchannelLanguage.needsIsolatedLanguageRead(latin: false, paddedConfirmsSource: false, isolatedAcoustic: ""))
        XCTAssertTrue(BackchannelLanguage.needsIsolatedLanguageRead(latin: false, paddedConfirmsSource: false, isolatedAcoustic: "слово"))
    }

    func testPaddedLatinAgreementIsTentativeWhenTheIsolatedReadsContradictIt() {
        func isolated(_ original: String, _ reread: String, _ language: String, _ acoustic: String?,
                      vocabulary: String = "") -> BackchannelLanguage.IsolatedLatinReading? {
            BackchannelLanguage.isolatedLatinReading(original: original, reread: reread, language: language,
                corroboration: acoustic, vocabulary: vocabulary)
        }
        for source in ["Exactly.", "Tomorrow."] {
            XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: source, reread: source))
            XCTAssertEqual(isolated(source, "समझा तो", "Hindi", "Запно."), .unconfirmed)
            XCTAssertEqual(isolated(source, "", "None", "Точно."), .unconfirmed)
            XCTAssertEqual(isolated(source, source, "English", "Запно."), .source)
            XCTAssertNil(isolated(source, "समझा तो", "Hindi", nil))
            XCTAssertNil(isolated(source, "समझा तो", "Hindi", ""))
            XCTAssertNil(isolated(source, "That sounds right.", "English", "Запно."))
        }
        XCTAssertEqual(isolated("Navio.", "Navío.", "Portuguese", "Навио."), .source)
        XCTAssertNil(isolated("Navio.", "сервис Navio", "Ukrainian", "сервис"))
        XCTAssertNil(isolated("Navio.", "समझा तो", "Hindi", "Запно.", vocabulary: "Navio"))
        XCTAssertNil(isolated("«Exactly».", "समझा तो", "Hindi", "Запно."))
    }

    func testIsolatedForeignCompoundUsesTheWordBoundaryHeardByBothVerifiers() {
        func reading(_ source: String, _ reread: String, _ corroboration: String?, language: String = "English",
                     vocabulary: String = "") -> BackchannelLanguage.IsolatedLatinReading? {
            BackchannelLanguage.isolatedLatinReading(original: source, reread: reread, language: language,
                corroboration: corroboration, vocabulary: vocabulary)
        }
        XCTAssertEqual(reading("Alright.", "All right.", "all right"), .foreign("All right."))
        XCTAssertEqual(reading("Breaktime.", "Break time.", "break time"), .foreign("Break time."))
        XCTAssertEqual(reading("Debout.", "De bout.", "de bout", language: "French"), .foreign("De bout."))
        XCTAssertNil(reading("Alright.", "All right.", "Запно."))
        XCTAssertNil(reading("Alright.", "All right.", nil))
        XCTAssertNil(reading("Going.", "Go in.", "go in"))
        XCTAssertNil(reading("Breaktime.", "Break time.", "break time", vocabulary: "Breaktime"))
        XCTAssertNil(reading("Breaktime.", "Break Time.", "break time"))
        XCTAssertNil(reading("Breaktime.", "Break time.", "break time", language: "None"))
        XCTAssertNil(reading("«Breaktime».", "Break time.", "break time"))
    }

    func testDisputedForeignEndingNeedsTheSameLeadInAndAFullIndependentFocusedRead() {
        func start(_ source: String, _ candidate: String, _ padded: String, _ acoustic: String,
                   language: String = "English", vocabulary: String = "") -> Int? {
            let tokens = acoustic.split(separator: " ").enumerated().map { i, word in
                RecognitionTimedWord(text: String(word), start: i == 0 ? 0.12 : 0.72, end: i == 0 ? 0.72 : 1)
            }
            return BackchannelLanguage.foreignEndingStart(original: source, reread: candidate, padded: padded, language: language,
                acoustic: .init(text: acoustic, words: tokens), sampleCount: 16000, vocabulary: vocabulary)
        }
        XCTAssertEqual(start("Follow than.", "Follow them.", "Follow them.", "Follow Dan"), 6720)
        XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: "Follow them.", reread: "follow them"))
        XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: "Follow them.", reread: "them"))
        XCTAssertNil(start("Follow than.", "Follow them.", "Follow me.", "Follow Dan"))
        XCTAssertNil(start("Follow than.", "Follow them.", "Follow them.", "Значит всё"))
        XCTAssertNil(start("Follow than.", "Follow them.", "Follow them.", "Fellow Dan"))
        XCTAssertNil(start("Follow than.", "Follow them.", "Follow them.", "Follow Dan", language: "Russian"))
        XCTAssertNil(start("Follow than.", "Follow them.", "Follow them.", "Follow Dan", vocabulary: "Follow"))
    }

    func testSilentTailOnlyRetriesTheLeadWordAndStillRequiresTheEntireEnglishReply() {
        var retries = 0
        func confirm(_ candidate: String, _ focused: String, retry: String) -> Bool {
            BackchannelLanguage.confirmsForeignEnding(candidate, focused: focused) {
                retries += 1
                return retry
            }
        }
        XCTAssertTrue(confirm("Review this.", "Reviewed this.", retry: "Review this!"))
        XCTAssertFalse(confirm("Review this.", "Reviewed this.", retry: "Reviewed this."))
        XCTAssertFalse(confirm("Review this.", "Reviewed this.", retry: "This."))
        XCTAssertEqual(retries, 3)
        XCTAssertTrue(confirm("Review this.", "review this", retry: ""))
        for unrelated in ["Review these.", "Reveal this.", "This.", "Reviewed this later.", "Проверь это."] {
            XCTAssertFalse(confirm("Review this.", unrelated, retry: "Review this."), unrelated)
        }
        XCTAssertEqual(retries, 3)
    }

    func testLexicalRereadRequiresIndependentWordsAndVocalizationsCanStandAlone() {
        for heard in [nil, "", "ну, а я?", "четыре слова для проверки"] {
            XCTAssertFalse(BackchannelLanguage.canVerifyAlternative(original: "Yeah.", corroboration: heard))
            XCTAssertNil(BackchannelLanguage.alternative(original: "Yeah.", russian: "Да.", corroboration: heard))
        }
        for (original, candidate, heard) in [("Yeah.", "Да.", "Ну да."), ("Uh-huh.", "Угу.", nil)] {
            XCTAssertTrue(BackchannelLanguage.canVerifyAlternative(original: original, corroboration: heard))
            XCTAssertEqual(BackchannelLanguage.alternative(original: original, russian: candidate, corroboration: heard), candidate)
        }
    }

    func testRepeatedOnsetUsesActualRepeatCountAndRussianConversation() throws {
        let source = "Dá, dá, dá, gotóvo."
        let hearing = "Да-да-да, готово."
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(source, duration: 1.3, vocabulary: ""))
        let candidate = try XCTUnwrap(BackchannelLanguage.repeatedOnsetAlternative(original: source, padded: "Да, да, готово.",
            language: "Russian", isolated: "好了。", acoustic: hearing))
        XCTAssertEqual(candidate, hearing)
        let target = segment(3, source), russian = segment(1, "Посмотрим что получилось после обновления")
        let english = segment(1, "Please send the report on Wednesday")
        for (context, expected) in [(russian, hearing), (english, source)] {
            XCTAssertEqual(BackchannelLanguage.resolve([context, target], alternatives: [:],
                lexicalAlternatives: [target.id: candidate], preceding: [])[1].text, expected)
        }
    }

    func testRepeatedOnsetRequiresUnpromptedSupportForAllWords() {
        let source = "Dá, dá, dá, gotóvo."
        func check(_ padded: String = "Да, да, готово.", _ core: String = "好了。",
                   _ acoustic: String = "Да-да-да, готово.", _ language: String = "Russian") -> String? {
            BackchannelLanguage.repeatedOnsetAlternative(original: source, padded: padded, language: language,
                isolated: core, acoustic: acoustic)
        }
        XCTAssertNil(check("Да, да, готово.", source))
        XCTAssertNil(check("Да, да, готово.", "Tak, już gotowe."))
        XCTAssertNil(check("Да, да, готово.", "Нет, ещё рано."))
        XCTAssertNil(check("Да, да, готово.", "", "Да-да-да, готово."))
        XCTAssertNil(check("Да, да, готово.", "好了。", "Да-да-да, готово.", "Polish"))
        XCTAssertNil(check("Нет, нет, готово."))
        XCTAssertNil(check("Да, да, готово.", "好了。", "Да-да-да, не готово."))
        XCTAssertNil(check("Да, да, потом."))
        XCTAssertNil(check("Да, да, готово.", "好了。", "Да-да-да-да, готово."))
        XCTAssertNil(check("Да, да, готово.", "好了。", "Да-да, готово."))
        XCTAssertNil(check("Да, да, 20.", "好了。", "Да-да-да, 20."))
        for translation in ["Tak, tak, tak rób.", "Dá, dá, dá, zrobione."] {
            XCTAssertNil(BackchannelLanguage.repeatedOnsetAlternative(original: translation, padded: "Да, да, готово.",
                language: "Russian", isolated: "好了。", acoustic: "Да-да-да, готово."))
        }
        XCTAssertEqual(BackchannelLanguage.repeatedOnsetAlternative(original: "Nie, nie, nie, vídno.",
            padded: "Не, не, видно.", language: "Russian", isolated: "没有。", acoustic: "Не-не-не, видно."), "Не-не-не, видно.")
    }

    func testShortTimedClausesKeepQuotesNamesGlossaryAndFillerChains() {
        for source in ["Go ahead.", "Opération", "Could cela sujet.", "Yo там digo."] {
            XCTAssertTrue(BackchannelLanguage.shouldVerifyTimedClause(source, duration: 1, vocabulary: ""), source)
        }
        for source in ["«Go ahead»", "María López", "File.go", "DevOps rules", "OK.", "San José",
                       "Говоримо про ці речі.", "Knock", "Si", "Ah yeah."] {
            XCTAssertFalse(BackchannelLanguage.shouldVerifyTimedClause(source, duration: 1, vocabulary: ""), source)
        }
        XCTAssertFalse(BackchannelLanguage.shouldVerifyTimedClause("Opération", duration: 1, vocabulary: "Opération"))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyTimedClause("Go ahead.", duration: 4, vocabulary: ""))
    }

    func testTimedClauseChecksTokenTimesAndNeighboringWordsInBothReadings() throws {
        func read(_ words: [(String, Double)]) -> RecognitionAcousticResult {
            RecognitionAcousticResult(text: words.map(\.0).joined(separator: " "),
                words: words.map { .init(text: $0.0, start: $0.1, end: $0.1 + 0.2) })
        }
        let core = read([("Ну", 0.05), ("я", 0.31)])
        let wide = read([("Ну", 2.04), ("я", 2.32), ("сегодня", 2.62), ("снова", 3), ("попробую", 3.5)])
        let clause = try XCTUnwrap(BackchannelLanguage.timedClause(source: "All right.", isolated: core,
            wide: wide, interval: 2..<2.55))
        XCTAssertEqual(clause.text, "Ну я.")
        XCTAssertTrue(clause.confirmed(in: "Ну, я сегодня снова попробую."))
        XCTAssertTrue(clause.confirmed(in: "Ну я уж точно сегодня снова всё попробую."))
        XCTAssertFalse(clause.confirmed(in: "Ну, я скоро смогу попробовать."))
        XCTAssertFalse(clause.confirmed(in: "All right! Ну я сегодня снова попробую."))
        XCTAssertFalse(clause.confirmed(in: "Ну, я сегодня снова попробую. Ну я."))
        XCTAssertNil(BackchannelLanguage.timedClause(source: "All right.", isolated: core, wide: wide, interval: 1.7..<2.8))
        let interfering = read([("Ну", 2.04), ("погоди", 2.18), ("я", 2.32), ("сегодня", 2.62), ("снова", 3)])
        XCTAssertNil(BackchannelLanguage.timedClause(source: "All right.", isolated: core, wide: interfering, interval: 2..<2.55))
        let unclearOnset = read([("Эй", 0.03), ("выставки", 0.44)])
        let ending = read([("говорили", 0.6), ("после", 1), ("про", 1.5), ("выставки", 2.42)])
        let partial = try XCTUnwrap(BackchannelLanguage.timedClause(source: "Exposición", isolated: unclearOnset,
            wide: ending, interval: 2..<3))
        XCTAssertEqual(partial.text, "… выставки.")
        XCTAssertTrue(partial.confirmed(in: "Говорили после про выставки."))
        XCTAssertFalse(partial.confirmed(in: "Exposicion. Говорили после про выставки."))
        let name = read([("Убер", 0.03)])
        let heardName = read([("сегодня", 0.6), ("представили", 1), ("Убер", 2.03)])
        XCTAssertNil(BackchannelLanguage.timedClause(source: "Über", isolated: name, wide: heardName, interval: 2..<3))
        let agreement = read([("готовим", 0.7), ("документы", 1.1), ("подписываем", 2.42)])
        for start in ["Не", "Ни", "Без", "Две", "Ян", "Ли", "Он"] {
            let core = read([(start, 0.03), ("подписываем", 0.44)])
            XCTAssertNil(BackchannelLanguage.timedClause(source: "All right.", isolated: core, wide: agreement, interval: 2..<3), start)
        }
        let verb = try XCTUnwrap(BackchannelLanguage.timedClause(source: "All right.",
            isolated: read([("подписываем", 0.44)]), wide: agreement, interval: 2..<3))
        XCTAssertFalse(verb.confirmed(in: "Готовим документы не подписываем."))
        XCTAssertTrue(verb.confirmed(in: "Готовим документы подписываем."))
        let full = read([("не", 0.05), ("подписываем", 0.44)])
        let supported = read([("готовим", 0.7), ("документы", 1.1), ("не", 2.05), ("подписываем", 2.42)])
        XCTAssertEqual(BackchannelLanguage.timedClause(source: "All right.", isolated: full, wide: supported,
            interval: 2..<3)?.text, "Не подписываем.")
        XCTAssertFalse(partial.confirmed(in: "Говорили после про две выставки."))
        XCTAssertFalse(partial.confirmed(in: "Говорили после про не выставки."))
        XCTAssertFalse(partial.confirmed(in: "Говорили после про Михаила выставки."))
        let changed = read([("новой", 0.03), ("выставки", 0.44)])
        XCTAssertNil(BackchannelLanguage.timedClause(source: "Exposición", isolated: changed, wide: ending, interval: 2..<3))
    }

    func testConfirmedForeignClauseNeedsTheSameGovernedNounAndItsSecondOccurrence() throws {
        let core = RecognitionAcousticResult(text: "Макетом.", words: [.init(text: "Макетом", start: 0.04, end: 0.52)])
        func clause(_ before: [String], _ after: [String], source: String = "Make them.") throws -> BackchannelLanguage.TimedClause {
            let tokens = before + ["макетом"] + after
            let times = before.indices.map { 0.1 + Double($0) * 0.25 } + [2.04]
                + after.indices.map { 2.8 + Double($0) * 0.24 }
            let words = zip(tokens, times).map { RecognitionTimedWord(text: $0.0, start: $0.1, end: $0.1 + 0.2) }
            return try XCTUnwrap(BackchannelLanguage.timedClause(source: source, isolated: core,
                wide: .init(text: tokens.joined(separator: " "), words: words), interval: 2..<2.6))
        }
        let lead = ["работаем", "сегодня", "с"], tail = ["нам", "этот", "макет", "позже", "пригодится"]
        let proposal = try clause(lead, tail)
        let full = "Мы работаем сегодня с макетом. Нам этот макет позже пригодится."
        let other = "Работаю сегодня с макетом. Нам макет потом пригодится."
        XCTAssertTrue(proposal.confirmsRepeatedInstrumental(verifier: full, primary: other))
        let homograph = try clause(["обсудили", "тему", "с"], tail)
        let heard = "Обсудили тему с макетом. Нам этот макет пригодится."
        XCTAssertTrue(homograph.confirmsRepeatedInstrumental(verifier: heard, primary: heard))
        for reading in ["Мы работаем сегодня с макетом.", "Мы работаем сегодня над макетом. Нам этот макет пригодится.",
                        "Мы сегодня с новым макетом. Нам этот макет пригодится.",
                        "Сказали «сегодня с макетом». Нам этот макет пригодится."] {
            XCTAssertFalse(proposal.confirmsRepeatedInstrumental(verifier: reading, primary: full), reading)
            XCTAssertFalse(proposal.confirmsRepeatedInstrumental(verifier: full, primary: reading), reading)
        }
        XCTAssertFalse(try clause(lead, ["снова", "работаем"]).confirmsRepeatedInstrumental(verifier: full, primary: full))
        XCTAssertFalse(try clause(["обсудили", "это"], tail).confirmsRepeatedInstrumental(verifier: full, primary: full))
        XCTAssertFalse(try clause(lead, tail, source: "Mockup").confirmsRepeatedInstrumental(verifier: full, primary: full))
    }

    func testMidstemScriptSwitchOnAClauseUsesAnIndependentReadAndConversation() {
        let source = segment(11, "So no, caжès.", mic: false)
        XCTAssertTrue(BackchannelLanguage.shortMixedFragment(source.text, duration: 1, vocabulary: ""))
        let positive = BackchannelLanguage.mixedFragmentReading(original: source.text, reread: "So no, caжès.",
            language: "English", corroboration: "ну вот")
        XCTAssertFalse(positive.uncertain)
        let foreign = BackchannelLanguage.mixedFragmentReading(original: "So no, caжès.", reread: "So no, cažes.",
            language: "Spanish", corroboration: "да нет")
        XCTAssertFalse(foreign.uncertain)
        let unconfirmed = BackchannelLanguage.mixedFragmentReading(original: source.text, reread: "没办法",
            language: "Chinese", corroboration: "ну вот")
        XCTAssertTrue(unconfirmed.uncertain)
        XCTAssertNil(unconfirmed.alternative)
        for source in ["So no, caЖès.", "So no, Caseжès.", "So no, señor.", "So, nos llegó.", "«So no, caжès»."] {
            XCTAssertFalse(BackchannelLanguage.shortMixedFragment(source, duration: 1, vocabulary: ""), source)
        }
        XCTAssertFalse(BackchannelLanguage.shortMixedFragment(source.text, duration: 1, vocabulary: "caжès"))
        var overlapping = segment(10, "Сегодня мы обсудим это решение.")
        overlapping.end = 13
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id],
            preceding: [overlapping])[0].text, "Неразборчиво")
        overlapping.text = "Today we will discuss our plan."
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id],
            preceding: [overlapping]), [source])
    }

    private func segment(_ start: Double, _ text: String, mic: Bool = true) -> TranscriptSegment {
        var value = TranscriptSegment(start: start, end: start + 1, speaker: mic ? "Я" : "Собеседники", text: text)
        value.audioFile = mic ? "test-mic.caf" : "test-remote.caf"
        return value
    }

    func testBackchannelUsesRussianFromFollowingSpeech() {
        let short = segment(0, "Uh huh.")
        let speech = segment(5, "Давайте проверим показатели перед запуском проекта")
        let result = BackchannelLanguage.resolve([short, speech], alternatives: [short.id: "Угу."], preceding: [])
        XCTAssertEqual(result[0].text, "Угу.")
    }

    func testEnglishAndUnknownContextRemainUnchanged() {
        let short = segment(0, "Uh huh.")
        let english = segment(3, "Please send the report before Friday")
        XCTAssertEqual(BackchannelLanguage.resolve([short, english], alternatives: [short.id: "Угу."], preceding: [])[0].text, "Uh huh.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Угу."], preceding: [])[0].text, "Uh huh.")
        XCTAssertFalse(BackchannelLanguage.shouldRecheck("Uh huh, please send the report", duration: 3))
    }

    func testLiveWindowsUseRecentSpeechFromTheSameTrack() {
        let short = segment(16, "Hmm.")
        let russian = segment(5, "Давайте проверим показатели перед запуском проекта")
        let english = segment(15, "Please send the report before Friday", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([english, short], alternatives: [short.id: "Хм."], preceding: [russian])[1].text, "Хм.")
        let late = segment(100, "Hmm.")
        XCTAssertEqual(BackchannelLanguage.resolve([late], alternatives: [late.id: "Хм."], preceding: [russian])[0].text, "Hmm.")
    }

    func testOnlyAcousticallyRecognizedRussianBackchannelsAreAccepted() {
        XCTAssertTrue(BackchannelLanguage.acceptsAlternative("Угу."))
        XCTAssertFalse(BackchannelLanguage.acceptsAlternative("Давайте проверим проект"))
        XCTAssertFalse(BackchannelLanguage.acceptsAlternative(""))
    }

    func testShortWordsNeedIndependentRussianAcousticAgreement() {
        XCTAssertTrue(BackchannelLanguage.shouldRecheck("And what?", duration: 0.7))
        XCTAssertFalse(BackchannelLanguage.shouldRecheck("Please send the report", duration: 2))
        XCTAssertFalse(BackchannelLanguage.shouldRecheck("And what?", duration: 5))
        XCTAssertEqual(BackchannelLanguage.alternative(original: "And what?", russian: "Я вот.", corroboration: "Вот."), "Я вот.")
        XCTAssertNil(BackchannelLanguage.alternative(original: "And what?", russian: "И что?", corroboration: "An what."))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Friends.", russian: "Правильно.", corroboration: "Пац."))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Thank you.", russian: "Спасибо.", corroboration: "Thanks."))
    }

    func testVocalAcknowledgmentCanUseForcedRussianAudioDecode() {
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh huh.", russian: "угу", corroboration: "Нет."), "угу")
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh huh.", russian: "Да.", corroboration: "Угу."), "Угу.")
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh huh.", russian: "Нет.", corroboration: "Нет."))
        XCTAssertEqual(BackchannelLanguage.alternative(original: "uh-huh, yeah.", russian: "Угу, да.", corroboration: "Угу."), "Угу, да.")
    }

    func testCompoundAcknowledgmentUsesIndependentAudioInRussianContext() {
        var short = segment(71.6798125, "uh-huh, yeah.", mic: false)
        short.end = 72.9878125
        let russian = segment(68, "Теперь обсудим следующий вопрос проекта", mic: false)
        let english = segment(68, "Let us discuss the next question", mic: false)
        XCTAssertTrue(BackchannelLanguage.shouldRecheck(short.text, duration: short.end - short.start))
        // Automatic Qwen, forced Russian Qwen, and GigaAM outputs on the exact audio fragment.
        let alternative = BackchannelLanguage.alternative(original: short.text, russian: "Да.", corroboration: "Угу. Да.")
        XCTAssertEqual(alternative, "Угу. Да.")
        let alternatives = alternative.map { [short.id: $0] } ?? [:]
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [russian])[0].text, "Угу. Да.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [english])[0].text, short.text)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [])[0].text, short.text)
    }

    func testRepeatedAcknowledgmentsAreRetriedWithoutBecomingLanguageAnchors() {
        let repeated = segment(70, "Uh-huh, uh-huh.")
        let short = segment(71, "Hmm.")
        let russian = segment(74, "Теперь обсудим следующий вопрос проекта")
        XCTAssertTrue(BackchannelLanguage.shouldRecheck(repeated.text, duration: 2))
        XCTAssertFalse(BackchannelLanguage.shouldRecheck(repeated.text, duration: 4))
        XCTAssertEqual(BackchannelLanguage.alternative(original: repeated.text, russian: "Угу, угу.", corroboration: nil), "Угу, угу.")
        let result = BackchannelLanguage.resolve([repeated, short, russian], alternatives: [repeated.id: "Угу, угу.", short.id: "Хм."], preceding: [])
        XCTAssertEqual(result.map(\.text), ["Угу, угу.", "Хм.", russian.text])
    }

    func testOpenVowelFillersUseRussianAudioInRussianContext() {
        for (start, end, original, forced, independent) in [
            (11.607, 12.400, "Um.", "а.", "А"),
            (684.219, 685.164, "Ah.", "аа", "А"),
            (684.219, 685.164, "Ah-ah.", "А-а.", "А"),
            (2112, 2113, "Uh.", "Аааа.", "А"),
            (2112, 2113, "Uh.", "А-а-а-а.", "А"),
        ] {
            var short = segment(start, original, mic: false)
            short.end = end
            let russian = segment(start - 3, "Теперь обсудим следующий вопрос проекта", mic: false)
            let english = segment(start - 3, "Let us discuss the next question", mic: false)
            let alternative = BackchannelLanguage.alternative(original: original, russian: forced, corroboration: independent)
            XCTAssertEqual(alternative, forced)
            let alternatives = alternative.map { [short.id: $0] } ?? [:]
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [russian])[0].text, forced)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [english])[0].text, original)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [])[0].text, original)
        }
    }

    func testOpenVowelsDoNotDisplaceConfirmedAcknowledgmentsOrDictionaryTerms() {
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh-huh.", russian: "А.", corroboration: "Угу."), "Угу.")
        XCTAssertNil(BackchannelLanguage.alternative(original: "Ah.", russian: "А.", corroboration: "А", vocabulary: "Ah"))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Hmm.", russian: "Вот.", corroboration: nil))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh.", russian: "Аааа, да.", corroboration: nil))
    }

    func testRussianConversationLocalizesKnownFillersWithoutAnAudioAlternative() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта", mic: false)
        for (original, expected) in [
            ("Uh.", "А-а-а…"), ("Um.", "Ааа."), ("Ah!", "А!"), ("Hmm?", "Хм?"),
            ("Uh-huh.", "Угу."), ("Mhm.", "Угу."), ("Yeah.", "Да."), ("Yep.", "Да."),
            ("Yes.", "Да."), ("Da da da.", "Да, да, да."), ("Okay.", "Окей."), ("Sorry.", "Сорри."),
            ("Uh-huh, yeah.", "Угу, да."), ("Yeah,", "Да,"),
            ("Uh-huh, uh-huh.", "Угу, угу."),
        ] {
            let short = segment(30, original, mic: false)
            let result = BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian])
            XCTAssertEqual(result[0].text, expected, original)
        }
    }

    func testIsolatedHesitationAtTheEndOfRussianSpeech() {
        for mic in [false, true] {
            let russian = segment(10, "Давайте продолжим наше обсуждение.", mic: mic)
            let english = segment(10, "Let us continue our discussion.", mic: mic)
            for text in ["… uh", "... Uh", "Uh", "uh.", "Uh…", "Uh..."] {
                let reply = segment(12, text, mic: mic)
                XCTAssertEqual(BackchannelLanguage.resolve([russian, reply], alternatives: [:], preceding: [])[1].text, "А-а-а…", text)
                for context in [[], [english]] {
                    XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:], preceding: context), [reply])
                }
                XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:], preceding: [russian], vocabulary: "Uh"), [reply])
            }
            for (source, expected) in [("Uh?", "А-а-а?"), ("Uh-huh.", "Угу."), ("Uh, I agree.", "Uh, I agree."), ("«Uh»", "«Uh»")] {
                let reply = segment(12, source, mic: mic)
                XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:], preceding: [russian])[0].text, expected)
            }
        }
    }

    func testHyphenatedVowelIsOneSoundInFillerEvidence() {
        for stretched in ["А-а-а", "А‑а‑а", "Аааа"] {
            XCTAssertTrue(BackchannelLanguage.confirmsFillerSequence(original: "Uh, yeah.", reread: stretched + ", да.", corroboration: "Uh, да."))
        }
        XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: "Uh, yeah.", reread: "А, а, а, да.", corroboration: "Uh, да."))
    }

    func testFillerFallbackPreservesEnglishSpeechAndUnknownContext() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let english = segment(27, "Let us discuss the next question", mic: false)
        let short = segment(30, "Yeah.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian, english])[0].text, short.text)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [])[0].text, short.text)
        let apology = segment(30, "Sorry.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([apology], alternatives: [:], preceding: [russian, english])[0].text, "Sorry.")
        let latinRepetition = segment(30, "Da da da.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([latinRepetition], alternatives: [:], preceding: [english]), [latinRepetition])
        let quotedRepetition = segment(30, "«Da da da».")
        XCTAssertEqual(BackchannelLanguage.resolve([quotedRepetition], alternatives: [:], preceding: [russian]), [quotedRepetition])
        for text in ["Yeah, send the report.", "Uh-huh, John.", "Sorry, I cannot attend.", "Focus.", "Y-1."] {
            let speech = segment(30, text)
            XCTAssertEqual(BackchannelLanguage.resolve([speech], alternatives: [:], preceding: [russian])[0].text, text)
        }
    }

    func testClippedQuestionAndNamesDoNotHideAcknowledgmentsInRussianConversation() {
        var discussion = segment(10, "Давайте проверим сроки и обсудим наши дальнейшие действия.")
        discussion.end = 30
        let single = segment(13, "Mm-hmm.", mic: false)
        let fragment = segment(15, "Is this", mic: false)
        let named = segment(18, "Иван Петров — это кто?", mic: false)
        let repeated = segment(20, "Mm-hmm, mm-hmm.", mic: false)
        let acknowledgment = segment(24, "Ajá.", mic: false)
        let result = BackchannelLanguage.resolve([single, fragment, named, repeated, acknowledgment],
            alternatives: [:], preceding: [discussion])
        XCTAssertEqual(result.map(\.text), ["Угу.", "Is this", named.text, "Угу, угу.", "Ага."])
        let jargon = segment(12, "Ой, я уже как бы протранслировал это в текущем состоянии доапрува.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([single], alternatives: [:], preceding: [jargon])[0].text, "Угу.")

        for foreign in ["Is this?", "Are you ready?", "¿Puedes revisar el informe mañana?"] {
            let anchor = segment(12, foreign, mic: false)
            XCTAssertEqual(BackchannelLanguage.resolve([single, acknowledgment], alternatives: [:],
                preceding: [discussion, anchor]), [single, acknowledgment], foreign)
        }
        XCTAssertEqual(BackchannelLanguage.resolve([acknowledgment], alternatives: [:], preceding: []), [acknowledgment])
        for literal in ["«Ajá.»", "Ajá, seguimos mañana."] {
            let quoted = segment(16, literal, mic: false)
            XCTAssertEqual(BackchannelLanguage.resolve([quoted], alternatives: [:], preceding: [discussion]), [quoted])
        }
    }

    func testVocalAcknowledgmentsUseOverlappingRussianSpeechOnTheOtherTrack() {
        for (mic, text, expected, competingTurn) in [
            (true, "Mm-hmm.", "Угу.", "Что тр."),
            (false, "Mm-hmm, mm-hmm.", "Угу, угу.", "Ми сьогодні переглянемо зміни."),
            (true, "Hmm.", "Хм.", "We can discuss the next question."),
        ] {
            let reply = segment(20, text, mic: mic)
            var speech = segment(13, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: !mic)
            speech.end = 24
            let distant = segment(28, competingTurn, mic: mic)
            let resolved = BackchannelLanguage.resolve([speech, reply, distant], alternatives: [:], preceding: [])
            var localized = reply
            localized.text = expected
            XCTAssertEqual(resolved, [speech, localized, distant])

            for foreign in ["Are you ready?", "Ми сьогодні переглянемо зміни."] {
                let switchOfLanguage = segment(21.5, foreign, mic: mic)
                let mixed = BackchannelLanguage.resolve([speech, reply, switchOfLanguage], alternatives: [:], preceding: [])
                XCTAssertEqual(mixed, [speech, reply, switchOfLanguage], foreign)
            }
            XCTAssertEqual(BackchannelLanguage.resolve([speech, reply, distant], alternatives: [:], preceding: [],
                vocabulary: text)[1], reply)

            speech.end = reply.start
            XCTAssertEqual(BackchannelLanguage.resolve([speech, reply, distant], alternatives: [:], preceding: [])[1], reply)
        }

        var speech = segment(13, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: false)
        speech.end = 24
        let foreign = segment(28, "We can discuss the next question.")
        for text in ["«Mm-hmm».", "Mm-hmm, I agree.", "Ajá.", "Yeah."] {
            let reply = segment(20, text)
            XCTAssertEqual(BackchannelLanguage.resolve([speech, reply, foreign], alternatives: [:], preceding: [])[1], reply)
        }
    }

    func testCorroboratedAffirmationUsesOverlappingRussianContext() {
        var russianSpeech = segment(10, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: false)
        russianSpeech.end = 25
        let english = segment(16, "Are you ready?")
        let reply = segment(20, "Yeah.")
        let source = [russianSpeech, english, reply]
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], preceding: []).last?.text, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [reply.id: "Да."], preceding: []).last?.text, "Да.")
        let nearbyEnglish = segment(19, english.text)
        XCTAssertEqual(BackchannelLanguage.resolve([russianSpeech, nearbyEnglish, reply],
            alternatives: [reply.id: "Да."], preceding: []).last?.text, "Yeah.")
    }

    func testCorroboratedLexicalTurnUsesOverlappingRussianContext() {
        var russianSpeech = segment(10, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: false)
        russianSpeech.end = 25
        let distantTurn = segment(2, "Что тр.")
        let reply = segment(20, "Then you probably back.")
        let reading = "Это не правда так."
        let source = [distantTurn, russianSpeech, reply]
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], uncertain: [reply.id],
            preceding: []).last?.text, reply.text)
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], lexicalAlternatives: [reply.id: reading],
            preceding: []).last?.text, reading)
        let nearbyEnglish = segment(19, "Are you ready?")
        XCTAssertEqual(BackchannelLanguage.resolve([russianSpeech, nearbyEnglish, reply], alternatives: [:],
            lexicalAlternatives: [reply.id: reading], preceding: []).last?.text, reply.text)
    }

    func testIndependentEquivalentAcknowledgmentsPreserveEverySoundAndSentenceBoundary() {
        let primary = "Mm-hmm, mm hmm. Okay."
        XCTAssertTrue(BackchannelLanguage.confirmsFillerSequence(original: primary, reread: "Uh huh. Uh huh. Okay.", corroboration: "Угу, угу. О'кей."))
        XCTAssertTrue(BackchannelLanguage.confirmsFillerSequence(original: "Okay.", reread: "okei.", corroboration: "О’кей."))
        for (reread, acoustic) in [("Uh huh. Okay.", "Угу, угу. Окей."), ("Uh huh. Uh huh. Okay.", "Окей."), ("Is this?", "Угу, угу. Окей.")] {
            XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: primary, reread: reread, corroboration: acoustic))
        }
        XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: "Okko.", reread: "Okay.", corroboration: "Окей."))
        XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: "Okay.", reread: "okei.", corroboration: nil))
        let speech = segment(1, "Давайте обсудим оставшиеся вопросы.")
        let turn = segment(3, primary, mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], preceding: [speech])[0].text, "Угу, угу. Окей.")
        XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], preceding: [segment(1, "We can discuss the remaining questions.")])[0], turn)
    }

    func testFillerRereadPreservesTheNumberOfAcknowledgments() throws {
        let spelling = try XCTUnwrap(BackchannelLanguage.russianSpelling(ofFiller: "Mm-hmm, mm-hmm, okay."))
        XCTAssertTrue(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: spelling, candidate: "Ага, угу. О'кей."))
        XCTAssertFalse(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: spelling, candidate: "Угу, окей."))
        XCTAssertFalse(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: spelling, candidate: "Да, я согласен."))
        XCTAssertFalse(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: "угу", candidate: "Угу, угу."))
    }

    func testFillerChainWithOneUnknownSyllableDoesNotEstablishTheLanguageOfNeighboringReplies() {
        let russian = segment(1, "Давайте обсудим оставшиеся вопросы.")
        let repeated = segment(3, "Mm-hmm.", mic: false)
        let chain = segment(5, "Uhum, tá, ok, ok.", mic: false)
        let result = BackchannelLanguage.resolve([repeated, chain], alternatives: [:], preceding: [russian])
        XCTAssertEqual(result.map(\.text), ["Угу.", chain.text])
    }

    func testLeadingVocalizationBeforeUnpunctuatedRussianSpeech() {
        XCTAssertEqual(TranscriptOrthography.normalize("Uh по каким"), "А-а-а по каким")
        XCTAssertEqual(TranscriptOrthography.normalize("Uh значит работа."), "А-а-а значит работа.")
        for text in ["Uh I know.", "Uh ne знаю trend of", "Uh і", "Okay сегодня идёт дождь",
                     "«Uh значит работа».", "Uh то ми по"] {
            XCTAssertEqual(TranscriptOrthography.normalize(text), text)
        }
        XCTAssertEqual(TranscriptOrthography.normalize("Uh значит работа.", vocabulary: "Uh"), "Uh значит работа.")
    }

    func testMixedFillerChainsKeepRussianWordsAndSentencePunctuation() {
        let russian = segment(79, "Теперь обсудим следующий вопрос проекта")
        let english = segment(79, "Let us discuss the next question")
        for (original, expected) in [
            ("Uh huh. Да.", "Угу. Да."),
            ("Да, uh-huh! Хм? Okay…", "Да, угу! Хм? Окей…"),
            ("Hmm. Угу, yeah?", "Хм. Угу, да?"),
            ("Да. Uh. Huh?", "Да. А-а-а. А?"),
        ] {
            let short = segment(75, original)
            XCTAssertFalse(BackchannelLanguage.shouldRecheck(original, duration: 1))
            XCTAssertEqual(BackchannelLanguage.resolve([short, russian], alternatives: [:], preceding: [])[0].text, expected)
            XCTAssertEqual(BackchannelLanguage.resolve([short, english], alternatives: [:], preceding: [])[0].text, original)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [])[0].text, original)
        }
        for original in ["Да, Uh huh, John.", "Угу. Please continue.", "«Uh huh». Да.", "Да. Хм!"] {
            let short = segment(75, original)
            XCTAssertEqual(BackchannelLanguage.resolve([short, russian], alternatives: [:], preceding: [])[0].text, original)
        }
        let protected = segment(75, "Uh huh. Да.")
        XCTAssertEqual(BackchannelLanguage.resolve([protected, russian], alternatives: [:], preceding: [], vocabulary: "Uh huh")[0].text, protected.text)
    }

    func testNearbyShortEnglishSentenceOutweighsOlderRussianSpeech() {
        let russian = segment(0, "Теперь обсудим следующий вопрос проекта")
        let english = segment(10, "Are you ready?")
        let name = segment(10, "John Patrick Doe.")
        let short = segment(12, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian, english])[0].text, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian, name])[0].text, "Да.")
        XCTAssertEqual(BackchannelLanguage.resolve([english], alternatives: [english.id: "Вы готовы?"], preceding: [russian])[0].text, "Вы готовы?")
    }

    func testUnconfirmedEnglishTurnsDoNotSetLanguageForAdjacentAcknowledgments() {
        for (mic, text, filler, expected) in [
            (true, "Then you probably back.", "Yeah.", "Да."),
            (false, "I don't know if it's", "Mm-hmm, mm-hmm.", "Угу, угу."),
        ] {
            let russian = segment(10, "Сегодня мы обсудим последние изменения проекта.", mic: !mic)
            var foreign = segment(14, text, mic: mic)
            foreign.independentRecognitionLanguage = false
            let reply = segment(16, filler, mic: mic)
            var localized = reply
            localized.text = expected

            XCTAssertEqual(BackchannelLanguage.resolve([foreign, reply], alternatives: [:], preceding: [russian]),
                [foreign, localized], text)
            XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:], preceding: [russian, foreign]),
                [localized], text)

            foreign.independentRecognitionLanguage = true
            XCTAssertEqual(BackchannelLanguage.resolve([foreign, reply], alternatives: [:], preceding: [russian]),
                [foreign, reply], text)
        }
    }

    func testVerifiedRussianTurnDoesNotBlockAnAdjacentFiller() {
        let russian = segment(10, "Обсудим план работы команды на неделю.")
        let mistranscribed = segment(12, "Well, I think.")
        let filler = segment(13, "Yeah.")

        let result = BackchannelLanguage.resolve([russian, mistranscribed, filler],
            alternatives: [:], lexicalAlternatives: [mistranscribed.id: "Ну, я думаю."], preceding: [])

        XCTAssertEqual(result.map(\.text), [russian.text, "Ну, я думаю.", "Да."])
    }

    func testLexicalRecheckIncludesLongerShortTurnsAndContractions() {
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Yeah, I could send the notes after lunch because it's nearly ready", duration: 3.9))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Let me check later.", duration: 1.9))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("It’s all right.", duration: 2.8))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Yeah, I think that's a good", duration: 3.23))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Oh, you can, what’s the capital?", duration: 1.37))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("It’s all right.", duration: 6.01))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("I really think you had the right answer when we first spoke yesterday.", duration: 5))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Please pass me the drawing after this meeting.", duration: 12))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Red Green Blue Yellow", duration: 9))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Please pass me the drawing after this meeting.", duration: 30.01))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Русский текст с English words.", duration: 3))
    }

    func testShortEnglishReadingsCanBeRecheckedWithoutReplacingTheirWordsFromContext() {
        let russian = segment(10, "Сегодня мы обсудим последние изменения проекта.")
        for text in ["Why not?", "And that's", "Didn't make IT.", "Then you probably back.",
                     "No, it's a chance.", "I don't know if it's"] {
            let turn = segment(12, text)
            XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(text, duration: turn.end - turn.start), text)
            XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], preceding: [russian]), [turn], text)
            XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: text, russian: "Давайте обсудим.",
                corroboration: "Давайте проверим."), text)
        }
    }

    func testEnglishContractionsDoNotMatchDictionaryAcronyms() {
        let anchor = segment(5, "Сейчас мы обсудим оставшиеся вопросы проекта.")
        for text in ["No, it's a chance.", "It’s a chance.", "I don't know if it's"] {
            let turn = segment(7, text)
            XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(text, duration: 0.7, vocabulary: "IT"), text)
            let candidate = BackchannelLanguage.lexicalAlternative(original: text, russian: "Ну, не знаю.",
                corroboration: "ну не знаю", vocabulary: "IT")
            XCTAssertEqual(candidate, "Ну, не знаю.", text)
            XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], uncertain: [turn.id],
                preceding: [anchor], vocabulary: "IT").first?.text, "Неразборчиво", text)
        }
        for (text, vocabulary) in [("Didn't make IT.", "IT"), ("Ask about IT's roadmap.", "IT"),
                                   ("No, it's a chance.", "it's"), ("Confluence’s roadmap.", "Confluence")] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(text, duration: 0.7, vocabulary: vocabulary), text)
        }
    }

    func testFormattingAnEnglishPronounDoesNotProtectAnUnverifiedEnglishSentence() {
        let russian = segment(1, "Сегодня мы обсуждаем новую задачу.")
        for (primary, formatted) in [
            ("That's it.", "That's IT."), ("That's it for now.", "That's IT for now."), ("They saved it.", "They saved IT."),
            ("Part of it grew.", "Part of IT grew."), ("It fits in the box.", "IT fits in the box."),
        ] {
            let source = BackchannelLanguage.sourceForLanguageCheck(primary: primary, formatted: formatted, duration: 2, vocabulary: "IT")
            XCTAssertEqual(source, primary)
            XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(source, duration: 2, vocabulary: "IT"))
            let turn = segment(4, source)
            let alternative = BackchannelLanguage.lexicalAlternative(original: source, russian: "Мы вернёмся.",
                corroboration: "мы вернемся", vocabulary: "IT")
            XCTAssertEqual(alternative, "Мы вернёмся.")
            XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:],
                lexicalAlternatives: alternative.map { [turn.id: $0] } ?? [:], preceding: [russian], vocabulary: "IT")[0].text, alternative)
        }
        for protected in ["IT needs a new server.", "it", "Please ask Jira about it."] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(protected, duration: 2, vocabulary: "IT, Jira"))
        }
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("We discussed it today.", duration: 2, vocabulary: "it"))
    }

    func testShortForeignScriptNeedsTwoAudioReadingsAndIndependentConversationContext() {
        let russian = segment(1, "Сегодня мы обсуждаем новую задачу.")
        let foreign = segment(1, "Ми сьогодні обговорюємо нову задачу.")
        for text in ["Tämä käy.", "Nie, to się udało.", "Строить ну такі башти.", "Зелененьку ялинку різали."] {
            XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(text, duration: 2, vocabulary: ""), text)
            let source = segment(4, text)
            let heard = BackchannelLanguage.corroboratedScriptReread("Вернёмся чуть позже.", corroboration: "вернемся чуть позже")
            XCTAssertEqual(heard, "Вернёмся чуть позже.")
            let alternatives = heard.map { [source.id: $0] } ?? [:]
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: alternatives,
                preceding: [russian])[0].text, heard)
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: alternatives,
                preceding: [foreign]), [source])
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], preceding: [russian]), [source])
        }
        XCTAssertNil(BackchannelLanguage.corroboratedScriptReread("Вернёмся чуть позже.", corroboration: "вернемся завтра"))
        XCTAssertNil(BackchannelLanguage.corroboratedScriptReread("Вернёмся чуть позже.", corroboration: nil))
        XCTAssertTrue(BackchannelLanguage.confirmsCyrillicSource(original: "Їдемо на зустріч.", reread: "їдемо на зустріч", language: nil))
        XCTAssertTrue(BackchannelLanguage.confirmsCyrillicSource(original: "Їдемо на зустріч.", reread: "їду на зустріч", language: "Ukrainian"))
        XCTAssertFalse(BackchannelLanguage.confirmsCyrillicSource(original: "Їдемо на зустріч.", reread: "идем на встречу", language: "Russian"))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("«Їдемо на зустріч».", duration: 2, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Вітаємо Андрія.", duration: 2, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Їдемо на зустріч.", duration: 2, vocabulary: "зустріч"))
    }

    func testLocalCyrillicCorrectionRetainsAClippedOnsetWhenBothDecodersAgreeInsideTheTurn() {
        let original = "Носить вот такі перчатки."
        let reread = "Носить вот такие перчатки."
        func repair(_ language: String, _ independent: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: original, language: language, reread: reread, corroboration: independent)
        }
        XCTAssertEqual(repair("Russian", "Приносить вот такие перчатки."), reread)
        XCTAssertNil(repair("Russian", "Приносить вот те перчатки."))
        XCTAssertNil(repair("Russian", "Приносить вот такие коробки."))
        XCTAssertNil(repair("Ukrainian", "Приносить вот такие перчатки."))
    }

    func testLexicalAlternativeRequiresIndependentAgreementOnRussianWords() {
        let original = "Yeah, I think that’s a good"
        let decoded = "Да, я ещё тогда об этом говорил."
        let heard = "да я еще тогда об этом говорил"
        XCTAssertEqual(BackchannelLanguage.lexicalAlternative(original: original, russian: decoded, corroboration: heard), decoded)
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: decoded, corroboration: nil))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: decoded, corroboration: "да я еще об этом говорил"))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: original, corroboration: heard))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: original, corroboration: original))
    }

    func testLexicalRereadAllowsOneInternalWordBoundaryWithIdenticalSounds() {
        let primary = "Then you probably back."
        let candidate = "Это не правда так."
        XCTAssertEqual(BackchannelLanguage.lexicalAlternative(original: primary, russian: candidate,
            corroboration: "Это неправда так."), candidate)
        for disagreement in ["Это неправильно так.", "Неправда так.", "Это просто неправда."] {
            XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: primary, russian: candidate,
                corroboration: disagreement), disagreement)
        }
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: primary, russian: "Не правда так.",
            corroboration: "Неправда так."))
    }

    func testLanguageForcedRereadRetainsOnlyWordsAlsoHeardByTheAcousticRecognizer() {
        let original = "Can you still hear us?"
        func resolve(_ candidate: String, _ independent: String) -> String? {
            BackchannelLanguage.russianRereadAlternative(original: original, russian: candidate,
                corroboration: independent, vocabulary: "")
        }
        XCTAssertEqual(resolve("И здесь.", "и здесь"), "И здесь.")
        XCTAssertEqual(resolve("Нет, получилось.", "нет"), "Нет…")
        XCTAssertEqual(resolve("Откроем окно после обеда.", "откроем окно утром"), "Откроем окно…")
        XCTAssertNil(resolve("И получилось.", "и замолчал"))
        XCTAssertNil(resolve("Можно рисовать.", ""))
        XCTAssertNil(resolve("Да, получилось.", "Не слышно"))
        XCTAssertNil(resolve("Флимбикс шнупкор.", "флимбикс шнупкор"))
        XCTAssertNil(BackchannelLanguage.russianRereadAlternative(original: "«Can you still hear us?»", russian: "Нет.",
            corroboration: "Нет", vocabulary: ""))
    }

    func testLongForeignSentenceRecognizedWithASmallDifferenceRemainsEnglish() {
        let sentence = "We will mail you the updated schedule after our next meeting."
        XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: sentence,
            reread: "We'll mail you the updated schedule after our next meeting."))
        XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: sentence,
            reread: "We will mail you the schedule after our next meeting."))
        XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: sentence, reread: "We may talk after this call."))
        XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: "Can we?", reread: "Can you?"))
    }

    func testSparseLatinTurnRequiresALongLowDensityUnquotedClause() {
        let source = "This is the API."
        XCTAssertTrue(BackchannelLanguage.shouldVerifySparseLatinTurn(source, duration: 17))
        XCTAssertTrue(BackchannelLanguage.shouldVerifySparseLatinTurn(source, duration: 30))
        XCTAssertTrue(BackchannelLanguage.shouldVerifySparseLatinTurn("We can review the plan at noon today.", duration: 8))
        XCTAssertTrue(BackchannelLanguage.shouldVerifySparseLatinTurn("We can't do it for the new project.", duration: 12))

        XCTAssertFalse(BackchannelLanguage.shouldVerifySparseLatinTurn(source, duration: 7.9))
        XCTAssertFalse(BackchannelLanguage.shouldVerifySparseLatinTurn(source, duration: 30.1))
        XCTAssertFalse(BackchannelLanguage.shouldVerifySparseLatinTurn(source, duration: .infinity))
        XCTAssertFalse(BackchannelLanguage.shouldVerifySparseLatinTurn("We can review the whole plan at noon today.", duration: 8))
        for ordinary in ["He is okay.", "Head of Sales Operations", "«This is the API»", "This is the API 2",
                         "We can проверить the API again."] {
            XCTAssertFalse(BackchannelLanguage.shouldVerifySparseLatinTurn(ordinary, duration: 17), ordinary)
        }
    }

    func testCorroboratedRussianTurnRetainsTheAgreedWordsAfterAnInteriorConflict() {
        let original = "We can't check that."
        let reread = "Мы не сделаем просто с единым ВВП этот важный кейс на следующей неделе."
        let corroboration = "мы не сделаем просто с единым CDP этот важный кейс на следующей неделе"
        XCTAssertEqual(BackchannelLanguage.corroboratedRussianTurn(original: original, language: "Russian", reread: reread,
            corroboration: corroboration, vocabulary: ""),
            "Мы не сделаем просто с единым … этот важный кейс на следующей неделе.")
    }

    func testCorroboratedRussianTurnPreservesSpeechBetweenSeveralSmallConflicts() {
        let reread = "Мы собрали полный отчёт для единой комиссии и проверили данные за прошлую неделю. "
            + "Затем спокойно отправили материалы на ревью всем коллегам из нашей команды. "
            + "Если появятся новые вопросы мы обсудим их на следующем общем созвоне."
        let corroboration = "мы собрали полный отчет для новой группы и проверили данные за прошлую неделю. "
            + "Затем отправили материалы на ревью всем коллегам из нашей команды. "
            + "Если появятся новые проблемы мы обсудим их на следующем общем созвоне."
        let expected = "Мы собрали полный отчёт для … и проверили данные за прошлую неделю. "
            + "Затем … отправили материалы на ревью всем коллегам из нашей команды. "
            + "Если появятся новые … мы обсудим их на следующем общем созвоне."
        XCTAssertEqual(BackchannelLanguage.corroboratedRussianTurn(original: "They need the plan.", language: "Russian",
            reread: reread, corroboration: corroboration, vocabulary: ""), expected)
    }

    func testCorroboratedRussianTurnProtectsGlossaryAndIndependentlyHeardEnglish() {
        let original = "This is the API."
        let agreed = "Мы проверили новый API в проде и передали отчёт коллегам на ревью."
        let unprotected = "Мы проверили новый сервис в проде и передали отчёт коллегам на ревью."
        let mixed = "Мы проверили новый сервис, this is the API, и передали отчёт коллегам на ревью."
        func recover(_ language: String?, _ reread: String, _ heard: String) -> String? {
            BackchannelLanguage.corroboratedRussianTurn(original: original, language: language, reread: reread,
                corroboration: heard, vocabulary: "API")
        }
        XCTAssertEqual(recover("Russian", agreed, agreed.lowercased().replacingOccurrences(of: "ё", with: "е")), agreed)
        XCTAssertNil(recover("Russian", unprotected, unprotected))
        XCTAssertNil(recover("Russian", mixed, mixed))
        XCTAssertNil(recover("English", original, agreed))
        XCTAssertNil(recover(nil, agreed, agreed))
    }

    func testCorroboratedRussianTurnAlignsHesitationsAndHeardInitialismSpelling() {
        let source = "This is the API."
        let reread = "Вот и здесь нужно сверить общую CRM мы CRM настроим позднее. После встречи обсудим, какую схему мы будем использовать и когда проверим API нового каталога."
        let heard = "Э-э, вот. И здесь нужно сверить общую ERP. Мы ERP э-э настроим позднее. После встречи обсудим, какую схему мы будем использовать и когда проверим апи нового каталога."
        XCTAssertEqual(BackchannelLanguage.corroboratedRussianTurn(original: source, language: "Russian",
            reread: reread, corroboration: heard, vocabulary: "API"),
            "Вот и здесь нужно сверить общую … мы … настроим позднее. После встречи обсудим, какую схему мы будем использовать и когда проверим API нового каталога.")
    }

    func testCorroboratedRussianTurnRejectsDisputedNumbersAndNegation() {
        let original = "They need the plan."
        for (reread, corroboration) in [
            ("Мы решили сегодня согласовать новую схему работы с коллегами перед итоговым созвоном.",
             "Мы решили сегодня не согласовать новую схему работы с коллегами перед итоговым созвоном."),
            ("Мы проверили и отправили 125 заявок нашей команде в начале рабочего дня.",
             "Мы проверили и отправили 126 заявок нашей команде в начале рабочего дня."),
            ("Мы проверили и отправили сто заявок нашей команде в начале рабочего дня.",
             "Мы проверили и отправили двести заявок нашей команде в начале рабочего дня."),
        ] {
            XCTAssertEqual(BackchannelLanguage.corroboratedRussianTurn(original: original, language: "Russian",
                reread: reread, corroboration: reread, vocabulary: ""), reread)
            XCTAssertNil(BackchannelLanguage.corroboratedRussianTurn(original: original, language: "Russian",
                reread: reread, corroboration: corroboration, vocabulary: ""), corroboration)
        }
    }

    func testCorroboratedRussianTurnRequiresEnoughAgreementAndBothEdges() {
        let original = "They need the plan."
        let agreed = "Мы сверили сроки проекта с командой и подготовили итоговый отчёт."
        XCTAssertEqual(BackchannelLanguage.corroboratedRussianTurn(original: original, language: "Russian",
            reread: agreed, corroboration: agreed, vocabulary: ""), agreed)
        for (reread, corroboration) in [
            (agreed, "Мы сверили сроки встречи с коллегами и подготовили итоговый отчёт."),
            (agreed, "Они сверили сроки проекта с командой и подготовили итоговый отчёт."),
            (agreed, "Мы сверили сроки проекта с командой и подготовили итоговый документ."),
            ("Утром мы проверили нашу схему перед созвоном.", "Утром мы проверили нашу схему перед созвоном."),
        ] {
            XCTAssertNil(BackchannelLanguage.corroboratedRussianTurn(original: original, language: "Russian",
                reread: reread, corroboration: corroboration, vocabulary: ""), corroboration)
        }
    }

    func testNoSpeechRequiresExplicitAbstentionAndAnEmptyIndependentResult() {
        XCTAssertTrue(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: " \n", corroboration: " \t"))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: nil, text: "", corroboration: ""))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: "", corroboration: nil))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "English", text: "", corroboration: ""))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "Chinese", text: "", corroboration: ""))
    }

    func testConflictingSubsecondHesitationRetainsAudioWithoutInventingAnEnglishWord() {
        let russian = segment(1, "Давайте вернёмся к обсуждению проекта", mic: false)
        let english = segment(1, "Please send the report before Friday", mic: false)
        var hesitation = segment(4, "Well.", mic: false)
        hesitation.end = 4.4
        let confirmed = BackchannelLanguage.resolve([hesitation], alternatives: [:], preceding: [russian])
        XCTAssertEqual(confirmed, [hesitation])
        let uncertain = BackchannelLanguage.resolve([hesitation], alternatives: [:], uncertain: [hesitation.id], preceding: [russian])
        var expected = hesitation
        expected.text = "Неразборчиво"
        XCTAssertEqual(uncertain, [expected])
        XCTAssertEqual(BackchannelLanguage.resolve([hesitation], alternatives: [:], uncertain: [hesitation.id], preceding: [english]), [hesitation])
        XCTAssertEqual(BackchannelLanguage.resolve([hesitation], alternatives: [:], uncertain: [hesitation.id], preceding: [russian], vocabulary: "Well"), [hesitation])
    }

    func testAnyRecognizedSpeechPreventsNoSpeechRejection() {
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: "", corroboration: "да"))
        for text in ["Угу.", "Well.", "好。"] {
            XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: text, corroboration: ""), text)
        }
    }

    func testIndependentAgreementPreservesForeignLatinSpeech() {
        for (original, reread) in [("Bonjour!", "bonjour."), ("Hola, buenos dias.", "HOLA BUENOS DIAS"),
                                    ("Ça va?", "ça va."), ("It's fine.", "It’s fine!")] {
            XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: original, reread: reread), original)
        }
        for (original, reread) in [("Bonjour.", "Hello."), ("Hola, buenos dias.", "Hola."),
                                    ("Да.", "Да."), ("Good, да.", "Good, да."), ("好。", "好。"),
                                    ("…", "…"), ("2026", "2026"), ("Well.", "")] {
            XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: original, reread: reread), original)
        }
    }

    func testIsolatedTurnConfirmsAQuoteOrRequiresIndependentRussianWords() {
        for text in ["Exactly.", "Let's eat.", "Product we do.", "Sí, perdón.", "That's it.", "Oi."] {
            let quote = BackchannelLanguage.isolatedLatinReading(original: text, reread: text,
                language: "English", corroboration: "Всё готово.", vocabulary: "IT")
            XCTAssertEqual(quote, .source, text)
            let russian = BackchannelLanguage.isolatedLatinReading(original: text, reread: "Всё готово.",
                language: "Russian", corroboration: "все готово", vocabulary: "IT")
            XCTAssertEqual(russian, .russian("Всё готово."), text)
            let disagreement = BackchannelLanguage.isolatedLatinReading(original: text, reread: "Всё готово.",
                language: "Russian", corroboration: "ещё рано", vocabulary: "IT")
            XCTAssertEqual(disagreement, .disputed, text)
            XCTAssertNil(BackchannelLanguage.isolatedLatinReading(original: text, reread: "Всё готово.",
                language: "Russian", corroboration: nil, vocabulary: "IT"), text)
        }
        XCTAssertEqual(BackchannelLanguage.isolatedLatinReading(original: "Sí, perdón.", reread: "Si, perdon.",
            language: "Spanish", corroboration: nil, vocabulary: ""), .source)
        for text in ["Product API", "«Let's eat.»", "Exactly@example.org"] {
            XCTAssertNil(BackchannelLanguage.isolatedLatinReading(original: text, reread: "Пока.",
                language: "Russian", corroboration: "пока", vocabulary: "API"), text)
        }
    }

    func testDisputedAccentedPhraseRetainsAudioAndRespectsConversationLanguage() {
        let source = segment(7, "Sí, perdón.", mic: false)
        let russian = segment(2, "Сегодня посмотрим какие задачи остались.", mic: false)
        let spanish = segment(2, "Vamos a revisar las tareas pendientes.", mic: false)
        var uncertain = source
        uncertain.text = "Неразборчиво"
        func resolve(after context: [TranscriptSegment], vocabulary: String = "") -> [TranscriptSegment] {
            BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id],
                preceding: context, vocabulary: vocabulary)
        }
        XCTAssertEqual(resolve(after: [russian]), [uncertain])
        XCTAssertEqual(resolve(after: [spanish]), [source])
        XCTAssertEqual(resolve(after: []), [source])
        XCTAssertEqual(resolve(after: [russian], vocabulary: "perdón"), [source])
    }

    func testUnconfirmedTurnsUseRussianContextAndKeepTheirAudio() {
        let russian = segment(10, "Обсудим план работы команды на неделю.", mic: false)
        for mic in [true, false] {
            let unclear = segment(12, "I mean.", mic: mic)
            let filler = segment(13, "Yeah.", mic: mic)
            let uncertain: Set<UUID> = [unclear.id, filler.id]
            var marked = unclear
            marked.text = "Неразборчиво"
            var localized = filler
            localized.text = "Да."

            var overlappingMic = segment(12, "Давайте обсудим следующий вопрос проекта")
            overlappingMic.end = 15
            let result = BackchannelLanguage.resolve([unclear, filler], alternatives: [:], uncertain: uncertain, preceding: [russian, overlappingMic])
            XCTAssertEqual(result, [marked, localized])

            let withFiller = BackchannelLanguage.resolve([unclear, filler], alternatives: [:], uncertain: [unclear.id], preceding: [russian, overlappingMic])
            XCTAssertEqual(withFiller, [marked, localized])
        }
    }

    func testDisputedRemoteTurnUsesNearbySameTrackLanguageWithoutMicrophoneOverlap() {
        let remote = segment(14, "Let me check later.", mic: false)
        let russian = segment(11, "Давайте обсудим следующий вопрос проекта")
        let sameTrack = segment(14, russian.text, mic: false)
        var unclear = remote
        unclear.text = "Неразборчиво"
        XCTAssertEqual(BackchannelLanguage.resolve([remote], alternatives: [:], uncertain: [remote.id],
            preceding: [sameTrack]), [unclear])
        for other in [segment(14, "Hmm."), segment(14, "We could discuss the next question.")] {
            let result = BackchannelLanguage.resolve([remote], alternatives: [:], uncertain: [remote.id], preceding: [other])
            XCTAssertEqual(result, [remote])
        }
    }

    func testSharedAlphabetShortReplyNeedsTwoAudioReadingsAndRussianConversation() {
        let short = segment(14, "Це такое?", mic: false)
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(short.text, duration: 0.574))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(short.text, duration: 2.1))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(short.text, duration: 0.574, vocabulary: "Це"))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("«Це такое?»", duration: 0.574))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: short.text, russian: "Что такое.", corroboration: "Что там?"))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: short.text, russian: "Что тогда.", corroboration: "Что тогда."))
        let alternative = BackchannelLanguage.lexicalAlternative(original: short.text, russian: "что такое.", corroboration: "Что такое!")
        XCTAssertEqual(alternative, "Что такое?")
        let choices = alternative.map { [short.id: $0] } ?? [:]
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], lexicalAlternatives: choices, preceding: []), [short])
        let russian = segment(11, "Давайте обсудим следующий вопрос проекта")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], lexicalAlternatives: choices, preceding: [russian])[0].text, "Что такое?")
    }

    func testUnconfirmedTurnsNeedIndependentRussianContext() {
        let russian = segment(10, "Обсудим план работы команды на неделю.", mic: false)
        let english = segment(12, "Are you ready?", mic: false)
        let unclear = segment(14, "I mean.", mic: false)
        let filler = segment(15, "Yeah.", mic: false)
        let uncertain: Set<UUID> = [unclear.id, filler.id]
        let source = [unclear, filler]
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], uncertain: uncertain, preceding: [russian, english]), source)
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], uncertain: uncertain, preceding: []), source)
    }

    func testUnconfirmedLongSentenceWithRussianContextKeepsAudioAndProtectsGlossaryAndQuotes() {
        let russian = segment(10, "Обсудим план работы команды на неделю.")
        let quoted = segment(12, "«I mean».")
        let named = segment(14, "Well, Jira.")
        var long = segment(16, "Please send this one later.")
        long.end = 23
        let source = [quoted, named, long]
        let actual = BackchannelLanguage.resolve(source, alternatives: [:], uncertain: Set(source.map(\.id)),
            preceding: [russian], vocabulary: "Jira")
        XCTAssertEqual(actual.map(\.text), [quoted.text, named.text, "Неразборчиво"])
        XCTAssertEqual(actual[2].audioFile, long.audioFile)
        XCTAssertEqual(actual[2].id, long.id)
    }

    func testResumeUsesSavedLanguageEvidenceAndOnlySafeLegacyAnchors() throws {
        var independent = segment(10, "Сегодня проверим новый рисунок.")
        independent.independentRecognitionLanguage = true
        var disputed = segment(11, "Сегодня проверим другой рисунок.")
        disputed.independentRecognitionLanguage = false
        var legacy = segment(13, "Сегодня проверим все доступные рисунки.")
        legacy.end = 20
        let legacyShort = segment(21, "Сегодня проверим цвет.")
        let source = [independent, disputed, legacy, legacyShort]
        let restored = try JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored.filter(BackchannelLanguage.canRestoreLanguageAnchor), [independent, legacy])
        let turn = segment(23, "Can you still hear us?")
        let result = BackchannelLanguage.resolve([turn], alternatives: [:],
            lexicalAlternatives: [turn.id: "Сейчас проверим."], preceding: restored.filter(BackchannelLanguage.canRestoreLanguageAnchor))
        XCTAssertEqual(result[0].text, "Сейчас проверим.")
    }

    func testAudioAlternativesOutrankTheUnclearMarker() {
        let russian = segment(10, "Обсудим план работы команды на неделю.")
        let lexical = segment(12, "I mean.")
        let vocal = segment(14, "Um.")
        let actual = BackchannelLanguage.resolve([lexical, vocal], alternatives: [lexical.id: "Я имею в виду.", vocal.id: "Эм."],
            lexicalAlternatives: [lexical.id: "Я думаю."], uncertain: [lexical.id, vocal.id], preceding: [russian])
        XCTAssertEqual(actual.map(\.text), ["Я думаю.", "Эм."])
    }

    func testLexicalRecheckPreservesQuotesIdentifiersAndGlossary() {
        for text in ["‘Right’", "“It’s all right”", "\"Good\"", "«Well»", "`Well`", "well.example", "well_right", "C++", "Right/Good"] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(text, duration: 2), text)
            XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: text, russian: "Да.", corroboration: "да"), text)
        }
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Well, Jira.", duration: 2, vocabulary: "Jira"))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: "Well, Jira.", russian: "Ну, Джира.", corroboration: "ну джира", vocabulary: "Jira"))
    }

    func testStandaloneTechnicalTermsKeepTheirSpellingEvenWithoutAPersonalDictionary() {
        let russian = segment(10, "Сегодня проверяем новый проект.")
        for term in ["MCP Figma", "API", "GraphQL", "proof of concept"] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(term, duration: 2), term)
            XCTAssertFalse(BackchannelLanguage.shouldRecheck(term, duration: 2), term)
            let source = segment(12, term)
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id], preceding: [russian]), [source])
        }
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Apple Music", duration: 2, vocabulary: "Apple Music"))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Sort of weird.", duration: 2))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Oh No.", duration: 2))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Can you see the screen?", duration: 2))
    }

    func testCompactTransliterationNeedsFullRussianAcousticAgreementAndIndependentContext() {
        let russian = segment(10, "Сегодня обсудим цвет новой картинки.")
        let source = segment(12, "Переdaча novogo risunka.")
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(source.text, duration: 2, vocabulary: ""))
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript("Otóż tak było.", duration: 2, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript(source.text, duration: 7, vocabulary: ""))
        for protected in ["«Otóż tak było».", "Witaj Jan Kowalski.", "Сегодня пишем proof of concept.", "Проверили MCP Figma."] {
            XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript(protected, duration: 2, vocabulary: ""), protected)
        }
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Witaj żuraw.", duration: 2, vocabulary: "żuraw"))
        let heard = BackchannelLanguage.agreedRussianText("Передача нового рисунка.", corroboration: "передача нового рисунка")
        XCTAssertEqual(heard, "Передача нового рисунка.")
        XCTAssertNil(BackchannelLanguage.agreedRussianText("Передача нового рисунка.", corroboration: "нового рисунка"))
        XCTAssertNil(BackchannelLanguage.agreedRussianText("Передача нового рисунка.", corroboration: nil))
        let alternatives = heard.map { [source.id: $0] } ?? [:]
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:],
            lexicalAlternatives: alternatives, preceding: [russian])[0].text, heard)
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id], preceding: [russian]), [source])
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: alternatives, preceding: []), [source])
    }

    func testMixedTurnCorroboratesTheLeadingAcknowledgmentAndOmitsUnfinishedTail() {
        func heard(_ source: String, _ candidate: String, _ corroboration: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: source, language: "Russian", reread: candidate, corroboration: corroboration)
        }
        XCTAssertEqual(heard("Mm-hmm, zrób to.", "Записала.", "Угу. Записала."), "Угу. Записала.")
        XCTAssertEqual(heard("Uh widzę снимок.", "Уже видела снимок и", "А-а, уже видела снимок и ка..."), "Уже видела снимок…")
        XCTAssertEqual(heard("Uh po вам", "По вам.", "А по нам опять"), "По вам.")
        XCTAssertNil(heard("Uh go мы", "Го мы.", "А го не туда"))
        XCTAssertNil(heard("Mm-hmm, zrób to.", "Записала.", "Не записала."))
        XCTAssertNil(heard("Uh widzę снимок.", "Уже видела снимок", "А-а, уже меняла снимок."))
        XCTAssertNil(heard("Uh po вам", "По ним.", "А по нам опять"))
        XCTAssertNil(heard("Uh po вам", "По вам.", "А при вас опять"))
    }

    func testVocalizationBeforeOneRussianWordNeedsTheSameOnsetAndWordFromAudio() {
        let source = "Uh готов."
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(source, duration: 0.8, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("«Uh готов»", duration: 0.8, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Uh Артём", duration: 0.8, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript(source, duration: 0.8, vocabulary: "Uh"))
        func result(_ acoustic: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: source, language: "None", reread: "", corroboration: acoustic)
        }
        XCTAssertEqual(result("А-а, готов."), "А-а, готов.")
        XCTAssertNil(result("А-а, готова."))
        XCTAssertNil(result("Угу, готов."))
        XCTAssertNil(result("Готов."))
    }

    func testWordWithTwoScriptsKeepsItsRussianNeighborsAndNeedsTwoAcousticReadings() throws {
        let primary = "Это гpaфика."
        let index = try XCTUnwrap(BackchannelLanguage.mixedWordIndex(primary, duration: 0.7, vocabulary: ""))
        let revised = BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "То графика.", corroboration: "Это графика.")
        XCTAssertEqual(revised, "Это графика.")
        XCTAssertEqual(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "То графика.",
            corroboration: "Это графика.", isolatedCorroboration: "Графика."), revised)
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "То графика.",
            corroboration: "Это графика.", isolatedCorroboration: "Графика потом."))
        XCTAssertTrue(BackchannelLanguage.confirmsOriginalMixedWordContext(original: primary, rendered: "EtO гpaфика.",
            index: index, corroboration: "Это графика."))
        XCTAssertFalse(BackchannelLanguage.confirmsOriginalMixedWordContext(original: primary, rendered: "EtO гpaфика.",
            index: index, corroboration: "Там графика."))
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "Это график.", corroboration: "Это графика."))
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "Это графика.", corroboration: "Там графика."))
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "Это кошка.", corroboration: "Это кошка."))
        let short = "Uh смеna"
        let second = try XCTUnwrap(BackchannelLanguage.mixedWordIndex(short, duration: 0.6, vocabulary: ""))
        XCTAssertEqual(BackchannelLanguage.restoredMixedWord(short, index: second, reread: "Смена.", corroboration: "А-а, смена"), "смена")
        for protected in ["Это гpaФика.", "Это «гpaфика».", "Это гpaфика.exe", "Это iCloud графика.", "Это гpaфика V2."] {
            XCTAssertNil(BackchannelLanguage.mixedWordIndex(protected, duration: 1, vocabulary: ""), protected)
        }
        XCTAssertNil(BackchannelLanguage.mixedWordIndex(primary, duration: 1, vocabulary: "гpaфика"))
        XCTAssertNil(BackchannelLanguage.mixedWordIndex(primary, duration: 6, vocabulary: ""))
        let source = segment(2, primary)
        let context = segment(0, "Сегодня обсудим новый рисунок.")
        let resolved = BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: [source.id: try XCTUnwrap(revised)],
            preceding: [context])
        XCTAssertEqual(resolved[0].text, "Это графика.")
    }

    func testShortMixedFragmentsUseOnlyTheAudioAndIndependentConversation() throws {
        let russian = segment(0, "Сегодня давайте обсудим эту задачу.")
        let ukrainian = segment(0, "Сьогодні ми обговорюємо цю задачу.")
        for text in ["Systemна.", "Uh фічі.", "Planовый.", "Hmm, зустріч."] {
            XCTAssertTrue(BackchannelLanguage.shortMixedFragment(text, duration: 0.8, vocabulary: ""), text)
            let source = segment(2, text)
            let agreed = BackchannelLanguage.mixedFragmentReading(original: text, reread: "Позже.",
                language: "Russian", corroboration: "позже")
            let candidate = try XCTUnwrap(agreed.alternative)
            XCTAssertFalse(agreed.uncertain)
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:],
                lexicalAlternatives: [source.id: candidate], preceding: [russian])[0].text, "Позже.")
            let disputed = BackchannelLanguage.mixedFragmentReading(original: text, reread: "Позже.",
                language: "Russian", corroboration: "сейчас")
            XCTAssertNil(disputed.alternative)
            XCTAssertTrue(disputed.uncertain)
            var unclear = source
            unclear.text = "Неразборчиво"
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id],
                preceding: [russian]), [unclear])
            for context in [[], [ukrainian]] {
                XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id],
                    preceding: context), [source])
                XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:],
                    lexicalAlternatives: [source.id: candidate], preceding: context), [source])
            }
            let missing = BackchannelLanguage.mixedFragmentReading(original: text, reread: "Позже.",
                language: "Russian", corroboration: nil)
            XCTAssertNil(missing.alternative)
            XCTAssertFalse(missing.uncertain)
        }
    }

    func testShortMixedFragmentProtectsNamesLiteralsAndIndependentlyHeardSwitches() {
        for text in ["«Systemна».", "Systemна.cc", "APIшка", "MyTeamна.", "Figmaна.", "Testами.",
                     "«Uh фічі».", "Uh Марії.", "Uh new.", "Uh перевод.", "Пишемо нові фічі."] {
            XCTAssertFalse(BackchannelLanguage.shortMixedFragment(text, duration: 1, vocabulary: ""), text)
        }
        for (text, glossary) in [("Systemна.", "System"), ("Systemна.", "Systemна"),
                                 ("Uh фічі.", "фічі"), ("Uh фічі.", "Uh")] {
            XCTAssertFalse(BackchannelLanguage.shortMixedFragment(text, duration: 1, vocabulary: glossary))
        }
        for (primary, reread, language) in [("Uh фічі.", "Ці фічі!", "Ukrainian"),
                                            ("Uh фічі.", "Фічі.", "Unknown"), ("Systemна.", "System на.", "Russian"),
                                            ("Systemна.", "System.", "English")] {
            let checked = BackchannelLanguage.mixedFragmentReading(original: primary, reread: reread, language: language,
                corroboration: "позже")
            XCTAssertNil(checked.alternative)
            XCTAssertFalse(checked.uncertain)
        }
        for (full, short) in [("А-а, фичи.", "Фичи."), ("Фичи.", "А-а, фичи.")] {
            let reading = BackchannelLanguage.mixedFragmentReading(original: "Uh фічі.", reread: full, language: "Russian",
                corroboration: short)
            XCTAssertEqual(reading.alternative, "А-а, фичи.")
        }
        for evidence in ["Угу, фичи.", "А-а, встречи.", "А-а, не фичи."] {
            XCTAssertNil(BackchannelLanguage.mixedFragmentReading(original: "Uh фічі.", reread: "Фичи.",
                language: "Russian", corroboration: evidence).alternative)
        }
    }

    func testMixedFillerRequiresTwoFullReadingsAndPreservesMultiplicity() {
        func heard(_ source: String, _ candidate: String, _ corroboration: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: source, language: "English", reread: candidate, corroboration: corroboration)
        }
        let source = "Uhum, ža, okay, ok."
        let check = "Uh huh. Da okay, okay."
        XCTAssertEqual(heard(source, check, "Угу. Да, окей, о’кей."), "Угу. Да, окей, окей.")
        XCTAssertNil(heard(source, check, "Угу. Да, окей."))
        XCTAssertNil(heard(source, "Okay, da okay, okay.", "Угу. Да, окей, окей."))
        XCTAssertNil(heard("Проект, ža, okay, ok.", check, "Угу. Да, окей, окей."))
        XCTAssertNil(heard("Uhum, ža, okay, ok.", check, "Uh huh. Da okay, okay."))
        XCTAssertNil(heard("Uhum, но, okay, ok.", check, "Угу. Да, окей, окей."))
    }

    func testLexicalCorrectionsDoNotEstablishConversationLanguage() {
        let first = segment(20, "Well, I think.")
        var second = segment(22, "Yeah, I think that’s a good")
        second.end = 25.23
        let filler = segment(26, "Yeah.")
        let turns = [first, second, filler]
        let alternatives = [first.id: "Ну, я думаю.", second.id: "Да, я тоже так считаю."]
        let result = BackchannelLanguage.resolve(turns, alternatives: [:], lexicalAlternatives: alternatives, preceding: [])
        XCTAssertEqual(result.map(\.text), turns.map(\.text))

        let russian = segment(15, "Обсудим план работы команды на неделю.")
        let english = segment(19, "Are you ready?")
        let withEnglish = BackchannelLanguage.resolve(turns, alternatives: [:], lexicalAlternatives: alternatives, preceding: [russian, english])
        XCTAssertEqual(withEnglish.map(\.text), turns.map(\.text))

        let withRussian = BackchannelLanguage.resolve(turns, alternatives: [:], lexicalAlternatives: alternatives, preceding: [russian])
        XCTAssertEqual(withRussian.map(\.text), ["Ну, я думаю.", "Да, я тоже так считаю.", "Да."])
    }

    func testFillerFallbackPreservesQuotedAndPathLikeLiterals() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        for text in ["`Yes`", "«Yes»", "\"Yes\"", "'Yes'.", "yes/yes", "yes.yes", "Yeah 2", "Okay+"] {
            let short = segment(30, text)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian])[0].text, text)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Да."], preceding: [russian])[0].text, text)
        }
        let filler = segment(30, "Uh-huh,yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([filler], alternatives: [:], preceding: [russian])[0].text, "Угу, да.")
        let quotedApology = segment(30, "«Sorry».")
        XCTAssertEqual(BackchannelLanguage.resolve([quotedApology], alternatives: [quotedApology.id: "Сорри."], preceding: [russian])[0].text, "«Sorry».")
    }

    func testForeignCyrillicTurnsAreNotRussianAnchors() {
        let earlier = segment(0, "Сегодня мы проверим новый проект.")
        let reply = segment(12, "I mean.")
        for anchor in ["Ми сьогодні перевіряємо новий проєкт.", "Мы працуем над новым праектам.", "Мы працуем над планам.",
                       "Мы сёння ўдакладняем тэрміны сустрэчы."] {
            let result = BackchannelLanguage.resolve([reply], alternatives: [:],
                lexicalAlternatives: [reply.id: "Ну да."], preceding: [earlier, segment(10, anchor)])
            XCTAssertEqual(result[0], reply, anchor)
            let acknowledgment = segment(12, "Mm-hmm.")
            XCTAssertEqual(BackchannelLanguage.resolve([acknowledgment], alternatives: [:],
                preceding: [earlier, segment(10, anchor)]), [acknowledgment], anchor)
        }
        let quote = segment(10, "«Сегодня мы проверим новый проект».")
        XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:],
            lexicalAlternatives: [reply.id: "Ну да."], preceding: [quote])[0], reply)
    }

    func testEqualDistanceConflictingLanguagesDoNotRewriteTheReply() {
        let left = segment(10, "Сегодня мы проверим новый проект.")
        let right = segment(14, "Let us review this project.")
        let reply = segment(12, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([left, reply, right], alternatives: [:], preceding: [])[1], reply)
    }

    func testTechnicalNamesInTheFollowingRussianTurnDoNotVetoAudioEvidence() {
        let before = segment(10, "Давайте обсудим последние изменения.", mic: false)
        var disputed = segment(11, "Yeah, they can see that.", mic: false)
        disputed.end = 12.28
        let after = segment(disputed.end, "В Luma и Demo добавили акварель.", mic: false)
        let heard = "Сейчас проверим."
        let turns = [before, disputed, after]
        XCTAssertEqual(BackchannelLanguage.resolve(turns, alternatives: [:],
            lexicalAlternatives: [disputed.id: heard], preceding: [])[1].text, heard)
        XCTAssertEqual(BackchannelLanguage.resolve(turns, alternatives: [:],
            uncertain: [disputed.id], preceding: [])[1].text, "Неразборчиво")
        XCTAssertEqual(BackchannelLanguage.resolve(turns, alternatives: [:], preceding: []), turns)
    }

    func testUncertainCyrillicAnchorUsesNearbyIndependentSpeechOnBothSides() {
        let left = segment(18, "Давайте начнём с нового рисунка.")
        let weak = segment(19, "Что тр.")
        let reply = segment(20, "Oh, look.")
        let right = segment(23, "Сейчас выберем подходящий цвет.")
        func resolved(_ context: [TranscriptSegment], uncertain: Bool = false) -> String {
            BackchannelLanguage.resolve([reply], alternatives: [:],
                lexicalAlternatives: uncertain ? [:] : [reply.id: "Тут."],
                uncertain: uncertain ? [reply.id] : [], preceding: context)[0].text
        }
        XCTAssertEqual(resolved([left, weak, right]), "Тут.")
        XCTAssertEqual(resolved([left, weak, right], uncertain: true), "Неразборчиво")
        for context in [[weak], [left, weak], [weak, right], [left, weak, segment(55, right.text)],
                        [left, weak, segment(23, "We should move on.")], [left, segment(19, "Are we ready?"), right],
                        [left, segment(19, "Ми сьогодні переглянемо зміни."), right]] {
            XCTAssertEqual(resolved(context), reply.text)
        }
    }

    func testRepeatedRussianFillersDoNotEstablishLanguageInFollowingWindows() {
        let repeated = segment(25, "Да, да, да, да.")
        let short = segment(30, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [repeated])[0].text, short.text)
    }

    func testLongFillerSequenceLocalizesWithoutRequestingAnAudioRetry() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let english = segment(25, "Let us discuss the next question")
        var short = segment(30, "Yeah! Yeah! Yeah! Yeah!")
        short.end = 34.1
        XCTAssertFalse(BackchannelLanguage.shouldRecheck(short.text, duration: short.end - short.start))
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian])[0].text, "Да, да, да, да!")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [english])[0].text, short.text)
    }

    func testAudioAlternativeTakesPrecedenceOverFillerFallback() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let short = segment(30, "Um.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Эм."], preceding: [russian])[0].text, "Эм.")
    }

    func testFillerFallbackAndAudioKeepDictionarySpelling() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let short = segment(30, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian], vocabulary: "Yeah")[0].text, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Да."], preceding: [russian], vocabulary: "Yeah")[0].text, "Yeah.")
        let apology = segment(30, "Sorry.")
        XCTAssertEqual(BackchannelLanguage.resolve([apology], alternatives: [:], preceding: [russian], vocabulary: "Sorry")[0].text, "Sorry.")
    }

    func testCompoundAcknowledgmentDoesNotRelaxChecksForEnglishWordsOrDictionaryTerms() {
        XCTAssertNil(BackchannelLanguage.alternative(original: "Yeah.", russian: "Да.", corroboration: nil))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh-huh, John.", russian: "Угу.", corroboration: nil))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh-huh, yeah.", russian: "Угу, да.", corroboration: "Угу.", vocabulary: "Yeah"))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh-huh, yeah.", russian: "Угу, нет.", corroboration: nil))
    }

    func testVerifiedShortWordStillRequiresRussianConversation() {
        let short = segment(30, "And what?", mic: false)
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта", mic: false)
        let english = segment(25, "Let us discuss the next question", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Вот."], preceding: [russian])[0].text, "Вот.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Вот."], preceding: [english])[0].text, "And what?")
    }

    func testShortLanguageRetryCannotUndoDictionarySpelling() {
        XCTAssertNil(BackchannelLanguage.alternative(original: "Confluence.", russian: "Конфлюенс.", corroboration: "Конфлюенс.", vocabulary: "Confluence"))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Hmm.", russian: "Хм.", corroboration: "Хм.", vocabulary: "Hmm"))
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh huh.", russian: "Угу.", corroboration: "Нет.", vocabulary: "Confluence"), "Угу.")
    }
    func testUnresolvedShortReplyRetriesWithLeadingSilenceWithoutChangingAudio() {
        let samples: [Float] = [0.2, -0.4, 0.1]
        let retry = BackchannelLanguage.retryAudio(samples)
        XCTAssertEqual(retry.count, samples.count + 2_000)
        XCTAssertTrue(retry.prefix(2_000).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(retry.suffix(samples.count)), samples)
    }

    func testRetriedLexicalReplyRequiresAgreementAndRussianContext() {
        let original = "Yeah, right."
        let candidate = "Давай, давай."
        XCTAssertNil(BackchannelLanguage.alternative(original: original, russian: candidate, corroboration: "Давай."))
        let alternative = BackchannelLanguage.alternative(original: original, russian: candidate, corroboration: "Давай давай.")
        XCTAssertEqual(alternative, candidate)
        let short = segment(30, original, mic: false)
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта", mic: false)
        let english = segment(25, "Let us discuss the next question", mic: false)
        let alternatives = [short.id: candidate]
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [russian])[0].text, candidate)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [english])[0].text, original)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [])[0].text, original)
    }

}
