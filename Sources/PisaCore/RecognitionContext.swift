import Foundation

/// A first-pass snapshot. Re-decoded segments never become evidence for their neighbors.
struct RecognitionContext {
    struct Neighbors {
        var preceding: [String]
        var following: [String]
    }

    struct Retry {
        let hints: String
        let context: String
        fileprivate let terms: [String]
        fileprivate let established: Set<String>
        fileprivate let phoneticTerms: Set<String>
        fileprivate let neighbors: Neighbors
        fileprivate let endingSites: [String: String]
        fileprivate let competingEndings: Set<String>
        fileprivate let sharedNameTerms: Set<String>
        fileprivate let explicitNumericTerms: Set<String>

        /// Small source intervals for an optional acoustic recheck. These
        /// ranges point into `original` and never authorize a text change.
        func targetSpans(in original: String, corroboration: String?) -> [Range<String.Index>] {
            RecognitionContext.targetSpans(in: original, corroboration: corroboration, retry: self)
        }

        func canDisambiguateInitialismEnding(in original: String) -> Bool {
            RecognitionContext.initialismEndingSite(in: original, retry: self) != nil
        }

        func canProbePhoneticBoundary(in original: String, corroboration: String) -> Bool {
            terms.contains { term in
                phoneticTerms.contains(term) && RecognitionContext.isLatinInitialism(term)
                    && !RecognitionContext.phoneticBoundarySites(in: original, corroboration: corroboration, term: term).isEmpty
            }
        }

        func hasEstablishedAcousticTerm(in text: String) -> Bool {
            terms.contains { established.contains($0) && RecognitionVocabulary.contains($0, in: text) }
        }

        func isNeighborEcho(_ text: String) -> Bool {
            let decoded = RussianRecognition.words(text)
            let nearby = (neighbors.preceding + neighbors.following).map(RussianRecognition.words)
            for words in nearby {
                let width = min(7, min(words.count, decoded.count))
                guard width >= 5 else { continue }
                for start in 0...(words.count - width) {
                    let excerpt = words[start..<(start + width)]
                    if decoded.starts(with: excerpt) || decoded.suffix(width).elementsEqual(excerpt) { return true }
                }
            }
            return false
        }
    }

    private final class Turn {
        let segment: TranscriptSegment
        lazy var plainText = RecognitionContext.withoutLiterals(segment.text)
        lazy var wordPairs = RecognitionContext.wordPairs(in: segment.text)
        lazy var exactMentions = RecognitionContext.tokens(plainText).map(\.text)
        lazy var head = RecognitionContext.excerpt(segment.text, plainText: plainText, useTail: false)
        lazy var tail = RecognitionContext.excerpt(segment.text, plainText: plainText, useTail: true)
        private var establishedTerms: [Data: Bool] = [:]

        init(_ segment: TranscriptSegment) { self.segment = segment }

        func establishes(_ term: String, key: Data) -> Bool {
            if let known = establishedTerms[key] { return known }
            let established = RecognitionContext.establishesTerm(term, in: plainText)
            establishedTerms[key] = established
            return established
        }
    }

    private let byStart: [Turn]
    private let byEnd: [Turn]

    init(segments: [TranscriptSegment], preceding: [TranscriptSegment] = []) {
        let current = Set(segments.map(\.id))
        let turns = segments.map(Turn.init)
        byStart = turns.sorted { $0.segment.start < $1.segment.start }
        byEnd = (turns + preceding.filter { !current.contains($0.id) }.map(Turn.init))
            .sorted { $0.segment.end < $1.segment.end }
    }

