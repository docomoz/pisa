import XCTest
@testable import PisaCore

final class TranscriptOrthographyTests: XCTestCase {
    func testFocusGroupUsesRussianCompoundSpelling() {
        for (input, expected) in [
            ("Поговорили об этом в Focus группах.", "Поговорили об этом в фокус-группах."),
            ("Обсудили фокус группы, затем интервью.", "Обсудили фокус-группы, затем интервью."),
            ("Focus\u{00A0}группа началась.", "Фокус-группа началась."),
            ("Расскажем о фокус‑группе завтра.", "Расскажем о фокус-группе завтра."),
            ("Встреча завершилась. Focus группы собрали отзыв.", "Встреча завершилась. Фокус-группы собрали отзыв."),
        ] {
            XCTAssertEqual(TranscriptOrthography.normalize(input), expected)
        }
    }

    func testSorryUsesRussianSpellingInRussianSentence() {
        XCTAssertEqual(TranscriptOrthography.normalize("Всё, Sorry, тогда вопрос."), "Всё, сорри, тогда вопрос.")
        XCTAssertEqual(TranscriptOrthography.normalize("Всё, сори, тогда вопрос."), "Всё, сорри, тогда вопрос.")
        XCTAssertEqual(TranscriptOrthography.normalize("Сори, я неправильно понял."), "Сорри, я неправильно понял.")
        XCTAssertEqual(TranscriptOrthography.normalize("Сори папоротника расположены снизу."), "Сори папоротника расположены снизу.")
        XCTAssertEqual(TranscriptOrthography.normalize("Sorry, тут мне нужно уточнить."), "Сорри, тут мне нужно уточнить.")
        XCTAssertEqual(TranscriptOrthography.normalize("Обсудим это. Sorry, I have to leave."), "Обсудим это. Sorry, I have to leave.")
    }

    func testIdeaFixUsesRequestedHyphenatedSpellingInRussian() {
        for (input, expected) in [
            ("Это идея fix.", "Это идея-фикс."),
            ("Идея фикс не помогла.", "Идея-фикс не помогла."),
            ("Он увлечён этой идеей\u{00A0}fix.", "Он увлечён этой идеей-фикс."),
            ("Обсудили идеи фикс, потом другую идею фикс.", "Обсудили идеи-фикс, потом другую идею-фикс."),
        ] {
            XCTAssertEqual(TranscriptOrthography.normalize(input), expected)
        }
    }

    func testIdeaFixPreservesEnglishQuotationsCodeAndGlossary() {
        for input in [
            "An idea fix is available.",
            "We should label it идея fix in English notes.",
            "Он процитировал «идея fix» и продолжил.",
            "Ищем `идея fix` в списке команд.",
            "Введите:\n```\nидея fix\n```\nПотом продолжим.",
            "Прочитайте фразу идея fix@example.com после встречи.",
        ] {
            XCTAssertEqual(TranscriptOrthography.normalize(input), input)
        }
        XCTAssertEqual(TranscriptOrthography.normalize("Это идея fix.", vocabulary: "идея fix"), "Это идея fix.")
    }

    func testUnambiguousYoFormsRestoreOnlyTheirDictionarySpelling() {
        XCTAssertEqual(TranscriptOrthography.normalize("Еще идем по отчету и учету."), "Ещё идём по отчёту и учёту.")
        XCTAssertEqual(TranscriptOrthography.normalize("ОТЧЕТ идёт на проверку."), "ОТЧЁТ идёт на проверку.")
        XCTAssertEqual(TranscriptOrthography.normalize("Все знают, что всё готово. Небо, летом, ведро, берет, узнаем."),
                       "Все знают, что всё готово. Небо, летом, ведро, берет, узнаем.")
        XCTAssertEqual(TranscriptOrthography.normalize("Еще идем. «Еще»; `отчет`; https://example.com/отчет.", vocabulary: "идем"),
                       "Ещё идем. «Еще»; `отчет`; https://example.com/отчет.")
    }

    func testOpenCorporaYoDictionaryCoversOrdinaryInflectedWords() {
        let input = "Он с семьей прошел весь маршрут и возьмет документы. Елка уже стоит."
        let expected = "Он с семьёй прошёл весь маршрут и возьмёт документы. Ёлка уже стоит."
        let restored = TranscriptOrthography.normalize(input)
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(TranscriptOrthography.normalize(restored), restored)
        XCTAssertEqual(TranscriptOrthography.normalize("Трёхзвездочный отель."), "Трёхзвёздочный отель.")
    }

