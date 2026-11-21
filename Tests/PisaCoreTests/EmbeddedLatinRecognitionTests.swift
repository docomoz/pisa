import XCTest
@testable import PisaCore

final class EmbeddedLatinRecognitionTests: XCTestCase {
    private let primary = "Вчера мы подробно обсудили Morgen L’Élève du Village после 16 часов."
    private let independent = "Мы обсудили план графек, э-э, перед общим собранием после шестнадцати часов."
    private let reread = "Вчера мы обсудили план-график перед общим собранием после шестнадцати."

    func testIndependentWordAgreementPreservesOriginalContextAndTime() throws {
        let proposal = try XCTUnwrap(RussianRecognition.embeddedLatinRepair(original: primary,
            heard: independent, vocabulary: "пятница"))
        XCTAssertEqual(proposal.confirmedText(language: "Russian", reread: reread),
            "Вчера мы подробно обсудили план-график перед общим собранием после 16 часов.")
        XCTAssertNil(proposal.confirmedText(language: nil, reread: reread))
        XCTAssertNil(proposal.confirmedText(language: "English", reread: reread))
    }

    func testRealEnglishAndUncertainContentStayAsHeardByPrimary() throws {
        let original = "Так мы обычно делаем one step at a time после перерыва."
        let proposal = try XCTUnwrap(RussianRecognition.embeddedLatinRepair(original: original,
            heard: "Мы делаем один шаг за другим после перерыва.", vocabulary: ""))
        XCTAssertNil(proposal.confirmedText(language: "Russian", reread: original))
        let latin = try XCTUnwrap(RussianRecognition.embeddedLatinRepair(original: primary, heard: independent, vocabulary: ""))
        for changed in ["план-график перед чужим собранием", "план-график не перед общим собранием",
                        "план-гараж перед общим собранием", "план-график после общего собрания",
                        "план-график перед вторым собранием", "план-график Перед. Общим собранием"] {
            XCTAssertNil(latin.confirmedText(language: "Russian",
                reread: "Мы обсудили " + changed + " после конца."), changed)
        }
    }

    func testGlossaryNamesQuotedClausesAndAmbiguousAnchorsAreProtected() {
        for term in ["Village", "du Village после", "обсудили Morgen"] {
            XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: primary, heard: independent, vocabulary: term))
        }
        for original in ["Вчера мы подробно обсудили «Morgen L’Élève du Village» после отчёта.",
                         "Вчера мы подробно обсудили Figma после отчёта.",
                         "Вчера мы подробно обсудили SDK for Cloud Storage после отчёта.",
                         "Вчера мы подробно обсудили MyTeam for Cloud Storage после отчёта."] {
            XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: original, heard: independent, vocabulary: ""))
        }
        XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: primary,
            heard: independent + " После собрания.", vocabulary: ""))
        XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: primary, heard: primary, vocabulary: ""))
    }

    func testOnlyActualSpeechIsCheckedOnLongerTurns() {
        XCTAssertEqual(SpeechCoverage.unpaddedTurn(start: 0.25, duration: 8, sampleCount: 136_000), 4_000..<132_000)
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: 0.25, duration: 8, sampleCount: 136_000))
        XCTAssertNil(SpeechCoverage.unpaddedTurn(start: 0.25, duration: 8, sampleCount: 120_000))
    }
}