    private func partition(_ turns: [Turn], before: (TranscriptSegment) -> Bool) -> Int {
        var lower = 0
        var upper = turns.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if before(turns[middle].segment) { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func endingAtOrBefore(_ time: Double) -> ReversedCollection<ArraySlice<Turn>> {
        byEnd[..<partition(byEnd) { $0.end <= time }].reversed()
    }

    private func startingAtOrAfter(_ time: Double) -> ArraySlice<Turn> {
        byStart[partition(byStart) { $0.start < time }...]
    }

    struct OverlappingWord {
        static let padding = 0.08
        fileprivate let source: String
        fileprivate let background: String

        fileprivate static func folded(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        /// A multilingual reading can confirm a name or foreign word even if
        /// the decoder changes its accents or makes a small spelling error.
        func confirmsSource(_ text: String) -> Bool {
            let source = Self.folded(source)
            let words = RussianRecognition.words(Self.folded(text))
            return words.contains(source) || words.joined().difference(from: source).count <= 2
        }

        /// Only accept different endings of the same attested adjective.
        /// The bundled forms work offline without macOS language assets.
        private static func agreesOnWord(_ left: String, _ right: String) -> Bool {
            if left == right { return true }
            let stem = left.dropLast(2)
            guard stem.count >= 4, stem == right.dropLast(2) else { return false }
            let leftEnding = String(left.suffix(2)), rightEnding = String(right.suffix(2))
            let genderEndings = [["ий", "яя", "ее"], ["ый", "ая", "ое"], ["ой", "ая", "ое"]]
            return genderEndings.contains { endings in
                endings.contains(leftEnding) && endings.contains(rightEnding)
                    && endings.allSatisfy { TranscriptTerms.isCommonRussianWord(String(stem) + $0) }
            }
        }

        /// Treat other plausible case or number endings in the ongoing voice
        /// as a veto. A shared stem alone never authorizes replacing a word.
        private static func possibleBackgroundWord(_ left: String, _ right: String) -> Bool {
            let shared = zip(left, right).prefix { $0 == $1 }.count
            return shared >= 4 && max(left.count, right.count) - shared <= 4
        }

        /// The word has to be audible in isolation. The small margin may
        /// clarify an inflection or add one preposition from the ongoing turn.
        /// That extra word never enters the transcript.
        func acousticWord(core: String, padded: String) -> String? {
            let exact = RussianRecognition.words(core), wide = RussianRecognition.words(padded)
            guard exact.count == 1, let word = wide.last, word.count >= 5,
                  wide.count == 1 || (wide.count == 2 && AbbreviationFamilies.isRussianFunctionWord(wide[0])),
                  TranscriptTerms.isCommonRussianWord(exact[0]), TranscriptTerms.isCommonRussianWord(word),
                  Self.agreesOnWord(exact[0], word),
                  !RussianRecognition.words(background).contains(where: { Self.possibleBackgroundWord($0, word) }) else { return nil }
            return word
        }

        func confirmedText(word: String, core: String, padded: String) -> String? {
            guard RussianRecognition.words(core) == [word], RussianRecognition.words(padded) == [word] else { return nil }
            let text = padded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = text.first, first.isLetter,
                  text.allSatisfy({ $0.isLetter || ".!?…".contains($0) }) else { return nil }
            let result = first.uppercased() + text.dropFirst()
            return result.last?.isLetter == true ? result + "." : result
        }
    }

    func overlappingWord(for target: TranscriptSegment, vocabulary: String) -> OverlappingWord? {
        let duration = target.end - target.start
        guard target.speakerEvidenceIsMixed == true, (0.35...1.5).contains(duration),
              let track = target.audioFile, !track.contains("-mic."),
              target.text.range(of: #"^\p{Latin}[\p{Latin}\p{M}]{4,24}[.!?…]?$"#, options: .regularExpression) != nil else { return nil }
        let token = target.text.prefix(while: { $0.isLetter })
        guard token.contains(where: { !$0.isASCII }), !token.dropFirst().contains(where: \.isUppercase) else { return nil }
        let source = OverlappingWord.folded(String(token))
        func containsSource(_ text: String) -> Bool {
            text.range(of: source, options: [.diacriticInsensitive, .caseInsensitive]) != nil
                && RussianRecognition.words(OverlappingWord.folded(text)).contains(source)
        }
        guard !containsSource(vocabulary) else { return nil }
        let start = target.start - OverlappingWord.padding, end = target.end + OverlappingWord.padding
        let overlapping = byEnd[partition(byEnd) { $0.end <= start }...].map(\.segment).filter {
            $0.id != target.id && $0.audioFile == track && $0.start < end
        }
        guard overlapping.count == 1, let background = overlapping.first,
              isAutomaticSpeakerName(target.speaker) || target.speaker.caseInsensitiveCompare(background.speaker) != .orderedSame,
              background.start <= start, background.end >= end, BackchannelLanguage.isRussianContext(background.text),
              !byEnd.contains(where: { $0.segment.id != target.id && (containsSource($0.segment.text) || containsSource($0.segment.speaker)) }),
              !containsSource(target.speaker) else { return nil }
        return OverlappingWord(source: source, background: background.text)
    }

    /// For one short word, padding may change the language even when the
    /// isolated turn is empty or cut in the middle of a syllable.
    struct TimedReply {
        fileprivate let source: String
        fileprivate let hasLeft: Bool
        fileprivate let hasRight: Bool
        fileprivate let previouslyConfirmed: Bool

        func canUseIsolated(_ text: String) -> Bool {
            let words = RussianRecognition.words(text)
            return words.count == 1 || (words.isEmpty && ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(source))
        }

        struct Word {
            fileprivate let text: String
            fileprivate let key: String
            fileprivate let left: [String]
            fileprivate let right: [String]
            fileprivate let name: Bool
            fileprivate let needsBoth: Bool

            func isConfirmed(in reading: String) -> Bool {
                let words = RussianRecognition.words(reading)
                let positions = words.indices.filter { words[$0] == key }
                guard positions.count == 1, let i = positions.first else { return false }
                if name {
                    let tokens = RecognitionContext.tokens(reading)
                    guard tokens.indices.contains(i), tokens[i].key == key,
                          reading[tokens[i].range.upperBound...].first == "," else { return false }
                    let before = reading[..<tokens[i].range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard before.last.map({ ".!?…".contains($0) }) ?? true else { return false }
                }
                // A neighbor's inflection or an additional conjunction can
                // differ. Locate the same word between anchors on both sides.
                func anchored(_ expected: [String], _ nearby: ArraySlice<String>) -> Bool {
                    expected.contains { $0.count >= 3 && TranscriptTerms.isCommonRussianWord($0)
                        && !AbbreviationFamilies.isRussianFunctionWord($0) && nearby.contains($0) }
                }
                let before = words[..<i].suffix(4), after = words[(i + 1)...].prefix(4)
                if left.isEmpty { return after.starts(with: right.prefix(2)) && anchored(right, after) }
                if right.isEmpty { return before.suffix(2).elementsEqual(left.suffix(2)) && anchored(left, before) }
                return anchored(left, before) && anchored(right, after)
            }
        }

        func candidate(acoustic: RecognitionAcousticResult, interval: Range<Double>, isolated: String) -> Word? {
            let keys = RussianRecognition.words(acoustic.text)
            guard keys == acoustic.words.map({ $0.text.lowercased().replacingOccurrences(of: "ё", with: "е") }) else { return nil }
            let inside = acoustic.words.indices.filter {
                let word = acoustic.words[$0]
                return word.start >= interval.lowerBound - 0.12 && word.start < interval.upperBound - 0.02
                    && word.end > interval.lowerBound && word.end > word.start
            }
            guard inside.count == 1, let i = inside.first else { return nil }
            let key = keys[i]
            let name = TranscriptTerms.isKnownEntityForm(key)
            guard keys.filter({ $0 == key }).count == 1, TranscriptTerms.isCommonRussianWord(key) || name,
                  !RecognitionConsensus.isNumberWord(key) else { return nil }
            // Some initial syllables lie outside the diarized audio. A clipped
            // Russian reading can support a word's stem or ending, never a
            // competing complete dictionary word.
            let exact = RussianRecognition.words(isolated)
            let original = RussianRecognition.words(source)
            let spelling = original.last?.replacingOccurrences(of: "і", with: "и")
            let incomplete = exact.count == 1 && exact[0].count >= 3 && !TranscriptTerms.isCommonRussianWord(exact[0])
                && (key.hasPrefix(exact[0]) || key.hasSuffix(exact[0]) ||
                    (exact[0].count >= 4 && key.contains(String(exact[0].dropLast()))))
            guard exact == [key] || incomplete || (exact.isEmpty && spelling == key) else { return nil }
            let left = hasLeft ? Array(keys[..<i].suffix(4)) : [], right = hasRight ? Array(keys[(i + 1)...].prefix(4)) : []
            let oneSided = left.isEmpty || right.isEmpty
            guard !oneSided || (exact == [key] && max(left.count, right.count) >= 2) else { return nil }
            if original.count == 1, let latin = original.first, latin.count >= 3,
               latin.allSatisfy(\.isASCII),
               let roman = key.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) {
                // Retain an unknown brand transcribed phonetically. A known
                // personal name must instead be heard as a Russian address.
                let sameName = SpokenVocabulary.distance(roman, latin.replacingOccurrences(of: "x", with: "ks")) <= 1
                guard name == sameName else { return nil }
            } else if name { return nil }
            guard !name || (exact == [key] && !right.isEmpty) else { return nil }
            let recognized = acoustic.words[i].text
            let punctuation = source.last.flatMap { ".!?…".contains($0) ? String($0) : nil } ?? "."
            return Word(text: recognized.prefix(1).uppercased() + recognized.dropFirst() + punctuation,
                        key: key, left: left, right: right, name: name, needsBoth: oneSided || name || previouslyConfirmed)
        }

        func retainsSource(_ reading: String) -> Bool {
            let original = RussianRecognition.words(source)
            let words = RussianRecognition.words(reading)
            guard let foreign = original.last else { return false }
            return words.contains { $0.compare(foreign, options: .diacriticInsensitive) == .orderedSame }
        }

        func confirmedText(_ word: Word, verifier: String, language: String?, primary: () -> String) -> String? {
            guard language?.lowercased() == "russian", !retainsSource(verifier) else { return nil }
            let confirmed = word.isConfirmed(in: verifier)
            if word.needsBoth && !confirmed { return nil }
            if !word.needsBoth && confirmed { return word.text }
            let widePrimary = primary()
            return !retainsSource(widePrimary) && word.isConfirmed(in: widePrimary) ? word.text : nil
        }
    }

    func timedReply(for target: TranscriptSegment, vocabulary: String) -> TimedReply? {
        let duration = target.end - target.start
        guard (0.2...2).contains(duration), let track = target.audioFile else { return nil }
        let words = RussianRecognition.words(target.text)
        let latin = words.count == 1 && BackchannelLanguage.isLatinSpeech(target.text)
            && (BackchannelLanguage.shouldRecheckLexical(target.text, duration: duration, vocabulary: vocabulary)
                || BackchannelLanguage.shouldVerifyShortScript(target.text, duration: duration, vocabulary: vocabulary))
            && BackchannelLanguage.russianSpelling(ofFiller: target.text) == nil
            && !TechnologyVocabulary.isCanonical(String(target.text.prefix(while: \.isLetter)))
        guard latin || BackchannelLanguage.shortMixedFragment(target.text, duration: duration, vocabulary: vocabulary) else { return nil }
        let left = endingAtOrBefore(target.start).lazy.prefix(while: { $0.segment.end >= target.start - 3.5 })
            .first(where: { $0.segment.audioFile == track })
        let right = startingAtOrAfter(target.end).lazy.prefix(while: { $0.segment.start <= target.end + 3.5 })
            .first(where: { $0.segment.audioFile == track })
        func russian(_ turn: Turn?) -> Bool {
            guard let turn, turn.segment.independentRecognitionLanguage != false else { return false }
            let text = turn.plainText, words = RussianRecognition.words(text)
            return BackchannelLanguage.isRussianContext(text) || ((2...3).contains(words.count)
                && words.allSatisfy(TranscriptTerms.isCommonRussianWord) && words.contains(where: { $0.count >= 4 }))
        }
        let hasLeft = russian(left), hasRight = russian(right)
        func absent(_ turn: Turn?) -> Bool { turn == nil || turn?.segment.text == "Неразборчиво" }
        guard hasLeft || hasRight, hasLeft || absent(left), hasRight || absent(right),
              !byEnd[partition(byEnd) { $0.end <= target.start }...].contains(where: {
                  $0.segment.id != target.id && $0.segment.audioFile == track && $0.segment.start < target.end
              }) else { return nil }
        return TimedReply(source: target.text, hasLeft: hasLeft, hasRight: hasRight,
                          previouslyConfirmed: target.independentRecognitionLanguage == true)
    }

    struct GlossaryClause {
        let unprotectedWords: Set<String>
        let glossaryWords: Set<String>

        func revisedText(isolated: String, language: String?, acoustic: RecognitionAcousticResult,
                         interval: Range<Double>, widePrimary: String) -> String? {
            guard language?.lowercased() == "russian", ParakeetRecognitionPolicy.hasRussianTextEvidence(isolated),
                  ParakeetRecognitionPolicy.hasRussianTextEvidence(widePrimary),
                  [isolated, acoustic.text, widePrimary].allSatisfy({
                      unprotectedWords.isDisjoint(with: RussianRecognition.words($0))
                  }) else { return nil }
            // The Russian acoustic model must have actually heard words in
            // this turn. Nearby Russian speakers alone cannot disprove a quote.
            let heard = acoustic.words.filter {
                interval.lowerBound - 0.1 <= $0.start && $0.start < interval.upperBound && $0.end > interval.lowerBound
            }.map(\.text)
            guard !heard.isEmpty, heard.allSatisfy(ParakeetRecognitionPolicy.hasRussianTextEvidence) else { return nil }
            let localized = heard.joined(separator: " ")
            if let agreed = BackchannelLanguage.agreedRussianText(isolated, corroboration: localized) { return agreed }
            let acousticKeys = RussianRecognition.words(localized)
            let core = RussianRecognition.words(isolated), wide = RussianRecognition.words(widePrimary)
            // A Russian-only model can spell a spoken product name in
            // Cyrillic. Require the full mixed sentence in the other two
            // models, and a local phonetic match at each glossary position.
            guard core.count == acousticKeys.count, core.contains(where: glossaryWords.contains),
                  wide.indices.filter({ wide[$0...].starts(with: core) }).count == 1,
                  core.indices.allSatisfy({ i in
                      if core[i] == acousticKeys[i] { return true }
                      guard glossaryWords.contains(core[i]), core[i].count >= 3,
                            let latin = acousticKeys[i].applyingTransform(.toLatin, reverse: false)?
                                .applyingTransform(.stripDiacritics, reverse: false) else { return false }
                      return SpokenVocabulary.distance(core[i], latin) <= 1
                  }) else { return "Неразборчиво" }
            return isolated
        }
    }

    func glossaryClause(for target: TranscriptSegment, vocabulary: String) -> GlossaryClause? {
        guard let free = BackchannelLanguage.unprotectedClauseWords(target.text, duration: target.end - target.start,
                  vocabulary: vocabulary), let track = target.audioFile else { return nil }
        let previous = endingAtOrBefore(target.start).prefix { $0.segment.end >= target.start - 5 }
            .first { $0.segment.audioFile == track }?.segment
        let next = startingAtOrAfter(target.end).prefix { $0.segment.start <= target.end + 5 }
            .first { $0.segment.audioFile == track }?.segment
        guard let previous, let next, [previous, next].allSatisfy({
            $0.independentRecognitionLanguage != false && BackchannelLanguage.isRussianContext($0.text)
        }), !byEnd[partition(byEnd) { $0.end <= target.start }...].contains(where: {
            $0.segment.id != target.id && $0.segment.audioFile == track && $0.segment.start < target.end
        }) else { return nil }
        let text = target.text
        let ranges = TranscriptOrthography.glossaryRanges(in: text, vocabulary: vocabulary, range: NSRange(text.startIndex..., in: text))
        let glossaryWords = ranges.compactMap { Range($0, in: text) }.flatMap { RussianRecognition.words(String(text[$0])) }
        return GlossaryClause(unprotectedWords: free, glossaryWords: Set(glossaryWords))
    }

    struct ShortReplyAnchor {
        let start: Double
        let end: Double
        fileprivate let preceding: [String]
        fileprivate let following: [String]

        // The isolated Russian recognizer must hear the reply itself. The
        // multilingual decoder must independently put it before the known
        // opening of the next turn, without a language or vocabulary prompt.
        func candidate(isolated: String, wide: String, language: String?) -> String? {
            let exact = RussianRecognition.words(isolated), heard = RussianRecognition.words(wide)
            guard language?.lowercased() == "russian", (1...3).contains(exact.count),
                  exact.allSatisfy({ TranscriptTerms.isCommonRussianWord($0) || AbbreviationFamilies.isRussianFunctionWord($0) }),
                  exact.contains(where: TranscriptTerms.isCommonRussianWord),
                  !following.starts(with: exact), heard.starts(with: exact),
                  heard.dropFirst(exact.count).starts(with: following.prefix(3)) else { return nil }
            let clean = isolated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = clean.first, first.isLetter,
                  clean.dropLast().allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "," || $0 == "-" }),
                  clean.last?.isLetter == true || clean.last.map({ ".!?".contains($0) }) == true else { return nil }
            return first.uppercased() + clean.dropFirst() + (clean.last?.isLetter == true ? "." : "")
        }

        // The following voice alone could bias language detection. Listen
        // from the opposite direction too, ending before that voice starts.
        func confirmsPreceding(_ candidate: String, wide: String, language: String?) -> Bool {
            let heard = RussianRecognition.words(wide)
            let reply = RussianRecognition.words(candidate)
            guard language?.lowercased() == "russian", !reply.isEmpty,
                  heard.suffix(reply.count).elementsEqual(reply), !preceding.suffix(reply.count).elementsEqual(reply)
            else { return false }
            let tail = Array(heard.dropLast(reply.count).suffix(9))
            return zip(tail, tail.dropFirst()).contains { [$0, $1].elementsEqual(preceding.suffix(2)) }
        }
    }

    func shortReplyAnchor(for target: TranscriptSegment, vocabulary: String) -> ShortReplyAnchor? {
        let duration = target.end - target.start
        guard (0.2...3).contains(duration), let track = target.audioFile else { return nil }
        let incomplete = duration <= 1.5 && BackchannelLanguage.isIncompleteLatinReply(target.text, vocabulary: vocabulary)
        let disputed = target.independentRecognitionLanguage == false && BackchannelLanguage.isLatinSpeech(target.text)
            && BackchannelLanguage.russianSpelling(ofFiller: target.text) == nil
            && (BackchannelLanguage.shouldRecheckLexical(target.text, duration: duration, vocabulary: vocabulary)
                || BackchannelLanguage.shouldVerifyShortScript(target.text, duration: duration, vocabulary: vocabulary))
        guard incomplete || disputed else { return nil }
        let following = startingAtOrAfter(target.end).lazy.prefix { $0.segment.start <= target.end + 5 }
            .first { $0.segment.audioFile == track }?.segment
        guard let following, BackchannelLanguage.isRussianContext(following.text),
              following.independentRecognitionLanguage != false, following.start - target.end > 0.25,
              let previous = endingAtOrBefore(target.start).lazy.prefix(while: { $0.segment.end >= target.start - 20 })
                .first(where: { $0.segment.audioFile == track })?.segment,
              previous.independentRecognitionLanguage != false, BackchannelLanguage.isRussianContext(previous.text),
              target.start - previous.end > 0.35
              else { return nil }
        let source = RussianRecognition.words(target.text)
        let anchors = RussianRecognition.words(previous.text) + RussianRecognition.words(following.text)
        guard !anchors.contains(where: source.contains),
              !byStart.contains(where: { $0.segment.id != target.id && $0.segment.audioFile == track
                  && $0.segment.start < target.end && $0.segment.end > target.start }) else { return nil }
        return ShortReplyAnchor(start: max(previous.end - 6, previous.start), end: min(following.start + 5, following.end),
                              preceding: RussianRecognition.words(previous.text),
                              following: RussianRecognition.words(following.text))
    }

    func neighbors(around target: TranscriptSegment) -> Neighbors {
        let previous = endingAtOrBefore(target.start).lazy.prefix(while: { $0.segment.end >= target.start - 60 })
            .filter { $0.segment.id != target.id }
            .compactMap(\.tail)
            .prefix(5)
        let next = startingAtOrAfter(target.end).lazy.prefix(while: { $0.segment.start <= target.end + 45 })
            .filter { $0.segment.id != target.id }
            .compactMap(\.head)
            .prefix(4)
        return Neighbors(preceding: previous.reversed(), following: Array(next))
    }

    private func nearbyTurns(for target: TranscriptSegment) -> [Turn] {
        let previous = endingAtOrBefore(target.start).lazy.prefix(while: { $0.segment.end >= target.start - 120 }).prefix(40)
        let next = startingAtOrAfter(target.end).lazy.prefix(while: { $0.segment.start <= target.end + 120 }).prefix(40)
        return (Array(previous) + Array(next)).filter { $0.segment.id != target.id && $0.segment.independentRecognitionLanguage != false }
    }

    private static func joinedInPhrase(_ first: Token, _ second: Token, in text: String) -> Bool {
        let separator = text[first.range.upperBound..<second.range.lowerBound]
        return !separator.isEmpty && separator.allSatisfy { $0.isWhitespace && !$0.isNewline }
    }

    private static func localPhrases(at index: Int, key: String, words: [Token], in text: String) -> Set<String> {
        var phrases = Set<String>()
        if index > 0, joinedInPhrase(words[index - 1], words[index], in: text) {
            phrases.insert(words[index - 1].key + " " + key)
        }
        if index + 1 < words.count, joinedInPhrase(words[index], words[index + 1], in: text) {
            phrases.insert(key + " " + words[index + 1].key)
        }
        return phrases
    }

    private static func wordPairs(in text: String) -> Set<String> {
        let words = tokens(text)
        let literals = TranscriptOrthography.literalRanges(in: text)
        return Set(zip(words, words.dropFirst()).compactMap { first, second in
            guard joinedInPhrase(first, second, in: text),
                  [first, second].allSatisfy({ isRussianWord($0.text) && $0.key.count >= 4 && !markers.contains($0.key) }),
                  !literals.contains(where: {
                      NSIntersectionRange($0, NSRange(first.range.lowerBound..<second.range.upperBound, in: text)).length > 0
                  }) else { return nil }
            return first.key + " " + second.key
        })
    }

    /// Count a phrase once per frozen turn, even when it repeats within that turn.
    func establishedPhrases(around target: TranscriptSegment) -> Set<String> {
        Self.establishedPhrases(in: nearbyTurns(for: target))
    }

    private static func establishedPhrases(in turns: [Turn], matching candidates: Set<String>? = nil) -> Set<String> {
        var seen = Set<String>(), repeated = Set<String>()
        var counted = Set<UUID>()
        for turn in turns where counted.insert(turn.segment.id).inserted {
            let phrases = candidates.map { turn.wordPairs.intersection($0) } ?? turn.wordPairs
            repeated.formUnion(seen.intersection(phrases))
            seen.formUnion(phrases)
        }
        return repeated
    }

    struct RecurringWord {
        fileprivate let original: String
        fileprivate let range: Range<String.Index>
        fileprivate let key: String
        fileprivate let left: [String]
        fileprivate let right: [String]
        fileprivate let requiredPhrases: Set<String>

        func confirmedText(language: String?, reread: String) -> String? {
            guard language?.lowercased() == "russian" else { return nil }
            let words = RecognitionContext.tokens(reread)
            let sites = RecognitionContext.matches(in: words, left: left, right: right, maximumWidth: 1)
            guard sites.count == 1, let site = sites.first, words[site.lowerBound].key == key,
                  RecognitionContext.safe(site, in: words, text: reread) else { return nil }
            if !requiredPhrases.isEmpty, requiredPhrases.isDisjoint(with:
                RecognitionContext.localPhrases(at: site.lowerBound, key: key, words: words, in: reread)) { return nil }
            return original.replacingCharacters(in: range, with: words[site.lowerBound].text)
        }
    }

    /// An unfamiliar word in running Russian can be a misspelling of a term
    /// used elsewhere. Locate a reread using the independent audio first.
    func recurringWord(for target: TranscriptSegment, independent: String, vocabulary: String) -> RecurringWord? {
        guard target.text != independent else { return nil }
        let source = Self.tokens(target.text), heard = Self.tokens(independent)
        guard source.count == heard.count, source.count >= 4, Self.isMostlyRussian(source) else { return nil }
        let changed = source.indices.filter { source[$0].key != heard[$0].key }
        guard (1...2).contains(changed.count) else { return nil }

        lazy var neighbors = nearbyTurns(for: target)
        lazy var lexicon = Self.terms(in: vocabulary)
        var result: RecurringWord?
        for index in changed {
            let old = source[index], new = heard[index], span = index..<(index + 1)
            guard old.text == old.text.lowercased(), Self.isRussianWord(old.text), Self.isRussianWord(new.text),
                  min(old.key.count, new.key.count) >= 5, abs(old.key.count - new.key.count) <= 2,
                  let distance = Self.phoneticDistance(old.key, new.key, term: new.key), distance <= 2,
                  let (left, right) = Self.anchors(around: span, in: source),
                  Self.matches(in: source, left: left, right: right, maximumWidth: 1) == [span],
                  changed.count == 1 || Self.matches(in: heard, left: left, right: right, maximumWidth: 1) == [span],
                  Self.safe(span, in: source, text: target.text), Self.safe(span, in: heard, text: independent)
            else { continue }

            var witnesses = Set<UUID>()
            for turn in neighbors where turn.exactMentions.contains(where: { $0.caseInsensitiveCompare(new.text) == .orderedSame }) {
                witnesses.insert(turn.segment.id)
                if witnesses.count == 2 { break }
            }
            guard witnesses.count == 2, Self.preservesTerms(source, span, text: target.text, lexicon: lexicon) else { continue }
            var requiredPhrases = Set<String>()
            if changed.count > 1 || TranscriptTerms.isCommonRussianWord(old.key) {
                // The recurring expression must also be a continuous phrase at
                // this exact site in both decodes, and again in the fresh reread.
                let proposed = Self.localPhrases(at: index, key: new.key, words: source, in: target.text)
                    .intersection(Self.localPhrases(at: index, key: new.key, words: heard, in: independent))
                guard !proposed.isEmpty else { continue }
                let existing = Self.localPhrases(at: index, key: old.key, words: source, in: target.text)
                let established = Self.establishedPhrases(in: neighbors, matching: proposed.union(existing))
                requiredPhrases = proposed.intersection(established)
                guard !requiredPhrases.isEmpty, established.isDisjoint(with: existing) else { continue }
            }
            guard result == nil else { return nil }
            result = RecurringWord(original: target.text, range: old.range, key: new.key, left: left, right: right,
                                   requiredPhrases: requiredPhrases)
        }
        return result
    }

    struct Continuation {
        let segment: TranscriptSegment
        let suffix: String
        fileprivate let unchangedPrefix: String

        func splice(_ revised: String) -> String? {
            guard revised.hasSuffix(suffix), revised.hasPrefix(unchangedPrefix) else { return nil }
            return String(revised.dropLast(suffix.count))
        }
    }

    /// A short, same-track continuation can supply the missing right anchor.
    /// The appended text is used for alignment and must survive any splice unchanged.
    func continuation(after target: TranscriptSegment) -> Continuation? {
        guard let track = target.audioFile,
              let next = startingAtOrAfter(target.end).lazy.prefix(while: { $0.segment.start <= target.end + 0.35 })
                .map(\.segment)
                .first(where: { $0.audioFile == track && $0.id != target.id }) else { return nil }
        let words = Self.tokens(next.text)
        guard words.count >= 3, Self.isMostlyRussian(Array(words.prefix(3))) else { return nil }
        let prefix = next.text[..<words[2].range.upperBound]
        guard prefix.count <= 90, !prefix.contains(where: \.isNewline),
              Self.withoutLiterals(String(prefix)) == prefix else { return nil }
        let source = Self.tokens(target.text)
        guard source.count >= 5 else { return nil }
        return Continuation(segment: next, suffix: " " + prefix,
                            unchangedPrefix: String(target.text[..<source[source.count - 3].range.lowerBound]))
    }

    func plan(for target: TranscriptSegment, independent: String?, vocabulary: String,
              spokenVocabulary: SpokenVocabulary, neighbors knownNeighbors: Neighbors? = nil) -> Retry? {
        let source = Self.withoutLiterals(target.text)
        let words = Self.tokens(source)
        guard words.count >= 4, Self.isMostlyRussian(words) else { return nil }
        let acoustic = spokenVocabulary.apply(to: Self.withoutLiterals(Self.acousticText(independent ?? "")))
        let acousticWords = Self.tokens(acoustic)
        let shared = Set(words.map(\.key)).intersection(acousticWords.map(\.key))
        let observed = (words + acousticWords).filter { token in
            // Agreeing ordinary words are poor candidates for a speculative
            // retry. A mixed-script or Latin acronym can still encode a case.
            !shared.contains(token.key) || Self.isWrittenInitialism(token.text)
        }
        let earlier = endingAtOrBefore(target.start).lazy.prefix(while: { $0.segment.end >= target.start - 300 })
        let later = startingAtOrAfter(target.end).lazy.prefix(while: { $0.segment.start <= target.end + 300 })
        func distance(_ segment: TranscriptSegment) -> Double {
            max(target.start - segment.end, segment.start - target.end)
        }
        let surrounding = (Array(earlier.prefix(40)) + Array(later.prefix(40))).filter { $0.segment.id != target.id }
        let entityContext = surrounding.filter { distance($0.segment) <= 120 }
        let exactMentions = Set(surrounding.flatMap(\.exactMentions))
        let lexicon = Self.terms(in: vocabulary)
        func isEstablished(_ term: String) -> Bool {
            let key = Data(term.utf8)
            return entityContext.contains { $0.establishes(term, key: key) }
        }
        // Agreement can hide a shared name error after a prompt-free primary
        // decode. Only a unique, anchored near-miss of an explicitly listed,
        // locally established name may schedule more audio; it is not evidence
        // that the glossary form was spoken.
        var sharedNames: [String: String] = [:]
        let targetWords = Self.tokens(target.text)
        for term in lexicon where Self.canBeSharedName(term) && isEstablished(term) {
            if let span = Self.sharedEstablishedNameSpan(in: target.text, source: targetWords,
                    corroboration: acoustic, acoustic: acousticWords, term: term) {
                sharedNames[term] = targetWords[span.lowerBound].text
            }
        }
        let sharedNameCounts = Dictionary(grouping: sharedNames, by: { $0.value.lowercased() })
        sharedNames = sharedNames.filter { sharedNameCounts[$0.value.lowercased()]?.count == 1 }
        var selected: [(term: String, forms: [String], established: Bool, strength: Int)] = []
        var endingSites: [String: String] = [:]
        for term in lexicon {
            let heard = RecognitionVocabulary.contains(term, in: acoustic)
            let missing = heard && (!RecognitionVocabulary.contains(term, in: source)
                || Self.occurrenceCount(of: term, in: acoustic, words: acousticWords)
                    > Self.occurrenceCount(of: term, in: source, words: words))
            let fused = independent != nil && !heard && source.range(of: NSRegularExpression.escapedPattern(for: term) + "[-‐‑][а-яё]+",
                options: [.regularExpression, .caseInsensitive]) != nil
            let forms = Self.hintForms(for: term)
            guard missing || fused || !forms.isEmpty else { continue }
            let established = isEstablished(term)
            let possibleMisses = observed.filter { !Self.isTermForm($0.text, of: term) }.map(\.text)
                + (sharedNames[term].map { [$0] } ?? [])
            let near = forms.compactMap { form -> (String, Int)? in
                let score = possibleMisses.compactMap { Self.phoneticScore($0, form, term: term) }.min()
                return score.map { (form, $0) }
            }.sorted { $0.1 < $1.1 }
            let endingSite = Self.isLatinInitialism(term) ? words.first {
                Self.endingStem($0.text) == term && ($0.text == term + "М" || exactMentions.contains(term))
            } : nil
            if let endingSite { endingSites[endingSite.text] = term }
            let numericConflict = established && words.contains { token in
                forms.contains { Self.numericEndingConflict(token.text, form: $0, term: term) }
            }
            let phoneticBoundary = exactMentions.contains(term) && Self.isLatinInitialism(term)
                && !Self.phoneticBoundarySites(in: source, corroboration: acoustic, term: term).isEmpty
            let compatible = near.filter { form, score in
                score == 0 || established || (words.contains { Self.isBareNumericStem($0.text, form: form, term: term) }
                    && acousticWords.contains { Self.hearsNumericPrefix($0.text, form: form, term: term) })
            }.prefix(2).map(\.0)
            guard missing || fused || !compatible.isEmpty || endingSite != nil || numericConflict || phoneticBoundary else { continue }
            var hints = compatible
            if numericConflict {
                hints += forms.filter { form in words.contains { Self.numericEndingConflict($0.text, form: form, term: term) } }
            }
            if endingSite != nil { hints.append(term + "'ем") }
            selected.append((term, hints, established, (missing ? 4 : 0) + (established ? 2 : 0) + (fused ? 1 : 0)))
        }
        let focused = selected.sorted { $0.strength > $1.strength }.prefix(4)
        guard !focused.isEmpty else { return nil }
        let neighbors = knownNeighbors ?? neighbors(around: target)
        var inserted = Set<String>()
        let hints = focused.flatMap { [$0.term] + $0.forms }.filter { inserted.insert($0).inserted }.joined(separator: ", ")
        let context = [hints, neighbors.preceding.joined(separator: "\n"), neighbors.following.joined(separator: "\n")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let endingTerms = Set(endingSites.values).intersection(focused.map(\.term))
        var competingEndings = Set<String>()
        if !endingTerms.isEmpty {
            endingSites = endingSites.filter { endingTerms.contains($0.value) && exactMentions.contains($0.value) }
            competingEndings = Self.initialismSpellings(surrounding.map { $0.segment.text } + lexicon)
        }
        return Retry(hints: hints, context: context, terms: focused.map(\.term),
                     established: Set(focused.filter(\.established).map(\.term)),
                     phoneticTerms: Set(focused.map(\.term)).intersection(exactMentions), neighbors: neighbors,
                     endingSites: endingSites, competingEndings: competingEndings,
                     sharedNameTerms: Set(sharedNames.keys).intersection(focused.map(\.term)),
                     explicitNumericTerms: Set(Self.terms(in: spokenVocabulary.decodingVocabulary)
                        .filter { RecognitionVocabulary.numericForms(for: $0) != nil }).intersection(focused.map(\.term)))
    }

    private static func canBeSharedName(_ term: String) -> Bool {
        term.count >= 5 && term == term.capitalized && isRussianWord(term)
    }

    private static func sharedEstablishedNameSpan(in original: String, source: [Token], corroboration: String,
                                                  acoustic: [Token], term: String) -> Range<Int>? {
        guard canBeSharedName(term) else { return nil }
        let forms = hintForms(for: term)
        let candidates = source.indices.filter { index in
            let token = source[index], span = index..<(index + 1)
            guard !isTermForm(token.text, of: term), isRussian(token),
                  safe(span, in: source, text: original),
                  forms.contains(where: { (phoneticScore(token.text, $0, term: term) ?? Int.max) <= 1 }),
                  let (left, right) = anchors(around: span, in: source),
                  left.count == 2, right.count == 2,
                  matches(in: source, left: left, right: right) == [span] else { return false }
            // Bare paths/handles must not become speculative name candidates.
            let before = original[..<token.range.lowerBound].last
            let after = original[token.range.upperBound...].first
            guard ![before, after].compactMap({ $0 }).contains(where: { "/\\_@".contains($0) }) else { return false }
            let matches = matches(in: acoustic, left: left, right: right)
            guard matches.count == 1, let heard = matches.first, heard.count == 1,
                  acoustic[heard.lowerBound].key == token.key,
                  safe(heard, in: acoustic, text: corroboration) else { return false }
            return true
        }
        guard candidates.count == 1, let index = candidates.first else { return nil }
        return index..<(index + 1)
    }

    private static func targetSpans(in original: String, corroboration: String?, retry: Retry) -> [Range<String.Index>] {
        let corroboration = corroboration.map(acousticText)
        let source = tokens(original), acoustic = tokens(corroboration ?? "")
        let shared = Set(source.map(\.key)).intersection(acoustic.map(\.key))
        var choices: [Range<Int>: Int] = [:]
        for term in retry.terms {
            let forms = hintForms(for: term)
            if retry.sharedNameTerms.contains(term), let corroboration,
               let span = sharedEstablishedNameSpan(in: original, source: source, corroboration: corroboration,
                   acoustic: acoustic, term: term) {
                choices[span] = 1
            }
            if retry.phoneticTerms.contains(term), isLatinInitialism(term), let corroboration {
                for span in phoneticBoundarySites(in: original, corroboration: corroboration, term: term) {
                    choices[span] = 1
                }
            }
            for index in source.indices {
                let token = source[index]
                if isLatinInitialism(term), token.text == term, index + 1 < source.count,
                   isRussian(source[index + 1]), original[token.range.upperBound..<source[index + 1].range.lowerBound].contains(where: { "-‐‑".contains($0) }) {
                    choices[index..<(index + 2)] = 0
                    continue
                }
                if retry.endingSites[token.text] == term || (retry.established.contains(term)
                    && forms.contains { numericEndingConflict(token.text, form: $0, term: term) }) {
                    choices[index..<(index + 1)] = 1
                    continue
                }
                guard (!shared.contains(token.key) || isWrittenInitialism(token.text)), !isTermForm(token.text, of: term) else { continue }
                for form in forms {
                    guard let score = phoneticScore(token.text, form, term: term),
                          score == 0 || retry.established.contains(term) || (isBareNumericStem(token.text, form: form, term: term)
                            && acoustic.contains { hearsNumericPrefix($0.text, form: form, term: term) }) else { continue }
                    let span = index..<(index + 1)
                    choices[span] = min(choices[span] ?? Int.max, 2 + score)
                }
            }
            if let corroboration {
                for start in acoustic.indices {
                    for end in (start + 1)...min(acoustic.count, start + 3) {
                        let span = start..<end
                        guard isTermForm(String(corroboration[range(in: acoustic, span)]), of: term),
                              safe(span, in: acoustic, text: corroboration),
                              let (left, right) = anchors(around: span, in: acoustic),
                              matches(in: acoustic, left: left, right: right) == [span] else { continue }
                        let aligned = matches(in: source, left: left, right: right)
                        guard aligned.count == 1, let old = aligned.first,
                              !isTermForm(String(original[range(in: source, old)]), of: term) else { continue }
                        choices[old] = min(choices[old] ?? Int.max, 1)
                    }
                }
            }
        }
        let ranked = choices.filter { safe($0.key, in: source, text: original) }.sorted { a, b in
            a.value == b.value ? a.key.lowerBound < b.key.lowerBound : a.value < b.value
        }
        var selected: [Range<Int>] = []
        for choice in ranked where !selected.contains(where: { $0.overlaps(choice.key) }) {
            selected.append(choice.key)
            if selected.count == 3 { break }
        }
        return selected.map { range(in: source, $0) }
    }

    static func revisedText(original: String, candidate: String, corroboration: String?,
                            retry: Retry, vocabulary: String, candidateIsAcoustic: Bool = true,
                            boundaryEvidence: [String] = []) -> String? {
        guard !retry.isNeighborEcho(candidate), MeetingSpeechText.accepts(candidate) else { return nil }
        let acoustic = corroboration.map { text in
            acousticText(text).replacingOccurrences(of: #"(?i)(?<![\p{L}\p{N}])э(?:[-‐‑]э)+(?![\p{L}\p{N}])"#,
                                      with: " ", options: .regularExpression)
        }
        let source = tokens(original), decoded = tokens(candidate), evidence = tokens(acoustic ?? "")
        guard isMostlyRussian(source), isMostlyRussian(decoded) else { return nil }
        let lexicon = terms(in: vocabulary)
        var edits: [(Range<String.Index>, String)] = []
        for start in decoded.indices {
            for end in (start + 1)...min(decoded.count, start + 3) {
                let span = start..<end
                let candidateRange = range(in: decoded, span)
                let candidateForm = String(candidate[candidateRange])
                guard safe(span, in: decoded, text: candidate) else { continue }
                let exactTerm = retry.terms.first {
                    isTermForm(candidateForm, of: $0)
                        || termWithLeadingWord(candidateForm, term: $0, atStart: start == 0)
                        || (span.count >= 2 && decoded[start].text == $0 && isLatinInitialism($0))
                }
                let contraction = exactTerm == nil && candidateIsAcoustic && span.count == 1
                    ? contractedNumericForm(candidateForm, lexicon: lexicon) : nil
                guard let term = exactTerm ?? contraction?.term, retry.terms.contains(term) else { continue }
                let proposed = contraction?.form ?? candidateForm
                guard let (left, right) = anchors(around: span, in: decoded),
                      matches(in: decoded, left: left, right: right) == [span] else { continue }
                let matchesInSource = matches(in: source, left: left, right: right)
                guard uniqueBoundaryAnchor(left: left, right: right, in: source),
                      uniqueBoundaryAnchor(left: left, right: right, in: decoded),
                      uniqueBoundaryAnchor(left: left, right: right, in: evidence),
                      matchesInSource.count == 1, let old = matchesInSource.first,
                      safe(old, in: source, text: original),
                      preservesTerms(source, old, text: original, lexicon: lexicon, replacing: term) else { continue }
                let sourceRange = range(in: source, old)
                let previous = String(original[sourceRange])
                guard previous != proposed else { continue }
                if left.count == 1 || right.count == 1 {
                    // One nearby anchor must not turn two recognizable names
                    // into a different person merely because a retry agrees.
                    let limit = RecognitionVocabulary.numericForms(for: term) != nil ? 3 : 2
                    guard let distance = phoneticDistance(previous, proposed, term: term), distance <= limit else { continue }
                }
                // A prompted retry must not erase an ending already heard in
                // the first pass when the verifier only recognizes the stem.
                let inflected = #"[\p{L}\p{N}]+['’][\p{L}]+"#
                if previous.range(of: inflected, options: .regularExpression) != nil,
                   proposed.range(of: inflected, options: .regularExpression) == nil { continue }
                let matchesInEvidence = matches(in: evidence, left: left, right: right)
                let heard = acoustic.flatMap { text -> String? in
                    guard matchesInEvidence.count == 1, let heardSpan = matchesInEvidence.first,
                          safe(heardSpan, in: evidence, text: text) else { return nil }
                    return String(text[range(in: evidence, heardSpan)])
                }
                let literalSafeEnding = ordinaryNumericSpan(sourceRange, in: original)
                    && ordinaryNumericSpan(candidateRange, in: candidate)
                    && matchesInEvidence.first.map { match in
                        ordinaryNumericSpan(range(in: evidence, match), in: acoustic ?? "")
                    } == true
                let complementaryEnding = candidateIsAcoustic && retry.explicitNumericTerms.contains(term)
                    && literalSafeEnding
                    && primarySupportsNumericEnding(previous: previous, proposed: proposed, heard: heard,
                                                    term: term, lexicon: lexicon)
                if !complementaryEnding {
                    if old.count > 1, RecognitionConsensus.isNumberWord(source[old.lowerBound].key) { continue }
                    if previous.first?.isNumber == true, RecognitionVocabulary.numericForms(for: term) != nil {
                        let written = String(previous.prefix { $0.isNumber || $0.isUppercase })
                        guard AbbreviationFamilies.aliases(for: term).contains(written) else { continue }
                    }
                }
                if contraction != nil {
                    guard let heard, (isTermForm(heard, of: term) && equivalentForm(heard, proposed, term: term))
                            || hearsNumericPrefix(heard, form: proposed, term: term) else { continue }
                }
                let confirmations = boundaryEvidence.compactMap { text -> String? in
                    guard !retry.isNeighborEcho(text), MeetingSpeechText.accepts(text) else { return nil }
                    let words = tokens(text)
                    let aligned = matches(in: words, left: left, right: right)
                    guard aligned.count == 1, let match = aligned.first, safe(match, in: words, text: text) else { return nil }
                    return String(text[range(in: words, match)])
                }
                let replacement: String?
                if termWithLeadingWord(proposed, term: term, atStart: left.isEmpty), let heard,
                   termWithLeadingWord(heard, term: term, atStart: left.isEmpty),
                   RussianRecognition.words(heard) == RussianRecognition.words(proposed),
                   closeLeadingTermEdit(previous: previous, proposed: proposed, term: term) {
                    replacement = proposed
                } else {
                    replacement = supportedEdit(previous: previous, proposed: proposed, heard: heard,
                        term: term, established: retry.established.contains(term), candidateIsAcoustic: candidateIsAcoustic,
                        phoneticBoundaryEstablished: retry.phoneticTerms.contains(term), boundaryEvidence: confirmations,
                        complementaryNumericEnding: complementaryEnding)
                }
                guard let replacement else { continue }
                if !edits.contains(where: { $0.0 == sourceRange && $0.1 == replacement }) {
                    edits.append((sourceRange, replacement))
                }
            }
        }
        // Independent occurrences can be supported in the same utterance.
        // Reject competing proposals for one interval, rather than discarding
        // every valid correction merely because there are two of them.
        let ordered = edits.sorted { $0.0.lowerBound < $1.0.lowerBound }
        guard (1...3).contains(ordered.count),
              zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.upperBound <= $1.0.lowerBound }) else { return nil }
        var revised = original
        for (range, replacement) in ordered.reversed() { revised.replaceSubrange(range, with: replacement) }
        return revised
    }

    /// Some acoustic outputs join an acronym to its case ending with a hyphen.
    /// Normalize only a complete explicit base; a truncated 2G stays 2G.
    private static func acousticVocabularyText(_ text: String, vocabulary: String) -> String {
        var result = acousticText(text)
        for term in terms(in: vocabulary) where AbbreviationFamilies.isBase(term) {
            let aliases = AbbreviationFamilies.aliases(for: term).map(NSRegularExpression.escapedPattern).joined(separator: "|")
            let endings = AbbreviationFamilies.caseEndings.joined(separator: "|")
            let pattern = #"(?i)(?<![\p{L}\p{N}])("# + aliases + ")[-‐‑](" + endings + #")(?![\p{L}\p{N}])"#
            result = result.replacingOccurrences(of: pattern, with: "$1'$2", options: .regularExpression)
        }
        return RecognitionVocabulary.apply(to: result, vocabulary: vocabulary)
    }

    /// A nearby word can also be malformed, so immediate anchors need not
    /// match. Two independent decodes must agree on the exact dictionary form;
    /// unique unchanged word pairs on both sides locate its phonetic source.
    /// Only that source interval changes; skipped surrounding words survive.
    static func revisedAnchoredDictionaryText(original: String, candidate: String, corroboration: String,
                                               retry: Retry, vocabulary: String, candidateFromIndependentAudio: Bool = false) -> String? {
        guard !retry.isNeighborEcho(candidate), MeetingSpeechText.accepts(candidate), MeetingSpeechText.accepts(corroboration) else { return nil }
        let candidate = candidateFromIndependentAudio ? acousticVocabularyText(candidate, vocabulary: vocabulary) : candidate
        let acoustic = acousticVocabularyText(corroboration, vocabulary: vocabulary)
        let source = tokens(original), proposed = tokens(candidate), evidence = tokens(acoustic)
        guard isMostlyRussian(source), isMostlyRussian(proposed) else { return nil }
        let lexicon = terms(in: vocabulary)
        func pairs(_ words: [Token], text: String, span: Range<Int>, before: Bool) -> Set<String> {
            guard words.count >= 2 else { return [] }
            let lower = before ? max(0, span.lowerBound - 7) : span.upperBound
            let upper = before ? span.lowerBound - 2 : min(words.count - 2, span.upperBound + 5)
            guard lower <= upper else { return [] }
            return Set((lower...upper).compactMap { index in
                let separator = text[words[index].range.upperBound..<words[index + 1].range.lowerBound]
                guard !separator.isEmpty, separator.allSatisfy({ $0.isWhitespace && !$0.isNewline }) else { return nil }
                let keys = [words[index].key, words[index + 1].key]
                // Uniqueness belongs to the complete bounded alignment below;
                // an ordinary pair can repeat elsewhere in a long utterance.
                return keys.joined(separator: " ")
            })
        }
        var revisions: [String] = []
        for start in proposed.indices {
            for width in [1, 3] where start + width <= proposed.count {
                let span = start..<(start + width)
                let proposedRange = range(in: proposed, span)
                let phrase = String(candidate[proposedRange])
                guard phrase.allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace || ",-'’".contains($0) }),
                      span.allSatisfy({ safe($0..<($0 + 1), in: proposed, text: candidate) }),
                      let numeric = retry.terms.first(where: { RecognitionVocabulary.numericForms(for: $0) != nil
                          && isTermForm(proposed[span.upperBound - 1].text, of: $0) }),
                      retry.established.contains(numeric) else { continue }
                var replacing: Set<String> = [numeric]
                var leadingTerm: String?
                if width == 3 {
                    guard boundaryPrepositions.contains(proposed[start + 1].key),
                          let firstTerm = lexicon.first(where: { $0 != numeric && isTermForm(proposed[start].text, of: $0) }) else { continue }
                    replacing.insert(firstTerm)
                    leadingTerm = firstTerm
                }
                let keys = proposed[span].map(\.key)
                guard evidence.count >= width else { continue }
                let observed = (0...(evidence.count - width)).compactMap { index -> (start: Int, boundaryVaries: Bool)? in
                    if evidence[index..<(index + width)].map(\.key) == keys { return (index, false) }
                    // A first-pass acoustic spelling can resolve a split case
                    // ending/preposition only when the other decoder retains
                    // both exact names and the same numeric case ending.
                    guard candidateFromIndependentAudio, width == 3, let leadingTerm,
                          isTermForm(evidence[index].text, of: leadingTerm),
                          evidence[index + 2].key == proposed[start + 2].key,
                          evidence[index + 1].key.count <= 3,
                          !boundaryPrepositions.contains(evidence[index + 1].key), !markers.contains(evidence[index + 1].key),
                          let distance = phoneticDistance(String(acoustic[range(in: evidence, index..<(index + 2))]),
                              String(candidate[range(in: proposed, start..<(start + 2))]), term: numeric), distance <= 1 else { return nil }
                    return (index, true)
                }
                guard observed.count == 1, let observation = observed.first else { continue }
                let heardStart = observation.start
                let heardSpan = heardStart..<(heardStart + width)
                guard heardSpan.allSatisfy({ safe($0..<($0 + 1), in: evidence, text: acoustic) }) else { continue }
                let left = pairs(proposed, text: candidate, span: span, before: true)
                    .intersection(pairs(evidence, text: acoustic, span: heardSpan, before: true))
                let right = pairs(proposed, text: candidate, span: span, before: false)
                    .intersection(pairs(evidence, text: acoustic, span: heardSpan, before: false))
                guard !left.isEmpty, !right.isEmpty else { continue }
                var matches: [Range<Int>] = []
                for oldStart in source.indices {
                    for oldWidth in 1...3 where oldStart + oldWidth <= source.count {
                        let old = oldStart..<(oldStart + oldWidth)
                        let previous = String(original[range(in: source, old)])
                        guard safe(old, in: source, text: original), previous != phrase,
                              !RecognitionConsensus.isNumberWord(source[oldStart].key),
                              !source[old].contains(where: { $0.text.first?.isNumber == true }),
                              !(width == 3 && source[old].contains(where: {
                                  boundaryPrepositions.contains($0.key) && $0.key != proposed[start + 1].key
                              })),
                              !left.isDisjoint(with: pairs(source, text: original, span: old, before: true)),
                              !right.isDisjoint(with: pairs(source, text: original, span: old, before: false)),
                              !lexicon.contains(where: { !replacing.contains($0) && RecognitionVocabulary.contains($0, in: previous) }),
                              let distance = phoneticDistance(previous, phrase, term: numeric), distance <= (width == 1 ? 3 : 1) else { continue }
                        if observation.boundaryVaries {
                            guard oldWidth == 2, distance == 0,
                                  original[source[oldStart].range.upperBound..<source[oldStart + 1].range.lowerBound]
                                    .contains(where: { "-‐‑".contains($0) }) else { continue }
                        }
                        matches.append(old)
                    }
                }
                guard matches.count == 1, let old = matches.first else { continue }
                var revision = original
                revision.replaceSubrange(range(in: source, old), with: phrase)
                revisions.append(revision)
            }
        }
        return mergeIndependentRevisions(original: original, revisions: revisions)
    }

    /// The caller nominates a rare Cyrillic spelling using the bounded domain
    /// lexicon. A fresh single-term prompt may repair only that exact interval,
    /// with unchanged unique anchors and a compatible independent observation.
    static func revisedTechnicalTerm(original: String, candidate: String, corroboration: String,
                                      term: String, sourceRange: Range<String.Index>, vocabulary: String) -> String? {
        guard MeetingSpeechText.accepts(candidate), MeetingSpeechText.accepts(corroboration) else { return nil }
        let source = tokens(original), proposed = tokens(candidate), evidence = tokens(corroboration)
        let indices = source.indices.filter { sourceRange.overlaps(source[$0].range) }
        guard let first = indices.first, let last = indices.last, indices.count <= 3,
              range(in: source, first..<(last + 1)) == sourceRange,
              source[first...last].allSatisfy({ isRussianWord($0.text) }),
              safe(first..<(last + 1), in: source, text: original),
              let (left, right) = anchors(around: first..<(last + 1), in: source),
              matches(in: source, left: left, right: right) == [first..<(last + 1)] else { return nil }
        let found = matches(in: proposed, left: left, right: right)
        let observed = matches(in: evidence, left: left, right: right)
        guard found.count == 1, let replacementSpan = found.first,
              observed.count == 1, let heard = observed.first, heard.count == 1,
              safe(replacementSpan, in: proposed, text: candidate), safe(heard, in: evidence, text: corroboration) else { return nil }
        let replacement = String(candidate[range(in: proposed, replacementSpan)])
        guard replacement == term else { return nil }
        let spelling = evidence[heard.lowerBound].text
        guard !terms(in: vocabulary).contains(where: { $0 != term && isTermForm(spelling, of: $0) }) else { return nil }
        let letters: [Character] = Array(spelling)
        let expected: [Character] = Array(term)
        let same = RecognitionVocabulary.contains(term, in: spelling)
        var compatibleLetters: Bool = letters.count == expected.count && spelling == spelling.uppercased()
        var differences: Int = 0
        if compatibleLetters {
            for index in letters.indices {
                let observedLetter: Character = letters[index]
                let expectedLetter: Character = expected[index]
                if observedLetter != expectedLetter {
                    differences += 1
                    if observedLetter != "T" || expectedLetter != "2" {
                        compatibleLetters = false
                        break
                    }
                }
            }
        }
        let digitSound: Bool = compatibleLetters && differences == 1
        guard same || digitSound else { return nil }
        var result = original
        result.replaceSubrange(sourceRange, with: replacement)
        return result
    }

    static func isWordRichShortTurn(_ text: String, duration: Double) -> Bool {
        (0.85..<2).contains(duration) && (4...6).contains(RussianRecognition.words(text).count)
    }

    /// Every input was independently checked against the same frozen source.
    /// Combining intervals does not make one correction evidence for another.
    /// A broader verified interval may preserve an earlier replacement at the
    /// same source edge. Conflicting overlapping alternatives keep the first.
    static func mergeIndependentRevisions(original: String, revisions: [String]) -> String? {
        var edits: [(Range<String.Index>, String)] = []
        let characters = Array(original)
        func wordCharacter(_ value: Character) -> Bool {
            value.isLetter || value.isNumber || "_'’".contains(value)
                || value.unicodeScalars.contains(where: CharacterSet.nonBaseCharacters.contains)
        }
        func preservesPrefix(_ spelling: String, in replacement: String) -> Bool {
            guard !spelling.isEmpty, replacement.hasPrefix(spelling) else { return false }
            return replacement.dropFirst(spelling.count).first.map { !wordCharacter($0) } ?? true
        }
        func preservesSuffix(_ spelling: String, in replacement: String) -> Bool {
            guard !spelling.isEmpty, replacement.hasSuffix(spelling) else { return false }
            return replacement.dropLast(spelling.count).last.map { !wordCharacter($0) } ?? true
        }
        for revision in revisions where revision != original {
            var prefix = zip(original, revision).prefix { $0 == $1 }.count
            var suffix = zip(original.dropFirst(prefix).reversed(), revision.dropFirst(prefix).reversed())
                .prefix { $0 == $1 }.count
            // Keep the complete earlier spelling, including any unchanged
            // case ending that character-level differences would trim away.
            while prefix > 0, prefix < characters.count,
                  wordCharacter(characters[prefix - 1]), wordCharacter(characters[prefix]) { prefix -= 1 }
            while suffix > 0, characters.count - suffix > 0,
                  wordCharacter(characters[characters.count - suffix - 1]), wordCharacter(characters[characters.count - suffix]) { suffix -= 1 }
            let lower = original.index(original.startIndex, offsetBy: prefix)
            let upper = original.index(original.endIndex, offsetBy: -suffix)
            let range = lower..<upper
            guard !range.isEmpty else { continue }
            let replacement = String(revision.dropFirst(prefix).dropLast(suffix))
            let overlaps = edits.indices.filter { edits[$0].0.overlaps(range) }
            guard overlaps.allSatisfy({ index in
                let (previous, spelling) = edits[index]
                guard range != previous, range.lowerBound <= previous.lowerBound,
                      range.upperBound >= previous.upperBound else { return false }
                return (range.lowerBound == previous.lowerBound && preservesPrefix(spelling, in: replacement))
                    || (range.upperBound == previous.upperBound && preservesSuffix(spelling, in: replacement))
            }) else { continue }
            for index in overlaps.reversed() { edits.remove(at: index) }
            edits.append((range, replacement))
        }
        guard !edits.isEmpty else { return nil }
        var result = original
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func wordRichShortTurn(original: String, candidate: String, corroboration: String,
                                  duration: Double, vocabulary: String) -> String? {
        guard isWordRichShortTurn(original, duration: duration) else { return nil }
        return RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: corroboration, vocabulary: vocabulary, allowShortTurn: true)
    }

    private static func termWithLeadingWord(_ text: String, term: String, atStart: Bool) -> Bool {
        let words = tokens(text)
        guard words.count >= 2, let first = words.first else { return false }
        let isName = atStart && first.text == first.text.capitalized && first.text.count >= 2
            && isRussianWord(first.text) && term == term.capitalized && isRussianWord(term)
        let isPreposition = isLatinInitialism(term) && boundaryPrepositions.contains(first.key)
        guard isName || isPreposition else { return false }
        let separator = text[first.range.upperBound..<words[1].range.lowerBound]
        return !separator.isEmpty && separator.allSatisfy { $0.isWhitespace && !$0.isNewline }
            && isTermForm(String(text[words[1].range.lowerBound...]), of: term)
    }

    private static func closeLeadingTermEdit(previous: String, proposed: String, term: String) -> Bool {
        let old = tokens(previous), new = tokens(proposed)
        guard let first = old.first, let leading = new.first else { return false }
        if isLatinInitialism(term), boundaryPrepositions.contains(leading.key) {
            // Preserve a competing written acronym or a different preposition.
            guard !old.contains(where: { token in
                token.text.count >= 2 && token.text == token.text.uppercased()
                    && token.text.allSatisfy(\.isLetter) && token.text != term
            }), !boundaryPrepositions.contains(first.key) || first.key == leading.key else { return false }
            let oldCore = first.key == leading.key ? old.dropFirst().map(\.text).joined(separator: " ") : previous
            return phoneticDistance(oldCore, term, term: term).map { $0 <= 2 } ?? false
        }
        // A normal pair of names is meaningful text, even if another
        // acoustically similar person is in the glossary.
        guard !old.dropFirst().contains(where: { token in
            isRussianWord(token.text) && token.text == token.text.capitalized
                && !new.contains(where: { $0.key == token.key })
        }) else { return false }
        if old.count == 2, first.key == leading.key {
            return phoneticDistance(old[1].text, new[1].text, term: term).map { $0 <= 2 } ?? false
        }
        // A split name can cross word boundaries, but must retain its audible
        // onset and remain close over the whole span.
        let previousKeys = phoneticKeys(previous, term: term), proposedKeys = phoneticKeys(proposed, term: term)
        return previousKeys.contains { before in
            proposedKeys.contains { after in
                guard before.prefix(3) == after.prefix(3), min(before.count, after.count) >= 6 else { return false }
                let distance = editDistance(before, after)
                return distance <= 6 && distance * 2 <= max(before.count, after.count)
            }
        }
    }

    private static func uniqueBoundaryAnchor(left: [String], right: [String], in words: [Token]) -> Bool {
        guard left.count <= 1 || right.count <= 1 else { return true }
        let anchor = left.count <= 1 ? right : left
        let keys = words.map(\.key)
        return anchor.count == 3 && keys.indices.filter { keys[$0...].starts(with: anchor) }.count == 1
    }

    /// At a cut, require three independently heard words to the right and
    /// the closest word to the left. Only a terminal term may be replaced.
    static func revisedAcrossBoundary(original: String, candidate: String, corroboration: String,
                                      continuation: Continuation, retry: Retry, vocabulary: String) -> String? {
        guard !retry.isNeighborEcho(candidate), MeetingSpeechText.accepts(candidate),
              MeetingSpeechText.accepts(corroboration) else { return nil }
        let source = tokens(original)
        let joined = tokens(original + continuation.suffix)
        let proposed = tokens(candidate), acoustic = tokens(corroboration)
        let right = tokens(continuation.suffix).map(\.key)
        let lexicon = terms(in: vocabulary)
        guard source.count >= 4, right.count == 3 else { return nil }
        func anchored(_ text: String, words: [Token], left: [String]) -> String? {
            let ranges = matches(in: words, left: left, right: right)
            guard ranges.count == 1, let span = ranges.first, safe(span, in: words, text: text) else { return nil }
            return String(text[range(in: words, span)])
        }
        func termForm(_ value: String, term: String) -> String? {
            let words = tokens(value)
            let prefix = words.first?.key == "и" && words.count > 1 ? "и " : ""
            let core = prefix.isEmpty ? value : String(value[words[1].range.lowerBound...])
            let canonical = RecognitionVocabulary.apply(to: core, vocabulary: term)
            return isTermForm(canonical, of: term) ? prefix + canonical : nil
        }
        var edits: [(Range<String.Index>, String)] = []
        for width in 1...3 {
            let old = (source.count - width)..<source.count
            let left = [source[old.lowerBound - 1].key]
            guard matches(in: joined, left: left, right: right) == [old],
                  safe(old, in: source, text: original),
                  let suggestion = anchored(candidate, words: proposed, left: left),
                  let heard = anchored(corroboration, words: acoustic, left: left) else { continue }
            for term in retry.terms {
                guard let replacement = termForm(suggestion, term: term), let observed = termForm(heard, term: term),
                      RussianRecognition.words(replacement) == RussianRecognition.words(observed),
                      preservesTerms(source, old, text: original, lexicon: lexicon, replacing: term) else { continue }
                let span = range(in: source, old)
                let previous = String(original[span])
                let addsConjunction = replacement.hasPrefix("и ")
                guard addsConjunction || !previous.hasPrefix("и ") else { continue }
                let previousCore = previous.hasPrefix("и ") ? String(previous.dropFirst(2)) : previous
                let replacementCore = addsConjunction ? String(replacement.dropFirst(2)) : replacement
                guard let distance = phoneticDistance(previousCore, replacementCore, term: term), distance <= 3 else { continue }
                if previous != replacement { edits.append((span, replacement)) }
            }
        }
        guard edits.count == 1, let (span, replacement) = edits.first else { return nil }
        var result = original
        result.replaceSubrange(span, with: replacement)
        return result
    }

    /// The first pass can preserve the initialism while the independently
    /// re-decoded audio preserves the adjacent preposition and Russian word.
    static func reconcileObservedInitialismBoundary(original: String, independent: String,
                                                      retry: Retry, vocabulary: String) -> String? {
        let source = tokens(original), evidence = tokens(independent)
        guard source.count >= 6, isMostlyRussian(source), isMostlyRussian(evidence),
              MeetingSpeechText.accepts(independent) else { return nil }
        let lexicon = terms(in: vocabulary)
        var edits: [(Range<String.Index>, String)] = []
        for index in 2..<(source.count - 3) {
            let first = source[index], suffix = source[index + 1]
            let term = first.text
            let join = original[first.range.upperBound..<suffix.range.lowerBound]
            let span = index..<(index + 2)
            guard isLatinInitialism(term), retry.terms.contains(term), lexicon.contains(term),
                  isRussianWord(suffix.text), join.count == 1, let hyphen = join.first, "-‐‑".contains(hyphen),
                  safe(span, in: source, text: original), preservesTerms(source, span, text: original, lexicon: lexicon, replacing: term),
                  let (left, right) = anchors(around: span, in: source), matches(in: source, left: left, right: right) == [span] else { continue }
            let aligned = matches(in: evidence, left: left, right: right)
            guard aligned.count == 1, let heard = aligned.first, heard.count == 2,
                  safe(heard, in: evidence, text: independent) else { continue }
            let preposition = evidence[heard.lowerBound], word = evidence[heard.lowerBound + 1]
            let separator = independent[preposition.range.upperBound..<word.range.lowerBound]
            guard boundaryPrepositions.contains(preposition.key), isRussianWord(word.text), !separator.isEmpty,
                  separator.allSatisfy({ $0.isWhitespace && !$0.isNewline }),
                  let suffixDistance = phoneticDistance(suffix.text, word.text, term: term), suffixDistance <= 3 else { continue }
            let sourceRange = range(in: source, span)
            let replacement = term + " " + preposition.text + " " + word.text
            guard let distance = phoneticDistance(String(original[sourceRange]), replacement, term: term), distance <= 3 else { continue }
            edits.append((sourceRange, replacement))
        }
        guard edits.count == 1, let (range, replacement) = edits.first else { return nil }
        var revised = original
        revised.replaceSubrange(range, with: replacement)
        return revised
    }

    private static let boundaryPrepositions: Set<String> = ["в", "во", "к", "ко", "с", "со", "у", "о", "об", "на", "за", "по", "для", "про"]

    /// Both unprompted observations must come from differently bounded audio
    /// windows. They attest to the letters; the established term supplies spelling.
    static func disambiguateInitialismEnding(original: String, candidate: String, unprompted: [String],
                                             retry: Retry, vocabulary: String) -> String? {
        guard unprompted.count == 2, !retry.isNeighborEcho(candidate),
              let site = initialismEndingSite(in: original, retry: retry),
              !hasLetterDictation(candidate), unprompted.allSatisfy({ !hasLetterDictation($0) }) else { return nil }
        let lexicon = terms(in: vocabulary)
        let source = tokens(original), proposed = tokens(candidate)
        let combined = site.term + "M", replacement = site.term + "'ем"
        guard !initialismSpellings(lexicon).contains(combined),
              preservesTerms(source, site.span, text: original, lexicon: lexicon, replacing: site.term),
              MeetingSpeechText.accepts(candidate), isMostlyRussian(proposed) else { return nil }
        let candidateMatches = matches(in: proposed, left: site.left, right: site.right, maximumWidth: max(3, site.term.count))
        guard candidateMatches.count == 1, let matched = candidateMatches.first,
              spellsInitialismEnding(candidate, words: proposed[matched], term: site.term, replacement: replacement),
              safe(matched, in: proposed, text: candidate),
              !hasCompetingInitialism(combined, in: proposed, outside: matched),
              unprompted.allSatisfy({ hearsSeparateInitialismLetters($0, site: site) }) else { return nil }
        var revised = original
        revised.replaceSubrange(range(in: source, site.span), with: replacement)
        return revised
    }

    private static func spellsInitialismEnding(_ text: String, words: ArraySlice<Token>, term: String, replacement: String) -> Bool {
        if words.count == 1 { return words.first?.text == replacement }
        let letters = term.map(String.init)
        guard words.count == letters.count, words.dropLast().map(\.text) == Array(letters.dropLast()),
              let last = letters.last, words.last?.text == last + "'ем" else { return false }
        return zip(words, words.dropFirst()).allSatisfy { left, right in
            let separator = text[left.range.upperBound..<right.range.lowerBound]
            return !separator.isEmpty && separator.allSatisfy { $0.isWhitespace && !$0.isNewline }
        }
    }

    private struct InitialismEndingSite {
        let term: String
        let span: Range<Int>
        let left: [String]
        let right: [String]
    }

    private static func initialismEndingSite(in original: String, retry: Retry) -> InitialismEndingSite? {
        guard !retry.endingSites.isEmpty, !hasLetterDictation(original),
              !(retry.neighbors.preceding + retry.neighbors.following).contains(where: hasLetterDictation) else { return nil }
        let source = tokens(original)
        guard source.count >= 5, isMostlyRussian(source) else { return nil }
        var sites: [InitialismEndingSite] = []
        for index in 2..<(source.count - 2) {
            let text = source[index].text
            guard let term = retry.endingSites[text] else { continue }
            let combined = term + "M"
            let span = index..<(index + 1)
            guard !retry.competingEndings.contains(combined),
                  !hasCompetingInitialism(combined, in: source, outside: span),
                  !hasDirectLetterDictation(before: source[index].range.lowerBound, in: original),
                  safe(span, in: source, text: original),
                  let (left, right) = anchors(around: span, in: source), matches(in: source, left: left, right: right) == [span] else { continue }
            sites.append(InitialismEndingSite(term: term, span: span, left: left, right: right))
        }
        return sites.count == 1 ? sites.first : nil
    }

    private static func endingStem(_ text: String) -> String? {
        guard text.hasSuffix("М"), text == text.uppercased(), text.allSatisfy(\.isLetter),
              let stem = String(text.dropLast()).applyingTransform(.toLatin, reverse: false),
              isLatinInitialism(stem) else { return nil }
        return stem
    }

    private static func hearsSeparateInitialismLetters(_ text: String, site: InitialismEndingSite) -> Bool {
        let evidence = tokens(text)
        let expected = site.term.map(String.init)
        guard MeetingSpeechText.accepts(text), isMostlyRussian(evidence) else { return false }
        let aligned = matches(in: evidence, left: site.left, right: site.right, maximumWidth: expected.count + 1)
        guard aligned.count == 1, let span = aligned.first, span.count == expected.count + 1,
              let last = evidence[span].last, ["M", "m", "М", "м"].contains(last.text),
              evidence[span].dropLast().map(\.text) == expected,
              !hasCompetingInitialism(site.term + "M", in: evidence, outside: span) else { return false }
        let letterRange = range(in: evidence, span)
        guard !TranscriptOrthography.literalRanges(in: text).contains(where: {
            NSIntersectionRange($0, NSRange(letterRange, in: text)).length > 0
        }) else { return false }
        return zip(evidence[span], evidence[span].dropFirst()).allSatisfy { left, right in
            let separator = text[left.range.upperBound..<right.range.lowerBound]
            return !separator.isEmpty && separator.allSatisfy { $0.isWhitespace && !$0.isNewline }
        }
    }

    private static let initialismHomoglyphs: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P",
        "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J", "Ѕ": "S",
    ]

    private static func foldedInitialism(_ text: String) -> String {
        String(text.prefix(while: { $0 != "'" && $0 != "’" }).uppercased().map { initialismHomoglyphs[$0] ?? $0 })
    }

    private static func hasCompetingInitialism(_ combined: String, in words: [Token], outside span: Range<Int>) -> Bool {
        words.indices.contains { !span.contains($0) && foldedInitialism(words[$0].text) == combined }
    }

    private static func initialismSpellings(_ texts: [String]) -> Set<String> {
        Set(texts.flatMap(tokens).map { foldedInitialism($0.text) }.filter {
            (3...7).contains($0.count) && $0.utf8.allSatisfy { (65...90).contains($0) }
        })
    }

    private static let letterDictation = try! NSRegularExpression(pattern:
        #"(?i)\b(?:по\s+буквам|продиктуй(?:те)?|(?:введи(?:те)?|нажми(?:те)?|набери(?:те)?|напечатай(?:те)?)\b[^\n.!?…]{0,60}\b(?:клавиш\p{L}*|букв(?:а|у|ы|ами|ах|ам)|символ\p{L}*|enter|esc(?:ape)?|shift|ctrl|alt|tab|backspace))\b"#)

    private static func hasLetterDictation(_ text: String) -> Bool {
        letterDictation.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let directLetterDictation = try! NSRegularExpression(pattern:
        #"(?i)\b(?:введи|набери|нажми|напечатай|напиши|вставь|впиши|продиктуй)(?:те)?\b[\p{Zs}\t,:—–-]*(?:(?:пожалуйста|сейчас|затем|сначала)\b[\p{Zs}\t,:—–-]*){0,2}$"#)

    private static func hasDirectLetterDictation(before target: String.Index, in text: String) -> Bool {
        directLetterDictation.firstMatch(in: text, range: NSRange(text.startIndex..<target, in: text)) != nil
    }

    static func reconcilePhoneticBoundary(original: String, corroboration: String, unprompted: [String],
                                          retry: Retry, vocabulary: String) -> String? {
        guard unprompted.count == 2, unprompted.allSatisfy({ !retry.isNeighborEcho($0) }) else { return nil }
        let source = tokens(original), acoustic = tokens(corroboration), lexicon = terms(in: vocabulary)
        var edits: [(Range<String.Index>, String)] = []
        for term in retry.terms where retry.phoneticTerms.contains(term) && isLatinInitialism(term) {
            let leads = phoneticKeys(term, term: term).filter { $0.count >= 2 && isRussianWord($0) }
            for span in phoneticBoundarySites(in: original, corroboration: corroboration, term: term) {
                guard preservesTerms(source, span, text: original, lexicon: lexicon, replacing: term),
                      let (left, right) = anchors(around: span, in: source) else { continue }
                let aligned = matches(in: acoustic, left: left, right: right)
                guard aligned.count == 1, let heard = aligned.first, heard.count == 2,
                      safe(heard, in: acoustic, text: corroboration) else { continue }
                let prep = acoustic[heard.lowerBound], word = acoustic[heard.lowerBound + 1]
                let observations = unprompted.compactMap { text -> String? in
                    let words = tokens(text), aligned = matches(in: words, left: left, right: right)
                    guard aligned.count == 1, let match = aligned.first, safe(match, in: words, text: text) else { return nil }
                    return String(text[range(in: words, match)])
                }
                guard observations.count == 2, observations.allSatisfy({
                    phoneticBoundary($0, term: term, preposition: prep.text, word: word.text, sameInitial: false)
                }), observations.contains(where: { text in
                    phoneticKeys(text, term: term).contains { observed in
                        leads.contains { observed.hasPrefix($0) && observed.count >= $0.count + 3 }
                    }
                }) else { continue }
                edits.append((range(in: source, span), term + " " + prep.text + " " + word.text))
            }
        }
        guard edits.count == 1, let (span, replacement) = edits.first else { return nil }
        var result = original
        result.replaceSubrange(span, with: replacement)
        return result
    }

    /// A contextual phonetic match can schedule a probe. It cannot supply
    /// the missing acronym when the independent recognizer heard only the preposition.
    private static func phoneticBoundarySites(in original: String, corroboration: String, term: String) -> [Range<Int>] {
        let source = tokens(original), acoustic = tokens(corroboration)
        guard acoustic.count >= 6 else { return [] }
        return (2..<(acoustic.count - 3)).compactMap { index in
            let span = index..<(index + 2)
            let preposition = acoustic[index], word = acoustic[index + 1]
            guard boundaryPrepositions.contains(preposition.key), isRussianWord(word.text),
                  safe(span, in: acoustic, text: corroboration),
                  let (left, right) = anchors(around: span, in: acoustic),
                  matches(in: acoustic, left: left, right: right) == [span] else { return nil }
            let aligned = matches(in: source, left: left, right: right)
            guard aligned.count == 1, let old = aligned.first, old.count <= 2,
                  safe(old, in: source, text: original),
                  phoneticBoundary(String(original[range(in: source, old)]), term: term,
                                   preposition: preposition.text, word: word.text) else { return nil }
            return old
        }
    }

    private static func phoneticBoundary(_ previous: String, term: String, preposition: String, word: String,
                                         sameInitial: Bool = true) -> Bool {
        let old = tokens(previous)
        guard old.count <= 2, let tail = old.last, isRussianWord(tail.text), tail.key != word.lowercased(),
              let tailDistance = phoneticDistance(tail.text, preposition + " " + word, term: term, sameInitial: false),
              tailDistance <= 4,
              let distance = phoneticDistance(previous, term + " " + preposition + " " + word, term: term, sameInitial: sameInitial) else { return false }
        return distance <= 3
    }

    private static func ordinaryNumericSpan(_ range: Range<String.Index>, in text: String) -> Bool {
        let literalMarkers = "/\\@_#~`"
        let before = text[..<range.lowerBound].last
        let after = text[range.upperBound...].first
        return !(before.map { literalMarkers.contains($0) } ?? false)
            && !(after.map { literalMarkers.contains($0) } ?? false)
            && !text[range].contains(where: literalMarkers.contains)
    }

    /// The first pass already supplies the ending; the independent decode
    /// supplies the complete number and base. A fresh acoustic candidate must
    /// confirm that same ending. Only a single doubled stem consonant may be
    /// removed, never arbitrary phonetic substitutions or numeral changes.
    private static func primarySupportsNumericEnding(previous: String, proposed: String, heard: String?,
                                                       term: String, lexicon: [String]) -> Bool {
        guard let numerals = RecognitionVocabulary.numericForms(for: term), let heard,
              let proposedForm = AbbreviationFamilies.parse(RecognitionVocabulary.apply(to: proposed, vocabulary: term), as: term),
              AbbreviationFamilies.caseEndings.contains(proposedForm.ending),
              let heardForm = AbbreviationFamilies.parse(RecognitionVocabulary.apply(to: heard, vocabulary: term), as: term),
              heardForm.ending.isEmpty,
              !lexicon.contains(where: { $0 != term && isTermForm(previous, of: $0) }),
              previous.allSatisfy({ $0.isLetter || $0.isNumber || " \t-‐‑'’".contains($0) }) else { return false }
        let digits = String(term.prefix(while: \.isNumber))
        let prefixes = ([digits] + numerals).sorted { $0.count > $1.count }
        let lower = previous.lowercased()
        let ending = proposedForm.ending
        let aliases = AbbreviationFamilies.aliases(for: term).map { String($0.dropFirst(digits.count)).lowercased() }
        for prefix in prefixes where lower.hasPrefix(prefix) {
            var tail = String(lower.dropFirst(prefix.count))
            tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: " \t-‐‑"))
            guard tail.hasSuffix(ending) else { continue }
            var stem = String(tail.dropLast(ending.count))
            if stem.last == "'" || stem.last == "’" { stem.removeLast() }
            if aliases.contains(stem) { return true }
            let letters = Array(stem)
            guard letters.count >= 2 else { continue }
            for index in 1..<letters.count where letters[index] == letters[index - 1]
                && "бвгджзйклмнпрстфхцчшщbcdfghjklmnpqrstvwxyz".contains(letters[index]) {
                var shortened = letters
                shortened.remove(at: index)
                if aliases.contains(String(shortened)) { return true }
            }
        }
        return false
    }

    private static func supportedEdit(previous: String, proposed: String, heard: String?, term: String,
                                      established: Bool, candidateIsAcoustic: Bool,
                                      phoneticBoundaryEstablished: Bool, boundaryEvidence: [String],
                                      complementaryNumericEnding: Bool) -> String? {
        if isTermForm(proposed, of: term) {
            let canonical = RecognitionVocabulary.numericForms(for: term) != nil
                ? RecognitionVocabulary.apply(to: proposed, vocabulary: term) : proposed
            guard let heard else { return nil }
            if isTermForm(heard, of: term) {
                return equivalentForm(heard, canonical, term: term) || complementaryNumericEnding ? canonical : nil
            }
            // Neither the first-pass wording nor a text proposal can replace
            // an independent observation of the ambiguous span.
            guard candidateIsAcoustic,
                  RecognitionVocabulary.numericForms(for: term) != nil || isLatinInitialism(term),
                  let score = phoneticScore(heard, canonical, term: term, allowOmittedNumeral: false) else { return nil }
            let complementary = isBareNumericStem(previous, form: canonical, term: term)
                && hearsNumericPrefix(heard, form: canonical, term: term)
            return score == 0 || established || complementary ? canonical : nil
        }

        // A fused spelling can preserve the initialism and blur the preposition.
        // Only join it to words from the same anchored interval of the other decode.
        guard let heard, isLatinInitialism(term) else { return nil }
        if phoneticBoundaryEstablished, !previous.hasPrefix(term) {
            let proposedWords = tokens(proposed), heardWords = tokens(heard)
            guard proposedWords.count == 3, proposedWords[0].text == term,
                  boundaryPrepositions.contains(proposedWords[1].key), isRussianWord(proposedWords[2].text),
                  phoneticBoundary(previous, term: term, preposition: proposedWords[1].text,
                                   word: proposedWords[2].text) else { return nil }
            let phrase = proposedWords.map(\.key)
            let heardExactly = heardWords.count == 3 && heardWords[0].text == term && heardWords.map(\.key) == phrase
            let heardTail = heardWords.map(\.key).elementsEqual(phrase.dropFirst())
            func exact(_ value: String) -> Bool {
                let observed = tokens(value)
                return observed.first?.text == term && observed.map(\.key) == phrase
            }
            let confirmedTwice = boundaryEvidence.count == 2 && boundaryEvidence.contains(where: exact)
                && boundaryEvidence.allSatisfy { value in
                    exact(value) || phoneticBoundary(value, term: term, preposition: proposedWords[1].text,
                                                     word: proposedWords[2].text, sameInitial: false)
                }
            guard heardExactly || (candidateIsAcoustic && heardTail && confirmedTwice) else { return nil }
            return proposed
        }
        guard previous.hasPrefix(term),
              let join = previous.dropFirst(term.count).first, "-‐‑".contains(join) else { return nil }
        let tail = RussianRecognition.words(proposed).dropFirst()
        let heardWords = RussianRecognition.words(heard)
        guard !tail.isEmpty, heardWords.count == 2, let preposition = heardWords.first,
              boundaryPrepositions.contains(preposition), tail.elementsEqual(heardWords) || tail.elementsEqual(heardWords.dropFirst()) else { return nil }
        let replacement = term + " " + heard
        guard let distance = phoneticDistance(previous, replacement, term: term), distance <= 3 else { return nil }
        return replacement
    }

    private static func excerpt(_ text: String, plainText: String, useTail: Bool) -> String? {
        guard !text.contains("<|"), !text.contains("|>") else { return nil }
        let words = plainText.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return nil }
        var selected: [Substring] = []
        var remaining = 160
        for word in useTail ? Array(words.reversed()) : words {
            guard word.count <= remaining else { break }
            selected.append(word)
            remaining -= word.count + 1
        }
        let excerpt = (useTail ? selected.reversed() : selected).joined(separator: " ")
        return MeetingSpeechText.accepts(excerpt) ? excerpt : nil
    }

    private static func withoutLiterals(_ text: String) -> String {
        let clean = NSMutableString(string: text)
        for range in TranscriptOrthography.literalRanges(in: text).reversed() {
            clean.replaceCharacters(in: range, with: " ")
        }
        return clean as String
    }

    /// The acoustic model supplies narrative quotation punctuation itself.
    /// It must not hide the words it heard. Only that evidence is unquoted;
    /// literals in the original transcript and proposed text stay protected.
    private static func acousticText(_ text: String) -> String {
        text.replacingOccurrences(of: "[«»“”]", with: " ", options: .regularExpression)
    }

    fileprivate struct Token {
        let text: String
        let key: String
        let range: Range<String.Index>
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#)
    private static let russianLetter = try! NSRegularExpression(pattern: #"\p{Cyrillic}"#)
    private static let markers: Set<String> = ["не", "ни", "нет", "нельзя", "никогда", "никто", "ничего", "нигде", "никак", "без", "или", "либо", "да", "ага", "угу"]

    private static func terms(in vocabulary: String) -> [String] {
        vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("<|") && !$0.contains("|>") }
    }

    private static func tokens(_ text: String) -> [Token] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let word = String(text[range])
            return Token(text: word, key: word.lowercased().replacingOccurrences(of: "ё", with: "е"), range: range)
        }
    }

    private static func isRussian(_ token: Token) -> Bool {
        russianLetter.firstMatch(in: token.text, range: NSRange(token.text.startIndex..., in: token.text)) != nil
    }

    private static func isRussianWord(_ text: String) -> Bool {
        text.lowercased().unicodeScalars.allSatisfy { (0x0430...0x044f).contains($0.value) || $0.value == 0x0451 }
    }

    private static func isMostlyRussian(_ tokens: [Token]) -> Bool {
        tokens.filter(isRussian).count * 2 > tokens.count
    }

    private static func anchors(around span: Range<Int>, in words: [Token]) -> ([String], [String])? {
        let left = Array(words[..<span.lowerBound].suffix(words.count - span.upperBound <= 1 ? 3 : 2).map(\.key))
        let right = Array(words[span.upperBound...].prefix(span.lowerBound <= 1 ? 3 : 2).map(\.key))
        guard (left.count == 2 && right.count == 2) || (left.count == 3 && right.isEmpty)
                || (right.count == 3 && left.isEmpty) || (left.count == 1 && right.count == 3)
                || (left.count == 3 && right.count == 1) else { return nil }
        return (left, right)
    }

    private static func matches(in words: [Token], left: [String], right: [String], maximumWidth: Int = 3) -> [Range<Int>] {
        let keys = words.map(\.key)
        return words.indices.flatMap { start -> [Range<Int>] in
            guard start >= left.count, (!left.isEmpty || start == 0),
                  keys[(start - left.count)..<start].elementsEqual(left) else { return [] }
            return (start + 1...min(start + maximumWidth, keys.count)).compactMap { end in
                guard end + right.count <= keys.count, (!right.isEmpty || end == keys.count),
                      keys[end..<(end + right.count)].elementsEqual(right) else { return nil }
                return start..<end
            }
        }
    }

    private static func range(in words: [Token], _ span: Range<Int>) -> Range<String.Index> {
        words[span.lowerBound].range.lowerBound..<words[span.upperBound - 1].range.upperBound
    }

    private static func safe(_ span: Range<Int>, in words: [Token], text: String) -> Bool {
        let range = range(in: words, span)
        let nsRange = NSRange(range, in: text)
        guard !TranscriptOrthography.literalRanges(in: text).contains(where: { NSIntersectionRange($0, nsRange).length > 0 }),
              text[range].allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace || "-‐‑'’".contains($0) }),
              words[span].allSatisfy({ !$0.key.allSatisfy(\.isNumber) && !markers.contains($0.key) }) else { return false }
        let neighbors = words[max(0, span.lowerBound - 2)..<min(words.count, span.upperBound + 2)]
        guard neighbors.filter(isRussian).count >= 2 else { return false }
        for index in span where !isRussian(words[index]) {
            let lower = max(0, index - 2), upper = min(words.count, index + 3)
            for start in lower..<min(index + 1, upper - 2) where start + 2 >= index {
                if words[start..<(start + 3)].allSatisfy({ $0.text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) } }) {
                    return false
                }
            }
        }
        return true
    }

    private static func preservesTerms(_ words: [Token], _ span: Range<Int>, text: String,
                                       lexicon: [String], replacing term: String? = nil) -> Bool {
        for other in lexicon where other != term {
            let width = tokens(other).count
            guard width > 0, width <= words.count else { continue }
            for start in max(0, span.lowerBound - width + 1)...min(span.upperBound - 1, words.count - width) {
                let wordSpan = start..<(start + width)
                if isTermForm(String(text[range(in: words, wordSpan)]), of: other) { return false }
            }
        }
        return true
    }

    private static func occurrenceCount(of term: String, in text: String, words: [Token]) -> Int {
        let width = tokens(term).count
        guard width > 0, words.count >= width else { return 0 }
        return (0...(words.count - width)).filter { start in
            RecognitionVocabulary.contains(term, in: String(text[range(in: words, start..<(start + width))]))
        }.count
    }

    private static func isTermForm(_ value: String, of term: String) -> Bool {
        let canonical = RecognitionVocabulary.apply(to: value, vocabulary: term)
        return tokens(canonical).count == tokens(term).count && RecognitionVocabulary.contains(term, in: canonical)
    }

    private static let numericEndings = ["ами", "ом", "ам", "ах", "ов", "а", "у", "е", "ы"]

    /// Some decodes retain an exact uppercase stem while dropping a vowel from
    /// the numeral before it. This is a local candidate, never an orthography rule.
    private static func contractedNumericForm(_ value: String, lexicon: [String]) -> (term: String, form: String)? {
        guard value.contains(where: \.isLowercase), value.dropFirst().contains(where: \.isUppercase) else { return nil }
        let vowels = "аеёиоуыэюя"
        let proposals = Set(lexicon).compactMap { term -> (term: String, form: String, base: String)? in
            guard let numerals = RecognitionVocabulary.numericForms(for: term) else { return nil }
            let acronym = String(term.drop(while: \.isNumber))
            guard let stem = value.range(of: acronym) else { return nil }
            let prefix = value[..<stem.lowerBound]
            guard prefix.count >= 2, prefix != prefix.uppercased() else { return nil }
            let suffix = value[stem.upperBound...]
            let ending = suffix.first == "'" || suffix.first == "’" ? suffix.dropFirst() : suffix
            guard suffix.isEmpty || numericEndings.contains(String(ending)) else { return nil }
            let folded = prefix.lowercased().replacingOccurrences(of: "ё", with: "е")
            let reduced = numerals.contains { numeral in
                guard numeral.count == folded.count + 1 else { return false }
                return numeral.indices.contains { index in
                    guard vowels.contains(numeral[index]) else { return false }
                    var shortened = numeral
                    shortened.remove(at: index)
                    return shortened.replacingOccurrences(of: "ё", with: "е") == folded
                }
            }
            guard reduced else { return nil }
            return (term, ending.isEmpty ? term : term + "'" + ending, String(value[..<stem.upperBound]))
        }
        guard proposals.count == 1, let proposal = proposals.first,
              !lexicon.contains(where: { $0 != proposal.term &&
                  ($0.caseInsensitiveCompare(proposal.base) == .orderedSame || isTermForm(value, of: $0)) }) else { return nil }
        return (proposal.term, proposal.form)
    }

    private static func establishesTerm(_ term: String, in text: String) -> Bool {
        if RecognitionVocabulary.contains(term, in: RecognitionVocabulary.apply(to: text, vocabulary: term)) { return true }
        // Product variants can retain the exact digit and acronym but glue a
        // lowercase descriptor to it. A longer uppercase acronym is separate.
        guard RecognitionVocabulary.numericForms(for: term) != nil, term.drop(while: \.isNumber).count >= 3 else { return false }
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: term) + #"\p{Ll}{2,}(?![\p{L}\p{N}])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func equivalentForm(_ first: String, _ second: String, term: String) -> Bool {
        let left = RecognitionVocabulary.apply(to: first, vocabulary: term)
        let right = RecognitionVocabulary.apply(to: second, vocabulary: term)
        return RussianRecognition.words(left) == RussianRecognition.words(right)
    }

    private static let initialismSounds: [Character: String] = [
        "A": "эй", "B": "би", "C": "си", "D": "ди", "E": "и", "F": "эф", "G": "джи", "H": "эйч", "I": "ай",
        "J": "джей", "K": "кей", "L": "эл", "M": "эм", "N": "эн", "O": "оу", "P": "пи", "Q": "кью", "R": "ар",
        "S": "эс", "T": "ти", "U": "ю", "V": "ви", "W": "даблъю", "X": "икс", "Y": "вай", "Z": "зед",
    ]

    private static func isLatinInitialism(_ term: String) -> Bool {
        (2...6).contains(term.count) && term.allSatisfy { initialismSounds[$0] != nil }
    }

    private static func isWrittenInitialism(_ text: String) -> Bool {
        (2...6).contains(text.count) && text.allSatisfy(\.isLetter) && text == text.uppercased()
            && text.utf8.contains { (65...90).contains($0) }
    }

    private static func hintForms(for term: String) -> [String] {
        if RecognitionVocabulary.numericForms(for: term) != nil { return ["ом", "е", "а", "у", ""].map { $0.isEmpty ? term : term + "'" + $0 } }
        if isLatinInitialism(term) {
            return ["ем", "ом", "е", "ки", ""].map { $0.isEmpty ? term : term + "'" + $0 }
        }
        // A known Cyrillic name may have a consonant omitted in its current
        // decode. Derived case forms can locate a reread, but never authorize
        // fuzzy replacement: supportedEdit still requires an exact independent
        // observation for ordinary names.
        if term.count >= 5, term == term.capitalized, isRussianWord(term) {
            return RecognitionVocabulary.cyrillicInflections(of: term)
        }
        return []
    }

    private static func phoneticKeys(_ text: String, term: String) -> Set<String> {
        let parts = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let pronunciations = parts.map { word -> [String] in
            if word == term, let numerals = RecognitionVocabulary.numericForms(for: term) {
                return numerals.map { $0 + term.drop(while: \.isNumber) }
            }
            let latin = word.applyingTransform(.toLatin, reverse: false) ?? String(word)
            if word == word.uppercased(), (2...6).contains(latin.count), latin.allSatisfy({ initialismSounds[$0] != nil }) {
                return [String(word), latin.compactMap { initialismSounds[$0] }.joined()]
            }
            return [String(word)]
        }
        let alternatives = pronunciations.reduce([""]) { accumulated, next in
            accumulated.flatMap { prefix in next.map { prefix + $0 } }
        }
        let folded: [Character: Character] = ["о": "а", "ы": "и", "э": "и", "е": "и", "ё": "и", "г": "к", "д": "т", "з": "с", "б": "п", "в": "ф"]
        return Set(alternatives.map { value in
            String(value.lowercased().filter { !"ьъй".contains($0) }.map { folded[$0] ?? $0 })
        })
    }

    private static func phoneticDistance(_ first: String, _ second: String, term: String, sameInitial: Bool = true) -> Int? {
        let left = phoneticKeys(first, term: term), right = phoneticKeys(second, term: term)
        return left.flatMap { a in right.compactMap { b in
            guard min(a.count, b.count) >= 4, !sameInitial || a.first == b.first else { return nil }
            return editDistance(a, b)
        } }.min()
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        var row = Array(0...second.count)
        for (index, x) in first.enumerated() {
            var next = [index + 1]
            for (j, y) in second.enumerated() {
                next.append(min(row[j] + (x == y ? 0 : 1), row[j + 1] + 1, next[j] + 1))
            }
            row = next
        }
        return row[second.count]
    }

    private static func isBareNumericStem(_ text: String, form: String, term: String) -> Bool {
        guard RecognitionVocabulary.numericForms(for: term) != nil else { return false }
        let acronym = String(term.drop(while: \.isNumber)).lowercased()
        let ending = form.split(separator: "'").dropFirst().first.map(String.init) ?? ""
        return text.lowercased() == acronym + ending
    }

    private static func hearsNumericPrefix(_ text: String, form: String, term: String) -> Bool {
        guard let numerals = RecognitionVocabulary.numericForms(for: term),
              let score = phoneticScore(text, form, term: term, allowOmittedNumeral: false), score <= 2 else { return false }
        let acronym = String(term.drop(while: \.isNumber)).lowercased()
        let ending = form.split(separator: "'").dropFirst().first.map(String.init) ?? ""
        let stem = text.lowercased().replacingOccurrences(of: "ё", with: "е").dropLast(ending.count)
        let prefixes = numerals.map { $0.replacingOccurrences(of: "ё", with: "е") }
        if prefixes.contains(where: { stem.count > $0.count && stem.hasPrefix($0) }) { return true }

        // If the verifier kept the complete acronym, permit one phoneme of
        // reduction in the numeral. An ordinary fused affirmation is separate.
        guard stem.hasSuffix(acronym) else { return false }
        let prefix = String(stem.dropLast(acronym.count))
        guard prefix.count >= 2, !markers.contains(prefix) else { return false }
        let heard = phoneticKeys(prefix, term: term)
        return prefixes.contains { numeral in
            phoneticKeys(numeral, term: term).contains { key in
                heard.contains { $0.first == key.first && editDistance($0, key) <= 1 }
            }
        }
    }

    private static func numericEndingConflict(_ text: String, form: String, term: String) -> Bool {
        guard RecognitionVocabulary.numericForms(for: term) != nil,
              let ending = form.split(separator: "'").dropFirst().first,
              let heard = numericEndings.first(where: text.lowercased().hasSuffix), heard != ending,
              let distance = phoneticDistance(String(text.dropLast(heard.count)), term, term: term) else { return false }
        return distance <= 2
    }

    private static func phoneticScore(_ first: String, _ second: String, term: String, allowOmittedNumeral: Bool = true) -> Int? {
        guard !hintForms(for: term).isEmpty, tokens(first).count == 1 else { return nil }
        let numeral = RecognitionVocabulary.numericForms(for: term) != nil
        if numeral {
            let normalized = first.lowercased().replacingOccurrences(of: "ё", with: "е")
            let ending = second.split(separator: "'").dropFirst().first.map(String.init)
            let acronym = String(term.drop(while: \.isNumber)).lowercased()
            let heard = normalized.hasSuffix(acronym) ? nil : numericEndings.first(where: normalized.hasSuffix)
            guard ending == heard else { return nil }
            // A bare stem can justify a retry, but it cannot corroborate that
            // the numeral was spoken, even if the full entity occurs nearby.
            if normalized == acronym + (ending ?? "") { return allowOmittedNumeral ? 2 : nil }
        }
        let maximumDistance = numeral || isLatinInitialism(term) ? 3 : 2
        guard let distance = phoneticDistance(first, second, term: term), distance <= maximumDistance else { return nil }
        return distance
    }
}

