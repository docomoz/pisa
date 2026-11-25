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

    func testSingleLatinWordRequiresTwoAgreeingFullReadingsAndPreservesItsSentence() throws {
        let source = "Прийти на Navio год."
        // The audio readings in this fixture are independent test inputs.
        let evidence = "прийти на новый год"
        let proposal = try XCTUnwrap(RussianRecognition.embeddedLatinRepair(original: source, heard: evidence, vocabulary: ""))
        XCTAssertEqual(proposal.confirmedText(language: "Russian", reread: evidence), "Прийти на новый год.")
        XCTAssertEqual(proposal.confirmedText(language: "Russian", reread: "Прийти на Новый год!"), "Прийти на Новый год.")
        for reread in [source, "Прийти на ранний год.", "Приду на новый год.", "Прийти на новый срок."] {
            XCTAssertNil(proposal.confirmedText(language: "Russian", reread: reread))
        }
        XCTAssertNil(proposal.confirmedText(language: "English", reread: evidence))
        XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: source, heard: "на новый год", vocabulary: ""))
        XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: source, heard: source, vocabulary: ""))
        XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: source, heard: evidence, vocabulary: "Navio"))
    }

    func testUnpromptedAudioCanRejectALatinNameIntroducedByGlossaryFormatting() throws {
        let raw = "прийти на Новий год."
        let vocabulary = "Navio"
        let formatted = SpokenVocabulary(vocabulary).apply(to: raw)
        XCTAssertEqual(formatted, "прийти на Navio год.")
        let site = try XCTUnwrap(RussianRecognition.formattedLatinWord(primary: raw, formatted: formatted, vocabulary: vocabulary))
        let proposal = try XCTUnwrap(site.proposal(heard: "Прийти на Новый год."))
        XCTAssertEqual(proposal.confirmedText(language: "Russian", reread: "прийти на Новый год."), "прийти на Новый год.")
        XCTAssertNil(proposal.confirmedText(language: "Russian", reread: "прийти на Navio год."))
        XCTAssertNil(proposal.confirmedText(language: "Russian", reread: "прийти на старый год."))
        XCTAssertNil(site.proposal(heard: "прийти на Навио год."))
        XCTAssertNil(site.proposal(heard: "пойти на Новый год."))
        XCTAssertNil(RussianRecognition.formattedLatinWord(primary: formatted, formatted: formatted, vocabulary: vocabulary))
        XCTAssertNil(RussianRecognition.formattedLatinWord(primary: raw, formatted: formatted, vocabulary: "Новий, Navio"))
        let explicitPhrase = try XCTUnwrap(RussianRecognition.formattedLatinWord(primary: raw, formatted: formatted,
            vocabulary: "Navio, Navio год"))
        XCTAssertNil(explicitPhrase.proposal(heard: "Прийти на Новый год."))
        let pronouncedName = try XCTUnwrap(RussianRecognition.formattedLatinWord(primary: "прийти на Навио год.",
            formatted: formatted, vocabulary: vocabulary))
        XCTAssertNil(pronouncedName.proposal(heard: "прийти на Новый год."))
    }

    func testSingleEmbeddedNameCannotBeChangedByTransliterationOrInsideALiteral() {
        for (source, evidence) in [
            ("Сегодня просим Mira помочь.", "сегодня просим мира помочь"),
            ("Мы открыли Figma сегодня.", "мы открыли окно сегодня"),
            ("Мы открыли MyTool сегодня.", "мы открыли окно сегодня"),
            ("Мы открыли «Navio» сегодня.", "мы открыли окно сегодня"),
            ("Мы открыли Navio.dev сегодня.", "мы открыли окно сегодня"),
            ("Мы открыли платформу Navio утром.", "мы открыли платформу вчера утром"),
            ("О нём просили Navio вчера.", "о нем просили Петю вчера"),
        ] {
            XCTAssertNil(RussianRecognition.embeddedLatinRepair(original: source, heard: evidence, vocabulary: ""), source)
        }
    }

    func testOnlyActualSpeechIsCheckedOnLongerTurns() {
        XCTAssertEqual(SpeechCoverage.unpaddedTurn(start: 0.25, duration: 8, sampleCount: 136_000), 4_000..<132_000)
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: 0.25, duration: 8, sampleCount: 136_000))
        XCTAssertNil(SpeechCoverage.unpaddedTurn(start: 0.25, duration: 8, sampleCount: 120_000))
    }
}
