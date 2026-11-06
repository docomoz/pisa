import Foundation

/// Evidence from the saved meeting and its current audio inventory, for MCP readers.
public enum TranscriptEvidence {
    public static func meeting(_ meeting: Meeting, library: MeetingLibrary) -> [String: Any] {
        let unidentifiedCount = meeting.segments.count { speakerIdentification($0.speaker) == "unidentified" }
        let audio = meetingAudio(meeting, library: library)
        var evidence = base(meeting, audio: audio, hasText: meeting.segments.contains { hasText($0.text) },
                            hasUnidentifiedSpeaker: unidentifiedCount > 0)
        evidence["segment_count"] = meeting.segments.count
        evidence["unidentified_speaker_segment_count"] = unidentifiedCount
        return evidence
    }

    public static func segment(_ segment: TranscriptSegment, meeting: Meeting, library: MeetingLibrary) -> [String: Any] {
        let identification = speakerIdentification(segment.speaker)
        let audio = segmentAudio(segment, meeting: meeting, library: library)
        var evidence = base(meeting, audio: audio, hasText: hasText(segment.text),
                            hasUnidentifiedSpeaker: identification == "unidentified")
        evidence["speaker_identification"] = identification
        return evidence
    }

    private enum AudioAvailability: String {
        case available, missing, partial, none

        var warning: String? {
            switch self {
            case .available: return nil
            case .missing: return "audio_missing"
            case .partial: return "audio_partially_available"
            case .none: return "no_audio_references"
            }
        }
    }

    private static func base(_ meeting: Meeting, audio: AudioAvailability, hasText: Bool,
                             hasUnidentifiedSpeaker: Bool) -> [String: Any] {
        let checkpoint = meeting.liveCommittedUntil.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let state: String
        switch meeting.status {
        case .recorded: state = "pending"
        case .processing: state = meeting.liveCommittedUntil == nil ? "processing" : "draft"
        case .ready: state = meeting.liveCommittedUntil == nil ? "final" : "draft"
        case .failed: state = (checkpoint ?? 0) > 0 ? "partial" : "failed"
        }

        var warnings = ["recording_coverage_not_measured"]
        if meeting.status == .failed { warnings.append("processing_failed") }
        if meeting.liveCommittedUntil != nil && checkpoint == nil { warnings.append("invalid_live_checkpoint") }
        if !hasText { warnings.append("no_transcript_text") }
        if hasUnidentifiedSpeaker { warnings.append("unidentified_speaker") }
        if let warning = audio.warning { warnings.append(warning) }

        var evidence: [String: Any] = [
            "processing_status": meeting.status.rawValue,
            "transcript_state": state,
            // A finished pipeline can still have missed speech or produced no text.
            "transcript_complete": state == "final",
            "recording_coverage": "unknown",
            "recognition_confidence": "not_measured",
            "human_verification": "unknown",
            "audio_availability": audio.rawValue,
            "audio_playability": "not_checked",
            "warnings": warnings
        ]
        if let checkpoint { evidence["live_committed_until_seconds"] = checkpoint }
        return evidence
    }

    private static func hasText(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    private static func speakerIdentification(_ speaker: String) -> String {
        let words = speaker.split(whereSeparator: \.isWhitespace)
        if words.isEmpty || words == ["Собеседники"] { return "unidentified" }
        if words == ["Я"] { return "self" }
        if words.count == 2, words[0] == "Спикер", let number = Int(words[1]), number > 0 { return "unidentified" }
        return "named"
    }

    private static func meetingAudio(_ meeting: Meeting, library: MeetingLibrary) -> AudioAvailability {
        let names = Set(meeting.audioFiles)
        guard !names.isEmpty else { return .none }
        let available = names.count { audioFileAvailable($0, library: library) }
        if available == 0 { return .missing }
        return available == names.count ? .available : .partial
    }

    private static func segmentAudio(_ segment: TranscriptSegment, meeting: Meeting, library: MeetingLibrary) -> AudioAvailability {
        // Removing audio clears the inventory and can leave old segment references behind.
        guard let first = meeting.audioFiles.first else { return .none }
        let trackSuffix = segment.speaker == "Я" ? "-mic." : "-remote."
        let name = segment.audioFile ?? meeting.audioFiles.first { $0.contains(trackSuffix) } ?? first
        guard meeting.audioFiles.contains(name) else { return .missing }
        return audioFileAvailable(name, library: library) ? .available : .missing
    }

    // Inventory checks do not open recordings or assess playback and time range coverage.
    private static func audioFileAvailable(_ name: String, library: MeetingLibrary) -> Bool {
        guard let url = try? library.audioURL(name),
              let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey, .fileSizeKey]) else { return false }
        return attributes.isRegularFile == true && attributes.isSymbolicLink == false
            && attributes.isReadable == true && (attributes.fileSize ?? 0) > 0
    }
}
