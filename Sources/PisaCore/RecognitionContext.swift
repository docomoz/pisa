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

    private let byStart: [TranscriptSegment]
    private let byEnd: [TranscriptSegment]

    init(segments: [TranscriptSegment], preceding: [TranscriptSegment] = []) {
        let current = Set(segments.map(\.id))
        byStart = segments.sorted { $0.start < $1.start }
        byEnd = (segments + preceding.filter { !current.contains($0.id) }).sorted { $0.end < $1.end }
    }

    func neighbors(around target: TranscriptSegment) -> Neighbors {
        let previous = byEnd.reversed().lazy.drop(while: { $0.end > target.start })
            .prefix(while: { $0.end >= target.start - 60 })
            .filter { $0.id != target.id }
            .compactMap { Self.excerpt($0.text, useTail: true) }
            .prefix(5)
        let next = byStart.lazy.drop(while: { $0.start < target.end })
            .prefix(while: { $0.start <= target.end + 45 })
            .filter { $0.id != target.id }
            .compactMap { Self.excerpt($0.text, useTail: false) }
            .prefix(4)
        return Neighbors(preceding: previous.reversed(), following: Array(next))
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
              let next = byStart.lazy.drop(while: { $0.start < target.end })
                .prefix(while: { $0.start <= target.end + 0.35 })
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
              spokenVocabulary: SpokenVocabulary) -> Retry? {
        let source = Self.withoutLiterals(target.text)
        let words = Self.tokens(source)
        guard words.count >= 4, Self.isMostlyRussian(words) else { return nil }
        let acoustic = spokenVocabulary.apply(to: Self.withoutLiterals(independent ?? ""))
        let acousticWords = Self.tokens(acoustic)
        let shared = Set(words.map(\.key)).intersection(acousticWords.map(\.key))
        let observed = (words + acousticWords).filter { token in
            // Agreeing ordinary words are poor candidates for a speculative
            // retry. A mixed-script or Latin acronym can still encode a case.
            !shared.contains(token.key) || Self.isWrittenInitialism(token.text)
        }
        let neighbors = neighbors(around: target)
        let earlier = byEnd.reversed().lazy.drop(while: { $0.end > target.start })
            .prefix(while: { $0.end >= target.start - 300 })
        let later = byStart.lazy.drop(while: { $0.start < target.end })
            .prefix(while: { $0.start <= target.end + 300 })
        func distance(_ segment: TranscriptSegment) -> Double {
            max(target.start - segment.end, segment.start - target.end)
        }
        let surrounding = (Array(earlier.prefix(40)) + Array(later.prefix(40))).filter { $0.id != target.id }
        let entityContext = surrounding.filter { distance($0) <= 120 }.map { Self.withoutLiterals($0.text) }
        let exactMentions = Set(surrounding.flatMap { Self.tokens(Self.withoutLiterals($0.text)) }.map(\.text))
        let lexicon = Self.terms(in: vocabulary)
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
            let possibleMisses = observed.filter { !Self.isTermForm($0.text, of: term) }.map(\.text)
            let near = forms.compactMap { form -> (String, Int)? in
                let score = possibleMisses.compactMap { Self.phoneticScore($0, form, term: term) }.min()
                return score.map { (form, $0) }
            }.sorted { $0.1 < $1.1 }
            let established = entityContext.contains { Self.establishesTerm(term, in: $0) }
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
        var inserted = Set<String>()
        let hints = focused.flatMap { [$0.term] + $0.forms }.filter { inserted.insert($0).inserted }.joined(separator: ", ")
        let context = [hints, neighbors.preceding.joined(separator: "\n"), neighbors.following.joined(separator: "\n")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let endingTerms = Set(endingSites.values).intersection(focused.map(\.term))
        var competingEndings = Set<String>()
        if !endingTerms.isEmpty {
            endingSites = endingSites.filter { endingTerms.contains($0.value) && exactMentions.contains($0.value) }
            competingEndings = Self.initialismSpellings(surrounding.map(\.text) + lexicon)
        }
        return Retry(hints: hints, context: context, terms: focused.map(\.term),
                     established: Set(focused.filter(\.established).map(\.term)),
                     phoneticTerms: Set(focused.map(\.term)).intersection(exactMentions), neighbors: neighbors,
                     endingSites: endingSites, competingEndings: competingEndings)
    }

    private static func targetSpans(in original: String, corroboration: String?, retry: Retry) -> [Range<String.Index>] {
        let source = tokens(original), acoustic = tokens(corroboration ?? "")
        let shared = Set(source.map(\.key)).intersection(acoustic.map(\.key))
        var choices: [Range<Int>: Int] = [:]
        for term in retry.terms {
            let forms = hintForms(for: term)
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
            text.replacingOccurrences(of: #"(?i)(?<![\p{L}\p{N}])э(?:[-‐‑]э)+(?![\p{L}\p{N}])"#,
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
                        phoneticBoundaryEstablished: retry.phoneticTerms.contains(term), boundaryEvidence: confirmations)
                }
                guard let replacement else { continue }
                if !edits.contains(where: { $0.0 == sourceRange && $0.1 == replacement }) {
                    edits.append((sourceRange, replacement))
                }
            }
        }
        guard edits.count == 1, let (range, replacement) = edits.first else { return nil }
        var revised = original
        revised.replaceSubrange(range, with: replacement)
        return revised
    }

    static func isWordRichShortTurn(_ text: String, duration: Double) -> Bool {
        (0.85..<2).contains(duration) && (4...6).contains(RussianRecognition.words(text).count)
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
        guard left.isEmpty || right.isEmpty else { return true }
        let anchor = left.isEmpty ? right : left
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

    private static func supportedEdit(previous: String, proposed: String, heard: String?, term: String,
                                      established: Bool, candidateIsAcoustic: Bool,
                                      phoneticBoundaryEstablished: Bool, boundaryEvidence: [String]) -> String? {
        if isTermForm(proposed, of: term) {
            let canonical = RecognitionVocabulary.numericForms(for: term) != nil
                ? RecognitionVocabulary.apply(to: proposed, vocabulary: term) : proposed
            guard let heard else { return nil }
            if isTermForm(heard, of: term) {
                return equivalentForm(heard, canonical, term: term) ? canonical : nil
            }
            // Neither the first-pass wording nor a text proposal can replace
            // an independent observation of the ambiguous span.
            guard candidateIsAcoustic,
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

    private static func excerpt(_ text: String, useTail: Bool) -> String? {
        guard !text.contains("<|"), !text.contains("|>") else { return nil }
        let words = withoutLiterals(text).split(whereSeparator: \.isWhitespace)
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

    private struct Token {
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
        let left = Array(words[..<span.lowerBound].suffix(span.upperBound == words.count ? 3 : 2).map(\.key))
        let right = Array(words[span.upperBound...].prefix(span.lowerBound == 0 ? 3 : 2).map(\.key))
        guard (left.count == 2 && right.count == 2) || (left.count == 3 && right.isEmpty)
                || (right.count == 3 && left.isEmpty) else { return nil }
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
                                       lexicon: [String], replacing term: String) -> Bool {
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
        guard let distance = phoneticDistance(first, second, term: term), distance <= 3 else { return nil }
        return distance
    }
}
