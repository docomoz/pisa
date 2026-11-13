import Foundation
import XCTest
@testable import PisaCore

final class TranscriptEvidenceTests: XCTestCase {
    func testSavedStatusAndCheckpointDetermineTranscriptState() throws {
        try withLibrary { library in
            let cases: [(MeetingStatus, Double?, String)] = [
                (.recorded, nil, "pending"),
                (.processing, nil, "processing"),
                (.processing, 0, "draft"),
                (.processing, 24, "draft"),
                (.failed, 24, "partial"),
                (.failed, 0, "failed"),
                (.failed, nil, "failed"),
                (.ready, 24, "draft"),
                (.ready, nil, "final")
            ]
            for (status, checkpoint, expected) in cases {
                var meeting = Meeting(title: "Meeting", source: "Test")
                meeting.status = status
                meeting.liveCommittedUntil = checkpoint
                meeting.segments = [.init(start: 1, end: 5, speaker: "Я", text: "Текст")]
                let evidence = TranscriptEvidence.meeting(meeting, library: library)
                XCTAssertEqual(evidence["processing_status"] as? String, status.rawValue)
                XCTAssertEqual(evidence["transcript_state"] as? String, expected)
                XCTAssertEqual(evidence["transcript_complete"] as? Bool, expected == "final")
                XCTAssertEqual(evidence["live_committed_until_seconds"] as? Double, checkpoint)
            }
        }
    }

    func testEmptyLegacyReadyMeetingDoesNotClaimAudioCoverageOrVerification() throws {
        try withLibrary { library in
            let data = Data("""
                {"id":"FE364AE6-DA02-48EC-B64E-CA08CDD8AC8D","title":"Legacy","date":0,
                "source":"Test","duration":200,"status":"ready","segments":[],"audioFiles":[],
                "audioOffsets":{},"notes":""}
                """.utf8)
            let meeting = try JSONDecoder().decode(Meeting.self, from: data)
            let evidence = TranscriptEvidence.meeting(meeting, library: library)
            XCTAssertEqual(evidence["transcript_state"] as? String, "final")
            XCTAssertEqual(evidence["transcript_complete"] as? Bool, true)
            XCTAssertEqual(evidence["recording_coverage"] as? String, "unknown")
            XCTAssertEqual(evidence["recognition_confidence"] as? String, "not_measured")
            XCTAssertEqual(evidence["human_verification"] as? String, "unknown")
            XCTAssertEqual(evidence["audio_playability"] as? String, "not_checked")
            XCTAssertEqual(evidence["segment_count"] as? Int, 0)
            XCTAssertTrue((evidence["warnings"] as? [String])?.contains("no_transcript_text") == true)
        }
    }

    func testMeetingDistinguishesUnlistedMissingAndPartiallyAvailableAudio() throws {
        try withLibrary { library in
            var meeting = Meeting(title: "Meeting", source: "Test")
            let file = try library.audioURL("track.caf")
            XCTAssertEqual(TranscriptEvidence.meeting(meeting, library: library)["audio_availability"] as? String, "none")

            meeting.audioFiles = ["track.caf", "missing.caf"]
            XCTAssertEqual(TranscriptEvidence.meeting(meeting, library: library)["audio_availability"] as? String, "missing")
            try Data([1]).write(to: file)
            XCTAssertEqual(TranscriptEvidence.meeting(meeting, library: library)["audio_availability"] as? String, "partial")

            meeting.audioFiles = ["track.caf", "track.caf"]
            XCTAssertEqual(TranscriptEvidence.meeting(meeting, library: library)["audio_availability"] as? String, "available")
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(TranscriptEvidence.meeting(meeting, library: library)["audio_availability"] as? String, "missing")
        }
    }

    func testSegmentAudioRespectsTrackBindingAndClearedInventory() throws {
        try withLibrary { library in
            var meeting = Meeting(title: "Meeting", source: "Test")
            meeting.audioFiles = ["sample-mic.caf", "sample-remote.caf"]
            try Data([1]).write(to: library.audioURL("sample-mic.caf"))
            var segment = TranscriptSegment(start: 1, end: 5, speaker: "Я", text: "Текст")
            let evidence = TranscriptEvidence.segment(segment, meeting: meeting, library: library)
            XCTAssertEqual(evidence["audio_availability"] as? String, "available")
            XCTAssertEqual(evidence["audio_playability"] as? String, "not_checked")

            segment.audioFile = "sample-remote.caf"
            XCTAssertEqual(TranscriptEvidence.segment(segment, meeting: meeting, library: library)["audio_availability"] as? String, "missing")
            meeting.audioFiles = []
            XCTAssertEqual(TranscriptEvidence.segment(segment, meeting: meeting, library: library)["audio_availability"] as? String, "none")
        }
    }

    func testInvalidOrUnownedAudioReferencesDoNotExposePaths() throws {
        try withLibrary { library in
            let otherFile = library.root.appendingPathComponent("outside.caf")
            try Data([1]).write(to: otherFile)
            try FileManager.default.createSymbolicLink(at: library.audioURL("link.caf"), withDestinationURL: otherFile)
            try Data([1]).write(to: library.audioURL("other-meeting.caf"))
            var meeting = Meeting(title: "Meeting", source: "Test")
            meeting.audioFiles = ["../outside.caf", "link.caf"]
            var segment = TranscriptSegment(start: 1, end: 5, speaker: "Спикер 1", text: "Текст")
            segment.embedding = [0.34]
            XCTAssertEqual(TranscriptEvidence.meeting(meeting, library: library)["audio_availability"] as? String, "missing")
            for file in ["../outside.caf", "link.caf", "other-meeting.caf"] {
                segment.audioFile = file
                let evidence = TranscriptEvidence.segment(segment, meeting: meeting, library: library)
                XCTAssertEqual(evidence["audio_availability"] as? String, "missing")
                let serialized = String(decoding: try JSONSerialization.data(withJSONObject: evidence), as: UTF8.self)
                XCTAssertFalse(serialized.contains(".caf"))
                XCTAssertFalse(serialized.contains("0.34"))
            }
        }
    }

    func testGeneratedLabelsAreUnidentifiedAndMicrophoneLabelIsSelf() throws {
        try withLibrary { library in
            var meeting = Meeting(title: "Meeting", source: "Test")
            let cases = [("", "unidentified"), ("Собеседники", "unidentified"),
                         ("Спикер 12", "unidentified"), ("Я", "self"), ("Анна", "named"), ("Спикер Иван", "named")]
            for (name, expected) in cases {
                let segment = TranscriptSegment(start: 1, end: 5, speaker: name, text: "Текст")
                meeting.segments.append(segment)
                let evidence = TranscriptEvidence.segment(segment, meeting: meeting, library: library)
                XCTAssertEqual(evidence["speaker_identification"] as? String, expected)
            }
            let evidence = TranscriptEvidence.meeting(meeting, library: library)
            XCTAssertEqual(evidence["unidentified_speaker_segment_count"] as? Int, 3)
            XCTAssertTrue((evidence["warnings"] as? [String])?.contains("unidentified_speaker") == true)
        }
    }

    private func withLibrary(_ body: (MeetingLibrary) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(MeetingLibrary(root: root))
    }
}