extension RecognitionContext {
    /// Decode context on the same physical channel, then return only the timed
    /// words belonging to this turn. Neighbors can schedule a read, not supply
    /// replacement words. Unprompted multilingual evidence protects switches.
    struct ContextualScriptRepair {
        let source: String
        let terms: [String]
        let scriptMismatch: Bool
        let protectedKeys: Set<String>

        private static func letterRun(_ words: ArraySlice<Token>, term: String) -> Bool {
            guard (2...term.count).contains(words.count), words.allSatisfy({ $0.text.count <= 4 && ($0.text.count == 1 || $0.text != $0.text.uppercased()) }) else { return false }
            let spelling = words.map(\.key).joined().replacingOccurrences(of: "і", with: "и")
            var endings: Set<String> = [spelling]
            for letter in term {
                guard let sound = RecognitionContext.initialismSounds[letter] else { return false }
                var forms = [String(letter).lowercased(), sound]
                // A clipped consonant may replace the letter name ("ти" → "т").
                if sound.count == 2, sound.last == "и" { forms.append(String(sound.prefix(1))) }
                endings = Set(endings.flatMap { rest in
                    forms.compactMap { rest.hasPrefix($0) ? String(rest.dropFirst($0.count)) : nil }
                })
                if endings.isEmpty { return false }
            }
            return endings.contains("")
        }

