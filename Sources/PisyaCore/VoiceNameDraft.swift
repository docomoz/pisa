import Foundation

func voiceNameForSelection(currentID: UUID?, currentName: String, segment: TranscriptSegment) -> String {
    currentID == segment.id ? currentName : segment.speaker
}
