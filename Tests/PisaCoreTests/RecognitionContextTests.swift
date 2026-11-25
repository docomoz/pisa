import XCTest
@testable import PisaCore

final class RecognitionContextTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, _ text: String, track: String = "remote") -> TranscriptSegment {
        var segment = TranscriptSegment(start: start, end: end, speaker: "Собеседник", text: text)
        segment.audioFile = "test-\(track).caf"
        return segment
    }

    func testDictionaryWordDoesNotVouchForTheRestOfAShortClause() throws {
        let before = segment(0, 6, "Сегодня мы обсуждаем новый продукт.")
        let target = segment(7, 8, "Product we do.")
        let after = segment(8.2, 12, "Дальше мы обсудим новый план.")
        let snapshot = RecognitionContext(segments: [before, target, after])
        let clause = try XCTUnwrap(snapshot.glossaryClause(for: target, vocabulary: "Product, IT"))
        let evidence = RecognitionAcousticResult(text: "группы новых идей чтобы продолжить", words: [
            .init(text: "группы", start: 0.4, end: 0.9), .init(text: "новых", start: 1.0, end: 1.3),
            .init(text: "идей", start: 1.4, end: 1.8), .init(text: "чтобы", start: 2.1, end: 2.4)
        ])
        func revised(_ core: String, _ wide: String, _ language: String? = "Russian") -> String? {
            clause.revisedText(isolated: core, language: language, acoustic: evidence, interval: 1..<2, widePrimary: wide)
        }
        XCTAssertEqual(revised("Новых идей.", "группы новых идей чтобы продолжить"), "Новых идей.")
        XCTAssertEqual(revised("новых людей", "группы новых идей чтобы продолжить"), "Неразборчиво")
        XCTAssertNil(revised("новых людей", "группы Product we do чтобы продолжить"))
        XCTAssertNil(revised("Product we do.", "группы новых идей чтобы продолжить", "English"))
        XCTAssertNil(clause.revisedText(isolated: "новых идей", language: "Russian", acoustic: evidence,
            interval: 3..<4, widePrimary: "группы новых идей чтобы продолжить"))
        XCTAssertNil(snapshot.glossaryClause(for: target, vocabulary: "Product we do"))
        XCTAssertNil(snapshot.glossaryClause(for: segment(7, 8, "«Product we do»."), vocabulary: "Product"))
        XCTAssertNil(snapshot.glossaryClause(for: segment(7, 8, "Acme Product Studio."), vocabulary: "Product"))
        let english = segment(0, 6, "Let us discuss the new product.")
        XCTAssertNil(RecognitionContext(segments: [english, target, after]).glossaryClause(for: target, vocabulary: "Product"))
        let overlapping = segment(7.1, 7.9, "Да, договорились.")
        let sameTrack = RecognitionContext(segments: [before, target, overlapping, after])
        XCTAssertNil(sameTrack.glossaryClause(for: target, vocabulary: "Product"))
        let microphone = segment(7.1, 7.9, "Да, договорились.", track: "mic")
        let separateTrack = RecognitionContext(segments: [before, target, microphone, after])
        let available = try XCTUnwrap(separateTrack.glossaryClause(for: target, vocabulary: "Product"))
        XCTAssertEqual(available.revisedText(isolated: "Новых идей.", language: "Russian", acoustic: evidence,
            interval: 1..<2, widePrimary: "группы новых идей чтобы продолжить"), "Новых идей.")
    }

    func testGlossaryClauseKeepsANameConfirmedInTheRussianReading() throws {
        let before = segment(0, 6, "Мы сегодня обсуждаем задачу.")
        let target = segment(7, 8, "I use Figma.")
        let after = segment(8.2, 12, "Дальше обсудим следующий проект.")
        let context = RecognitionContext(segments: [before, target, after])
        let clause = try XCTUnwrap(context.glossaryClause(for: target, vocabulary: "Figma"))
        func revise(_ core: String, _ acoustic: String, _ wide: String) -> String? {
            let words = RussianRecognition.words(acoustic).enumerated().map { index, word in
                RecognitionTimedWord(text: word, start: Double(index) * 0.2, end: Double(index + 1) * 0.2)
            }
            return clause.revisedText(isolated: core, language: "Russian", acoustic: .init(text: acoustic, words: words),
                interval: 0..<1, widePrimary: wide)
        }
        let mixed = "Мы используем Figma."
        XCTAssertEqual(revise(mixed, "мы используем фигму", "В отделе мы используем Figma для проекта."), mixed)
        XCTAssertEqual(revise(mixed, "мы используем почту", mixed), "Неразборчиво")
        XCTAssertEqual(revise(mixed, "мы обсуждаем фигму", mixed), "Неразборчиво")
        XCTAssertEqual(revise(mixed, "мы используем фигму", "В отделе обсуждают Figma."), "Неразборчиво")
        XCTAssertEqual(revise("Мы закончили.", "мы закончили", "В отделе мы закончили работу в Figma."), "Мы закончили.")
    }

    func testContextualScriptRepairRequiresTimeAlignedIndependentSpeech() throws {
        let target = segment(10, 12, "Провіряємо Т С П далі.")
        let before = segment(4, 9, "Сегодня мы будем проверять TCP.")
        let after = segment(13, 18, "Потом мы проверим ещё одно соединение.")
        let plan = try XCTUnwrap(RecognitionContext(segments: [before, target, after]).scriptRepair(for: target,
            vocabulary: "TCP"))
        let words = ["Давайте", "проверим", "свой", "TCP", "дальше", "вместе"]
        let evidence = RecognitionAcousticResult(text: words.joined(separator: " "),
            words: zip(words, [0.2, 1.1, 1.5, 1.8, 2.5, 3.4]).map {
                RecognitionTimedWord(text: $0.0, start: $0.1, end: $0.1 + 0.2)
            })
        func result(_ primary: String, _ verifier: String, language: String = "Russian") -> String? {
            plan.revised(acoustic: evidence, target: 1..<3, primary: primary, verifier: verifier, language: language)
        }
        XCTAssertEqual(result("Давайте проверим свой T C P дальше вместе.", "Давайте проверим свой TCP дальше вместе."),
                       "Проверим свой TCP дальше.")
        XCTAssertNil(result("Провіряємо Т С П далі.", "Провіряємо Т С П далі.", language: "Ukrainian"))
        XCTAssertNil(result("Давайте проверим свой TCP дальше вместе.", "Провіряємо Т С П далі.", language: "Ukrainian"))
        XCTAssertNil(plan.revised(acoustic: .init(text: evidence.text, words: []), target: 1..<3,
            primary: evidence.text, verifier: evidence.text, language: "Russian"))
        var foreign = target
        foreign.independentRecognitionLanguage = true
        XCTAssertNil(RecognitionContext(segments: [before, foreign, after]).scriptRepair(for: foreign, vocabulary: "TCP"))
    }

    func testShortReplyUsesTheWordInsideItsOwnTimeAndAnchorsOnEachSide() throws {
        let before = segment(1, 6, "Сегодня обсуждаем план нашей команды.")
        let after = segment(9, 10, "Очень круто.")
        for (original, core, word) in [("Uh фічі.", "", "фичи"), ("Oi.", "Ой!", "ой"),
                                        ("Exactly.", "Запно.", "внезапно"), ("Exactly.", "Запа.", "внезапно")] {
            let target = segment(7, 7.8, original)
            let reply = try XCTUnwrap(RecognitionContext(segments: [before, target, after]).timedReply(for: target, vocabulary: ""))
            let words = ["мы", "обсудили", "сегодня", word, "очень", "круто"]
            let evidence = RecognitionAcousticResult(text: words.joined(separator: " "), words:
                zip(words, [0.2, 0.6, 1.2, 3.46, 4.9, 5.1]).map { .init(text: $0.0, start: $0.1, end: $0.1 + 0.4) })
            let interval = 3.5..<4.3
            let heard = try XCTUnwrap(reply.candidate(acoustic: evidence, interval: interval, isolated: core))
            let result = word.capitalized + "."
            XCTAssertEqual(reply.confirmedText(heard, verifier: evidence.text, language: "Russian") {
                XCTFail("Matching timed and multilingual evidence already confirms the word"); return ""
            }, result)
            XCTAssertEqual(reply.confirmedText(heard, verifier: "Мы обсудили сегодня другое. Очень круто.", language: "Russian") {
                evidence.text
            }, result)
            XCTAssertNil(reply.confirmedText(heard, verifier: "Мы обсудили сегодня " + original + " Очень круто.", language: "Russian") {
                evidence.text
            })
            XCTAssertNil(reply.confirmedText(heard, verifier: word + " очень круто.", language: "Russian") { "" })
            XCTAssertNil(reply.confirmedText(heard, verifier: evidence.text, language: "Ukrainian") { evidence.text })
            XCTAssertNil(reply.candidate(acoustic: evidence, interval: 3.95..<4.9, isolated: core))
            XCTAssertNil(reply.candidate(acoustic: evidence, interval: interval, isolated: "кошки"))
        }
    }

    func testTimedReplyPreservesForeignConversationQuotedWordsAndGlossary() {
        let before = segment(1, 6, "Мы сегодня обсуждали план.")
        let after = segment(9, 14, "Дальше мы вернёмся к этому вопросу.")
        let target = segment(7, 7.8, "Oi.")
        func plan(_ source: TranscriptSegment, _ anchors: [TranscriptSegment], vocabulary: String = "") -> RecognitionContext.TimedReply? {
            RecognitionContext(segments: anchors + [source]).timedReply(for: source, vocabulary: vocabulary)
        }
        XCTAssertNil(plan(target, [before, after], vocabulary: "Oi"))
        XCTAssertNil(plan(segment(7, 7.8, "«Oi»."), [before, after]))
        XCTAssertNil(plan(segment(7, 7.8, "Figma."), [before, after]))
        XCTAssertNil(plan(target, [before, segment(9, 14, "Please check the appendix.")]))
        XCTAssertNil(plan(target, []))
        XCTAssertNil(plan(target, [before, after, segment(7.1, 7.5, "Параллельный разговор.")]))
    }

    func testOneSidedShortReplyRequiresTheExactIsolatedWordAndAllThreeWideReads() throws {
        for (original, core, wide) in [("Max.", "Макс.", "Макс, что за бутылки?"),
                                       ("No.", "Ну", "Ну, да-да, я начал тестировать варианты.")] {
            var target = segment(7, 7.8, original)
            target.independentRecognitionLanguage = true
            let after = segment(8.1, 10, "Что за бутылки?")
            let snapshot = RecognitionContext(segments: [target, after])
            let plan = try XCTUnwrap(snapshot.timedReply(for: target, vocabulary: ""))
            let keys = RussianRecognition.words(wide)
            let evidence = RecognitionAcousticResult(text: wide, words: keys.enumerated().map {
                let start = $0.offset == 0 ? 3.52 : 4.5 + 0.2 * Double($0.offset)
                return .init(text: $0.element, start: start, end: start + 0.2)
            })
            let word = try XCTUnwrap(plan.candidate(acoustic: evidence, interval: 3.5..<4.3, isolated: core))
            XCTAssertEqual(plan.confirmedText(word, verifier: wide, language: "Russian") { wide }, keys[0].capitalized + ".")
            XCTAssertNil(plan.confirmedText(word, verifier: wide, language: "Russian") { "Другое слово." })
            XCTAssertNil(plan.confirmedText(word, verifier: "Другое слово.", language: "Russian") { wide })
            XCTAssertNil(plan.confirmedText(word, verifier: wide, language: "Russian") { original + " " + wide })
            XCTAssertNil(plan.candidate(acoustic: evidence, interval: 3.5..<4.3, isolated: ""))
            XCTAssertNil(snapshot.timedReply(for: target, vocabulary: original))
            if original == "Max." {
                let label = "Макс. Что за бутылки?"
                XCTAssertNil(plan.confirmedText(word, verifier: label, language: "Russian") { label })
                let object = "Мы купили Макс, что за бутылки?"
                XCTAssertNil(plan.confirmedText(word, verifier: object, language: "Russian") { object })
            }
        }
    }

    func testScriptRepairChangesOnlyOneAnchoredWordConfirmedOnItsOwnAudio() throws {
        let old = "Значит, мы сейчас уже включаєм эту кнопку вместе."
        let target = segment(10, 15, old)
        let previous = segment(4, 9, "Мы планировали сегодня проверить установку.")
        let plan = try XCTUnwrap(RecognitionContext(segments: [previous, target]).scriptRepair(for: target, vocabulary: ""))
        let heard = "Кажется мы сейчас уже включаем эту кнопку вместе"
        let evidence = RecognitionAcousticResult(text: heard, words: heard.split(separator: " ").enumerated().map {
            .init(text: String($0.element), start: Double($0.offset) / 2, end: Double($0.offset + 1) / 2)
        })
        let wide = "Вероятно мы сейчас уже включаем эту кнопку вместе."
        func confirm(_ local: String, label: String = "Russian", primary: String? = nil) -> String? {
            plan.revised(acoustic: evidence, target: 0..<5, primary: primary ?? wide, verifier: wide, language: "Russian",
                confirmWord: { span in
                    XCTAssertEqual(span, 1.5..<3)
                    return (local, label)
                })
        }
        XCTAssertEqual(confirm("Уже включаем эту."), "Значит, мы сейчас уже включаем эту кнопку вместе.")
        XCTAssertNil(confirm("Уже включаєм цю.", label: "Ukrainian"))
        XCTAssertNil(confirm("Уже включаем эту.", label: "English"))
        XCTAssertNil(confirm("Уже выключаем эту."))
        XCTAssertNil(confirm("Уже включаем эту.", primary: "Вероятно мы сейчас уже выключаем эту кнопку вместе."))
        XCTAssertNil(confirm("Уже включаем эту.", primary: wide + " " + wide))
    }

    func testTimedScriptPrefixRestoresOnlyAudioSupportedWords() throws {
        let before = segment(2, 8, "Мы сегодня обсуждаем план работ.")
        let original = "В новій студії ми зібрали нашу групу біля вікна."
        let prefix = "В новой студии мы собрали нашу группу"
        func timed(_ text: String, offset: Double) -> RecognitionAcousticResult {
            .init(text: text, words: text.split(separator: " ").enumerated().map { i, word in
                .init(text: String(word), start: offset + Double(i) * 0.3, end: offset + Double(i + 1) * 0.3)
            })
        }
        func recover(_ source: String, narrow: String = "В новой студии мы сограли нашу группу перед перерывом",
                     checked: String = "Новой студии мы собрали нашу группу после объявления",
                     primary: String = "В новой студии мы собрали нашу группу после выступления",
                     language: String = "Russian", offset: Double = 0) throws -> String? {
            let target = segment(10, 12.7, source)
            let plan = try XCTUnwrap(RecognitionContext(segments: [before, target]).scriptRepair(for: target, vocabulary: ""))
            return plan.timedPrefix(acoustic: timed(prefix + " перед перерывом", offset: offset), target: 0..<2.7,
                primary: "Раньше. " + prefix + " после выступления.", verifier: prefix + " затем разошлись.",
                language: "Russian", exact: { .init(acoustic: timed(narrow, offset: 0), verifier: checked, language: language) },
                exactPrimary: { primary })
        }
        XCTAssertEqual(try recover(original), prefix + "…")
        XCTAssertNil(try recover(original, language: "Ukrainian"))
        XCTAssertNil(try recover(original, language: "Belarusian"))
        XCTAssertNil(try recover(original, offset: 3))
        // The disputed word and the remaining tail cannot pass on either
        // wide context or the exact multilingual verifier alone.
        XCTAssertNotEqual(try recover(original, primary: "В новой студии мы открыли нашу группу."), prefix + "…")
        for suffix in [" Ивана.", " пять.", " не.", " перерывом."] {
            XCTAssertNil(try recover(original + suffix), suffix)
        }
    }

    func testShortTimedScriptOpeningPreservesTheDisputedRemainderAndRejectsOverlap() throws {
        let before = segment(1, 8, "Давайте теперь обсудим план работ.")
        let target = segment(10, 13, "Мы собираєм ті речи біля вокзалу.")
        let context = RecognitionContext(segments: [before, target])
        let plan = try XCTUnwrap(context.scriptRepair(for: target, vocabulary: ""))
        let words = ["Мы", "собираем", "посылки", "перед", "обедом"]
        let audio = RecognitionAcousticResult(text: words.joined(separator: " "), words: words.enumerated().map { i, word in
            .init(text: word, start: Double(i) * 0.6, end: Double(i + 1) * 0.6)
        })
        let exact = RecognitionContext.ContextualScriptRepair.IsolatedReading(acoustic: audio,
            verifier: "Мы собираем заявки по телефону.", language: "Russian")
        func result(_ plan: RecognitionContext.ContextualScriptRepair) -> String? {
            plan.timedPrefix(acoustic: audio, target: 0..<3, primary: "Мы собираем заявки для почты.",
                verifier: "Мы собираем письма для почты.", language: "Russian", exact: { exact }, exactPrimary: { "" })
        }
        XCTAssertEqual(result(plan), "Мы собираем ті речи біля вокзалу.")
        let unchanged = segment(10, 13, "Мы собираем ті речи біля вокзалу.")
        XCTAssertNil(result(try XCTUnwrap(RecognitionContext(segments: [before, unchanged]).scriptRepair(for: unchanged, vocabulary: ""))))
        let overlap = segment(12, 14, "Вторая реплика.")
        XCTAssertNil(RecognitionContext(segments: [before, target, overlap]).scriptRepair(for: target, vocabulary: ""))
        let separate = segment(12, 14, "Вторая реплика.", track: "mic")
        XCTAssertNotNil(RecognitionContext(segments: [before, target, separate]).scriptRepair(for: target, vocabulary: ""))
    }

    func testScriptRepairUsesExactIsolatedWordsWhenWideReadsDisagreeOnACaseEnding() throws {
        let target = segment(10, 11.4, "Каталога й табліца.")
        let previous = segment(4, 9, "Сегодня мы проверим новую версию.")
        let plan = try XCTUnwrap(RecognitionContext(segments: [previous, target]).scriptRepair(for: target, vocabulary: ""))
        let evidence = RecognitionAcousticResult(text: "из каталога и таблицы", words: [
            .init(text: "из", start: 2, end: 4.02), .init(text: "каталога", start: 4.02, end: 4.6),
            .init(text: "и", start: 4.6, end: 4.8), .init(text: "таблицы", start: 4.8, end: 5.4)])
        func read(_ core: String, language: String = "Russian") -> String? {
            plan.revised(acoustic: evidence, target: 4..<5.4, primary: "Из каталога и таблица.",
                         verifier: "Из каталога и лица.", language: "Russian", isolated: (core, language))
        }
        XCTAssertEqual(read("Каталога и таблицы."), "Каталога и таблицы.")
        XCTAssertNil(read("Из каталога и таблицы."))
        XCTAssertNil(read("Каталога и таблица."))
        XCTAssertNil(read("Каталога и таблицы.", language: "English"))
        XCTAssertNil(read("Каталогу і таблиці.", language: "Ukrainian"))
        for language in ["Ukrainian", "English"] {
            XCTAssertNil(plan.revised(acoustic: evidence, target: 4..<5.4, primary: evidence.text,
                verifier: evidence.text, language: "Russian", isolated: ("Каталогу і таблиці.", language)))
        }
    }

    func testScriptRepairPreservesIdentifiersAndRequiresCoverageOfTheOriginalTurn() throws {
        let before = segment(1, 6, "Сегодня мы проверим соединение через шлюз.")
        func replace(_ old: String, with text: String, vocabulary: String = "") throws -> String? {
            let target = segment(10, 14, old)
            let plan = try XCTUnwrap(RecognitionContext(segments: [before, target]).scriptRepair(for: target,
                vocabulary: vocabulary))
            let heard = RecognitionAcousticResult(text: text, words: text.split(separator: " ").enumerated().map {
                .init(text: String($0.element), start: Double($0.offset) / 3, end: Double($0.offset + 1) / 3)
            })
            return plan.revised(acoustic: heard, target: 0..<4, primary: text, verifier: text, language: "Russian")
        }
        XCTAssertNil(try replace("Сегодня ми перевіряємо OpenVPN на сервері.", with: "Сегодня проверяем настройки на сервере"))
        XCTAssertNil(try replace("Сегодня ми перевіряємо Полюс на сервері.", with: "Сегодня проверяем настройки на сервере",
                                 vocabulary: "Полюс"))
        XCTAssertNil(try replace("Сегодня ми перевіряємо доступ з усіх робочих станцій.", with: "Сегодня проверяем"))
        XCTAssertEqual(try replace("Компілятор і бібліотека.", with: "Компилятор и библиотека"), "Компилятор и библиотека.")
    }

    func testTwoWideDecodersCanRecoverOneWordBesideAnIndependentlyHeardTerm() throws {
        let target = segment(10, 12, "Настроїмо Т С П сьогодні.")
        let before = segment(1, 7, "Сегодня мы проверим соединение через TCP.")
        let plan = try XCTUnwrap(RecognitionContext(segments: [before, target]).scriptRepair(for: target, vocabulary: "TCP"))
        let heard = RecognitionAcousticResult(text: "Настроим TCP сегодня", words: [
            .init(text: "Настроим", start: 0.8, end: 1.5), .init(text: "TCP", start: 1.8, end: 2.2),
            .init(text: "сегодня", start: 2.4, end: 2.9)])
        func reread(_ other: String) -> String? {
            plan.revised(acoustic: heard, target: 0..<3, primary: "Потом настроим свой TCP сегодня вместе.",
                         verifier: other, language: "Russian")
        }
        XCTAssertEqual(reread("Затем настроим свой TSP сегодня вместе."), "Настроим свой TCP сегодня.")
        XCTAssertNotEqual(reread("Затем настроим этот TSP сегодня вместе."), "Настроим свой TCP сегодня.")
        XCTAssertNotEqual(reread("Затем настроим свой сервер сегодня вместе."), "Настроим свой TCP сегодня.")
        let withNegation = plan.revised(acoustic: heard, target: 0..<3, primary: "Настроим никогда TCP сегодня.",
                                        verifier: "Настроим никогда TCP сегодня.", language: "Russian")
        XCTAssertFalse(withNegation?.contains("никогда") == true)
    }

    func testSegmentedInitialismOnlyChangesMatchingLetters() throws {
        let target = segment(10, 14, "Можно включать Т С Пи?")
        let before = segment(1, 6, "Сегодня мы проверим соединение через TCP.")
        let plan = try XCTUnwrap(RecognitionContext(segments: [before, target]).scriptRepair(for: target, vocabulary: "TCP"))
        let heard = RecognitionAcousticResult(text: "Включи TCP сейчас", words: [
            .init(text: "Включи", start: 1.0, end: 1.6), .init(text: "TCP", start: 2.0, end: 2.6),
            .init(text: "сейчас", start: 3.0, end: 3.3)])
        XCTAssertEqual(plan.revised(acoustic: heard, target: 1..<4, primary: "Можно включать ти си пи?",
            verifier: "Можно выключить TSP?", language: "Russian"), "Можно включать TCP?")
        XCTAssertNil(plan.revised(acoustic: heard, target: 3..<4, primary: "Можно включать TCP?",
            verifier: "TCP", language: "Russian"))
        for literal in ["Введи по буквам Т С Пи.", "Можно включать Т, С, Пи?", "Можно включать Т СП?"] {
            let dictation = segment(10, 14, literal)
            XCTAssertNil(RecognitionContext(segments: [before, dictation]).scriptRepair(for: dictation, vocabulary: "TCP"))
        }
    }

    func testShortArticleRequiresAnIsolatedReadingAndAnAudibleFollowingAnchor() throws {
        let previous = segment(1, 5, "Сегодня мы проверим новую настройку.")
        let reply = segment(9, 9.7, "An.")
        let next = segment(12, 18, "Теперь можно проверить этот режим.")
        let context = RecognitionContext(segments: [previous, reply, next])
        let plan = try XCTUnwrap(context.shortReplyAnchor(for: reply, vocabulary: ""))
        XCTAssertEqual(plan.candidate(isolated: "Нет.", wide: "Нет, теперь можно проверить режим.", language: "Russian"), "Нет.")
        XCTAssertNil(plan.candidate(isolated: "Нет.", wide: "Теперь можно проверить режим.", language: "Russian"))
        XCTAssertNil(plan.candidate(isolated: "Нет.", wide: "Нет, посмотрите ещё раз.", language: "Russian"))
        XCTAssertNil(plan.candidate(isolated: "Нет.", wide: "An. Теперь можно проверить режим.", language: "Russian"))
        XCTAssertNil(plan.candidate(isolated: "Нет.", wide: "Нет, теперь можно проверить режим.", language: "English"))
        XCTAssertTrue(plan.confirmsPreceding("Нет.", wide: "Сегодня мы проверим новую настройку. Нет.", language: "Russian"))
        XCTAssertFalse(plan.confirmsPreceding("Нет.", wide: "Мы проверим новую настройку.", language: "Russian"))
        XCTAssertFalse(plan.confirmsPreceding("Нет.", wide: "Конец чужой фразы. Нет.", language: "Russian"))
        let interruption = segment(10, 11, "Ещё одна реплика.")
        XCTAssertNil(RecognitionContext(segments: [previous, reply, interruption, next]).shortReplyAnchor(for: reply, vocabulary: ""))
        XCTAssertNil(context.shortReplyAnchor(for: reply, vocabulary: "An"))
        for spelling in ["Yes.", "GPU", "«An»"] {
            XCTAssertNil(context.shortReplyAnchor(for: segment(9, 9.7, spelling), vocabulary: ""))
        }
    }

    func testDisputedShortForeignClauseRequiresBothAudibleNeighborsAndEveryReplyWord() throws {
        let previous = segment(1, 5, "Сегодня мы проверим новую настройку.")
        let next = segment(11, 18, "Теперь можно проверить этот режим.")
        for text in ["Exactly.", "Product we do.", "Sí, perdón.", "Let's eat."] {
            var reply = segment(7, 9.2, text)
            reply.independentRecognitionLanguage = false
            let context = RecognitionContext(segments: [previous, reply, next])
            let plan = try XCTUnwrap(context.shortReplyAnchor(for: reply, vocabulary: ""))
            let accepted = try XCTUnwrap(plan.candidate(isolated: "Пока рано", wide: "Пока рано. Теперь можно проверить этот режим.", language: "Russian"))
            XCTAssertEqual(accepted, "Пока рано.")
            XCTAssertTrue(plan.confirmsPreceding(accepted, wide: "Мы проверим новую настройку. Пока рано.", language: "Russian"))
            XCTAssertFalse(plan.confirmsPreceding(accepted, wide: "Мы проверим новую настройку. Рано.", language: "Russian"))
            XCTAssertNil(plan.candidate(isolated: "Пока рано", wide: "Пока. Теперь можно проверить этот режим.", language: "Russian"))
            reply.independentRecognitionLanguage = true
            XCTAssertNil(context.shortReplyAnchor(for: reply, vocabulary: ""), text)
        }
    }

    func testOverlappingWordNeedsOneRussianBackgroundAndUnprotectedSpelling() throws {
        var target = segment(5, 5.8, "Blänke.")
        target.speaker = TranscriptSegment.unidentifiedSpeaker
        target.speakerEvidenceIsMixed = true
        let background = segment(1, 12, "Сегодня мы решили проверить новую настройку.")
        let context = RecognitionContext(segments: [target, background])
        let plan = try XCTUnwrap(context.overlappingWord(for: target, vocabulary: ""))
        XCTAssertTrue(plan.confirmsSource("Blanke!"))
        XCTAssertTrue(plan.confirmsSource("Wie bitte, Blänke?"))
        XCTAssertFalse(plan.confirmsSource("anderes Wort"))
        XCTAssertNil(context.overlappingWord(for: target, vocabulary: "Blänke Studio"))
        for spelling in ["«Blänke».", "BlÄnke.", "Widget.", "deux mots"] {
            var literal = target
            literal.text = spelling
            XCTAssertNil(context.overlappingWord(for: literal, vocabulary: ""))
        }
        var duplicate = target
        duplicate.speaker = background.speaker
        XCTAssertNil(context.overlappingWord(for: duplicate, vocabulary: ""))
        duplicate.speaker = TranscriptSegment.unidentifiedSpeaker
        for mixed in [false, nil] as [Bool?] {
            duplicate.speakerEvidenceIsMixed = mixed
            XCTAssertNil(context.overlappingWord(for: duplicate, vocabulary: ""))
        }
        var speaker = background
        speaker.speaker = "Blänke"
        let sourceMention = segment(15, 20, "Название сервиса — Blänke.")
        let third = segment(5.84, 7, "Начало следующей реплики.")
        for others in [[speaker], [background, sourceMention], [background, third],
                       [segment(1, 12, "They finished their report.")],
                       [segment(1, 12, background.text, track: "mic")], [segment(1, 5.81, background.text)]] {
            XCTAssertNil(RecognitionContext(segments: [target] + others).overlappingWord(for: target, vocabulary: ""))
        }
    }

    func testOverlappingWordRequiresIndependentAgreementOnCoreAndMargin() throws {
        var target = segment(5, 5.8, "Blänke.")
        target.speaker = TranscriptSegment.unidentifiedSpeaker
        target.speakerEvidenceIsMixed = true
        func plan(_ background: String) throws -> RecognitionContext.OverlappingWord {
            try XCTUnwrap(RecognitionContext(segments: [target, segment(1, 12, background)])
                .overlappingWord(for: target, vocabulary: ""))
        }
        let overlap = try plan("Сегодня мы решили проверить новую настройку.")
        let word = try XCTUnwrap(overlap.acousticWord(core: "Вечерняя.", padded: "Про вечернее?"))
        XCTAssertEqual(overlap.acousticWord(core: "Архивная.", padded: "Архивное."), "архивное")
        XCTAssertEqual(overlap.acousticWord(core: "Здание.", padded: "Здание."), "здание")
        XCTAssertNil(overlap.acousticWord(core: "Учение.", padded: "Учёное."))
        XCTAssertEqual(overlap.confirmedText(word: word, core: "вечернее", padded: "Вечернее."), "Вечернее.")
        XCTAssertNil(overlap.confirmedText(word: word, core: "дневное", padded: "вечернее"))
        XCTAssertNil(overlap.confirmedText(word: word, core: "вечернее", padded: "Про вечернее?"))
        XCTAssertNil(overlap.acousticWord(core: "", padded: "вечернее"))
        XCTAssertNil(overlap.acousticWord(core: "летнее", padded: "вечернее"))
        XCTAssertNil(overlap.acousticWord(core: "вечерняя", padded: "окно вечернее"))
        let background = try plan("Сегодня мы решили проверить вечерний выпуск.")
        XCTAssertNil(background.acousticWord(core: "вечерняя", padded: "вечернее"))
        let oblique = try plan("Мы хотим посмотреть на фасад здания.")
        XCTAssertNil(oblique.acousticWord(core: "Здание.", padded: "Здание."))
    }

    func testEstablishedPhraseNeedsContiguousWordsInTwoDistinctFrozenTurns() {
        let target = segment(100, 110, "Мы обсуждали совсем другую тему.")
        let first = segment(70, 80, "Нам нужен умный город, именно умный город.")
        let second = segment(120, 130, "Позже появится умный город рядом.")
        XCTAssertTrue(RecognitionContext(segments: [first, target, second]).establishedPhrases(around: target).contains("умный город"))
        XCTAssertFalse(RecognitionContext(segments: [first, target], preceding: [first]).establishedPhrases(around: target).contains("умный город"))
        for separated in ["Он умный. Город рядом.", "Он умный «человек» город рядом.", "Он умный\nгород рядом.", "Обсуждаем «умный город» вместе."] {
            XCTAssertFalse(RecognitionContext(segments: [first, target, segment(120, 130, separated)])
                .establishedPhrases(around: target).contains("умный город"), separated)
        }
    }

    func testRecurringWordUsesUnpromptedAudioAndTwoIndependentMentions() throws {
        let target = segment(30, 35, "Нам нужен этот фотабонк перед новым запуском.")
        let heard = "Нам нужен этот фотобанк перед новым запуском."
        let earlier = segment(1, 5, "Откроем фотобанк после обеда.")
        let later = segment(50, 55, "Где наш фотобанк для обложек?")
        let context = RecognitionContext(segments: [target, earlier, later])
        let repair = try XCTUnwrap(context.recurringWord(for: target, independent: heard, vocabulary: ""))
        XCTAssertEqual(repair.confirmedText(language: "Russian", reread: "Очень нужен этот фотобанк перед новым показом."), heard)
        XCTAssertNil(repair.confirmedText(language: "Russian", reread: "Нам нужен этот фотоальбом перед новым запуском."))
        XCTAssertNil(repair.confirmedText(language: "Russian", reread: "Мне нравится фотобанк."))
        XCTAssertNil(repair.confirmedText(language: "Ukrainian", reread: heard))
        XCTAssertNil(context.recurringWord(for: target, independent: heard, vocabulary: "фотабонк"))
        var unverified = later
        unverified.independentRecognitionLanguage = false
        for turn in [earlier, unverified, segment(50, 55, "Там было написано «фотобанк».")] {
            XCTAssertNil(RecognitionContext(segments: [target, earlier, turn]).recurringWord(for: target, independent: heard, vocabulary: ""))
        }
    }

    func testTwoPlausibleWordsNeedAnUncontestedRecurringPhraseAndMatchingAudio() throws {
        let target = segment(30, 35, "Нам нужна новая таблица перед первым запуском.")
        let heard = "Нам нужна новая теплица перед первым запуском."
        let earlier = segment(1, 5, "Там появится новая теплица.")
        let later = segment(50, 55, "Новая теплица уже готова.")
        func probe(_ context: [TranscriptSegment]) -> RecognitionContext.RecurringWord? {
            RecognitionContext(segments: context + [target]).recurringWord(for: target, independent: heard, vocabulary: "")
        }
        XCTAssertTrue(TranscriptTerms.isCommonRussianWord("таблица"))
        let repair = try XCTUnwrap(probe([earlier, later]))
        XCTAssertEqual(repair.confirmedText(language: "Russian", reread: heard), heard)
        XCTAssertNil(repair.confirmedText(language: "Russian", reread: target.text))
        XCTAssertNil(probe([earlier, segment(60, 65, "А эта теплица готова.")]))
        XCTAssertNil(probe([earlier, later, segment(7, 10, "Вот новая таблица."), segment(15, 19, "Новая таблица готова.")]))
    }

    func testRecurringPhraseCanResolveOneWordDespiteAnotherDistantDisagreement() throws {
        let source = "Вчера мы решили, что новая таблица пригодится для нашего сада."
        let target = segment(30, 35, source)
        let earlier = segment(1, 5, "На участке появится новая теплица.")
        let later = segment(50, 55, "Новая теплица выдержит заморозки.")
        let context = RecognitionContext(segments: [earlier, target, later])
        let expected = source.replacingOccurrences(of: "таблица", with: "теплица")
        let independent = expected.replacingOccurrences(of: "Вчера", with: "Сегодня")
        let repair = try XCTUnwrap(context.recurringWord(for: target, independent: independent, vocabulary: ""))
        XCTAssertEqual(repair.confirmedText(language: "Russian", reread: independent), expected)
        XCTAssertNil(repair.confirmedText(language: "Russian", reread: source))
        let keepingUnrelatedTerm = try XCTUnwrap(context.recurringWord(for: target, independent: independent,
            vocabulary: "Вчера мы решили"))
        XCTAssertEqual(keepingUnrelatedTerm.confirmedText(language: "Russian", reread: independent), expected)
        let interrupted = independent.replacingOccurrences(of: "новая теплица", with: "новая. Теплица")
        XCTAssertNil(repair.confirmedText(language: "Russian", reread: interrupted))
        XCTAssertNil(context.recurringWord(for: target, independent: interrupted, vocabulary: ""))
        XCTAssertNil(context.recurringWord(for: target,
            independent: independent.replacingOccurrences(of: "новая", with: "большая"), vocabulary: ""))
    }

    func testRecurringPhraseMustBeContinuousAtTheSiteOfTheProposedChange() {
        let source = "Скажи, какая именно новая, таблица или схема для отчёта?"
        let target = segment(30, 35, source)
        let context = RecognitionContext(segments: [segment(1, 5, "Там стоит новая теплица."),
            target, segment(50, 55, "Новая теплица уже готова.")])
        let independent = source.replacingOccurrences(of: "таблица", with: "теплица")
        XCTAssertNil(context.recurringWord(for: target, independent: independent, vocabulary: ""))
    }

    func testTwoLocallySupportedRecurringChangesDoNotTriggerASingleWordReread() {
        let source = "До обеда новая таблица была открыта, а вечером новая таблица уже пропала."
        let target = segment(30, 35, source)
        let context = RecognitionContext(segments: [segment(1, 5, "Там стоит новая теплица."),
            target, segment(50, 55, "Новая теплица уже готова.")])
        let independent = source.replacingOccurrences(of: "таблица", with: "теплица")
        XCTAssertNil(context.recurringWord(for: target, independent: independent, vocabulary: ""))
    }

    func testRecurringCorrectionPreservesDictionaryTermAtItsOriginalPosition() {
        let source = "До обеда новая таблица была готова, а к вечеру исчезла теплица."
        let independent = "До обеда новая теплица была готова, а к вечеру исчезла таблица."
        let target = segment(30, 35, source)
        let context = RecognitionContext(segments: [segment(1, 5, "Там стоит новая теплица."),
            target, segment(50, 55, "Новая теплица уже готова.")])
        XCTAssertNotNil(context.recurringWord(for: target, independent: independent, vocabulary: ""))
        XCTAssertNil(context.recurringWord(for: target, independent: independent, vocabulary: "таблица"))
        XCTAssertNil(context.recurringWord(for: target, independent: independent, vocabulary: "новая таблица"))
    }

    func testSecondWordCanUseUniqueThreeWordOppositeAnchor() throws {
        let original = "В Конторе мы обсуждали этот проект сегодня."
        let candidate = "В Контуре мы обсуждали этот проект сегодня."
        let target = segment(100, 110, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target, independent: candidate,
            vocabulary: "Контур", spokenVocabulary: SpokenVocabulary("Контур")))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: candidate, retry: retry, vocabulary: "Контур"), candidate)
        let repeated = candidate + " Мы обсуждали этот проект вчера."
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: repeated,
            corroboration: repeated, retry: retry, vocabulary: "Контур"))
    }

    func testAcousticNarrativeQuotesDoNotHideEvidenceButOriginalLiteralsRemainProtected() throws {
        let original = "Мы работали в Конторе и обсуждали результаты вчера."
        let candidate = original.replacingOccurrences(of: "Конторе", with: "Контуре")
        let evidence = "Он говорил: «Мы работали в Контуре и обсуждали результаты вчера»."
        let target = segment(100, 110, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target, independent: evidence,
            vocabulary: "Контур", spokenVocabulary: SpokenVocabulary("Контур")))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: evidence, retry: retry, vocabulary: "Контур"), candidate)
        XCTAssertNil(RecognitionContext.revisedText(original: "«" + original + "»", candidate: candidate,
            corroboration: evidence, retry: retry, vocabulary: "Контур"))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: "«" + candidate + "»",
            corroboration: evidence, retry: retry, vocabulary: "Контур"))
    }

    func testIndependentExactNumericNameCanUseUnpromptedPhoneticCorroboration() throws {
        let original = "В Твагисе как некий пилотный проект появилось решение."
        let observed = "В 2ГИС'е как некий пилотный проект появилось решение."
        let unprompted = "В Тагисе как некий пилотный проект появилось решение."
        let target = segment(100, 110, original)
        let context = RecognitionContext(segments: [segment(70, 80, "Мы работаем с 2ГИС давно."), target])
        let retry = try XCTUnwrap(context.plan(for: target, independent: observed, vocabulary: "2ГИС",
            spokenVocabulary: SpokenVocabulary("2ГИС")))
        XCTAssertTrue(retry.hasEstablishedAcousticTerm(in: observed))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: observed,
            corroboration: unprompted, retry: retry, vocabulary: "2ГИС"), observed)
        for source in ["2G", "2Gе", "5G", "3ГИС"] {
            XCTAssertNil(RecognitionContext.revisedText(original: original.replacingOccurrences(of: "Твагисе", with: source),
                candidate: observed, corroboration: unprompted, retry: retry, vocabulary: "2ГИС"), source)
        }
    }

    func testIndependentlyVerifiedCropsMergeOnlyDisjointSourceIntervals() {
        let original = "В имени была ошибка, потом другое имя тоже исказилось."
        let first = original.replacingOccurrences(of: "имени", with: "названии")
        let second = original.replacingOccurrences(of: "другое имя", with: "второе название")
        XCTAssertEqual(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [first, second]),
            "В названии была ошибка, потом второе название тоже исказилось.")
        let conflict = original.replacingOccurrences(of: "имени", with: "фамилии")
        XCTAssertEqual(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [first, conflict, first]), first)
        XCTAssertNil(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [original]))
    }

    func testBroaderVerifiedPhrasePreservesTheExactEarlierNumericRepairAtItsSourceEdge() {
        let original = "В ТВАГИСе работаем с системой Сбераз-ТВАГИСом, там наша аудитория огромная."
        let firstName = original.replacingOccurrences(of: "ТВАГИСе", with: "2ГИС'е")
        let narrow = original.replacingOccurrences(of: "ТВАГИСом", with: "2ГИС'ом")
        let broad = original.replacingOccurrences(of: "Сбераз-ТВАГИСом", with: "Сбера, с 2ГИС'ом")
        let expected = broad.replacingOccurrences(of: "ТВАГИСе", with: "2ГИС'е")
        XCTAssertEqual(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [firstName, narrow, broad]), expected)
        XCTAssertEqual(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [firstName, broad, narrow]), expected)
        for conflict in [broad.replacingOccurrences(of: "2ГИС'ом", with: "3ГИС'ом"),
                         broad.replacingOccurrences(of: "2ГИС'ом", with: "12ГИС'ом"),
                         broad.replacingOccurrences(of: "2ГИС'ом", with: "2ГИС'е")] {
            XCTAssertEqual(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [narrow, conflict]), narrow)
        }
        let sameInterval = original.replacingOccurrences(of: "ТВАГИСом", with: "2ГИС'е")
        XCTAssertEqual(RecognitionContext.mergeIndependentRevisions(original: original, revisions: [narrow, sameInterval]), narrow)
    }

    func testFusedDictionaryNamesNeedExactIndependentPhraseAndBothDistantAnchors() throws {
        let original = "Давайте там вместе сотрудничать с этой системой Сбераз-ТВАГИСом, там с нашей аудиторией огромной."
        let candidate = "Давайте там вместе сотрудничать с этой системой Сбера, с 2ГИС'ом, там со нашей аудиторией."
        let independent = "Давайте там вместе сотрудничать с экосистемой Сбера, с Два Гисом, там с нашей аудиторией огромной."
        let vocabulary = "2ГИС, Сбер"
        let target = segment(100, 110, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [segment(70, 80, "Работаем с 2ГИС и Сбером давно."), target])
            .plan(for: target, independent: independent, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: candidate,
            corroboration: independent, retry: retry, vocabulary: vocabulary),
            original.replacingOccurrences(of: "Сбераз-ТВАГИСом", with: "Сбера, с 2ГИС'ом"))
        for bad in [independent.replacingOccurrences(of: "Два Гисом", with: "2G"),
                    independent.replacingOccurrences(of: "нашей аудиторией", with: "этой командой")] {
            XCTAssertNil(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: candidate,
                corroboration: bad, retry: retry, vocabulary: vocabulary), bad)
        }
        XCTAssertEqual(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: candidate,
            corroboration: independent.replacingOccurrences(of: "Сбера", with: "СБР"), retry: retry, vocabulary: vocabulary),
            original.replacingOccurrences(of: "ТВАГИСом", with: "2ГИС'ом"))
        let differentPreposition = original.replacingOccurrences(of: "Сбераз-ТВАГИСом", with: "Сбер-за-ТВАГИСом")
        XCTAssertEqual(RecognitionContext.revisedAnchoredDictionaryText(original: differentPreposition, candidate: candidate,
            corroboration: independent, retry: retry, vocabulary: vocabulary),
            differentPreposition.replacingOccurrences(of: "ТВАГИСом", with: "2ГИС'ом"))
        for spelling in ["Сбераз-3ГИСом", "«Сбераз-ТВАГИСом»"] {
            XCTAssertNil(RecognitionContext.revisedAnchoredDictionaryText(original: original.replacingOccurrences(of: "Сбераз-ТВАГИСом", with: spelling),
                candidate: candidate, corroboration: independent, retry: retry, vocabulary: vocabulary), spelling)
        }
    }

    func testFarAnchorsKeepUncertainAdjacentWordsAndRequireCompleteNumericBase() throws {
        let original = "Будем этим пользоваться в Дублисе или не в Дублисе где-то они будут получать сервисы."
        let candidate = "В 2ГИС'е или не в 2ГИС'е где-то они будут получать."
        let independent = "Будем этим пользоваться в 2Gе или не в 2GIS-е-то они будут получать сервисы."
        let target = segment(100, 110, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [segment(70, 80, "Работаем с 2ГИС давно."), target])
            .plan(for: target, independent: independent, vocabulary: "2ГИС", spokenVocabulary: SpokenVocabulary("2ГИС")))
        XCTAssertEqual(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: candidate,
            corroboration: independent, retry: retry, vocabulary: "2ГИС"),
            "Будем этим пользоваться в Дублисе или не в 2ГИС'е где-то они будут получать сервисы.")
        XCTAssertNil(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: candidate,
            corroboration: independent.replacingOccurrences(of: "2GIS-е", with: "2Gе"), retry: retry, vocabulary: "2ГИС"))
        for quantity in ["три ГИС", "две ГИС"] {
            XCTAssertNil(RecognitionContext.revisedText(original: "В \(quantity) загрузили наши новые данные.",
                candidate: "В 2ГИС загрузили наши новые данные.", corroboration: "В 2ГИС загрузили наши новые данные.",
                retry: retry, vocabulary: "2ГИС"))
        }
    }

    func testSelectiveTechnicalRereadOnlyReplacesNominatedCyrillicSpan() throws {
        let original = "Мы делаем бит-бить продукт. Это сервис для бизнеса."
        let candidate = "Мы делаем B2B-продукт. Это сервис для бизнеса."
        let independent = "Мы делаем BTB-продукт. Это сервис для бизнеса."
        let hint = try XCTUnwrap(SpokenVocabulary("").technologyRereadHint(in: original))
        XCTAssertEqual(RecognitionContext.revisedTechnicalTerm(original: original, candidate: candidate,
            corroboration: independent, term: hint.term, sourceRange: hint.range, vocabulary: ""),
            "Мы делаем B2B продукт. Это сервис для бизнеса.")
        for bad in ["Мы создаём B2B-продукт. Это сервис для бизнеса.", "Мы делаем B2C-продукт. Это сервис для бизнеса.",
                    "Мы делаем «B2B»-продукт. Это сервис для бизнеса.", "Мы делаем B2B'у продукт. Это сервис для бизнеса."] {
            XCTAssertNil(RecognitionContext.revisedTechnicalTerm(original: original, candidate: bad,
                corroboration: independent, term: hint.term, sourceRange: hint.range, vocabulary: ""), bad)
        }
        XCTAssertNil(RecognitionContext.revisedTechnicalTerm(original: original, candidate: candidate,
            corroboration: independent.replacingOccurrences(of: "BTB", with: "BDB"), term: hint.term, sourceRange: hint.range, vocabulary: ""))
        XCTAssertNil(RecognitionContext.revisedTechnicalTerm(original: original, candidate: candidate,
            corroboration: independent, term: hint.term, sourceRange: hint.range, vocabulary: "BTB"))
        for name in ["BTB", "BDB"] {
            let source = original.replacingOccurrences(of: "бит-бить", with: name)
            XCTAssertNil(RecognitionContext.revisedTechnicalTerm(original: source, candidate: candidate,
                corroboration: independent, term: hint.term, sourceRange: source.range(of: name)!, vocabulary: ""))
        }
    }

    func testDistantAnchorsMayRepeatOutsideTheUniqueLocalAlignment() throws {
        let original = "Они будут получать данные и этим пользоваться в Дублисе или не в Дублисе где-то они будут получать сервисы, они будут получать новую информацию."
        let candidate = "В 2ГИС'е или не в 2ГИС'е где-то они будут получать."
        let heard = "Они будут получать данные и этим пользоваться в 2Gе или не в 2GIS-е-то они будут получать сервисы, они будут получать новую информацию."
        let target = segment(100, 115, original)
        let retry = try XCTUnwrap(RecognitionContext(segments: [segment(80, 90, "Работаем с 2ГИС давно."), target])
            .plan(for: target, independent: heard, vocabulary: "2ГИС", spokenVocabulary: SpokenVocabulary("2ГИС")))
        XCTAssertEqual(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: candidate,
            corroboration: heard, retry: retry, vocabulary: "2ГИС"),
            original.replacingOccurrences(of: "не в Дублисе", with: "не в 2ГИС'е"))
        XCTAssertNil(RecognitionContext.revisedAnchoredDictionaryText(original: original + " " + original,
            candidate: candidate, corroboration: heard, retry: retry, vocabulary: "2ГИС"))
    }

    func testFusedCaseAndPrepositionCanUseIndependentWholePhraseAndOriginalPhonemes() throws {
        let original = "Давайте там вместе сотрудничать с этой системой Сбераз-ТВАГИСом, там наша аудитория огромная и так далее."
        let independent = "Давайте там вместе сотрудничать с экосистемой Сбера, с Два Гисом, там с нашей аудиторией огромной и так далее."
        let checked = "Давайте там вместе сотрудничать с такой системой Сбер, раз-2ГИС'ом, там наша аудитория огромная и так далее."
        let target = segment(100, 115, original)
        let vocabulary = "2ГИС, Сбер"
        let retry = try XCTUnwrap(RecognitionContext(segments: [segment(80, 90, "Работаем с 2ГИС и Сбером давно."), target])
            .plan(for: target, independent: independent, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        let expected = original.replacingOccurrences(of: "Сбераз-ТВАГИСом", with: "Сбера, с 2ГИС'ом")
        XCTAssertEqual(RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: independent,
            corroboration: checked, retry: retry, vocabulary: vocabulary, candidateFromIndependentAudio: true), expected)
        for source in ["Сберраз-ТВАГИСом", "Сбер-за-ТВАГИСом", "Сбераз-3ГИСом", "Сбераз ТВАГИСом"] {
            let changed = original.replacingOccurrences(of: "Сбераз-ТВАГИСом", with: source)
            let result = RecognitionContext.revisedAnchoredDictionaryText(original: changed, candidate: independent,
                corroboration: checked, retry: retry, vocabulary: vocabulary, candidateFromIndependentAudio: true)
            XCTAssertFalse(result?.contains("Сбера, с 2ГИС'ом") ?? false, source)
        }
        for heard in [checked.replacingOccurrences(of: "Сбер, раз", with: "СБР, раз"),
                      checked.replacingOccurrences(of: "Сбер, раз", with: "Сбер, за"),
                      checked.replacingOccurrences(of: "2ГИС'ом", with: "2ГИС'е")] {
            let result = RecognitionContext.revisedAnchoredDictionaryText(original: original, candidate: independent,
                corroboration: heard, retry: retry, vocabulary: vocabulary, candidateFromIndependentAudio: true)
            XCTAssertFalse(result?.contains("Сбера, с 2ГИС'ом") ?? false, heard)
        }
    }

    func testEstablishedCyrillicNameCanSelectAudioWithoutAuthorizingFuzzyReplacement() throws {
        let original = "Мы работали в Конторе и обсуждали результаты вчера."
        let candidate = original.replacingOccurrences(of: "Конторе", with: "Контуре")
        let target = segment(100, 110, original)
        let previous = segment(70, 80, "Ранее мы обсуждали работу Контура.")
        let vocabulary = "Контур"
        let context = RecognitionContext(segments: [previous, target])
        let retry = try XCTUnwrap(context.plan(for: target, independent: "Мы работали в кантуре и обсуждали результаты вчера.",
            vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertTrue(retry.hints.contains("Контуре"))
        XCTAssertEqual(retry.targetSpans(in: original, corroboration: nil).map { String(original[$0]) }, ["Конторе"])
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: candidate, retry: retry, vocabulary: vocabulary), candidate)
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: "Мы работали в кантуре и обсуждали результаты вчера.", retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext(segments: [target]).plan(for: target,
            independent: "Мы работали в канторе и обсуждали результаты вчера.", vocabulary: vocabulary,
            spokenVocabulary: SpokenVocabulary(vocabulary)))
    }

    func testSharedEstablishedNameMissOnlySchedulesIndependentAudioVerification() throws {
        let original = "Мы работали в Конторе и обсуждали результаты вчера."
        let correct = original.replacingOccurrences(of: "Конторе", with: "Контуре")
        let target = segment(100, 110, original)
        let previous = segment(70, 80, "Ранее мы обсуждали работу Контура.")
        let retry = try XCTUnwrap(RecognitionContext(segments: [previous, target]).plan(for: target,
            independent: original, vocabulary: "Контур", spokenVocabulary: SpokenVocabulary("Контур")))
        XCTAssertEqual(retry.targetSpans(in: original, corroboration: original).map { String(original[$0]) }, ["Конторе"])
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: correct,
            corroboration: original, retry: retry, vocabulary: "Контур"))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: correct,
            corroboration: correct, retry: retry, vocabulary: "Контур"), correct)
    }

    func testSharedNameMissNeedsExplicitEstablishedUniqueUnquotedEvidence() {
        let previous = segment(70, 80, "Ранее мы обсуждали работу Контура.")
        let ordinary = "Мы работали в Конторе и обсуждали результаты вчера."
        for (text, context, vocabulary) in [
            (ordinary, [TranscriptSegment](), "Контур"),
            (ordinary, [previous], ""),
            ("Мы работали в «Конторе» и обсуждали результаты вчера.", [previous], "Контур"),
            ("Мы работали в /Конторе/ и обсуждали результаты вчера.", [previous], "Контур"),
            ("Мы работали в Конторе и обсуждали результаты, потом работали в Конторе и обсуждали планы.", [previous], "Контур")
        ] {
            let target = segment(100, 110, text)
            let retry = RecognitionContext(segments: context + [target]).plan(for: target,
                independent: text, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary))
            if text.contains("«") {
                // Existing disagreement logic can plan from unquoted acoustic
                // evidence; protected original text must still have no target.
                XCTAssertTrue(retry?.targetSpans(in: text, corroboration: text).isEmpty ?? true)
            } else { XCTAssertNil(retry, text) }
        }
    }

    func testTwoIndependentlyAnchoredNameOccurrencesCanBeCorrectedTogether() throws {
        let original = "Мы работали в Конторе и обсуждали результаты, потом снова посетили Контору на следующей неделе."
        let candidate = original.replacingOccurrences(of: "Конторе", with: "Контуре").replacingOccurrences(of: "Контору", with: "Контуру")
        let target = segment(100, 110, original)
        let vocabulary = "Контур"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: candidate, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: candidate, retry: retry, vocabulary: vocabulary), candidate)
        let partial = candidate.replacingOccurrences(of: "Контуру", with: "контору")
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: partial, retry: retry, vocabulary: vocabulary), original.replacingOccurrences(of: "Конторе", with: "Контуре"))
    }

    func testContextRetryDoesNotDiscardAnAlreadyRecognizedAcronymEnding() throws {
        let original = "Проверим поиск внутри 2ГИС'а и обсудим результаты."
        let candidate = "Проверим поиск внутри 2ГИС и обсудим результаты."
        let heard = "Проверим поиск внутри два ГИС и обсудим результаты."
        let target = segment(8, 11, original)
        let previous = segment(0, 3, original)
        let vocabulary = "2ГИС"
        let context = RecognitionContext(segments: [previous, target])
        let retry = try XCTUnwrap(context.plan(for: target, independent: heard, vocabulary: vocabulary,
                                               spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
                       corroboration: heard, retry: retry, vocabulary: vocabulary))
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

    func testCyrillicInitialismEndingNeedsEstablishedTermAndAudio() throws {
        let target = segment(150, 158, "Как меняются рабочие процессы вот АИМ? Насколько ты доволен результатом?")
        let prior = segment(10, 15, "На встрече обсуждали рабочие сценарии AI.")
        let vocabulary = "AI"
        let spoken = SpokenVocabulary(vocabulary)
        let context = RecognitionContext(segments: [prior, target])
        let retry = try XCTUnwrap(context.plan(for: target, independent: nil, vocabulary: vocabulary, spokenVocabulary: spoken))
        let candidate = "Рабочие процессы вот AI'ем насколько ты доволен результатом"
        let evidence = ["Рабочие процессы вот A I M насколько ты доволен", "Процессы вот A I м насколько ты доволен результатом"]
        XCTAssertEqual(RecognitionContext.disambiguateInitialismEnding(original: target.text, candidate: candidate,
            unprompted: evidence, retry: retry, vocabulary: vocabulary),
            "Как меняются рабочие процессы вот AI'ем? Насколько ты доволен результатом?")
        XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: target.text, candidate: candidate,
            unprompted: [evidence[0], "Рабочие процессы вот АИМ насколько ты доволен"], retry: retry, vocabulary: vocabulary))
        XCTAssertEqual(RecognitionContext.disambiguateInitialismEnding(original: target.text,
            candidate: candidate.replacingOccurrences(of: "AI'ем", with: "A I'ем"), unprompted: evidence,
            retry: retry, vocabulary: vocabulary),
            "Как меняются рабочие процессы вот AI'ем? Насколько ты доволен результатом?")
        for spelling in ["A I ем", "A И'ем", "A, I'ем", "A I'ом"] {
            XCTAssertNil(RecognitionContext.disambiguateInitialismEnding(original: target.text,
                candidate: candidate.replacingOccurrences(of: "AI'ем", with: spelling), unprompted: evidence,
                retry: retry, vocabulary: vocabulary), spelling)
        }
        let unestablished = RecognitionContext(segments: [target]).plan(for: target, independent: nil,
            vocabulary: vocabulary, spokenVocabulary: spoken)
        XCTAssertNotEqual(unestablished?.canDisambiguateInitialismEnding(in: target.text), true)
    }

    func testNumericEndingDisagreementSchedulesProbeWithoutOverridingAudio() throws {
        let target = segment(100, 108, "Ты когда-нибудь говорил с Двуге до нашего разговора?")
        let prior = segment(85, 90, "На встрече обсуждали рабочие сценарии 2ГИС.")
        let vocabulary = "2ГИС"
        let spoken = SpokenVocabulary(vocabulary)
        let retry = try XCTUnwrap(RecognitionContext(segments: [prior, target]).plan(
            for: target, independent: target.text, vocabulary: vocabulary, spokenVocabulary: spoken))
        XCTAssertTrue(retry.hints.contains("2ГИС'ом"))
        XCTAssertTrue(retry.targetSpans(in: target.text, corroboration: target.text).contains {
            target.text[$0] == "Двуге"
        })
        let candidate = "Ты когда-нибудь говорил с 2ГИС'ом до нашего разговора?"
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate,
            corroboration: target.text, retry: retry, vocabulary: vocabulary))
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: candidate,
            corroboration: candidate, retry: retry, vocabulary: vocabulary), candidate)
    }

    func testTerminalProbeBorrowsOnlyAnAdjacentSameTrackAnchor() throws {
        let target = segment(100, 108, "Там обсудили важный клиентский профиль.")
        let next = segment(108, 115, "Это поможет дальнейшей разработке продукта.")
        let context = RecognitionContext(segments: [target, next])
        let continuation = try XCTUnwrap(context.continuation(after: target))
        XCTAssertEqual(continuation.segment.id, next.id)
        let suffix = continuation.suffix
        var joined = target
        joined.text += suffix
        let vocabulary = "бизнес-профиль"
        let candidate = "Там обсудили важный бизнес-профиль." + suffix
        let retry = try XCTUnwrap(context.plan(for: joined, independent: candidate, vocabulary: vocabulary,
                                               spokenVocabulary: SpokenVocabulary(vocabulary)))
        let revised = try XCTUnwrap(RecognitionContext.revisedText(original: joined.text, candidate: candidate,
            corroboration: candidate, retry: retry, vocabulary: vocabulary))
        XCTAssertEqual(continuation.splice(revised), "Там обсудили важный бизнес-профиль.")
        XCTAssertNil(RecognitionContext.revisedText(original: joined.text, candidate: candidate,
            corroboration: "Там обсудили важный бизнес-профиль.", retry: retry, vocabulary: vocabulary))
        XCTAssertEqual(continuation.splice("Там обсудили важный бизнес-профиль." + suffix),
                       "Там обсудили важный бизнес-профиль.")
        XCTAssertNil(continuation.splice("Там обсудили важный бизнес-профиль. Это поможет проекту."))
        XCTAssertNil(continuation.splice("Обсудили важный бизнес-профиль." + suffix))
        XCTAssertNil(RecognitionContext(segments: [target, segment(108, 115, next.text, track: "mic")])
            .continuation(after: target))
        XCTAssertNil(RecognitionContext(segments: [target, segment(109, 115, next.text)])
            .continuation(after: target))
    }


    func testPhoneticBoundaryNeedsTheAcronymInAnIndependentDecode() throws {
        let target = segment(250, 258, "У тебя есть примеры где ты встроил и айфсовые процессы насколько тебе понравилось?")
        let prior = segment(10, 15, "На встрече обсуждали рабочие сценарии AI.")
        let context = RecognitionContext(segments: [prior, target])
        let vocabulary = "AI"
        let spoken = SpokenVocabulary(vocabulary)
        let independent = "Например где ты встроил в свои процессы насколько тебе понравилось"
        let retry = try XCTUnwrap(context.plan(for: target, independent: independent, vocabulary: vocabulary, spokenVocabulary: spoken))
        let candidate = "Например где ты встроил AI в свои процессы насколько тебе понравилось"
        XCTAssertTrue(retry.targetSpans(in: target.text, corroboration: independent).contains { target.text[$0] == "и айфсовые" })
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: independent,
            retry: retry, vocabulary: vocabulary))
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: candidate,
            retry: retry, vocabulary: vocabulary),
            "У тебя есть примеры где ты встроил AI в свои процессы насколько тебе понравилось?")
        let secondWindow = "Где ты встроил AI в свои процессы насколько тебе понравилось"
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: independent,
            retry: retry, vocabulary: vocabulary, boundaryEvidence: [candidate, secondWindow]),
            "У тебя есть примеры где ты встроил AI в свои процессы насколько тебе понравилось?")
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: independent,
            retry: retry, vocabulary: vocabulary, boundaryEvidence: [candidate, independent]))
        let phoneticWindow = "Где ты встроил айфсовые процессы насколько тебе понравилось"
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: independent,
            retry: retry, vocabulary: vocabulary, boundaryEvidence: [candidate, phoneticWindow]),
            "У тебя есть примеры где ты встроил AI в свои процессы насколько тебе понравилось?")
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: independent,
            retry: retry, vocabulary: vocabulary, boundaryEvidence: [target.text, phoneticWindow]))
        XCTAssertEqual(RecognitionContext.reconcilePhoneticBoundary(original: target.text, corroboration: independent,
            unprompted: [target.text, phoneticWindow], retry: retry, vocabulary: vocabulary),
            "У тебя есть примеры где ты встроил AI в свои процессы насколько тебе понравилось?")
        XCTAssertNil(RecognitionContext.reconcilePhoneticBoundary(original: target.text, corroboration: independent,
            unprompted: [phoneticWindow, "Я видел где ты встроил айфсовые процессы насколько тебе понравилось"],
            retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.reconcilePhoneticBoundary(original: target.text, corroboration: independent,
            unprompted: [target.text, phoneticWindow], retry: retry, vocabulary: "AI, Айфсовые"))
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: nil,
            retry: retry, vocabulary: vocabulary, boundaryEvidence: [candidate, secondWindow]))
    }


    func testTerminalRepairCanUseOneLeftAnchorAndAnAgreedConjunction() throws {
        let target = segment(100, 108, "Мы собрали отзывы, это биснес профиль.")
        let next = segment(108, 115, "Это поможет дальнейшей разработке продукта.")
        let context = RecognitionContext(segments: [target, next])
        let continuation = try XCTUnwrap(context.continuation(after: target))
        var joined = target
        joined.text += continuation.suffix
        let vocabulary = "бизнес-профиль"
        let candidate = "Мы собрали опросы это и бизнес-профиль это поможет дальнейшей разработке"
        let heard = "Мы собрали отзывы, это и бизнеспрофиль, это поможет дальнейшей разработке."
        let retry = try XCTUnwrap(context.plan(for: joined, independent: heard, vocabulary: vocabulary,
                                               spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedAcrossBoundary(original: target.text, candidate: candidate,
            corroboration: heard, continuation: continuation, retry: retry, vocabulary: vocabulary),
            "Мы собрали отзывы, это и бизнес-профиль.")
        XCTAssertNil(RecognitionContext.revisedAcrossBoundary(original: target.text, candidate: candidate,
            corroboration: heard.replacingOccurrences(of: "и бизнеспрофиль", with: "бизнеспрофиль"),
            continuation: continuation, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedAcrossBoundary(original: target.text, candidate: candidate,
            corroboration: heard.replacingOccurrences(of: "это поможет дальнейшей", with: "это помогает дальнейшей"),
            continuation: continuation, retry: retry, vocabulary: vocabulary))
        for existing in ["рабочий профиль", "крайне дорогой профиль", "важный профиль"] {
            XCTAssertNil(RecognitionContext.revisedAcrossBoundary(original: "Мы собрали отзывы, это " + existing + ".",
                candidate: candidate, corroboration: heard, continuation: continuation, retry: retry,
                vocabulary: vocabulary), existing)
        }
    }

    func testAcousticStutterDoesNotHideTheRightAnchor() throws {
        let target = segment(100, 108, "Ты раньше разговаривал с Двуге до этого дня?")
        let prior = segment(85, 90, "На встрече обсуждали рабочие сценарии 2ГИС.")
        let vocabulary = "2ГИС"
        let retry = try XCTUnwrap(RecognitionContext(segments: [prior, target]).plan(for: target,
            independent: target.text, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        let candidate = "Ты раньше разговаривал с 2ГИС'ом до этого дня?"
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: candidate,
            corroboration: "Ты раньше разговаривал с Давгисом, э-э, до этого дня.", retry: retry, vocabulary: vocabulary), candidate)
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate,
            corroboration: "Ты раньше разговаривал с Давгисом, или до этого дня.", retry: retry, vocabulary: vocabulary))
    }


    func testMissingEarlierOccurrenceIsNotHiddenByLaterCorrectSpelling() throws {
        let target = segment(100, 108, "Мы запросили деньги. Вопрос джару? GR может здесь помочь.")
        let heard = "Мы запросили деньги. Вопрос к GR. GR может здесь помочь."
        let vocabulary = "GR"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target, independent: heard,
            vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: heard, corroboration: heard,
            retry: retry, vocabulary: vocabulary), "Мы запросили деньги. Вопрос к GR? GR может здесь помочь.")
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: heard, corroboration: target.text,
            retry: retry, vocabulary: vocabulary))
        for source in ["бюджета", "PR", "обсуждали бюджет"] {
            XCTAssertNil(RecognitionContext.revisedText(
                original: "Мы запросили деньги. Вопрос " + source + "? GR может здесь помочь.",
                candidate: heard, corroboration: heard, retry: retry, vocabulary: vocabulary), source)
        }
        XCTAssertNil(RecognitionContext.revisedText(original: "Мы запросили деньги. Вопрос к PR? GR может здесь помочь.",
            candidate: heard, corroboration: heard, retry: retry, vocabulary: "GR, PR"))
    }

    func testStartOfSegmentNameRequiresFullAgreementAndUniqueRightAnchor() throws {
        let target = segment(100, 108, "Нас идёт всё знает, что будет за за")
        let heard = "Настя Дегтева знает, что будет за"
        let candidate = "Настя Дёгтева знает, что будет за"
        let vocabulary = "Дёгтева"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target, independent: heard,
            vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedText(original: target.text, candidate: candidate, corroboration: heard,
            retry: retry, vocabulary: vocabulary), "Настя Дёгтева знает, что будет за за")
        XCTAssertNil(RecognitionContext.revisedText(original: target.text, candidate: candidate,
            corroboration: "Даша Дёгтева знает, что будет за", retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: target.text + " знает что будет",
            candidate: candidate, corroboration: heard, retry: retry, vocabulary: vocabulary))
        for source in ["Петя Петров всё", "Настя Петрова", "Настя петрова", "Настя Дёмина"] {
            XCTAssertNil(RecognitionContext.revisedText(original: source + " знает, что будет за за",
                candidate: candidate, corroboration: heard, retry: retry, vocabulary: vocabulary), source)
        }
    }

    func testWordRichShortTurnRequiresTwoAudioDecodersToAgree() {
        let source = "Наташке взнулся, сказал да."
        let heard = "Наташа кивнула, сказала: «Да»."
        XCTAssertNotNil(RecognitionContext.wordRichShortTurn(original: source, candidate: "Наташа кивнула, сказала да.",
            corroboration: heard, duration: 1.37, vocabulary: "Наташа"))
        XCTAssertNil(RecognitionContext.wordRichShortTurn(original: source, candidate: "Наташа отказалась, сказала да.",
            corroboration: heard, duration: 1.37, vocabulary: "Наташа"))
        XCTAssertNil(RecognitionContext.wordRichShortTurn(original: source, candidate: "Наташа кивнула, сказала да.",
            corroboration: heard, duration: 0.6, vocabulary: "Наташа"))
    }

    func testNumericNameKeepsEndingAlreadyHeardByPrimary() throws {
        for (term, heardStem) in [("2ГИС", "два Гиссе"), ("7АБВ", "семь Аббве")] {
            let original = "Мы работали в \(heardStem) над новым проектом, потом встретились со Сбером."
            let acoustic = original.replacingOccurrences(of: heardStem, with: term)
            let expected = original.replacingOccurrences(of: heardStem, with: term + "'е")
            let candidate = expected.replacingOccurrences(of: "Сбером", with: "сбором")
            let target = segment(100, 108, original)
            let vocabulary = term + ", Сбер"
            let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
                independent: acoustic, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
            XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
                corroboration: acoustic, retry: retry, vocabulary: vocabulary), expected)
            XCTAssertNil(RecognitionContext.revisedText(original: original, candidate: candidate,
                corroboration: acoustic, retry: retry, vocabulary: vocabulary, candidateIsAcoustic: false))
        }
    }

    func testNumericNameEndingRequiresExactComplementaryEvidence() throws {
        let good = "Мы работали в два Гиссе над новым проектом вчера."
        let target = segment(100, 108, good)
        let vocabulary = "2ГИС"
        let acoustic = good.replacingOccurrences(of: "два Гиссе", with: "2ГИС")
        let candidate = good.replacingOccurrences(of: "два Гиссе", with: "2ГИС'е")
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: acoustic, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        for source in ["два Гисс", "два Гисса", "три Гиссе", "два Гиксе", "два Гисссе", "два/Гиссе", "/два Гиссе/", "@дваГиссе", "«два Гиссе»"] {
            XCTAssertNil(RecognitionContext.revisedText(original: good.replacingOccurrences(of: "два Гиссе", with: source),
                candidate: candidate, corroboration: acoustic, retry: retry, vocabulary: vocabulary), source)
        }
        XCTAssertNil(RecognitionContext.revisedText(original: good, candidate: candidate,
            corroboration: acoustic.replacingOccurrences(of: "2ГИС", with: "3ГИС"), retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: good, candidate: candidate,
            corroboration: acoustic, retry: retry, vocabulary: "2ГИС, 2ГИСС"))
        XCTAssertNil(RecognitionContext.revisedText(original: good, candidate: candidate.replacingOccurrences(of: "2ГИС'е", with: "2ГИС'а"),
            corroboration: acoustic, retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: good, candidate: candidate,
            corroboration: acoustic.replacingOccurrences(of: "2ГИС", with: "2ГИС'ом"), retry: retry, vocabulary: vocabulary))
        XCTAssertNil(RecognitionContext.revisedText(original: good + " " + good, candidate: candidate,
            corroboration: acoustic, retry: retry, vocabulary: vocabulary))
        let implicit = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: acoustic, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary("")))
        XCTAssertNil(RecognitionContext.revisedText(original: good, candidate: candidate,
            corroboration: acoustic, retry: implicit, vocabulary: vocabulary))
    }

    func testNumericNameEndingAtStartPreservesOtherNumbersAndNames() throws {
        let original = "В два Гиссе обсуждали проект с бюджетом 48 рублей, затем со Сбером согласовали 12 заявок."
        let acoustic = original.replacingOccurrences(of: "два Гиссе", with: "2GIS")
        let expected = original.replacingOccurrences(of: "два Гиссе", with: "2ГИС'е")
        let candidate = expected.replacingOccurrences(of: "Сбером", with: "сбором").replacingOccurrences(of: "12", with: "13")
        let target = segment(100, 108, original)
        let vocabulary = "2ГИС, Сбер"
        let retry = try XCTUnwrap(RecognitionContext(segments: [target]).plan(for: target,
            independent: acoustic, vocabulary: vocabulary, spokenVocabulary: SpokenVocabulary(vocabulary)))
        XCTAssertEqual(RecognitionContext.revisedText(original: original, candidate: candidate,
            corroboration: acoustic, retry: retry, vocabulary: vocabulary), expected)
    }

}