    func testOpenCorporaYoDictionaryPreservesAmbiguitiesAndLiteralSpelling() {
        let ambiguous = "Все, берем, берет, небо, летом, ведро, узнаем, передохнем, съем. Мед. училище. Семен."
        XCTAssertEqual(TranscriptOrthography.normalize(ambiguous), ambiguous)
        let source = "С семьей, потом прошел. «семьей»; ``прошел``; https://example.com/возьмет."
        XCTAssertEqual(TranscriptOrthography.normalize(source, vocabulary: "прошел"),
                       "С семьёй, потом прошел. «семьей»; ``прошел``; https://example.com/возьмет.")
    }

    func testDelimitedEnglishFillersUseRussianSpellingInsideRussianSpeech() {
        XCTAssertEqual(TranscriptOrthography.normalize("Ну, uh, да."), "Ну, аааа, да.")
        XCTAssertEqual(TranscriptOrthography.normalize("Yeah, понятно."), "Да, понятно.")
        XCTAssertEqual(TranscriptOrthography.normalize("Uh-huh, конечно."), "Угу, конечно.")
        XCTAssertEqual(TranscriptOrthography.normalize("Да, yeah."), "Да, да.")
        XCTAssertEqual(TranscriptOrthography.normalize("Yeah, send the report."), "Yeah, send the report.")
        XCTAssertEqual(TranscriptOrthography.normalize("Я слушаю Yes, потом Rush."), "Я слушаю Yes, потом Rush.")
        XCTAssertEqual(TranscriptOrthography.normalize("Она сказала: «Yeah», и ушла."), "Она сказала: «Yeah», и ушла.")
        XCTAssertEqual(TranscriptOrthography.normalize("Yeah, понятно.", vocabulary: "Yeah"), "Yeah, понятно.")
    }

    func testNamesEnglishTextQuotationsAndLinksArePreserved() {
        for input in [
            "Открой Focus, потом вернёмся к обсуждению.",
            "У них Ford Focus группы, обсуждение в чате.",
            "Sorry, we need to discuss the focus group.",
            "The Focus группы are ready for the test.",
            "Он ответил: «Sorry, I have to leave», и вышел.",
            "Он ответил: \"Sorry\", и вышел.",
            "Он написал `Sorry`, затем вышел.",
            "Всё есть по адресу https://example.com/Sorry, проверьте.",
            "Откройте /Sorry и напишите мне.",
            "Отправим ответ на Sorry@example.com после встречи.",
            "Посмотрите Sorry.example.com перед встречей.",
        ] {
            XCTAssertEqual(TranscriptOrthography.normalize(input), input)
        }
    }

    func testVariableCodeDelimitersProtectText() {
        for input in ["Напишите ``отчет`` здесь.", "Проверьте `` `отчет` `` ещё раз.", "Пример:\n~~~\nотчет\n~~~\nПонятно."] {
            XCTAssertEqual(TranscriptOrthography.normalize(input), input)
        }
    }

    func testQuotedRussianDoesNotDetermineLanguageOfSurroundingEnglish() {
        let input = "Sorry, read «это русская цитата»."
        XCTAssertEqual(TranscriptOrthography.normalize(input), input)
    }

    func testSentenceClassificationIsStableAfterOrthographyChanges() {
        for (input, expected) in [
            ("Focus группа и Sorry.", "Фокус-группа и сорри."),
            ("Идея fix и Sorry.", "Идея-фикс и сорри."),
            ("Да, yeah, понятно, Sorry.", "Да, да, понятно, сорри."),
            ("Focus группа and Sorry, read the notes.", "Focus группа and Sorry, read the notes."),
        ] {
            let result = TranscriptOrthography.normalize(input)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(TranscriptOrthography.normalize(result), result)
        }
    }

    func testGlossaryProtectsTheExactOccurrencesEvenWhenTermsRepeat() {
        let input = "Мы обсудили Focus группы, потом Focus группы. Всё, Sorry, тогда вопрос."
        XCTAssertEqual(TranscriptOrthography.normalize(input, vocabulary: "Focus, Sorry"), input)
        XCTAssertEqual(TranscriptOrthography.normalize(input, vocabulary: "Focus группы; Sorry"), input)
        XCTAssertEqual(TranscriptOrthography.normalize(input, vocabulary: "Фокус-группа"),
                       "Мы обсудили фокус-группы, потом фокус-группы. Всё, сорри, тогда вопрос.")
    }
}
