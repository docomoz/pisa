import Observation
import SwiftUI

struct TermReview: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting

    struct ReviewInput: Equatable, Sendable {
        let segments: [TranscriptSegment]
        let vocabulary: String

        func indexSegments() -> [UUID: TranscriptSegment] {
            Dictionary(segments.lazy.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    @MainActor
    @Observable
    final class CandidateList {
        struct Snapshot {
            let input: ReviewInput
            let candidates: [TermCandidate]
            let segmentsByID: [UUID: TranscriptSegment]
        }

        enum Change {
            case replacement([TermOccurrence], String)
            case dictionaryAddition(String)
            case undo
        }

        private(set) var snapshot: Snapshot?

        @ObservationIgnored private var requestedInput: ReviewInput?
        @ObservationIgnored private var worker: Task<Void, Never>?
        @ObservationIgnored private var pending: [(Change, ReviewInput)] = []
        @ObservationIgnored private var beforeReplacement: Snapshot?

        func snapshot(for input: ReviewInput) -> Snapshot? {
            guard snapshot?.input == input else { return nil }
            return snapshot
        }

        func apply(_ change: Change, from previous: ReviewInput, to input: ReviewInput) {
            guard previous != input else { return }
            guard requestedInput == previous else {
                prepare(input)
                return
            }
            if case .undo = change, beforeReplacement?.input != input,
               !pending.contains(where: { change, _ in
                   if case .replacement = change { return true }
                   return false
               }) {
                prepare(input)
                return
            }
            requestedInput = input
            if let snapshot {
                self.snapshot = updated(snapshot, applying: change, to: input)
            } else {
                // Manual search can finish while the first candidate scan is
                // still running. Apply the same edits before showing its result.
                pending.append((change, input))
            }
        }

        private func updated(_ snapshot: Snapshot, applying change: Change, to input: ReviewInput) -> Snapshot {
            switch change {
            case let .replacement(occurrences, spelling):
                beforeReplacement = snapshot
                let segments = input.indexSegments()
                let candidates = TranscriptTerms.retainingCandidates(snapshot.candidates, afterReplacing: occurrences,
                                                                    with: spelling, in: segments)
                return Snapshot(input: input, candidates: candidates, segmentsByID: segments)
            case let .dictionaryAddition(term):
                if let previous = beforeReplacement {
                    let previousInput = ReviewInput(segments: previous.input.segments, vocabulary: input.vocabulary)
                    beforeReplacement = removingKnownTerms(from: previous, added: term, input: previousInput)
                }
                return removingKnownTerms(from: snapshot, added: term, input: input)
            case .undo:
                defer { beforeReplacement = nil }
                if let beforeReplacement, beforeReplacement.input == input { return beforeReplacement }
                return snapshot
            }
        }

        private func removingKnownTerms(from snapshot: Snapshot, added term: String, input: ReviewInput) -> Snapshot {
            Snapshot(input: input, candidates: TranscriptTerms.retainingCandidates(snapshot.candidates, afterAdding: term),
                     segmentsByID: snapshot.segmentsByID)
        }

        func prepare(_ input: ReviewInput) {
            guard requestedInput != input else { return }
            requestedInput = input
            worker?.cancel()
            worker = nil
            pending.removeAll()
            beforeReplacement = nil
            snapshot = nil
            guard !input.segments.isEmpty else { return }

            worker = Task(priority: .utility) { [weak self] in
                guard let initial = await TermReview.analyze(priority: .utility, {
                    Snapshot(input: input,
                             candidates: TranscriptTerms.candidates(in: input.segments, vocabulary: input.vocabulary),
                             segmentsByID: input.indexSegments())
                }), let self else { return }
                var result = initial
                for (change, input) in pending {
                    result = updated(result, applying: change, to: input)
                }
                pending.removeAll()
                snapshot = result
                worker = nil
            }
        }

        deinit { worker?.cancel() }
    }

    private struct MatchRequest: Equatable, Sendable {
        let input: ReviewInput
        let source: String
        let selectionID: UUID
    }

    private struct Matches: Sendable {
        let request: MatchRequest
        let occurrences: [TermOccurrence]
        let segmentsByID: [UUID: TranscriptSegment]
        let spellingSamples: [TermOccurrence]
        let confirmed: Bool

        init(request: MatchRequest, occurrences: [TermOccurrence], segmentsByID: [UUID: TranscriptSegment],
             confirmed: Bool = true) {
            self.request = request
            self.occurrences = occurrences
            self.segmentsByID = segmentsByID
            self.confirmed = confirmed
            spellingSamples = confirmed ? TranscriptTerms.distinctSpellings(in: occurrences) : []
        }
    }

    @State private var candidateList: CandidateList
    @State private var matchResult: Matches?
    @State private var selectionID = UUID()
    @State private var query = ""
    @State private var source: String?
    @State private var sourceLabel: String?
    @State private var replacement = ""
    @State private var notice: String?
    @State private var replacementFocused = false
    @State private var suggestionSelection = FormSuggestionSelection()
    @State private var suggestionListFocused = false
    @State private var caretEndRequest: UUID?
    @State private var lastReplacement: (source: String, label: String?, correctedSource: String)?
    @State private var dictionary: TranscriptTerms.DictionaryAdditions?
    @State private var dictionaryTerms: [String] = []

    init(meeting: Meeting, candidateList: CandidateList? = nil) {
        self.meeting = meeting
        _candidateList = State(initialValue: candidateList ?? CandidateList())
    }

    private var currentMeeting: Meeting? {
        state.meetings.first { $0.id == meeting.id && state.canReviewTerms($0) }
    }
    private var input: ReviewInput {
        ReviewInput(segments: currentMeeting?.segments ?? [], vocabulary: state.preferences.vocabulary)
    }
    private var matchRequest: MatchRequest? {
        source.map { MatchRequest(input: input, source: $0, selectionID: selectionID) }
    }
    private var term: String { replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var suggestions: [String] {
        let term = self.term
        guard suggestionSelection.isOpen, let query = WordPrefixQuery(term) else { return [] }
        return dictionaryTerms.filter { $0 != term && query.matches($0) }
    }

    private func canReplace(_ occurrences: [TermOccurrence], with term: String) -> Bool {
        guard !term.isEmpty else { return false }
        var hasChanges = false
        for occurrence in occurrences {
            guard let replacement = TranscriptTerms.replacement(for: occurrence, with: term) else { return false }
            hasChanges = hasChanges || replacement != occurrence.text
        }
        return hasChanges
    }

    var body: some View {
        let input = self.input
        let request = matchRequest
        let candidateSnapshot = candidateList.snapshot(for: input)
        let matches = matchResult?.request == request && matchResult?.confirmed == true ? matchResult : nil
        let displayedMatches = matchResult.flatMap { previous in
            previous.request.selectionID == request?.selectionID && previous.request.source == request?.source &&
                previous.request.input.segments == input.segments ? previous : nil
        }
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            HStack(spacing: PisaDesign.Spacing.related) {
                SectionHeading("Разметка терминов", subtitle: "Проверьте написание в расшифровке и сохраните нужные слова для будущих встреч", style: .dialog)
                Spacer()
                screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction)
            }
            if let currentMeeting {
                HSplitView {
                    candidatePane(candidateSnapshot, input: input)
                        .frame(minWidth: 275, idealWidth: 300, maxWidth: 360)
                    reviewPane(in: currentMeeting, matches: matches, displayedMatches: displayedMatches).frame(minWidth: 450)
                }
                footer
            } else {
                SupportingText("Готовая расшифровка недоступна")
                Spacer()
            }
        }
        .dialogContent()
        .frame(width: 940, height: 660)
        .background(ClickToUnfocus(onEscape: {
            guard replacementFocused else { return false }
            return suggestionSelection.dismiss(matches: suggestions)
        }))
        .onChange(of: input, initial: true) { _, input in candidateList.prepare(input) }
        .onChange(of: input.vocabulary, initial: true) { _, vocabulary in
            dictionary = TranscriptTerms.DictionaryAdditions(vocabulary)
            var seen: Set<String> = []
            dictionaryTerms = VocabularyDictionary.entries(in: vocabulary).map(\.text).filter { seen.insert($0).inserted }
            suggestionSelection.close()
        }
        .task(id: request) { await refreshMatches(request) }
        .onDisappear { state.stopPlayback() }
    }

    @ViewBuilder private func candidatePane(_ snapshot: CandidateList.Snapshot?, input: ReviewInput) -> some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                SectionHeading("Поиск по тексту")
                HStack(spacing: PisaDesign.Spacing.inline) {
                    FormTextField(title: "Слово или фраза", text: $query, onSubmit: search)
                        .measuredForInterfaceTest(.termSearch)
                    screenButton("Найти", action: search).actionButton().disabled(searchTerm.isEmpty)
                        .measuredForInterfaceTest(.termFind)
                }
            }
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                SectionHeading("Кандидаты", subtitle: "Названия и необычные слова из этой расшифровки")
                if let candidates = snapshot?.candidates, !candidates.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                            ForEach(candidates) { candidate in
                                Button {
                                    select(candidate.text, label: candidate.observedLabel)
                                    guard let snapshot, input == self.input else { return }
                                    let request = MatchRequest(input: input, source: candidate.text, selectionID: selectionID)
                                    matchResult = Matches(request: request, occurrences: candidate.occurrences,
                                                          segmentsByID: snapshot.segmentsByID)
                                } label: {
                                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                                        HStack(spacing: PisaDesign.Spacing.related) {
                                            screenText(candidate.observedLabel).lineLimit(2)
                                            Spacer(minLength: 0)
                                            screenText(verbatim: String(candidate.occurrences.count))
                                                .foregroundStyle(Color.mutedInk)
                                        }
                                        if let alternatives = candidate.alternativeSpellings {
                                            SupportingText(alternatives, style: PisaDesign.Typography.caption)
                                                .lineLimit(2)
                                                .help(alternatives)
                                        }
                                    }
                                    .padding(PisaDesign.Spacing.inline)
                                    .background(source == candidate.text ? Color.selectionTint : .clear,
                                                in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                                    .contentShape(Rectangle())
                                }
                                .shapeAwarePlainButton()
                                .accessibilityAddTraits(source == candidate.text ? .isSelected : [])
                                .measuredForInterfaceTest(.termCandidate(candidate.observedLabel))
                            }
                        }
                    }
                } else if snapshot == nil {
                    SupportingText("Ищем кандидатов…")
                } else {
                    SupportingText("Кандидаты не найдены. Нужное слово можно найти вручную.")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, PisaDesign.Spacing.content)
    }

    private func reviewPane(in meeting: Meeting, matches: Matches?, displayedMatches: Matches?) -> some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            if let source {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    SectionHeading("Правильное написание", subtitle: "В тексте: «\(sourceLabel ?? source)». При замене основы аббревиатуры окончания сохраняются.")
                    replacementEditor
                    HStack(spacing: PisaDesign.Spacing.inline) {
                        screenButton("Исправить все", action: replace).actionButton(.primary)
                            .disabled(!canReplace(matches?.spellingSamples ?? [], with: term))
                            .measuredForInterfaceTest(.termApply)
                        screenButton("Добавить в словарь", action: addTerm).actionButton()
                            .disabled(dictionary?.termToAdd(term) == nil)
                            .measuredForInterfaceTest(.termAdd)
                    }
                }
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    SectionHeading("Вхождения")
                    if let matches = displayedMatches, !matches.occurrences.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.content) {
                                ForEach(matches.occurrences) { occurrence in
                                    if let segment = matches.segmentsByID[occurrence.segmentID] {
                                        occurrenceRow(occurrence, segment: segment, meeting: meeting,
                                                      showsReplacement: matches.confirmed)
                                    }
                                }
                            }
                        }
                        .id(selectionID)
                    } else if matches == nil {
                        SupportingText("Ищем вхождения…")
                    } else {
                        SupportingText("В расшифровке нет точных совпадений")
                    }
                }
            } else {
                SupportingText("Выберите кандидата или найдите слово в расшифровке")
            }
            Spacer(minLength: 0)
        }
        .overlayPreferenceValue(FormSuggestionFieldBounds.self, alignment: .topLeading) { anchor in
            FormSuggestionOverlay(anchor: anchor, matches: suggestions, selectedIndex: suggestionSelection.selectedIndex,
                                  element: InterfaceLayoutElement.termSuggestion, choose: chooseSuggestion,
                                  keyboardFocus: $suggestionListFocused, onListCommand: handleSuggestionCommand)
        }
        .padding(.leading, PisaDesign.Spacing.content)
    }

    private var replacementEditor: some View {
        // Update the suggestions in the native edit callback before any arrow or Return event.
        FormTextField(title: "Термин", text: Binding(get: { replacement }, set: { text in
            replacement = text
            suggestionListFocused = false
            suggestionSelection.open()
        }), isFocused: $replacementFocused, accessibilityTitle: "Правильное написание",
                      onSubmit: submitReplacement, onCommand: handleReplacementCommand, caretEndRequest: caretEndRequest)
            .anchorPreference(key: FormSuggestionFieldBounds.self, value: .bounds) { $0 }
            .measuredForInterfaceTest(.termReplacement)
    }

    private func handleReplacementCommand(_ command: Selector) -> Bool {
        let matches = suggestions
        if command == #selector(NSResponder.insertTab(_:)), suggestionSelection.activate(matches: matches) {
            suggestionListFocused = true
            return true
        }
        return suggestionSelection.handle(command, matches: matches)
    }

    private func handleSuggestionCommand(_ command: Selector) -> Bool {
        let matches = suggestions
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            if let suggestion = suggestionSelection.selected(in: matches) { chooseSuggestion(suggestion) }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertBacktab(_:)):
            suggestionSelection.close()
            suggestionListFocused = false
            replacementFocused = true
            return true
        default:
            return suggestionSelection.handle(command, matches: matches)
        }
    }

    private func submitReplacement() {
        if let suggestion = suggestionSelection.selected(in: suggestions) {
            chooseSuggestion(suggestion)
        } else {
            replace()
        }
    }

    private func chooseSuggestion(_ suggestion: String) {
        replacement = suggestion
        suggestionSelection.close()
        suggestionListFocused = false
        caretEndRequest = UUID()
        replacementFocused = true
    }

    private func occurrenceRow(_ occurrence: TermOccurrence, segment: TranscriptSegment, meeting: Meeting,
                               showsReplacement: Bool) -> some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
            HStack(spacing: PisaDesign.Spacing.related) {
                screenText("\(timecode(segment.start)) · \(segment.speaker)")
                Spacer(minLength: 0)
                if !meeting.audioFiles.isEmpty {
                    screenButton(state.playingSegmentID == segment.id ? "Остановить" : "Послушать") {
                        state.play(segment, in: meeting)
                    }.actionButton(size: .small).disabled(state.recording || state.demo)
                }
            }
            context(occurrence, segment: segment)
                .textStyle(PisaDesign.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if showsReplacement, !term.isEmpty {
                if let preview = TranscriptTerms.replacement(for: occurrence, with: term) {
                    if occurrence.text != preview {
                        SupportingText("«\(occurrence.text)» → «\(preview)»", style: PisaDesign.Typography.caption)
                    }
                } else {
                    SupportingText("Для «\(occurrence.text)» нельзя сохранить окончание с этой заменой", style: PisaDesign.Typography.caption)
                }
            }
        }
    }

    private func context(_ occurrence: TermOccurrence, segment: TranscriptSegment) -> Text {
        guard let range = Range(occurrence.range, in: segment.text) else { return screenText(segment.text) }
        let before = segment.text[..<range.lowerBound]
        let after = segment.text[range.upperBound...]
        let left = (before.count > 80 ? "…" : "") + before.suffix(80)
        let right = String(after.prefix(100)) + (after.count > 100 ? "…" : "")
        let word = screenText(searchMatch: String(segment.text[range]))
        return Text("\(screenText(left))\(word)\(screenText(right))")
    }

    private var footer: some View {
        HStack(spacing: PisaDesign.Spacing.related) {
            if let notice { SupportingText(notice) }
            Spacer(minLength: 0)
            if state.canUndoTermReplacement(meetingID: meeting.id) {
                screenButton("Отменить исправление", action: undo).actionButton()
                    .measuredForInterfaceTest(.termUndo)
            }
        }
    }

    private func search() {
        guard currentMeeting != nil, !searchTerm.isEmpty else { return }
        select(searchTerm)
    }

    private func select(_ text: String, label: String? = nil) {
        suggestionSelection.close()
        selectionID = UUID()
        source = text
        sourceLabel = label
        replacement = text
        notice = nil
    }

    private func refreshMatches(_ request: MatchRequest?) async {
        guard let request, !request.input.segments.isEmpty else { return }
        if matchResult?.request == request, matchResult?.confirmed == true { return }
        guard let matches = await Self.analyze({
            let input = request.input
            let occurrences = TranscriptTerms.matches(request.source, in: input.segments, vocabulary: input.vocabulary)
            return Matches(request: request, occurrences: occurrences, segmentsByID: input.indexSegments())
        }), request == matchRequest else { return }
        matchResult = matches
    }

    private nonisolated static func analyze<Result: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () -> Result
    ) async -> Result? {
        guard !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: priority, operation: work)
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        return Task.isCancelled ? nil : result
    }

    private func replace() {
        let corrected = term
        guard let matches = matchResult, matches.request == matchRequest, matches.confirmed,
              canReplace(matches.spellingSamples, with: corrected) else { return }
        let occurrences = matches.occurrences
        let chosen = occurrences.filter { TranscriptTerms.replacement(for: $0, with: corrected) != $0.text }
        do {
            let original = source
            let correctedSource = TranscriptTerms.replacementSearchTerm(for: occurrences, with: corrected)
            try state.replaceTerms(chosen, with: corrected, meetingID: meeting.id)
            let updated = input
            candidateList.apply(.replacement(occurrences, corrected), from: matches.request.input, to: updated)
            let segments = candidateList.snapshot(for: updated)?.segmentsByID ?? updated.indexSegments()
            let correctedSpans = TranscriptTerms.correctedOccurrences(occurrences, with: corrected, in: segments)
            matchResult = Matches(request: MatchRequest(input: updated, source: correctedSource, selectionID: selectionID),
                                  occurrences: correctedSpans, segmentsByID: segments, confirmed: false)
            if let original { lastReplacement = (original, sourceLabel, correctedSource) }
            source = correctedSource
            sourceLabel = nil
            replacement = corrected
            suggestionSelection.close()
            replacementFocused = false
            notice = "Исправлено: \(chosen.count)"
        } catch { notice = error.localizedDescription }
    }

    private func undo() {
        do {
            let previous = input
            try state.undoTermReplacement(meetingID: meeting.id)
            suggestionSelection.close()
            candidateList.apply(.undo, from: previous, to: input)
            if let lastReplacement, source == lastReplacement.correctedSource {
                source = lastReplacement.source
                sourceLabel = lastReplacement.label
                replacement = lastReplacement.source
            }
            lastReplacement = nil
            notice = "Исправление отменено"
        } catch { notice = error.localizedDescription }
    }

    private func addTerm() {
        do {
            let previous = input
            let added = TranscriptTerms.dictionaryTerm(term)
            try state.addRecognitionTerm(term)
            candidateList.apply(.dictionaryAddition(added), from: previous, to: input)
            notice = "«\(added)» добавлен в словарь"
        } catch { notice = error.localizedDescription }
    }
}
