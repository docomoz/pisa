import XCTest
@testable import PisaCore

final class RecognitionWorkReductionTests: XCTestCase {
    func testIdenticalDecodeReusesRawOutputButEveryChangedInputRunsAgain() throws {
        let cache = RecognitionDecodeCache<String>()
        var calls = 0
        func decode(_ samples: [Float] = [0, 1], context: String = "словарь", language: String? = nil,
                    maxTokens: Int = 96) throws -> String {
            cache.value(samples: samples, context: context, language: language, maxTokens: maxTokens) {
                calls += 1
                return "output-\(calls)"
            }
        }
        XCTAssertEqual(try decode(), "output-1")
        XCTAssertEqual(try decode(), "output-1")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try decode([-0.0, 1]), "output-2")
        XCTAssertEqual(try decode([0, Float(1).nextUp]), "output-3")
        XCTAssertEqual(try decode(context: ""), "output-4")
        XCTAssertEqual(try decode(language: "Russian"), "output-5")
        XCTAssertEqual(try decode(maxTokens: 97), "output-6")
        XCTAssertEqual(try decode(), "output-1")
    }

    func testCanonicallyEquivalentPromptAndLanguageBytesDoNotShareDecode() {
        let cache = RecognitionDecodeCache<String>()
        var calls = 0
        func decode(context: String, language: String? = nil) -> String {
            cache.value(samples: [0, 1], context: context, language: language, maxTokens: 96) {
                calls += 1
                return "output-\(calls)"
            }
        }
        // Swift String equality normalizes these spellings; a byte tokenizer
        // must still receive the exact prompt of each original decode.
        XCTAssertEqual(decode(context: "ё"), "output-1")
        XCTAssertEqual(decode(context: "е\u{0308}"), "output-2")
        XCTAssertEqual(decode(context: "ё"), "output-1")
        XCTAssertEqual(decode(context: "", language: "ё"), "output-3")
        XCTAssertEqual(decode(context: "", language: "е\u{0308}"), "output-4")
    }

    func testFailedDecodeCanBeRetriedAndNaNPayloadIsComparedBitwise() throws {
        enum Failure: Error { case cancelled }
        let cache = RecognitionDecodeCache<String>()
        let samples = [Float(bitPattern: 0x7fc00001)]
        XCTAssertThrowsError(try cache.value(samples: samples, context: "", language: nil, maxTokens: 96) {
            throw Failure.cancelled
        })
        XCTAssertEqual(cache.value(samples: samples, context: "", language: nil, maxTokens: 96) { "recovered" }, "recovered")
        XCTAssertEqual(cache.value(samples: samples, context: "", language: nil, maxTokens: 96) { XCTFail("same PCM decoded twice"); return "wrong" }, "recovered")
    }

    func testBroadRetrySkipsDifferencesWhichCannotHaveAcceptanceAnchors() {
        for evidence in ["Обсудим сегодня эти сроки завтра", "Обсудим сегодня эти сроки сейчас",
                         "Проверим сегодня эти сроки завтра"] {
            XCTAssertFalse(RussianRecognition.canRevise(original: "Обсудим сегодня эти сроки завтра",
                corroboration: evidence, hypothesis: evidence, vocabulary: ""), evidence)
        }
        XCTAssertFalse(RussianRecognition.canRevise(original: "Обсудим сегодня эти сроки завтра",
            corroboration: "Совсем другая фраза без совпадений", hypothesis: "Совсем другая фраза без совпадений", vocabulary: ""))
    }

    func testBroadRetryPreservesLocalRepairDespiteOtherVerifierDifferences() {
        let original = "Сегодня мы быстро обсудим старые сроки и завтра закроем вопрос"
        let evidence = "Вчера мы быстро обсудим новые сроки и завтра отправим письмо"
        let candidate = "Сегодня мы быстро обсудим новые сроки и завтра закроем вопрос"
        XCTAssertNotNil(RussianRecognition.revisedText(original: original, candidate: candidate,
            corroboration: evidence, hypothesis: evidence, vocabulary: "", usesCyrillicHints: false))
        XCTAssertTrue(RussianRecognition.canRevise(original: original, corroboration: evidence,
            hypothesis: evidence, vocabulary: ""))
    }

    func testEveryAcceptedBoundedRepairSurvivesPreflightWithIndependentOuterErrors() {
        let oldWords = ["старые", "большие", "городские", "рабочие"]
        let newWords = ["новые", "малые", "сельские", "дневные"]
        var accepted = 0
        for oldCount in 0...4 {
            for newCount in 0...4 where oldCount != 0 || newCount != 0 {
                let original = (["Сегодня", "обсудим"] + oldWords.prefix(oldCount) + ["сроки", "позже"]).joined(separator: " ")
                let evidence = (["Вчера", "обсудим"] + newWords.prefix(newCount) + ["сроки", "раньше"]).joined(separator: " ")
                let candidate = (["Сегодня", "обсудим"] + newWords.prefix(newCount) + ["сроки", "позже"]).joined(separator: " ")
                if let result = RussianRecognition.revisedText(original: original, candidate: candidate,
                    corroboration: evidence, hypothesis: evidence, vocabulary: "", usesCyrillicHints: false), result != original {
                    accepted += 1
                    XCTAssertTrue(RussianRecognition.canRevise(original: original, corroboration: evidence,
                        hypothesis: evidence, vocabulary: ""), "\(oldCount) -> \(newCount): \(result)")
                }
            }
        }
        // The matrix must exercise real accepted changes, not vacuous rejection.
        XCTAssertGreaterThan(accepted, 0)
    }

    func testBroadRetryRetainsRightOnlyNameAndCanonicalGlossaryEvidence() {
        let original = "Мы говорили Санджелой по этому вопросу."
        let evidence = "Дальше обсуждали с Анжелой по этому вопросу."
        XCTAssertTrue(RussianRecognition.canRevise(original: original, corroboration: evidence,
            hypothesis: evidence, vocabulary: "Анжела"))
        let source = "Передадим данные вай-клиенты, обсудим Retail Media."
        let raw = "Передадим данные в Vie Clints и обсудим Rity Media."
        let hint = "Передадим данные в YClients и обсудим Retail Media."
        XCTAssertTrue(RussianRecognition.canRevise(original: source, corroboration: raw,
            hypothesis: hint, vocabulary: "YClients, Retail Media"))
    }
}
