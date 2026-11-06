import XCTest
@testable import PisyaCore

final class TranscriptTermsTests: XCTestCase {
    func testCandidatesPreferMarkedTermsAndIgnoreKnownWordsAndLiterals() {
        let segments = [
            segment("Сегодня обсудили API, Геопэй и 7АБВ. Потом повторили Геопэй."),
            segment("Обычное слово, обычное слово. API и 7АБВ. `FAKE` и https://example.com/NOPE")
        ]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "api")
        XCTAssertEqual(Set(candidates.map(\.text)), ["Геопэй", "7АБВ"])
        XCTAssertEqual(candidates.first { $0.text == "7АБВ" }?.occurrences.count, 2)
    }

    func testApostropheEndingsRequireMatchingTheWholeForm() throws {
        let segments = [segment("LLM, LLM'ки и LLM’ки, а также API.")]
        let base = TranscriptTerms.matches("LLM", in: segments)
        XCTAssertEqual(base.map(\.text), ["LLM"])
        XCTAssertTrue(TranscriptTerms.matches("ки", in: segments).isEmpty)
        let full = TranscriptTerms.matches("LLM'ки", in: segments)
        XCTAssertEqual(full.map(\.text), ["LLM'ки", "LLM’ки"])
        let edited = try XCTUnwrap(TranscriptTerms.replacing(full, with: "ИИ", in: segments))
        XCTAssertEqual(edited[0].text, "LLM, ИИ и ИИ, а также API.")
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "Внутренний API")
        XCTAssertTrue(candidates.contains { $0.text == "API" })
        XCTAssertEqual(candidates.first { $0.text == "LLM" }?.occurrences.count, 1)
        XCTAssertEqual(candidates.first { $0.text == "LLM'ки" }?.occurrences.count, 2)
    }

    func testSelectedWholeTermReplacementPreservesOtherTextAndMetadata() throws {
        let segments = [
            segment("🎙 гео пэй и гео\u{00a0}пэй. Супергео пэй. `гео пэй`."),
            segment("Открыли Гео Пэй.")
        ]
        let occurrences = TranscriptTerms.matches("гео пэй", in: segments)
        XCTAssertEqual(occurrences.count, 3)
        let changed = try XCTUnwrap(TranscriptTerms.replacing(Array(occurrences.prefix(2)), with: "Геопэй", in: segments))
        XCTAssertEqual(changed.map(\.text), ["🎙 Геопэй и Геопэй. Супергео пэй. `гео пэй`.", "Открыли Гео Пэй."])
        var restored = changed
        restored[0].text = segments[0].text
        XCTAssertEqual(restored, segments)

        var stale = segments
        stale[0].text = "Сдвиг: " + stale[0].text
        XCTAssertNil(TranscriptTerms.replacing(occurrences, with: "Геопэй", in: stale))
    }

    func testDictionaryPreservesExistingEntriesAndAvoidsDuplicatesAndSeparators() {
        let vocabulary = "API, Северный Атлас\nЯндекс"
        XCTAssertEqual(TranscriptTerms.adding("северный\u{00a0}атлас", to: vocabulary), vocabulary)
        XCTAssertEqual(TranscriptTerms.adding("  Геопэй  ", to: vocabulary), vocabulary + "\nГеопэй")
        XCTAssertEqual(TranscriptTerms.adding("Одно, другое", to: vocabulary), vocabulary)
    }

    private func segment(_ text: String) -> TranscriptSegment {
        var segment = TranscriptSegment(start: 2, end: 4, speaker: "Участник", text: text)
        segment.audioFile = "recording.wav"
        segment.embedding = [0.5]
        return segment
    }
}
