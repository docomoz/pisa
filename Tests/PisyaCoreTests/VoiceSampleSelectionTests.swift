import XCTest
@testable import PisyaCore

final class VoiceSampleSelectionTests: XCTestCase {
    func testRenamingAllRepliesKeepsTheVoiceGroupInPlace() {
        let first = TranscriptSegment(start: 0, end: 3, speaker: "Борис", text: "Первая реплика")
        var second = TranscriptSegment(start: 5, end: 8, speaker: "Голос 2", text: "Ответ")
        var later = TranscriptSegment(start: 10, end: 16, speaker: "Голос 2", text: "Продолжение ответа")
        let expectedIDs = [first.id, second.id]
        XCTAssertEqual(voiceGroupAnchors(in: [first, second, later]).map(\.id), expectedIDs)

        second.speaker = "Анна"
        later.speaker = "Анна"
        let renamed = voiceGroupAnchors(in: [first, second, later])
        XCTAssertEqual(renamed.map(\.id), expectedIDs)
        XCTAssertEqual(renamed.map(\.speaker), ["Борис", "Анна"])
    }

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

final class AutomaticVoiceSampleTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, speaker: String = "Анна", embedding: [Float]? = [1, 0]) -> TranscriptSegment {
        var segment = TranscriptSegment(start: start, end: end, speaker: speaker, text: "Содержательная реплика участника")
        segment.embedding = embedding
        return segment
    }
    private func meeting(_ segments: [TranscriptSegment]) -> Meeting {
        var meeting = Meeting(title: "Встреча", source: "Аудиофайл")
        meeting.audioFiles = ["speech.caf"]; meeting.segments = segments
        return meeting
    }
    func testSelectsLongSpeechEvenWhenClickedReplyIsShortAndHasNoEmbedding() throws {
        let clicked = segment(0, 1, embedding: nil), good = segment(10, 22)
        let result = try XCTUnwrap(automaticVoiceSample(for: clicked.id, in: meeting([clicked, good]), allMatching: true))
        XCTAssertEqual(result.id, good.id)
        XCTAssertEqual(result.start, 12); XCTAssertEqual(result.end, 20)
        XCTAssertEqual(result.audioFile, "speech.caf")
        XCTAssertEqual(result.embedding, [1, 0])
    }
    func testSingleReplyCorrectionNeverLearnsFromOtherReplies() {
        let clicked = segment(0, 1), good = segment(10, 22)
        XCTAssertNil(automaticVoiceSample(for: clicked.id, in: meeting([clicked, good]), allMatching: false))
    }
    func testCutsAwayOtherSpeakersAndUsesLongestRemainingInterval() throws {
        let clicked = segment(0, 14), other = segment(3, 7, speaker: "Борис")
        let result = try XCTUnwrap(automaticVoiceSample(for: clicked.id, in: meeting([clicked, other]), allMatching: true))
        XCTAssertEqual(result.start, 7.15, accuracy: 0.001); XCTAssertEqual(result.end, 14)
    }
    func testOverlappingAndNestedInterruptionsLeaveNoUsableSample() {
        let clicked = segment(0, 10)
        let others = [segment(1, 5, speaker: "Борис"), segment(2, 3, speaker: "Вера"), segment(4, 9, speaker: "Глеб")]
        XCTAssertNil(automaticVoiceSample(for: clicked.id, in: meeting([clicked] + others), allMatching: true))
    }
    func testPrefersFullEightSecondsOverShortCleanSpeechAndNeverTakesAnotherSpeaker() throws {
        let short = segment(0, 3), good = segment(20, 28), other = segment(40, 60, speaker: "Борис")
        let result = try XCTUnwrap(automaticVoiceSample(for: short.id, in: meeting([short, other, good]), allMatching: true))
        XCTAssertEqual(result.id, good.id); XCTAssertEqual(result.start, 20); XCTAssertEqual(result.end, 28)
    }
    func testHonorsTrackOffsetAndRejectsUnavailableAudio() throws {
        let clicked = segment(0, 12)
        var value = meeting([clicked]); value.audioOffsets = ["speech.caf": 9]
        let result = try XCTUnwrap(automaticVoiceSample(for: clicked.id, in: value, allMatching: true))
        XCTAssertEqual(result.start, 9); XCTAssertEqual(result.end, 12)
        value.audioOffsets = ["speech.caf": 11]
        XCTAssertNil(automaticVoiceSample(for: clicked.id, in: value, allMatching: true))
        value.audioFiles = []
        XCTAssertNil(automaticVoiceSample(for: clicked.id, in: value, allMatching: true))
    }
    func testRejectsMissingInvalidAndEmptySamples() {
        var empty = segment(0, 8); empty.text = " \n "
        var missingTrack = segment(10, 18); missingTrack.audioFile = "deleted.caf"
        let invalid = [empty, missingTrack, segment(-1, 10), segment(.nan, 8), segment(0, .infinity),
                       segment(0, 8, embedding: nil), segment(0, 8, embedding: []),
                       segment(0, 8, embedding: [.nan]), segment(0, 8, embedding: [0, 0])]
        for clicked in invalid {
            XCTAssertNil(automaticVoiceSample(for: clicked.id, in: meeting([clicked]), allMatching: true))
        }
        XCTAssertNil(automaticVoiceSample(for: UUID(), in: meeting([]), allMatching: true))
    }
    func testUsesRealFileBoundsAndSkipsMissingFiles() throws {
        let clicked = segment(10, 40), fallback = segment(0, 3)
        var value = meeting([clicked, fallback]); value.audioOffsets = ["speech.caf": 0]
        let result = try XCTUnwrap(automaticVoiceSample(for: clicked.id, in: value, allMatching: true, audioDurations: ["speech.caf": 11]))
        XCTAssertEqual(result.id, fallback.id)
        XCTAssertEqual(result.start, 0); XCTAssertEqual(result.end, 3)
        XCTAssertNil(automaticVoiceSample(for: clicked.id, in: value, allMatching: true, audioDurations: [:]))
        XCTAssertNil(automaticVoiceSample(for: clicked.id, in: value, allMatching: true, audioDurations: ["speech.caf": .nan]))
    }
    func testKeepsExactlyTwoSecondsAndBreaksTiesByTime() throws {
        let later = segment(10, 12), earlier = segment(0, 2)
        let result = try XCTUnwrap(automaticVoiceSample(for: later.id, in: meeting([later, earlier]), allMatching: true))
        XCTAssertEqual(result.id, earlier.id); XCTAssertEqual(result.start, 0); XCTAssertEqual(result.end, 2)
    }
}
