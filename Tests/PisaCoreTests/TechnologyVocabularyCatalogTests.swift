import XCTest
@testable import PisaCore

final class TechnologyVocabularyCatalogTests: XCTestCase {
    private let vocabulary = TechnologyVocabulary(personalVocabulary: "")

    func testWhiteLabelIsOneTermAcrossSpokenAndWrittenForms() {
        let source = "Предлагаем вайт лейбл, white label и white‑label."
        XCTAssertEqual(vocabulary.apply(to: source), "Предлагаем white-label, white-label и white-label.")
        XCTAssertEqual(vocabulary.observedTerms(in: [source], limit: 8), ["white-label"])
    }

    func testHeadHunterUsesOneBrandSpellingAndPreservesCaseEnding() {
        let source = "Сервис хедхантер ответил. Обсудили Headhunter и нашли вакансию в хитхантере."
        XCTAssertEqual(vocabulary.apply(to: source), "Сервис HeadHunter ответил. Обсудили HeadHunter и нашли вакансию в HeadHunter'е.")
        XCTAssertEqual(vocabulary.observedTerms(in: [source], limit: 8), ["HeadHunter"])
    }

    func testOtelloRecognizesBrandWithoutChangingCharacterName() {
        let source = "Интеграция с сервисом отэлло и платформой Otella. Читаем трагедию «Отелло»."
        let expected = "Интеграция с сервисом Otello и платформой Otello. Читаем трагедию «Отелло»."
        XCTAssertEqual(vocabulary.apply(to: source), expected)
        XCTAssertEqual(vocabulary.observedTerms(in: [source], limit: 8), ["Otello"])
        XCTAssertEqual(TechnologyVocabulary(personalVocabulary: "Otello").apply(to: source), expected)
    }

    func testProfessionalTermsCoverDevelopmentFinanceAndExecutiveMeetings() {
        let source = "Обсудили контрактное тестирование и канареечный релиз. Для отчётности по ай эф ар эс открыли дата рум. Решения согласует си сюит."
        XCTAssertEqual(vocabulary.observedTerms(in: [source], limit: 8),
                       ["контрактное тестирование", "канареечный релиз", "IFRS", "data room", "C-suite"])
    }

    func testBusinessToConsumerCanonicalSpellingUsesLatinLetters() {
        let source = "Сравнили Б2С, B2С и Б2C."
        let expected = "Сравнили B2C, B2C и B2C."
        XCTAssertEqual(vocabulary.apply(to: source), expected)
        XCTAssertEqual(TechnologyVocabulary(personalVocabulary: "B2C").apply(to: source), expected)
    }

    func testRecognizedProfessionalInitialismsUseTheirUsualLatinSpelling() {
        let source = "Сверили КПИ и оу кей ар на квартал. Посчитали эн пи эс и ЭБИТДА. Согласовали АПИ и эс ди кей для си ар эм. ПО и НДС обсудили в РФ."
        let expected = "Сверили KPI и OKR на квартал. Посчитали NPS и EBITDA. Согласовали API и SDK для CRM. ПО и НДС обсудили в РФ."
        XCTAssertEqual(vocabulary.apply(to: source), expected)
    }

    func testPlanningTermsAreRecognizedByTheSystemVocabulary() {
        let source = "Обсудили роудмап и челлендж на кью один, кью два, кью три и q4. Через первый квартал сверим результаты."
        XCTAssertEqual(vocabulary.apply(to: source),
                       "Обсудили roadmap и challenge на Q1, Q2, Q3 и Q4. Через первый квартал сверим результаты.")
        XCTAssertEqual(vocabulary.observedTerms(in: [source], limit: 8), ["roadmap", "challenge", "Q1", "Q2", "Q3", "Q4"])
    }

    func testOrdinaryWordsAndLiteralPathsArePreserved() {
        let source = "We hired a headhunter. Наняли хедхантера и встретились с хедхантером. Прочли Отелло. Обсудили НИР и ОКР. Изучили симптомы ОКР. В отчёте есть СРМ. Не меняем B2S, `white label` и https://otello.ru."
        XCTAssertEqual(vocabulary.apply(to: source), source)
        XCTAssertTrue(vocabulary.observedTerms(in: [source], limit: 8).isEmpty)
    }
}