        fileprivate static func runs(in words: [Token], text: String, term: String) -> [Range<Int>] {
            guard words.count >= 2 else { return [] }
            return (0..<(words.count - 1)).flatMap { start -> [Range<Int>] in
                (2...min(term.count, words.count - start)).compactMap { length in
                    let span = start..<start + length
                    guard letterRun(words[span], term: term),
                          text[RecognitionContext.range(in: words, span)].allSatisfy({
                              $0.isLetter || $0.isWhitespace || $0 == "-"
                          }) else { return nil }
                    return span
                }
            }
        }

        private func normalized(_ text: String) -> [String] {
            var words = RecognitionContext.tokens(text)
            for term in terms {
                let matches = Self.runs(in: words, text: text, term: term)
                guard matches.count == 1, let match = matches.first else { continue }
                let range = RecognitionContext.range(in: words, match)
                words.replaceSubrange(match, with: [Token(text: term, key: term.lowercased(), range: range)])
            }
            return words.map(\.key)
        }

        private static func containsOnce(_ phrase: [String], in text: [String]) -> Bool {
            guard !phrase.isEmpty, phrase.count <= text.count else { return false }
            return (0...(text.count - phrase.count)).filter { text[$0..<($0 + phrase.count)].elementsEqual(phrase) }.count == 1
        }

