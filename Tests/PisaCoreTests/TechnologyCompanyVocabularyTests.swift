import XCTest
@testable import PisaCore

final class TechnologyCompanyVocabularyTests: XCTestCase {
    func testBundledCatalogAndWrittenRussianAlias() {
        XCTAssertGreaterThan(TechnologyCompanyVocabulary.entryCount, 10_000)
        let names = TechnologyCompanyVocabulary.matches(in: "Выбрали Microsoft и Лаборатория Касперского для обсуждения", protecting: [])
        XCTAssertTrue(names.contains { $0.term == "Microsoft" })
        XCTAssertTrue(names.contains { $0.term == "Kaspersky Lab" })
        XCTAssertTrue(names.allSatisfy { $0.replacement == nil })
    }

    func testOrdinaryEnglishWordsNeedLocalCompanyContext() {
        XCTAssertTrue(TechnologyCompanyVocabulary.matches(in: "Apple pie is good. Nothing is wrong. True words matter.", protecting: []).isEmpty)
        XCTAssertTrue(TechnologyCompanyVocabulary.matches(in: "Apple pie is good. Компания выбрала поставщика.", protecting: []).isEmpty)
        XCTAssertTrue(TechnologyCompanyVocabulary.matches(in: "Обсудили компанию Apple", protecting: []).contains { $0.term == "Apple" })
    }

    func testIndustryConceptsAreNotCompanyNames() {
        for concept in ["software company", "application developer", "Design rule checking", "дизайн пользовательского интерфейса"] {
            XCTAssertFalse(TechnologyCompanyVocabulary.isCanonical(concept), concept)
            XCTAssertTrue(TechnologyCompanyVocabulary.matches(in: concept, protecting: []).isEmpty, concept)
        }
    }

    func testProtectedSpansPathsAndCaseAreNotCompanyMentions() {
        let text = "Microsoft и Microsoft"
        let found = TechnologyCompanyVocabulary.matches(in: text, protecting: [NSRange(location: 0, length: 9)])
        XCTAssertEqual(found.filter { $0.term == "Microsoft" }.map(\.range.location), [12])
        for text in ["`Microsoft`", "https://Microsoft.com", "foo_Microsoft", "dir/Microsoft", "microsoft"] {
            XCTAssertFalse(TechnologyCompanyVocabulary.matches(in: text, protecting: []).contains { $0.term == "Microsoft" }, text)
        }
    }
}
