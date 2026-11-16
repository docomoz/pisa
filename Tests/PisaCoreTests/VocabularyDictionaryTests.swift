import XCTest
@testable import PisaCore

final class VocabularyDictionaryTests: XCTestCase {
    func testEntriesSplitMixedSeparatorsSkipEmptyAndKeepDistinctOccurrences() {
        let source = " , API;\r\n  👩🏽‍💻 Геопэй \nAPI;; "
        let entries = VocabularyDictionary.entries(in: source)
        XCTAssertEqual(entries.map(\.text), ["API", "👩🏽‍💻 Геопэй", "API"])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertEqual(entries, VocabularyDictionary.entries(in: source))
    }

    func testReplacementChangesOnlySelectedUnicodeRangeAndKeepsExplicitForm() throws {
        let source = "👩🏽‍💻 Старт;  LLM \r\n API,\tХвост "
        let selected = VocabularyDictionary.entries(in: source)[1]
        let result = try VocabularyDictionary.replacing(selected, with: " LLM'ки ", in: source)
        XCTAssertEqual(Array(result.utf8), Array("👩🏽‍💻 Старт;  LLM'ки \r\n API,\tХвост ".utf8))
    }

    func testRemovalTouchesOnlySelectedDuplicateAndRestoresExactBytes() throws {
        let source = "API;  API \r\nХвост"
        let removal = try VocabularyDictionary.removing(VocabularyDictionary.entries(in: source)[1], from: source)
        XCTAssertEqual(removal.vocabulary, "API;   \r\nХвост")
        XCTAssertEqual(Array(try removal.restoring(in: removal.vocabulary).utf8), Array(source.utf8))
    }

    func testStaleOperationsFailEvenWhenSelectedTextStillExists() throws {
        let source = "API;LLM"
        let entry = VocabularyDictionary.entries(in: source)[1]
        for changed in ["XPI;LLM", "API;LLMы", "X;API;LLM"] {
            XCTAssertThrowsError(try VocabularyDictionary.replacing(entry, with: "ИИ", in: changed))
            XCTAssertThrowsError(try VocabularyDictionary.removing(entry, from: changed))
        }
        let removal = try VocabularyDictionary.removing(entry, from: source)
        XCTAssertThrowsError(try removal.restoring(in: "XPI;"))
    }

    func testAppendAllowsOldEntryEditsAndUndoPreservesAppendedTerm() throws {
        let source = " API; LLM "
        let entry = VocabularyDictionary.entries(in: source)[1]
        XCTAssertEqual(try VocabularyDictionary.replacing(entry, with: "ИИ", in: source + "\nНовый"), " API; ИИ \nНовый")
        let removal = try VocabularyDictionary.removing(entry, from: source)
        let appended = TranscriptTerms.adding("Новый", to: removal.vocabulary)
        XCTAssertEqual(try removal.restoring(in: appended), source + "\nНовый")
    }

    func testUndoSoleEntryAfterAppendKeepsEntriesSeparate() throws {
        let removal = try VocabularyDictionary.removing(VocabularyDictionary.entries(in: "API")[0], from: "API")
        XCTAssertEqual(try removal.restoring(in: TranscriptTerms.adding("Новый", to: removal.vocabulary)), "API\nНовый")
    }

    func testUndoSoleEntryWithWhitespaceAfterAdditionPreservesOriginalSpacing() throws {
        let source = "  API \t"
        let removal = try VocabularyDictionary.removing(VocabularyDictionary.entries(in: source)[0], from: source)
        XCTAssertEqual(removal.vocabulary, "   \t")
        let appended = TranscriptTerms.adding("Новый", to: removal.vocabulary)
        XCTAssertEqual(try removal.restoring(in: appended), "  API \t\nНовый")
        XCTAssertThrowsError(try removal.restoring(in: " "))
    }

    func testReplacementRejectsEmptyInvalidAndDuplicatesButAllowsUnchangedValue() throws {
        let source = "API;Северный Атлас;LLM’ки"
        let entry = VocabularyDictionary.entries(in: source)[0]
        for invalid in [" ", "123", "Один,два", "Один;два", "Один\rдва", "Один\nдва", "северный\u{00a0}атлас", "LLM'ки"] {
            XCTAssertThrowsError(try VocabularyDictionary.replacing(entry, with: invalid, in: source))
        }
        XCTAssertEqual(try VocabularyDictionary.replacing(entry, with: "API", in: source), source)
    }

    func testBatchClassifiesSequentialDuplicatesInvalidAndEmptyFields() {
        let source = " API; Северный Атлас "
        let batch = VocabularyDictionary.preview("api;Геопэй\nгеопэй,123;;северный\u{00a0}атлас\rLLM", vocabulary: source)
        XCTAssertEqual(batch.additions, ["Геопэй", "LLM"])
        XCTAssertEqual(batch.duplicates, ["api", "геопэй", "северный\u{00a0}атлас"])
        XCTAssertEqual(batch.invalid, ["123"])
        XCTAssertEqual(batch.emptyCount, 1)
        XCTAssertEqual(batch.vocabulary, source + "\nГеопэй\nLLM")
    }

    func testUnchangedReplacementOfLegacyDuplicatePreservesOriginalBytes() throws {
        let source = " API; API \r\n"
        let entry = VocabularyDictionary.entries(in: source)[1]
        let updated = try VocabularyDictionary.replacing(entry, with: "API", in: source)
        XCTAssertEqual(Array(updated.utf8), Array(source.utf8))
    }