        struct IsolatedReading {
            let acoustic: RecognitionAcousticResult
            let verifier: String
            let language: String?
        }

        /// Recover only the beginning of a turn. Agreement later in a padded
        /// window can come from the next utterance, even on the same channel.
        func timedPrefix(acoustic: RecognitionAcousticResult, target: Range<Double>, primary: String,
                         verifier: String, language: String?, exact: () -> IsolatedReading?,
                         exactPrimary: () -> String) -> String? {
            guard scriptMismatch, terms.isEmpty, language?.lowercased() == "russian",
                  RussianRecognition.isCyrillicSpeech(source),
                  !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(verifier) else { return nil }
            let tokens = RecognitionContext.tokens(acoustic.text)
            guard tokens.map(\.text) == acoustic.words.map(\.text),
                  let first = acoustic.words.firstIndex(where: {
                      $0.start >= target.lowerBound - 0.15 && $0.end > target.lowerBound
                  }), acoustic.words[first].start <= target.lowerBound + 0.3 else { return nil }
            let indices = acoustic.words.indices[first...].prefix { acoustic.words[$0].start < target.upperBound - 0.03 }
            let keys = indices.map { tokens[$0].key }
            let wide = [normalized(primary), normalized(verifier)]
            guard keys.count >= 2, let width = (2...keys.count).reversed().first(where: { count in
                let prefix = Array(keys.prefix(count))
                return prefix.allSatisfy(RecognitionContext.isRussianWord) && wide.allSatisfy { Self.containsOnce(prefix, in: $0) }
            }), let core = exact(), core.language?.lowercased() == "russian",
                  !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(core.verifier),
                  !BackchannelLanguage.confirmsCyrillicSource(original: source, reread: core.verifier, language: core.language)
            else { return nil }
            let narrow = core.acoustic.words, narrowKeys = normalized(core.acoustic.text)
            guard !narrow.isEmpty, RecognitionContext.tokens(core.acoustic.text).map(\.text) == narrow.map(\.text) else { return nil }
            let checked = normalized(core.verifier)
            var independentPrimary: [String]?
            func supports(_ i: Int, in reading: [String]) -> Bool {
                // An exact crop can omit its first short word. Anchor each
                // match with an adjacent word, allowing a one-word displacement.
                for a in [i - 1, i] where a >= 0 && a + 1 < width {
                    let pair = Array(keys[a...a+1])
                    if Self.containsOnce(pair, in: reading), reading.indices.contains(where: {
                        abs($0 - a) <= 1 && reading[$0...].starts(with: pair)
                    }) { return true }
                }
                return false
            }
            var count = 0
            for i in 0..<width {
                let word = acoustic.words[first + i], middle = (word.start + word.end) / 2 - target.lowerBound
                let sites = narrow.indices.filter { abs((narrow[$0].start + narrow[$0].end) / 2 - middle) <= 0.25 }
                let same = sites.contains { narrowKeys[$0] == keys[i] }
                let qwen = supports(i, in: checked)
                if !same || !qwen {
                    if independentPrimary == nil { independentPrimary = normalized(exactPrimary()) }
                    guard supports(i, in: independentPrimary ?? []) else { break }
                }
                if !same {
                    guard qwen, keys[i].count >= 4, i > 0, i + 1 < keys.count, sites.contains(where: { j in
                        j > 0 && j + 1 < narrow.count && narrowKeys[j - 1] == keys[i - 1] && narrowKeys[j + 1] == keys[i + 1]
                            && narrowKeys[j].count == keys[i].count && narrowKeys[j].prefix(2) == keys[i].prefix(2)
                            && RecognitionContext.editDistance(keys[i], narrowKeys[j]) <= 2
                    }) else { break }
                }
                count += 1
            }
            let original = RecognitionContext.tokens(source), kept = Array(keys.prefix(count))
            guard count >= 2 else { return nil }
            let common = min(count, original.count)
            let edits = (0..<common).filter { i in
                let old = original[i].key
                let folded = old.replacingOccurrences(of: "і", with: "и").replacingOccurrences(of: "є", with: "е")
                    .replacingOccurrences(of: "ї", with: "и")
                return ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(old) && min(old.count, kept[i].count) >= 3
                    && !protectedKeys.contains(old) && !TranscriptTerms.isKnownEntityForm(old)
                    && RecognitionContext.editDistance(folded, kept[i]) <= min(2, kept[i].count / 2)
            }
            guard let edit = edits.first else { return nil }
            let last = first + count - 1
            let strong = count >= 4 && count * 3 >= max(original.count, narrow.count) * 2
                && acoustic.words[last].end - max(target.lowerBound, acoustic.words[first].start)
                    >= (target.upperBound - target.lowerBound) * 2 / 3
            if strong, count < narrow.count, count <= original.count + 3 {
                let names = Set(original.enumerated().filter { i, token in
                    token.text.first?.isUppercase == true && (i > 0 || TranscriptTerms.isKnownEntityForm(token.key)
                        || (token.key.count >= 3 && !TranscriptTerms.isCommonRussianWord(token.key)))
                }.map { $0.element.key })
                let important: (String) -> Bool = { key in
                    protectedKeys.contains(key) || names.contains(key) || RecognitionContext.markers.contains(key)
                        || key == "ні" || RecognitionConsensus.isNumberWord(key) || key.contains(where: \.isNumber)
                }
                let old = original.map(\.key), attested = Set(wide.flatMap { $0 } + checked + narrowKeys)
                let retain = old.filter { important($0) || ($0.count >= 3 && attested.contains($0)) }
                var remaining = kept[...]
                guard old.filter(important) == kept.filter(important) else { return nil }
                for word in retain {
                    guard let index = remaining.firstIndex(of: word) else { return nil }
                    remaining = remaining[remaining.index(after: index)...]
                }
                let range = RecognitionContext.range(in: tokens, first..<(last + 1))
                var prefix = String(acoustic.text[range])
                if source.first?.isUppercase == true { prefix = prefix.prefix(1).uppercased() + prefix.dropFirst() }
                return prefix + "…"
            }
            // A short opening licenses a spelling edit only at its own source
            // position. Keep the rest, even if the two wider decoders diverge.
            guard edits.count == 1, count <= original.count,
                  (0..<count).allSatisfy({ $0 == edit || original[$0].key == kept[$0] }),
                  !RecognitionContext.markers.contains(kept[edit]), !RecognitionConsensus.isNumberWord(kept[edit]),
                  original[edit].text.first?.isLowercase == true else { return nil }
            return source.replacingCharacters(in: original[edit].range, with: kept[edit])
        }

