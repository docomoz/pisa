import Foundation

/// Language-neutral vocal acknowledgments need nearby conversation context.
/// The Russian alternative must come from audio, never from translating text.
enum BackchannelLanguage {
    private static let englishVocalizations: Set<String> = ["ah", "uh", "huh", "uhhuh", "hmm", "mm", "mhm", "um"]
    private static let englishAffirmatives: Set<String> = ["yeah", "yep", "yes"]
    private static let englishOpenVowels: Set<String> = ["ah", "uh", "um"]
    private static let russianVocalizations: Set<String> = ["угу", "ага", "мгм", "хм", "мм", "м", "эм"]
    private static let russianOpenVowels: Set<String> = ["а", "аа"]

    static func shouldRecheck(_ text: String, duration: Double) -> Bool {
        guard duration <= 3 else { return false }
        let words = RussianRecognition.words(text)
        if isAmbiguous(words) { return true }
        return (1...3).contains(words.count) && words.joined().unicodeScalars.allSatisfy {
            (0x61...0x7A).contains($0.value)
        }
    }

    private static func isAmbiguous(_ words: [String]) -> Bool {
        words.contains(where: englishVocalizations.contains) && words.allSatisfy {
            englishVocalizations.contains($0) || englishAffirmatives.contains($0)
        }
    }

    static func acceptsAlternative(_ text: String, allowingAffirmative: Bool = false, allowingOpenVowels: Bool = false) -> Bool {
        let words = RussianRecognition.words(text)
        guard (1...3).contains(words.count) else { return false }
        if allowingOpenVowels, words.allSatisfy(russianOpenVowels.contains) { return true }
        return words.contains(where: russianVocalizations.contains) && words.allSatisfy {
            russianVocalizations.contains($0) || (allowingAffirmative && $0 == "да")
        }
    }

    /// A forced language decode may translate real English. For lexical replies,
    /// require the independent acoustic recognizer to hear the same Russian words.
    /// A vocal acknowledgment may include a brief affirmative in either decode.
    static func alternative(original: String, russian: String, corroboration: String?, vocabulary: String = "") -> String? {
        let originalWords = RussianRecognition.words(original)
        if isAmbiguous(originalWords) {
            let hasAffirmative = originalWords.contains(where: englishAffirmatives.contains)
            let allowsOpenVowels = originalWords.allSatisfy(englishOpenVowels.contains)
            let candidate = [russian, corroboration].compactMap { $0 }.first {
                acceptsAlternative($0, allowingAffirmative: hasAffirmative, allowingOpenVowels: allowsOpenVowels)
            }
            if let candidate {
                return RussianRecognition.preservesVocabulary(candidate: candidate, original: original, vocabulary: vocabulary) ? candidate : nil
            }
            if !hasAffirmative { return nil }
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
        let anchors = (preceding + segments).filter {
            let words = RussianRecognition.words($0.text)
            return words.count >= 4 && !isAmbiguous(words) && language($0.text) != nil
        }
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
