import XCTest
@testable import PisaCore

final class VocabularyVariantReplacementsTests: XCTestCase {
    func testExplicitVariantsUseExactDictionarySpelling() {
        let replacements = VocabularyVariantReplacements([
            "C&B": ["CnB", "си эн би", "C and B"],
            "R&D": ["RND"]
        ], vocabulary: "C&B, R&D")

        XCTAssertEqual(replacements.apply(to: "CNB, си  эн би, C AND B и rnd."), "C&B, C&B, C&B и R&D.")
        XCTAssertEqual(replacements.apply(to: "CMB, сиэнби и R and D."), "CMB, сиэнби и R and D.")
        XCTAssertEqual(replacements.apply(to: "RNDish, xCNB, old-RND, CNB'ом и foo_RND."), "RNDish, xCNB, old-RND, CNB'ом и foo_RND.")
        XCTAssertEqual(replacements.apply(to: "си эн, би. си эн\nби"), "си эн, би. си эн\nби")
    }

    func testLongestMatchingPhraseWinsWithoutASecondReplacementPass() {
        let replacements = VocabularyVariantReplacements([
            "Brand": ["C and B"],
            "C and B Europe": ["CnB", "C and B EU"],
            "US": ["Europe"]
        ], vocabulary: "Brand, C and B Europe, US")

        XCTAssertEqual(replacements.apply(to: "C and B EU, C and B и CnB."), "C and B Europe, Brand и C and B Europe.")
    }

    func testLiteralsAndPathsRemainAsRecognized() {
        let replacements = VocabularyVariantReplacements(["C&B": ["CnB"], "R&D": ["RND"]], vocabulary: "C&B, R&D")

        let source = #"Встреча CnB, `RND`, «CnB», https://example.com/CnB, CnB@example.com, /tmp/RND и C:\Temp\CnB."#
        let expected = #"Встреча C&B, `RND`, «CnB», https://example.com/CnB, CnB@example.com, /tmp/RND и C:\Temp\CnB."#
        XCTAssertEqual(replacements.apply(to: source), expected)
    }

    func testAmbiguousPreferencesDoNotReplaceAnAlias() {
        let replacements = VocabularyVariantReplacements([
            "C&B": ["CnB"],
            "CMB": ["cnb"],
            "R&D": ["RND"]
        ], vocabulary: "C&B, CMB, R&D")

        XCTAssertEqual(replacements.apply(to: "CNB и RND."), "CNB и R&D.")
    }

    func testVariantsCannotOverrideCanonicalTermsOrUseDeletedTargets() {
        let replacements = VocabularyVariantReplacements([
            "C&B": ["CNB", "C’N’B"],
            "R&D": ["RND"]
        ], vocabulary: "C&B, CNB")

        XCTAssertEqual(replacements.apply(to: "CNB и C'N'B, затем RND."), "CNB и C&B, затем RND.")
    }
}
