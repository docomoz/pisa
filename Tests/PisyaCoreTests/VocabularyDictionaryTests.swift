import XCTest
@testable import PisyaCore

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

    func testCanonicalEquivalentSourceChangeIsStale() {
        let source = "Caf\u{00e9};API"
        let entry = VocabularyDictionary.entries(in: source)[1]
        XCTAssertThrowsError(try VocabularyDictionary.removing(entry, from: "Cafe\u{0301};API"))
    }
}
