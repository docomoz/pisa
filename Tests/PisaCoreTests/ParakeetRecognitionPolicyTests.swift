import XCTest
@testable import PisaCore

final class ParakeetRecognitionPolicyTests: XCTestCase {
    func testIsolatedSubtitleAttributionsCanBeFalseOnSilenceOrMaskRealSpeech() {
        for credit in ["Субтитры сделал DimaTorzok", "Редактор субтитров — Анна Смирнова.",
                       "Субтитры подготовила Команда Север", "Captions by River Studio"] {
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
                verifier: "", language: "None", acoustic: ""), .silence)
            // The first pass may instead have obtained the credit from the verifier.
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: "",
                verifier: credit, language: "Russian", acoustic: ""), .silence)
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
                verifier: "Вернёмся завтра.", language: "Russian", acoustic: "вернемся завтра"), .speech("Вернёмся завтра."))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: "Уже готово.",
                verifier: credit, language: "Russian", acoustic: "уже готово"), .speech("Уже готово."))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
                verifier: "Не успели.", language: "Russian", acoustic: "мы хотели"), .unclear)
        }
    }

    func testSpokenCreditsAndUnrelatedConversationSurvive() {
        let credit = "Субтитры сделал DimaTorzok"
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Субтитры сделал Дима Торзок.", language: "Russian", acoustic: "субтитры сделал дима торзок"), .keep)
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Субтитры сделал Михаил.", language: "Russian", acoustic: "субтитры сделал михаил"), .speech("Субтитры сделал Михаил."))
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Субтитры сделал Михаил.", language: "Russian", acoustic: "субтитры сделал иван"), .unclear)
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "Включи субтитры.", language: "Russian", acoustic: "включи субтитры"), .speech("Включи субтитры."))
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: nil, language: nil, acoustic: nil), .keep)
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit,
            verifier: "", language: nil, acoustic: ""), .keep)
        for ordinary in ["Мы обсуждали, кто сделал субтитры.", "Субтитры включим позже.",
                         "Он процитировал: «Субтитры сделал DimaTorzok».", "Can you turn the captions on?"] {
            XCTAssertFalse(RecognitionSubtitleCredit.needsVerification(ordinary))
            XCTAssertEqual(RecognitionSubtitleCredit.decision(for: ordinary, primary: ordinary,
                verifier: "", language: "None", acoustic: ""), .keep)
        }
    }

    func testIndependentWideReadingConfirmsTheEntireIsolatedTurnWithoutBorrowingItsEnding() {
        let credit = "Субтитры сделал NorthStudio"
        let acoustic = "Проверяют со стороны команды и"
        let verifier = "проверяют стороны команды и дальше"
        func decision(_ wide: String, check: String = "проверяют стороны команды и дальше") -> RecognitionSubtitleCredit.Decision {
            RecognitionSubtitleCredit.decision(for: credit, primary: credit, verifier: check, language: "Russian",
                acoustic: acoustic, expandedPrimary: { wide })
        }
        let wide = "Договорились, проверяют со стороны команды, и дальше всё пришлют."
        XCTAssertEqual(decision(wide), .speech(acoustic))
        for wrong in [
            "Договорились, проверяют со стороны отдела, и дальше всё пришлют.",
            "Договорились, проверяют со стороны команды. Дальше всё пришлют.", // missing the final word
            "Проверяют со стороны команды, и потом проверяют со стороны команды и снова приходят.",
            "Проверяют вчера, а сегодня проверяют со стороны команды, и дальше всё пришлют.",
            "Договорились, не проверяют со стороны команды, и дальше всё пришлют.",
        ] {
            XCTAssertEqual(decision(wrong), .unclear)
        }
        XCTAssertEqual(decision(wide, check: "Не " + verifier), .unclear)
        XCTAssertEqual(decision(wide, check: "Об этом поговорим завтра"), .unclear)
        var widerReads = 0
        XCTAssertEqual(RecognitionSubtitleCredit.decision(for: credit, primary: credit, verifier: credit,
            language: "Russian", acoustic: acoustic, expandedPrimary: { widerReads += 1; return wide }), .keep)
        XCTAssertEqual(widerReads, 0)
    }

    func testRussianEvidenceDoesNotComeFromDecoderLanguageDefault() {
        for text in ["Проверим LLM'ки завтра", "Серёжа встретился со Сбером", "угу", "Да, вылазию", "Мы с Євгеном обсудили два ГИСа и выпустили новый релиз"] {
            XCTAssertTrue(ParakeetRecognitionPolicy.hasRussianTextEvidence(text), text)
        }
        for text in ["Let's review the API tomorrow", "OK, sure", "123", "", "перевіримо зміни завтра", "Καλημέρα"] {
            XCTAssertFalse(ParakeetRecognitionPolicy.hasRussianTextEvidence(text), text)
        }
    }

    func testCustomPrimaryDoesNotRedirectManagedVerifier() {
        let speakers = URL(fileURLWithPath: "/managed/Models/Speakers")
        XCTAssertEqual(ParakeetRecognitionPolicy.verifierDirectory(explicit: nil, speakerDirectory: speakers).path,
                       "/managed/Models/Qwen3-ASR")
        let custom = URL(fileURLWithPath: "/custom/verification")
        XCTAssertEqual(ParakeetRecognitionPolicy.verifierDirectory(explicit: custom, speakerDirectory: speakers), custom)
    }

    func testEngineIdentityDistinguishesPrimaryAndVerifierRoles() {
        XCTAssertEqual(ParakeetRecognitionPolicy.checkpointVariants["primary"], ["parakeet-tdt-v3", "weights-float32", "audio-float32"])
        XCTAssertEqual(ParakeetRecognitionPolicy.checkpointVariants["verifier"], ["qwen-selective"])
    }

    func testCheckpointRejectsOldEngineAndChangedVerifierWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.caf")
        let verifier = root.appendingPathComponent("verifier.safetensors")
        try Data([1]).write(to: audio)
        try Data([2]).write(to: verifier)
        func inputs(_ variants: [String: [String]]) throws -> BatchTranscriptionCheckpoint.Inputs {
            try BatchTranscriptionCheckpoint.Inputs(files: [(audio, 0)], model: root,
                vocabulary: "Сбер", variants: variants, supportingModels: [verifier])
        }
        let old = try inputs([:])
        let current = try inputs(ParakeetRecognitionPolicy.checkpointVariants)
        XCTAssertNotEqual(old, current)
        try Data([2, 3]).write(to: verifier)
        XCTAssertNotEqual(current, try inputs(ParakeetRecognitionPolicy.checkpointVariants))
    }


    func testManagedDerivedTokenizerKeepsCheckpointButSourcesAndCustomTokenizerInvalidateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("Qwen3-ASR")
        let custom = root.appendingPathComponent("Custom")
        let speakers = root.appendingPathComponent("Speakers")
        for url in [managed, custom] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.caf")
        try Data([1]).write(to: audio)
        func inputs(_ directory: URL) throws -> BatchTranscriptionCheckpoint.Inputs {
            try BatchTranscriptionCheckpoint.Inputs(files: [(audio, 0)], model: root,
                vocabulary: "", variants: ParakeetRecognitionPolicy.checkpointVariants,
                supportingModels: ParakeetRecognitionPolicy.verifierCheckpointFiles(directory: directory, speakerDirectory: speakers))
        }
        let vocab = managed.appendingPathComponent("vocab.json")
        try Data([2]).write(to: vocab)
        let beforeLoad = try inputs(managed)
        try Data([3]).write(to: managed.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(beforeLoad, try inputs(managed))
        try Data([2, 4]).write(to: vocab)
        XCTAssertNotEqual(beforeLoad, try inputs(managed))

        let authored = custom.appendingPathComponent("tokenizer.json")
        try Data([5]).write(to: authored)
        let originalCustom = try inputs(custom)
        try Data([5, 6]).write(to: authored)
        XCTAssertNotEqual(originalCustom, try inputs(custom))
    }

}