        // The acoustic decoder can skip a short word beside a run of spelled
        // letters. Keep it only if both multilingual reads agree on the full
        // phrase. A one-letter competing abbreviation does not change the
        // term backed by the timed acoustic word, source letters and primary.
        private func restoredModifier(phrase: String, primary: [String], verifier: String) -> String? {
            guard terms.count == 1, let term = terms.first else { return nil }
            let words = RecognitionContext.tokens(phrase), keys = words.map(\.key), base = term.lowercased()
            guard let t = words.firstIndex(where: { $0.text == term }), t > 0, t + 1 < words.count,
                  keys.filter({ $0 == base }).count == 1, keys.count >= 3 else { return nil }
            let variants = Set(RecognitionContext.tokens(verifier).map(\.text).filter {
                RecognitionContext.isLatinInitialism($0) && RecognitionContext.editDistance($0, term) == 1
            })
            var checked = normalized(verifier)
            for i in checked.indices where variants.contains(checked[i].uppercased()) { checked[i] = base }
            let modifiers = primary.indices.compactMap { i -> String? in
                guard primary[i] == base, i > 0 else { return nil }
                let word = primary[i - 1]
                guard RecognitionContext.isRussianWord(word), TranscriptTerms.isCommonRussianWord(word),
                      (2...10).contains(word.count), !RecognitionContext.markers.contains(word), word != "вряд",
                      word != keys[t - 1] else { return nil }
                var expanded = keys
                expanded.insert(word, at: t)
                guard Self.containsOnce(expanded, in: primary), Self.containsOnce(expanded, in: checked) else { return nil }
                return word
            }
            guard modifiers.count == 1, let modifier = modifiers.first else { return nil }
            var result = phrase
            result.insert(contentsOf: modifier + " ", at: words[t].range.lowerBound)
            return result
        }

