import XCTest
@testable import PisaCore

final class RecognitionWorkReductionTests: XCTestCase {
    private final class Probe {
        let cache = RecognitionDecodeCache<Int, Int>()
        var preparations = 0
        var generations = 0
        var lastInput = 0

        func prepare() -> Int {
            preparations += 1
            return preparations
        }

        func decode(_ samples: [Float] = [0, 1], context: String = "словарь", language: String? = nil,
                    maxTokens: Int = 96, tokens: Int? = nil) -> Int {
            cache.value(samples: samples, context: context, language: language, maxTokens: maxTokens,
                        prepare: prepare, generate: { input in
                lastInput = input
                generations += 1
                return generations
            }, completedTokens: { _ in tokens })
        }
    }

    func testIdenticalDecodeReusesRawOutputButEveryChangedInputRunsAgain() {
        let probe = Probe()
        XCTAssertEqual(probe.decode(), 1)
        XCTAssertEqual(probe.decode(), 1)
        XCTAssertEqual(probe.decode([-0.0, 1]), 2)
        XCTAssertEqual(probe.decode([0, Float(1).nextUp]), 3)
        XCTAssertEqual(probe.decode(context: ""), 4)
        XCTAssertEqual(probe.decode(language: "Russian"), 5)
        XCTAssertEqual(probe.decode(maxTokens: 97), 6)
        XCTAssertEqual(probe.decode(), 1)
        XCTAssertEqual(probe.preparations, 3)
        XCTAssertEqual(probe.lastInput, 1)
        XCTAssertEqual(probe.cache.hitCount, 2)
    }

    func testCanonicallyEquivalentPromptAndLanguageBytesDoNotShareDecode() {
        let probe = Probe()
        XCTAssertEqual(probe.decode(context: "ё"), 1)
        XCTAssertEqual(probe.decode(context: "е\u{0308}"), 2)
        XCTAssertEqual(probe.decode(context: "ё"), 1)
        XCTAssertEqual(probe.decode(context: "", language: "ё"), 3)
        XCTAssertEqual(probe.decode(context: "", language: "е\u{0308}"), 4)
        XCTAssertEqual(probe.decode(context: "", language: nil), 5)
        XCTAssertEqual(probe.decode(context: "", language: ""), 6)
        XCTAssertEqual(probe.preparations, 1)
    }

    func testCompletedGenerationCanServeOtherCapsStrictlyAboveItsLength() {
        let probe = Probe()
        // Short caps produce distinct partial results, including the cap that
        // ends on the last text token before the stop token could be observed.
        XCTAssertEqual(probe.decode(maxTokens: 7, tokens: 7), 1)
        XCTAssertEqual(probe.decode(maxTokens: 8, tokens: 8), 2)
        XCTAssertEqual(probe.decode(maxTokens: 10, tokens: 8), 3)
        XCTAssertEqual(probe.decode(maxTokens: 12), 3)
        XCTAssertEqual(probe.decode(maxTokens: 9), 3)
        XCTAssertEqual(probe.decode(maxTokens: 7), 1)
        XCTAssertEqual(probe.decode(maxTokens: 8), 2)
        XCTAssertEqual(probe.decode(maxTokens: 6, tokens: 6), 4)
        XCTAssertEqual(probe.preparations, 1)
    }

    func testUnknownOrInvalidCompletionCountsOnlyServeTheirExactCaps() {
        let probe = Probe()
        XCTAssertEqual(probe.decode(maxTokens: 3), 1)
        XCTAssertEqual(probe.decode(maxTokens: 4, tokens: -1), 2)
        XCTAssertEqual(probe.decode(maxTokens: 5, tokens: 6), 3)
        XCTAssertEqual(probe.decode(maxTokens: 6, tokens: 0), 4)
        XCTAssertEqual(probe.decode(maxTokens: 1), 4)
        XCTAssertEqual(probe.decode(maxTokens: 0, tokens: 0), 5)
        XCTAssertEqual(probe.cache.hitCount, 1)
    }

    func testFailedDecodeCanBeRetriedAndNaNPayloadIsComparedBitwise() {
        enum Failure: Error { case cancelled }
        let probe = Probe()
        let samples = [Float(bitPattern: 0x7fc00001)]
        XCTAssertThrowsError(try probe.cache.value(samples: samples, context: "словарь", language: nil,
            maxTokens: 96, prepare: probe.prepare, generate: { _ in throw Failure.cancelled },
            completedTokens: { _ in XCTFail("No output to cache after a failure"); return nil }))
        XCTAssertEqual(probe.decode(samples), 1)
        XCTAssertEqual(probe.decode(samples), 1)
        XCTAssertEqual(probe.decode([Float(bitPattern: 0x7fc00002)]), 2)
        XCTAssertEqual(probe.preparations, 2)
        XCTAssertEqual(probe.cache.hitCount, 1)
    }

    func testOnlyEightRecentResultsAreRetainedPerClip() {
        let probe = Probe()
        for index in 0..<8 { XCTAssertEqual(probe.decode(context: String(index)), index + 1) }
        XCTAssertEqual(probe.decode(context: "0"), 1)
        XCTAssertEqual(probe.decode(context: "8"), 9)
        XCTAssertEqual(probe.decode(context: "0"), 1)
        XCTAssertEqual(probe.decode(context: "1"), 10)
        XCTAssertEqual(probe.preparations, 1)
    }

    func testOnlyThirtyTwoRecentInputsAreRetained() {
        let probe = Probe()
        for index in 0..<32 { _ = probe.decode([Float(index)]) }
        XCTAssertEqual(probe.decode([0]), 1)
        _ = probe.decode([32])
        XCTAssertEqual(probe.decode([0]), 1)
        XCTAssertEqual(probe.decode([1]), 34)
        XCTAssertEqual(probe.preparations, 34)
    }

    func testSampleBudgetChargesAtLeastOneSecondPerClip() {
        let probe = Probe()
        let full = [Float](repeating: 0, count: 30 * 16_000)
        _ = probe.decode(full)
        _ = probe.decode([Float](repeating: 1, count: full.count))
        _ = probe.decode([Float](repeating: 2, count: full.count))
        _ = probe.decode([Float](repeating: 3, count: 29 * 16_000))
        _ = probe.decode([4])
        // Three thirty-second clips, a 29-second clip and a single sample fit.
        XCTAssertEqual(probe.preparations, 5)
        XCTAssertEqual(probe.decode([4]), 5)
        _ = probe.decode([5])
        XCTAssertEqual(probe.decode(full), 7)
        XCTAssertEqual(probe.preparations, 7)
    }

    func testMultiChunkOutputServesOnlyItsExactCapAndOversizeAudioBypassesCache() {
        let probe = Probe()
        let multiChunk = [Float](repeating: 0, count: 30 * 16_000 + 1)
        let oversize = [Float](repeating: 0, count: 120 * 16_000 + 1)
        // Multiple chunks have individual caps. The caller supplies no single completion count.
        XCTAssertEqual(probe.decode(multiChunk, maxTokens: 96, tokens: nil), 1)
        XCTAssertEqual(probe.decode(multiChunk, maxTokens: 128, tokens: nil), 2)
        XCTAssertEqual(probe.decode(oversize, tokens: 1), 3)
        XCTAssertEqual(probe.decode(oversize, tokens: 1), 4)
        XCTAssertEqual(probe.decode(multiChunk, maxTokens: 96), 1)
        XCTAssertEqual(probe.preparations, 3)
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
