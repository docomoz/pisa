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
}
