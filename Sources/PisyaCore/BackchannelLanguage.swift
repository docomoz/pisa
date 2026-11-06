import Foundation

/// Language-neutral vocal acknowledgments need nearby conversation context.
/// The Russian alternative must come from audio, never from translating text.
enum BackchannelLanguage {
    static func shouldRecheck(_ text: String, duration: Double) -> Bool {
        let words = RussianRecognition.words(text)
        return duration <= 3 && (1...3).contains(words.count) && words.joined().unicodeScalars.allSatisfy {
            (0x61...0x7A).contains($0.value)
        }
    }

    static func isAmbiguous(_ text: String, duration: Double) -> Bool {
        guard duration <= 3 else { return false }
        return ["uh huh", "hmm", "mm hmm", "mhm", "um", "uh", "huh", "mm"]
            .contains(RussianRecognition.words(text).joined(separator: " "))
    }

    static func acceptsAlternative(_ text: String) -> Bool {
        let words = RussianRecognition.words(text)
        let acknowledgments: Set<String> = ["угу", "ага", "мгм", "хм", "мм", "м", "эм"]
        return (1...3).contains(words.count) && words.allSatisfy(acknowledgments.contains)
    }

    /// A forced language decode may translate real English. For lexical replies,
    /// require the independent acoustic recognizer to hear the same Russian word.
    /// Vocal acknowledgments have no lexical language: nearby speech decides.
    static func alternative(original: String, russian: String, corroboration: String?, vocabulary: String = "") -> String? {
        if isAmbiguous(original, duration: 0) {
            let candidate = acceptsAlternative(russian) ? russian : corroboration.flatMap { acceptsAlternative($0) ? $0 : nil }
            return candidate.flatMap { RussianRecognition.preservesVocabulary(candidate: $0, original: original, vocabulary: vocabulary) ? $0 : nil }
        }
        let words = RussianRecognition.words(russian)
        guard (1...3).contains(words.count), words.joined().unicodeScalars.allSatisfy({ (0x0400...0x052F).contains($0.value) }),
              let corroboration,
              RussianRecognition.preservesVocabulary(candidate: russian, original: original, vocabulary: vocabulary) else { return nil }
        let particles: Set<String> = ["я", "ну", "а", "и"]
        let substantive = words.filter { !particles.contains($0) }
        let independent = RussianRecognition.words(corroboration).filter { !particles.contains($0) }
        return !substantive.isEmpty && substantive == independent ? russian : nil
    }

    static func resolve(_ segments: [TranscriptSegment], alternatives: [UUID: String], preceding: [TranscriptSegment]) -> [TranscriptSegment] {
        let anchors = (preceding + segments).filter { RussianRecognition.words($0.text).count >= 4 && language($0.text) != nil }
        return segments.map { segment in
            guard shouldRecheck(segment.text, duration: segment.end - segment.start),
                  let alternative = alternatives[segment.id] else { return segment }
            func gap(_ anchor: TranscriptSegment) -> Double { max(0, max(anchor.start - segment.end, segment.start - anchor.end)) }
            let nearby = anchors.filter { gap($0) <= 60 }
            let sameTrack = nearby.filter { track($0) == track(segment) }
            guard let closest = (sameTrack.isEmpty ? nearby : sameTrack).min(by: { gap($0) < gap($1) }),
                  language(closest.text) == "Russian" else { return segment }
            var revised = segment; revised.text = alternative; return revised
        }
    }

    private static func track(_ segment: TranscriptSegment) -> String {
        if segment.audioFile?.contains("-mic.") == true { return "mic" }
        if segment.audioFile?.contains("-remote.") == true { return "remote" }
        return segment.speaker
    }

    private static func language(_ text: String) -> String? {
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x052F).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }.count
        if cyrillic > 0, cyrillic >= latin * 2 { return "Russian" }
        if latin > 0, latin >= cyrillic * 2 { return "English" }
        return nil
    }
}
