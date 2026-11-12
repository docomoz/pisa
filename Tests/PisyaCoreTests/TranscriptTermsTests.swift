import XCTest
@testable import PisyaCore

final class TranscriptTermsTests: XCTestCase {
    func testAbbreviationFamiliesGroupFormsAndRecognizeKnownBase() {
        let segments = [segment("2ГИС'а, 2ГИС’е, 2ГИСом и 2ГИС. Также LLM'ки и LLM'ками.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["2ГИС", "LLM"])
        XCTAssertEqual(candidates.first { $0.text == "2ГИС" }?.occurrences.count, 4)
        XCTAssertTrue(TranscriptTerms.candidates(in: segments, vocabulary: "2ГИС, LLM").isEmpty)
    }

    func testBaseSearchAndReplacementPreserveEachObservedEnding() throws {
        let segments = [segment("2GIS'a, 2GIS'е, 2GISом, 2GIS и Супер2GIS. `2GIS'у`.")]
        let found = TranscriptTerms.matches("2GIS", in: segments)
        XCTAssertEqual(found.map(\.text), ["2GIS'a", "2GIS'е", "2GISом", "2GIS"])
        let changed = try XCTUnwrap(TranscriptTerms.replacing(found, with: "2ГИС", in: segments))
        XCTAssertEqual(changed[0].text, "2ГИС'а, 2ГИС'е, 2ГИС'ом, 2ГИС и Супер2GIS. `2GIS'у`.")
        XCTAssertEqual(TranscriptTerms.matches("2GIS'е", in: segments).map(\.text), ["2GIS'е"])
    }

    func testAddingInflectedAbbreviationStoresOnlyBase() {
        XCTAssertEqual(TranscriptTerms.adding("2ГИС'ом", to: "API"), "API\n2ГИС")
        XCTAssertEqual(TranscriptTerms.adding("2ГИС'е", to: "2ГИС"), "2ГИС")
        XCTAssertEqual(TranscriptTerms.adding("LLM'ками", to: ""), "LLM")
        XCTAssertEqual(TranscriptTerms.adding("Марины", to: ""), "Марины")
    }

    func testCandidatesPreferMarkedTermsAndIgnoreKnownWordsAndLiterals() {
        let segments = [
            segment("Сегодня обсудили API, Геопэй и 7АБВ. Потом повторили Геопэй."),
            segment("Обычное слово, обычное слово. API и 7АБВ. `FAKE` и https://example.com/NOPE")
        ]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "api")
        XCTAssertEqual(Set(candidates.map(\.text)), ["Геопэй", "7АБВ"])
        XCTAssertEqual(candidates.first { $0.text == "7АБВ" }?.occurrences.count, 2)
    }

    func testCandidatesSkipNamesOfPeopleAndPlacesInRussian() {
        let segments = [
            segment("Про это говорили Дима, Макс, Анфиса, Кирилл и Алексей. По России, из Армении и Москвы."),
            segment("Мы звонили Диме, Максу, Анфисе, Кириллу и Алексею из Новосибирска и Армении."),
            segment("Команда показала ДФА, MapKit, Геопэй и Яндекс. Встретились в США и Санкт-Петербурге.")
        ]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["ДФА", "MapKit", "Геопэй", "Яндекс"])
        XCTAssertEqual(TranscriptTerms.matches("Дима", in: segments).map(\.text), ["Дима"])
        XCTAssertEqual(TranscriptTerms.matches("Москвы", in: segments).map(\.text), ["Москвы"])
    }

    func testCandidatesSkipTheNamedSpeakersEvenWithoutNameContext() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, speaker: "Спикер 1", text: "Отдельно обсудили Куделька, куделька и ДФА."),
            TranscriptSegment(start: 2, end: 4, speaker: "Анфиса Куделька", text: "Продолжим завтра.")
        ]
        XCTAssertEqual(TranscriptTerms.candidates(in: segments, vocabulary: "").map(\.text), ["ДФА"])
        XCTAssertEqual(TranscriptTerms.matches("Куделька", in: segments).count, 2)
        XCTAssertEqual(TranscriptTerms.adding("Куделька", to: ""), "Куделька")
    }

    func testCandidatesSkipMultiwordNamesInEnglish() {
        let segments = [segment("The team met Alice Smith in London and flew to New York with Bob. Later we tested PostgreSQL and the API.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["PostgreSQL", "API"])
    }

    func testFullFormSearchRemainsLiteralWhileBaseSearchFindsFamily() throws {
        let segments = [segment("LLM, LLM'ки и LLM’ки, а также API.")]
        let base = TranscriptTerms.matches("LLM", in: segments)
        XCTAssertEqual(base.map(\.text), ["LLM", "LLM'ки", "LLM’ки"])
        XCTAssertTrue(TranscriptTerms.matches("ки", in: segments).isEmpty)
        let full = TranscriptTerms.matches("LLM'ки", in: segments)
        XCTAssertEqual(full.map(\.text), ["LLM'ки", "LLM’ки"])
        let edited = try XCTUnwrap(TranscriptTerms.replacing(full, with: "ИИ", in: segments))
        XCTAssertEqual(edited[0].text, "LLM, ИИ и ИИ, а также API.")
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "Внутренний API")
        XCTAssertTrue(candidates.contains { $0.text == "API" })
        XCTAssertEqual(candidates.first { $0.text == "LLM" }?.occurrences.count, 3)
        XCTAssertFalse(candidates.contains { $0.text == "LLM'ки" })
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
