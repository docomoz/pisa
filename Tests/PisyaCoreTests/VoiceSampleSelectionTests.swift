import XCTest
@testable import PisyaCore

final class VoiceSampleSelectionTests: XCTestCase {
    func testSelectsOnlyTwoLongestFragmentsForTheRequestedSpeakerInTimeOrder() {
        let first = TranscriptSegment(start: 0, end: 5, speaker: "Анна", text: "Первая реплика")
        let longest = TranscriptSegment(start: 30, end: 42, speaker: "Анна", text: "Длинная реплика")
        let secondLongest = TranscriptSegment(start: 10, end: 18, speaker: "Анна", text: "Другая длинная реплика")
        let otherSpeaker = TranscriptSegment(start: 50, end: 90, speaker: "Борис", text: "Другой голос")

        let selected = voiceSamples(for: "Анна", in: [first, longest, otherSpeaker, secondLongest])

        XCTAssertEqual(selected.map(\.id), [secondLongest.id, longest.id])
        XCTAssertEqual(selected, [secondLongest, longest])
    }

    func testDoesNotFillTheSecondSlotWithAShortInterjection() {
        let short = TranscriptSegment(start: 0, end: 1.9, speaker: "Анна", text: "Да")
        let usable = TranscriptSegment(start: 10, end: 12, speaker: "Анна", text: "Достаточно длинный образец")

        XCTAssertEqual(voiceSamples(for: "Анна", in: [short, usable]).map(\.id), [usable.id])
    }

    func testKeepsOneLongestFallbackWhenTheSpeakerHasOnlyShortFragments() {
        let brief = TranscriptSegment(start: 0, end: 0.4, speaker: "Анна", text: "Да")
        let longest = TranscriptSegment(start: 5, end: 6.5, speaker: "Анна", text: "Согласна")

        XCTAssertEqual(voiceSamples(for: "Анна", in: [brief, longest]).map(\.id), [longest.id])
    }

    func testEqualLengthFragmentsPreferEarlierSpeechAndKeepStableInputOrder() {
        let late = TranscriptSegment(start: 30, end: 35, speaker: "Анна", text: "Поздно")
        let early = TranscriptSegment(start: 0, end: 5, speaker: "Анна", text: "Рано")
        let sameTime = TranscriptSegment(start: 0, end: 5, speaker: "Анна", text: "То же время")

        XCTAssertEqual(voiceSamples(for: "Анна", in: [late, early, sameTime]).map(\.id), [early.id, sameTime.id])
    }

    func testIgnoresInvalidTimeRangesAndHandlesMissingSpeaker() {
        let invalid = [
            TranscriptSegment(start: 1, end: 1, speaker: "Анна", text: "Пустой диапазон"),
            TranscriptSegment(start: 3, end: 2, speaker: "Анна", text: "Обратный диапазон"),
            TranscriptSegment(start: -1, end: 10, speaker: "Анна", text: "До начала записи"),
            TranscriptSegment(start: 0, end: .infinity, speaker: "Анна", text: "Некорректное время"),
            TranscriptSegment(start: .nan, end: 10, speaker: "Анна", text: "Некорректное начало")
        ]

        XCTAssertTrue(voiceSamples(for: "Анна", in: invalid).isEmpty)
        XCTAssertTrue(voiceSamples(for: "Борис", in: invalid).isEmpty)
    }
}
