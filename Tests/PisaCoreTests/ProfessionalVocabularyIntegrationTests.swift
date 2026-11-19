import XCTest
@testable import PisaCore

final class ProfessionalVocabularyIntegrationTests: XCTestCase {
    func testProductOwnerStaysDistinctFromRussianPrepositionAndSoftware() {
        let input = "PO и P-O поговорили с пи оу по дороге. По сути обновили ПО. В команде ай ти есть эйч ар и джи ар."
        for vocabulary in ["", "PO, IT, HR, GR"] {
            XCTAssertEqual(SpokenVocabulary(vocabulary).apply(to: input),
                           "PO и PO поговорили с PO по дороге. По сути обновили ПО. В команде IT есть HR и GR.")
        }
    }

    func testWhiteLabelDoesNotRewriteAnOrdinaryEnglishLabel() {
        let text = "Put the white label on the box."
        XCTAssertEqual(SpokenVocabulary("").apply(to: text), text)
        XCTAssertEqual(SpokenVocabulary("").apply(to: "Предлагаем white label для бизнеса."),
                       "Предлагаем white-label для бизнеса.")
        XCTAssertEqual(SpokenVocabulary("").apply(to: "We offer a white label product."),
                       "We offer a white-label product.")
        XCTAssertEqual(SpokenVocabulary("").apply(to: "Это вайт лейбл."), "Это white-label.")
    }

    func testPersonalCanonicalTermKeepsBuiltInWrittenAliases() {
        for vocabulary in ["", "B2C", "B2C, API, JavaScript"] {
            let normalizer = SpokenVocabulary(vocabulary)
            XCTAssertEqual(normalizer.apply(to: "Для Б2Ц и В2С сделали продукт."),
                           "Для B2C и B2C сделали продукт.", vocabulary)
        }
        XCTAssertEqual(SpokenVocabulary("b2c").apply(to: "Для Б2Ц сделали продукт."),
                       "Для b2c сделали продукт.")
        XCTAssertEqual(SpokenVocabulary("JavaScript").apply(to: "Пишем на Javascript."),
                       "Пишем на JavaScript.")
    }

    func testExplicitCompetingAliasKeepsUserSpelling() {
        for vocabulary in ["Б2Ц", "B2C, Б2Ц"] {
            XCTAssertEqual(SpokenVocabulary(vocabulary).apply(to: "Для Б2Ц сделали продукт."),
                           "Для Б2Ц сделали продукт.")
        }
        XCTAssertEqual(SpokenVocabulary("B2C").apply(to: "B2S и би ту эс — другое имя."),
                       "B2S и би ту эс — другое имя.")
        let literal = "Код `Б2Ц`, цитата «Б2Ц», путь /Б2Ц/data и my_Б2Ц."
        XCTAssertEqual(SpokenVocabulary("B2C").apply(to: literal), literal)
    }

    func testPersonalCompanyKeepsInflectionsAndOccupationMeaning() {
        let normalizer = SpokenVocabulary("HeadHunter", pronunciations: "head HH EH1 D\nhunter HH AH1 N T ER0")
        XCTAssertEqual(normalizer.apply(to: "Разместили вакансию на хедхантере."),
                       "Разместили вакансию на HeadHunter'е.")
        let occupation = "Мы наняли хедхантера. Он встретился с хедхантером."
        XCTAssertEqual(normalizer.apply(to: occupation), occupation)
    }

    func testCuratedPersonalAliasesDoNotDuplicateDecoderHints() {
        let normalizer = SpokenVocabulary("B2C")
        XCTAssertEqual(normalizer.contextualVocabulary(in: ["Для Б2С сделали продукт."]), "B2C")
        XCTAssertEqual(normalizer.relevantTerms(in: ["Для Б2С сделали продукт."]), "B2C")
    }

    func testPersonalNumericBrandKeepsChosenScriptForCatalogPronunciations() {
        let input = "Проверим 2GIS, ту гис и результат ту гиса после обновления."
        for term in ["2GIS", "2ГИС"] {
            let normalizer = SpokenVocabulary(term)
            XCTAssertEqual(normalizer.apply(to: input), "Проверим \(term), \(term) и результат \(term)'а после обновления.")
            XCTAssertEqual(normalizer.contextualVocabulary(in: ["Проверим ту гис."]), term)
            XCTAssertEqual(normalizer.relevantTerms(in: ["Проверим ту гис."]), term)
            XCTAssertEqual(normalizer.apply(to: "Остались 2GS и обычный термин."), "Остались 2GS и обычный термин.")
        }
        let competing = SpokenVocabulary("2GIS, 2ГИС, 2GS")
        XCTAssertEqual(competing.apply(to: "Сравнили 2GIS, 2ГИС и 2GS."), "Сравнили 2GIS, 2ГИС и 2GS.")
        XCTAssertEqual(competing.apply(to: "Сравнили ту гис."), "Сравнили ту гис.")
    }