        private func anchoredWord(sourceTokens: [Token], timed: ArraySlice<RecognitionTimedWord>,
                                  primary: [String], verifier: [String],
                                  confirm: (Range<Double>) -> (text: String, language: String?)?) -> String? {
            let distinctive = sourceTokens.indices.filter { ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(sourceTokens[$0].text) }
            guard distinctive.count == 1, let pos = distinctive.first, pos >= 2, pos + 2 < sourceTokens.count else { return nil }
            let old = sourceTokens[pos], sourceKeys = sourceTokens.map(\.key)
            guard old.text.first?.isLowercase == true, !protectedKeys.contains(old.key) else { return nil }
            let left = sourceKeys[(pos - 2)..<pos], right = sourceKeys[(pos + 1)...(pos + 2)]
            func site(in keys: [String]) -> Int? {
                guard keys.count >= 5 else { return nil }
                let matches = (2..<(keys.count - 2)).filter { i in
                    keys[(i - 2)..<i].elementsEqual(left) && keys[(i + 1)...(i + 2)].elementsEqual(right)
                }
                return matches.count == 1 ? matches.first : nil
            }
            let acoustic = timed.map { $0.text.lowercased().replacingOccurrences(of: "ё", with: "е") }
            guard site(in: sourceKeys) == pos, let center = site(in: acoustic),
                  let p = site(in: primary), let v = site(in: verifier) else { return nil }
            let word = acoustic[center], i = timed.startIndex + center
            guard primary[p] == word, verifier[v] == word, RecognitionContext.isRussianWord(word),
                  !RecognitionContext.markers.contains(word), word.count >= 4, old.key.prefix(4) == word.prefix(4),
                  RecognitionContext.editDistance(old.key, word) <= 2 else { return nil }
            let start = timed[i - 1].start, end = timed[i + 1].end
            guard start.isFinite, end.isFinite, end > start, let local = confirm(start..<end),
                  local.language?.lowercased() == "russian", !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(local.text),
                  Self.containsOnce(Array(acoustic[(center - 1)...(center + 1)]), in: normalized(local.text)) else { return nil }
            return source.replacingCharacters(in: old.range, with: timed[i].text.lowercased())
        }

