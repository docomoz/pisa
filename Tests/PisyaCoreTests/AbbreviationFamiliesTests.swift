import XCTest
@testable import PisyaCore

final class AbbreviationFamiliesTests: XCTestCase {
    func testAllSupportedEndingsKeepTheirOwnFormAndAreIdempotent() {
        for base in ["2ГИС", "7АБВ", "LLM", "AI"] {
            let families = AbbreviationFamilies(base)
            for ending in AbbreviationFamilies.endings {
                let expected = base + "'" + ending
                XCTAssertEqual(families.normalize(in: base + ending), expected)
                XCTAssertEqual(families.normalize(in: expected), expected)
                XCTAssertEqual(families.known(expected)?.ending, ending)
            }
            XCTAssertEqual(families.normalize(in: base), base)
        }
    }

    func testExplicitCompetingAcronymsAndFullFormsWinOverAliases() {
        let families = AbbreviationFamilies("2ГИС, 2GIS, 2GISA, AI, AIM, LLM'ки")
        for exact in ["2ГИС", "2GIS", "2GISA", "AI", "AIM", "LLM'ки"] {
            XCTAssertEqual(families.normalize(in: exact), exact)
        }
        XCTAssertNil(families.known("2GIS'ом"))
        XCTAssertNil(families.form("LLM'ки"))
        XCTAssertEqual(SpokenVocabulary("2ГИС, 2GIS").apply(to: "2ГИС и 2GIS"), "2ГИС и 2GIS")
        let segment = TranscriptSegment(start: 0, end: 2, speaker: "А", text: "С 2GIS'ом и 2ГИС'ом")
        XCTAssertTrue(TranscriptTerms.matches("2ГИС", in: [segment], vocabulary: "2ГИС, 2GIS").isEmpty)
    }

    func testNumericLatinSpellingAlsoAcceptsRussianWrittenNumber() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "в двух ГИСе и с двугисом", vocabulary: "2GIS"),
                       "в 2GIS'е и с 2GIS'ом")
    }

    func testWordsAndProtectedRangesAreNotAcronymFragments() {
        let source = "AIM, задача, api_key, X-AIем, `AIем`, https://x.test/AIем, «AIем»"
        XCTAssertEqual(AbbreviationFamilies("AI, API").normalize(in: source), source)
        XCTAssertNil(AbbreviationFamilies.inferred("Марина"))
        XCTAssertNil(AbbreviationFamilies.inferred("2ГИСоном"))
    }

    func testDictionaryAddingKnownAliasDoesNotCreateAnotherEntry() {
        XCTAssertEqual(TranscriptTerms.adding("2GIS'ом", to: "2ГИС"), "2ГИС")
    }

    func testKnownAliasSearchRetainsOccurrencesAfterBaseReplacement() throws {
        let segment = TranscriptSegment(start: 0, end: 3, speaker: "А", text: "С 2GIS'ом и в 2GIS'е")
        XCTAssertEqual(TranscriptTerms.matches("2GIS", in: [segment], vocabulary: "2ГИС").count, 2)
        XCTAssertEqual(TranscriptTerms.matches("2gis", in: [segment], vocabulary: "2ГИС").count, 2)
    }

    func testFamilyPreviewRejectsIncompatibleBaseAndStaleEdits() throws {
        let segment = TranscriptSegment(start: 0, end: 3, speaker: "А", text: "С 2GIS'ом и в 2GIS'е")
        let found = TranscriptTerms.matches("2GIS", in: [segment])
        XCTAssertEqual(found.count, 2)
        XCTAssertNil(TranscriptTerms.replacement(for: found[0], with: "Компания"))
        XCTAssertNil(TranscriptTerms.replacing(found, with: "Компания", in: [segment]))
        XCTAssertEqual(TranscriptTerms.replacement(for: found[0], with: "2ГИС"), "2ГИС'ом")
        var stale = segment
        stale.text = "Изменённая реплика"
        XCTAssertNil(TranscriptTerms.replacing(found, with: "2ГИС", in: [stale]))
    }

    func testNativeAcronymNoOpAndSentenceInitialAttachedForms() throws {
        let segment = TranscriptSegment(start: 0, end: 3, speaker: "А", text: "МИДом занимаются. LLMки помогают.")
        let candidates = TranscriptTerms.candidates(in: [segment], vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["МИД", "LLM"])
        let found = TranscriptTerms.matches("МИД", in: [segment])
        XCTAssertEqual(TranscriptTerms.replacement(for: try XCTUnwrap(found.first), with: "МИД"), "МИДом")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "МИДом", vocabulary: "МИД"), "МИДом")
    }

    func testAcronymWithInternalDigitsUsesTheSameFamily() {
        XCTAssertEqual(AbbreviationFamilies("B2C").normalize(in: "B2C'у и B2Cом"), "B2C'у и B2C'ом")
        let segment = TranscriptSegment(start: 0, end: 2, speaker: "А", text: "B2C'у и B2C'ом")
        XCTAssertEqual(TranscriptTerms.candidates(in: [segment], vocabulary: "").map(\.text), ["B2C"])
    }
}