    func testLiteralReplacementRejectsEquivalentApostropheSpellingsBeforeFamilyNormalization() throws {
        let source = "API;LLM’ки;О’Коннор Атлас"
        let entry = VocabularyDictionary.entries(in: source)[0]
        for duplicate in ["LLM'ки", "о'коннор\u{00a0}атлас"] {
            XCTAssertThrowsError(try VocabularyDictionary.replacing(entry, with: duplicate, in: source))
        }
    }

    func testLiteralReplacementPreservesDifferenceBetweenYeAndYo() throws {
        let source = "API;Семен О’Коннор"
        let entry = VocabularyDictionary.entries(in: source)[0]
        XCTAssertEqual(try VocabularyDictionary.replacing(entry, with: "Семён О'Коннор", in: source),
                       "Семён О'Коннор;Семен О’Коннор")
    }

    func testAddingVariantsUsesExistingCanonicalSpellingAndKeepsOtherEntries() throws {
        let original = "  C&B; Яндекс "
        let variants = ["C&B": ["CnB"], "Яндекс": ["Якс"]]
        let updated = try VocabularyDictionary.addingVariants(
            "CNB, си эн би, C and B", for: "c&b", to: original, variants: variants)
        XCTAssertEqual(updated.vocabulary, original)
        XCTAssertEqual(updated.variants, ["C&B": ["CnB", "си эн би", "C and B"], "Яндекс": ["Якс"]])
    }

    func testSavingATermAllowsNoVariantsAndPreservesRegularAcronymEndings() throws {
        let plain = try VocabularyDictionary.addingVariants("", for: "2ГИС", to: "C&B", variants: [:])
        XCTAssertEqual(plain.vocabulary, "C&B\n2ГИС")
        XCTAssertTrue(plain.variants.isEmpty)

        let existing = ["2ГИС": ["тугис"]]
        let same = try VocabularyDictionary.addingVariants("2ГИС, 2ГИС'а, 2ГИСом", for: "2ГИС",
                                                           to: plain.vocabulary, variants: existing)
        XCTAssertEqual(same.vocabulary, plain.vocabulary)
        XCTAssertEqual(same.variants, existing)
    }

    func testAddingVariantsCreatesNewCanonicalAndRejectsOtherOwners() throws {
        let existing = ["C&B": ["CnB"]]
        let updated = try VocabularyDictionary.addingVariants("RND", for: "R&D", to: "C&B", variants: existing)
        XCTAssertEqual(updated.vocabulary, "C&B\nR&D")
        XCTAssertEqual(updated.variants, ["C&B": ["CnB"], "R&D": ["RND"]])
        for conflict in ["cnb", "C&B", "111"] {
            XCTAssertThrowsError(try VocabularyDictionary.addingVariants(
                conflict, for: "R&D", to: updated.vocabulary, variants: updated.variants))
        }
        XCTAssertThrowsError(try VocabularyDictionary.addingVariants(
            "ещё вариант", for: "CNB", to: updated.vocabulary, variants: updated.variants))
    }

    func testEditingAndRestoringVariantsPreservesOtherEntries() throws {
        let original = "API; R&D"
        let entry = VocabularyDictionary.entries(in: original)[1]
        let updated = try VocabularyDictionary.replacing(entry, with: "Research and Development",
            variantInput: "R and D", in: original, variants: ["API": ["эй пи ай"], "R&D": ["RND"]])
        XCTAssertEqual(updated.vocabulary, "API; Research and Development")
        XCTAssertEqual(updated.variants, ["API": ["эй пи ай"], "Research and Development": ["R and D"]])

        let renamed = VocabularyDictionary.entries(in: updated.vocabulary)[1]
        let removal = try VocabularyDictionary.removing(renamed, from: updated.vocabulary, variants: updated.variants)
        XCTAssertEqual(removal.variants, ["API": ["эй пи ай"]])
        let restored = try removal.restoring(in: removal.vocabulary + "\nB2C",
                                             variants: ["API": ["эй пи ай"], "B2C": ["би ту си"]])
        XCTAssertEqual(restored.vocabulary, updated.vocabulary + "\nB2C")
        XCTAssertEqual(restored.variants, updated.variants.merging(["B2C": ["би ту си"]]) { current, _ in current })
    }

    func testLegacyPreferencesDecodeWithoutVariantsAndPersistNewOnes() throws {
        let json = #"{"vocabulary":"C&B","automaticRecording":true,"mcpEnabled":false,"keepAudio":true}"#
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.vocabulary, "C&B")
        XCTAssertTrue(preferences.automaticRecording)
        XCTAssertFalse(preferences.mcpEnabled)
        XCTAssertTrue(preferences.vocabularyVariants.isEmpty)
        preferences.vocabularyVariants = ["C&B": ["CnB"]]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.vocabularyVariants, ["C&B": ["CnB"]])
    }

    func testCanonicalEquivalentSourceChangeIsStale() {
        let source = "Caf\u{00e9};API"
        let entry = VocabularyDictionary.entries(in: source)[1]
        XCTAssertThrowsError(try VocabularyDictionary.removing(entry, from: "Cafe\u{0301};API"))
    }
}