        func revised(acoustic: RecognitionAcousticResult, target: Range<Double>,
                     primary: String, verifier: String, language: String?,
                     isolated: (text: String, language: String?)? = nil,
                     confirmWord: ((Range<Double>) -> (text: String, language: String?)?)? = nil) -> String? {
            guard language?.lowercased() == "russian", !acoustic.words.isEmpty,
                  target.lowerBound.isFinite, target.upperBound.isFinite else { return nil }
            if let isolated, let detected = isolated.language?.lowercased(),
               !detected.isEmpty, detected != "russian" { return nil }
            if let isolated, BackchannelLanguage.confirmsCyrillicSource(original: source,
                reread: isolated.text, language: isolated.language) { return nil }
            let tokens = RecognitionContext.tokens(acoustic.text)
            guard tokens.map(\.text) == acoustic.words.map(\.text) else { return nil }
            // RNNT token emission can precede the diarized onset by a fraction
            // of a second; a word must also extend into the actual speech.
            let indices = acoustic.words.indices.filter {
                let word = acoustic.words[$0]
                return word.start >= target.lowerBound - 0.25 && word.start < target.upperBound - 0.03
                    && word.end > target.lowerBound
            }
            guard let first = indices.first, let last = indices.last, indices.count == last - first + 1 else { return nil }
            let span = first..<(last + 1)
            let phrase = String(acoustic.text[RecognitionContext.range(in: tokens, span)])
            let keys = normalized(phrase)
            let checked = normalized(verifier), multilingual = normalized(primary)
            let originals = normalized(source)
            let isolatedAgreement = isolated.map { reading in
                reading.language?.lowercased() == "russian" && originals.count == keys.count
                    && normalized(reading.text) == keys
            } ?? false
            let supported = Self.containsOnce(keys, in: checked) || isolatedAgreement
            let negations = RecognitionContext.markers
            let anchored = originals.contains { old in keys.contains { new in
                let folded = old.replacingOccurrences(of: "і", with: "и")
                return (folded.count >= 3 && folded == new)
                    || (min(folded.count, new.count) >= 4 && folded.prefix(4) == new.prefix(4))
            } }
            let completed = scriptMismatch && !supported
                ? restoredModifier(phrase: phrase, primary: multilingual, verifier: verifier) : nil
            // Collapse letter runs before comparing lengths. A clipped decode can
            // agree verbatim across models while omitting part of the turn.
            if scriptMismatch, anchored, originals.filter(negations.contains) == keys.filter(negations.contains),
               originals.filter(protectedKeys.contains) == keys.filter(protectedKeys.contains),
               keys.count >= 2, keys.count * 3 >= originals.count * 2, keys.count <= originals.count + 3,
               !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(phrase),
               completed != nil || supported || (Self.containsOnce(keys, in: multilingual)
                    && !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(verifier)
                    && !terms.isEmpty),
               RussianRecognition.words(source) != keys {
                var result = completed ?? phrase
                if source.first?.isUppercase == true, let first = result.first, first.isLowercase {
                    result = first.uppercased() + result.dropFirst()
                }
                if let last = source.last, ".!?…".contains(last) { result.append(last) }
                return result
            }
            let sourceTokens = RecognitionContext.tokens(source)
            if scriptMismatch, terms.isEmpty, let confirmWord,
               let word = anchoredWord(sourceTokens: sourceTokens, timed: acoustic.words[span],
                                       primary: multilingual, verifier: checked, confirm: confirmWord) { return word }
            // The rest of the sentence can disagree while the locally spelled
            // acronym is independently supported at this time.
            guard terms.count == 1, let term = terms.first, tokens[span].filter({ $0.text == term }).count == 1,
                  normalized(primary).contains(term.lowercased()) || checked.contains(term.lowercased()),
                  let match = Self.runs(in: sourceTokens, text: source, term: term).first else { return nil }
            return source.replacingCharacters(in: RecognitionContext.range(in: sourceTokens, match), with: term)
        }
    }

    func scriptRepair(for target: TranscriptSegment, vocabulary: String, neighbors knownNeighbors: Neighbors? = nil) -> ContextualScriptRepair? {
        let text = target.text, duration = target.end - target.start
        guard (0.45...9).contains(duration), !Self.hasLetterDictation(text),
              TranscriptOrthography.literalRanges(in: text).isEmpty, !text.contains(where: \.isNumber) else { return nil }
        let words = Self.tokens(text)
        guard (2...18).contains(words.count) else { return nil }
        let script = ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(text)
        // An independent multilingual reading of the isolated turn already
        // confirmed this spelling. Neighbors can be in a different language.
        if script, target.independentRecognitionLanguage == true || target.speakerEvidenceIsMixed == true
            || byEnd[partition(byEnd) { $0.end <= target.start }...].contains(where: {
                $0.segment.id != target.id && $0.segment.audioFile == target.audioFile && $0.segment.start < target.end
            }) { return nil }
        let split = zip(words, words.dropFirst()).contains { a, b in
            min(a.text.count, b.text.count) == 1 && max(a.text.count, b.text.count) <= 3
                && (a.text.first?.isUppercase == true || b.text.first?.isUppercase == true)
        }
        guard script || split else { return nil }
        let nearby = knownNeighbors ?? neighbors(around: target)
        let excerpts = nearby.preceding + nearby.following
        guard excerpts.contains(where: BackchannelLanguage.isRussianContext),
              !excerpts.contains(where: Self.hasLetterDictation) else { return nil }
        let dictionary = Self.terms(in: vocabulary)
        let possible = Set(dictionary + excerpts.flatMap { Self.tokens($0).map(\.text) })
        let terms = possible.filter { $0.count >= 3 && Self.isLatinInitialism($0)
            && ContextualScriptRepair.runs(in: words, text: text, term: $0).count == 1 }
        guard terms.count <= 1, script || terms.count == 1 else { return nil }
        let sourceKeys = words.map(\.key)
        let writtenTerms = dictionary.flatMap { term -> [String] in
            let keys = Self.tokens(term).map(\.key)
            return !keys.isEmpty && keys.count <= sourceKeys.count && (0...(sourceKeys.count - keys.count)).contains { offset in
                sourceKeys[offset..<(offset + keys.count)].elementsEqual(keys)
            } ? keys : []
        }
        // Preserve names even when they have never appeared in the dictionary.
        let latinWords = words.filter { $0.text.range(of: #"\p{Latin}"#, options: .regularExpression) != nil }
        return ContextualScriptRepair(source: text, terms: Array(terms), scriptMismatch: script,
                                      protectedKeys: Set(writtenTerms + latinWords.map(\.key)))
    }
}