    func testObservedNumericBrandAliasesFollowThePersonalSpelling() {
        let input = "Проверили 2 ги, в два гесе и затем два Гиз. Оставили два проекта ГИС."
        for term in ["2GIS", "2ГИС"] {
            let normalizer = SpokenVocabulary(term)
            XCTAssertEqual(normalizer.apply(to: input),
                           "Проверили \(term), в \(term)'е и затем \(term). Оставили два проекта ГИС.")
        }
        XCTAssertEqual(SpokenVocabulary("").apply(to: input), input)
        XCTAssertEqual(SpokenVocabulary("2GIS, Гиз").apply(to: "Также два Гиз."), "Также два Гиз.")
        XCTAssertEqual(SpokenVocabulary("2GIS, 2ГИ").apply(to: "Проверили 2 ги."), "Проверили 2ГИ.")
    }

    func testOmittedNumericAcronymLetterRequiresExactIndependentlyHeardBrand() {
        let source = "Мы вчера проверили 2GS после обновления карты."
        for term in ["2GIS", "2ГИС"] {
            let vocabulary = "API, " + term
            let normalizer = SpokenVocabulary(vocabulary)
            let confirmed = "Мы вчера проверили \(term) после обновления карты."
            let heard = "Мы вчера проверили ту гис после обновления карты."
            func revised(_ source: String, heard: String, candidate: String, vocabulary: String) -> String? {
                let normalizer = SpokenVocabulary(vocabulary)
                return RussianRecognition.revisedText(original: source, candidate: normalizer.apply(to: candidate),
                    corroboration: heard, hypothesis: normalizer.promptHypothesis(heard), vocabulary: vocabulary,
                    usesCyrillicHints: false, dictionaryCorroboration: normalizer.apply(to: heard), rawCandidate: candidate)
            }
            XCTAssertEqual(normalizer.apply(to: source), source)
            XCTAssertEqual(revised(source, heard: heard, candidate: confirmed, vocabulary: vocabulary), confirmed)
            XCTAssertNil(revised(source, heard: source, candidate: confirmed, vocabulary: vocabulary))
            XCTAssertNil(revised(source, heard: heard, candidate: source, vocabulary: vocabulary))
            XCTAssertNil(revised(source, heard: heard, candidate: confirmed, vocabulary: vocabulary + ", 2GS"))
            XCTAssertNil(revised("Мы вчера проверили проект после обновления карты.", heard: heard,
                                 candidate: confirmed, vocabulary: vocabulary))
            XCTAssertNil(revised("Мы вчера проверили `2GS` после обновления карты.", heard: heard,
                                 candidate: confirmed, vocabulary: vocabulary))
            XCTAssertNil(revised("Мы вчера проверили тест-2GS после обновления карты.",
                                 heard: "Мы вчера проверили тест-ту гис после обновления карты.",
                                 candidate: "Мы вчера проверили тест-\(term) после обновления карты.", vocabulary: vocabulary))
            let inflected = "Мы вчера работали с 2GS’ом до обновления карты."
            let independent = "Мы вчера работали с ту гисом до обновления карты."
            let spelled = "Мы вчера работали с \(term)'ом до обновления карты."
            XCTAssertEqual(revised(inflected, heard: independent, candidate: spelled, vocabulary: vocabulary), spelled)
            XCTAssertNil(revised(inflected, heard: independent, candidate: spelled, vocabulary: vocabulary + ", 2GS"))
            XCTAssertNil(revised(inflected.replacingOccurrences(of: "2GS", with: "3GS"),
                                 heard: independent, candidate: spelled, vocabulary: vocabulary))
            XCTAssertNil(revised(inflected.replacingOccurrences(of: "’ом", with: "’е"),
                                 heard: independent, candidate: spelled, vocabulary: vocabulary))
        }
    }

    func testFinalNumericSpellingKeepsTwoExplicitAcronymsAndOrdinarySpeech() {
        for term in ["2GIS", "2ГИС"] {
            let vocabulary = term + ", 2GS"
            let normalizer = SpokenVocabulary(vocabulary)
            let tokens = "В 2ГИС'е проверили поиск, с 2GS’ом и 2GS сравнили результаты."
            let expected = "В \(term)'е проверили поиск, с 2GS'ом и 2GS сравнили результаты."
            XCTAssertEqual(TranscriptOrthography.normalize(normalizer.apply(to: tokens), vocabulary: vocabulary), expected)
            for ordinary in ["Проверили два разных ГИС и 2 проекта, потом закончили.",
                             "Скачали 2 ги данных и сжали их.", "[шум]", "Да, хорошо."] {
                XCTAssertEqual(normalizer.apply(to: ordinary), ordinary)
            }
            let noise = "[шум]"
            XCTAssertNil(RussianRecognition.revisedText(original: noise, candidate: term,
                corroboration: noise, hypothesis: noise, vocabulary: vocabulary, usesCyrillicHints: false))
        }
    }
}
