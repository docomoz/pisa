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
        private(set) var snapshot: (input: ReviewInput, candidates: [TermCandidate])?

        @ObservationIgnored private var requestedInput: ReviewInput?
        @ObservationIgnored private var worker: Task<Void, Never>?

        func prepare(_ input: ReviewInput, after delay: Duration = .zero) {
            guard requestedInput != input else { return }
            requestedInput = input
            worker?.cancel()
            worker = nil
            guard !input.segments.isEmpty, snapshot?.input != input else { return }

            worker = Task(priority: .utility) { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let candidates = await TermReview.analyze(priority: .utility, {
                    TranscriptTerms.candidates(in: input.segments, vocabulary: input.vocabulary)
                }), !Task.isCancelled else { return }
                self?.snapshot = (input, candidates)
                self?.worker = nil
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
    }

    @State private var candidateList: CandidateList
    @State private var matchResult: Matches?
    @State private var selectionID = UUID()
    @State private var query = ""
    @State private var source: String?
    @State private var replacement = ""
    @State private var rememberVariant = false
    @State private var variantInput = ""
    @State private var notice: String?
    @State private var replacementFocused = false
    @State private var lastReplacement: (source: String, correctedSource: String, remembered: Bool)?

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
    private var term: String {
        let spelling = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rememberVariant else { return spelling }
        return VocabularyDictionary.canonicalSpelling(for: spelling, in: state.preferences.vocabulary)
    }
    private func dictionarySuggestion(for spelling: String) -> String? {
        guard rememberVariant, !spelling.isEmpty else { return nil }
        let entries = VocabularyDictionary.entries(in: state.preferences.vocabulary)
        guard !entries.contains(where: { $0.text == spelling }) else { return nil }
        return entries.first {
            $0.text.range(of: spelling, options: [.anchored, .caseInsensitive]) != nil
        }?.text
    }
    private var hasVariantInput: Bool {
        !variantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        let candidateSnapshot = candidateList.snapshot
        let matches = matchResult?.request == request ? matchResult : nil
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            HStack(spacing: PisaDesign.Spacing.related) {
                SectionHeading("Разметка терминов", subtitle: "Проверьте написание в расшифровке и сохраните нужные слова для будущих встреч", style: .dialog)
                Spacer()
                screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction)
            }
            if let currentMeeting {
                HSplitView {
                    candidatePane(candidateSnapshot?.candidates, input: input,
                                  snapshotIsCurrent: candidateSnapshot?.input == input)
                        .frame(minWidth: 275, idealWidth: 300, maxWidth: 360)
                    reviewPane(in: currentMeeting, matches: matches).frame(minWidth: 450)
                }
                footer
            } else {
                SupportingText("Готовая расшифровка недоступна")
                Spacer()
            }
        }
        .dialogContent()
        .frame(width: 940, height: 660)
        .background(ClickToUnfocus())
        .onChange(of: input, initial: true) { _, input in candidateList.prepare(input) }
        .task(id: request) { await refreshMatches(request) }
        .onDisappear { state.stopPlayback() }
    }

    private func candidatePane(_ candidates: [TermCandidate]?, input: ReviewInput,
                               snapshotIsCurrent: Bool) -> some View {
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
                if let candidates, !candidates.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                            ForEach(candidates) { candidate in
                                Button {
                                    select(candidate.text)
                                    // A visible row can predate the current transcript or dictionary.
                                    // In that case the selection's search task will find fresh ranges.
                                    guard snapshotIsCurrent, input == self.input else { return }
                                    let request = MatchRequest(input: input, source: candidate.text, selectionID: selectionID)
                                    matchResult = Matches(request: request, occurrences: candidate.occurrences,
                                                          segmentsByID: input.indexSegments())
                                } label: {
                                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                                        HStack(spacing: PisaDesign.Spacing.related) {
                                            screenText(candidate.text).lineLimit(2)
                                            Spacer(minLength: 0)
                                            screenText(verbatim: String(candidate.occurrences.count))
                                                .foregroundStyle(Color.mutedInk)
                                        }
                                        let forms = Array(Set(candidate.occurrences.map(\.text))).sorted()
                                        if Set(forms.map { $0.lowercased() }).count > 1 {
                                            SupportingText(forms.joined(separator: ", "), style: PisaDesign.Typography.caption)
                                                .lineLimit(2)
                                                .help(forms.joined(separator: ", "))
                                        }
                                    }
                                    .padding(PisaDesign.Spacing.inline)
                                    .background(source == candidate.text ? Color.selectionTint : .clear,
                                                in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                                    .contentShape(Rectangle())
                                }
                                .shapeAwarePlainButton()
                                .accessibilityAddTraits(source == candidate.text ? .isSelected : [])
                            }
                        }
                    }
                } else if candidates == nil {
                    SupportingText("Ищем кандидатов…")
                } else {
                    SupportingText("Кандидаты не найдены. Нужное слово можно найти вручную.")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, PisaDesign.Spacing.content)
    }

    private func reviewPane(in meeting: Meeting, matches: Matches?) -> some View {
        let spelling = term
        return VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            if let source {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    SectionHeading("Правильное написание", subtitle: "В тексте: «\(source)». При замене основы аббревиатуры окончания сохраняются.")
                    FormTextField(title: "Термин", text: $replacement, isFocused: $replacementFocused,
                                  accessibilityTitle: "Правильное написание", onSubmit: replace)
                        .measuredForInterfaceTest(.termReplacement)
                    if let suggestion = dictionarySuggestion(for: spelling) {
                        screenButton("Выбрать \(suggestion)") { replacement = suggestion }
                            .actionButton(size: .small)
                    }
                    let occurrences = matches?.occurrences ?? []
                    let canCorrect = canReplace(occurrences, with: spelling)
                    if !occurrences.isEmpty || rememberVariant {
                        screenToggle("Запомнить для будущих встреч", isOn: rememberBinding(for: occurrences))
                            .measuredForInterfaceTest(.termRemember)
                    }
                    if rememberVariant {
                        VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                            SupportingText("Варианты распознавания", style: PisaDesign.Typography.caption)
                            FormTextField(title: "Через запятую", text: $variantInput,
                                          accessibilityTitle: "Варианты распознавания", onSubmit: replace)
                                .measuredForInterfaceTest(.termVariant)
                        }
                    }
                    HStack(spacing: PisaDesign.Spacing.inline) {
                        screenButton(rememberVariant ? "Исправить и запомнить" : "Исправить все", action: replace)
                            .actionButton(.primary)
                            .disabled(!canCorrect || (rememberVariant && !hasVariantInput))
                            .measuredForInterfaceTest(.termApply)
                        if !canCorrect, !rememberVariant {
                            screenButton("Добавить в словарь", action: addTerm).actionButton()
                                .disabled(TranscriptTerms.adding(term, to: state.preferences.vocabulary) == state.preferences.vocabulary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    SectionHeading("Вхождения")
                    if let matches, !matches.occurrences.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.content) {
                                ForEach(matches.occurrences) { occurrence in
                                    if let segment = matches.segmentsByID[occurrence.segmentID] {
                                        occurrenceRow(occurrence, segment: segment, meeting: meeting, spelling: spelling)
                                    }
                                }
                            }
                        }
                        .id(source)
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
        .padding(.leading, PisaDesign.Spacing.content)
    }

    private func rememberBinding(for occurrences: [TermOccurrence]) -> Binding<Bool> {
        Binding(get: { rememberVariant }, set: { enabled in
            if enabled {
                variantInput = occurrences.first { $0.text.caseInsensitiveCompare(term) != .orderedSame }?.text
                    ?? occurrences.first?.text ?? ""
            }
            rememberVariant = enabled
            notice = nil
        })
    }

    private func occurrenceRow(_ occurrence: TermOccurrence, segment: TranscriptSegment, meeting: Meeting,
                               spelling: String) -> some View {
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
            if !spelling.isEmpty {
                if let preview = TranscriptTerms.replacement(for: occurrence, with: spelling) {
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
            }
        }
    }

    private func search() {
        guard currentMeeting != nil, !searchTerm.isEmpty else { return }
        select(searchTerm)
    }

    private func select(_ text: String) {
        selectionID = UUID()
        source = text
        replacement = text
        rememberVariant = false
        variantInput = ""
        notice = nil
    }

    private func refreshMatches(_ request: MatchRequest?) async {
        guard let request, !request.input.segments.isEmpty, matchResult?.request != request else { return }
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
        guard let matches = matchResult, matches.request == matchRequest,
              canReplace(matches.occurrences, with: corrected),
              !rememberVariant || hasVariantInput else { return }
        let occurrences = matches.occurrences
        let chosen = occurrences.filter { TranscriptTerms.replacement(for: $0, with: corrected) != $0.text }
        do {
            let original = source
            let correctedSource = TranscriptTerms.replacementSearchTerm(for: occurrences, with: corrected)
            try state.replaceTerms(chosen, with: corrected, meetingID: meeting.id,
                                   remembering: rememberVariant ? variantInput : nil)
            if let original { lastReplacement = (original, correctedSource, rememberVariant) }
            source = correctedSource
            replacement = corrected
            replacementFocused = false
            notice = rememberVariant ? "Исправлено: \(chosen.count). Варианты сохранены в словаре."
                : "Исправлено: \(chosen.count)"
            rememberVariant = false
            variantInput = ""
        } catch { notice = error.localizedDescription }
    }

    private func undo() {
        do {
            try state.undoTermReplacement(meetingID: meeting.id)
            if let lastReplacement, source == lastReplacement.correctedSource {
                source = lastReplacement.source
                replacement = lastReplacement.source
            }
            rememberVariant = false
            variantInput = ""
            notice = lastReplacement?.remembered == true
                ? "Исправление отменено. Варианты сохранены в словаре."
                : "Исправление отменено"
            lastReplacement = nil
        } catch { notice = error.localizedDescription }
    }

    private func addTerm() {
        do {
            try state.addRecognitionTerm(term)
            notice = "«\(TranscriptTerms.dictionaryTerm(term))» добавлен в словарь"
        } catch { notice = error.localizedDescription }
    }
}
