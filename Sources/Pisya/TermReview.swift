import SwiftUI

struct TermReview: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting

    @State private var candidates: [TermCandidate] = []
    @State private var segmentsByID: [UUID: TranscriptSegment] = [:]
    @State private var query = ""
    @State private var source: String?
    @State private var occurrences: [TermOccurrence] = []
    @State private var selectedIDs: Set<String> = []
    @State private var replacement = ""
    @State private var notice: String?

    private var currentMeeting: Meeting? {
        state.meetings.first { $0.id == meeting.id && state.canReviewTerms($0) }
    }
    private var term: String { replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canReplace: Bool {
        !term.isEmpty && occurrences.contains { selectedIDs.contains($0.id) && $0.text != term }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                SectionHeading("Разметка терминов", subtitle: "Проверьте написание в расшифровке и сохраните нужные слова для будущих встреч", style: .dialog)
                Spacer()
                screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction)
            }
            if let currentMeeting {
                HSplitView {
                    candidatePane.frame(minWidth: 275, idealWidth: 300, maxWidth: 360)
                    reviewPane(in: currentMeeting).frame(minWidth: 450)
                }
                footer
            } else {
                SupportingText("Готовая расшифровка недоступна")
                Spacer()
            }
        }
        .dialogContent()
        .frame(width: 940, height: 660)
        .onAppear { refresh() }
        .onChange(of: currentMeeting?.segments) { refresh() }
        .onChange(of: state.preferences.vocabulary) { refreshCandidates() }
        .onDisappear { state.stopPlayback() }
    }

    private var candidatePane: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                SectionHeading("Поиск по тексту")
                HStack(spacing: PisyaDesign.Spacing.inline) {
                    TextField("Слово или фраза", text: $query)
                        .textFieldStyle(PisyaTextFieldStyle())
                        .onSubmit(search)
                    screenButton("Найти", action: search).actionButton(size: .small).disabled(searchTerm.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                SectionHeading("Кандидаты", subtitle: "Названия и необычные слова из этой расшифровки")
                if candidates.isEmpty {
                    SupportingText("Кандидаты не найдены. Нужное слово можно найти вручную.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.compact) {
                            ForEach(candidates) { candidate in
                                Button {
                                    select(candidate.text, occurrences: candidate.occurrences)
                                } label: {
                                    HStack(spacing: PisyaDesign.Spacing.related) {
                                        screenText(candidate.text).lineLimit(2)
                                        Spacer(minLength: 0)
                                        screenText(verbatim: String(candidate.occurrences.count))
                                            .foregroundStyle(Color.mutedInk)
                                    }
                                    .padding(PisyaDesign.Spacing.inline)
                                    .background(source == candidate.text ? Color.selectionTint : .clear,
                                                in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                                    .contentShape(Rectangle())
                                }
                                .shapeAwarePlainButton()
                                .accessibilityAddTraits(source == candidate.text ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, PisyaDesign.Spacing.content)
    }

    private func reviewPane(in meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            if let source {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                    SectionHeading("Правильное написание", subtitle: "В тексте: «\(source)»")
                    TextField("Термин", text: $replacement).textFieldStyle(PisyaTextFieldStyle())
                        .accessibilityLabel("Правильное написание")
                    screenButton("Добавить в словарь", action: addTerm).actionButton()
                        .disabled(TranscriptTerms.adding(term, to: state.preferences.vocabulary) == state.preferences.vocabulary)
                }
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                    SectionHeading("Вхождения")
                    if occurrences.isEmpty {
                        SupportingText("В расшифровке нет точных совпадений")
                    } else {
                        HStack(spacing: PisyaDesign.Spacing.related) {
                            SupportingText("Выбрано \(selectedIDs.count) из \(occurrences.count)", style: PisyaDesign.Typography.caption)
                            Spacer()
                            if selectedIDs.count == occurrences.count {
                                screenButton("Снять выбор") { selectedIDs.removeAll() }.actionButton(size: .small)
                            } else {
                                screenButton("Выбрать все") { selectedIDs = Set(occurrences.map(\.id)) }.actionButton(size: .small)
                            }
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
                                ForEach(occurrences) { occurrence in
                                    if let segment = segmentsByID[occurrence.segmentID] {
                                        occurrenceRow(occurrence, segment: segment, meeting: meeting)
                                    }
                                }
                            }
                        }
                        .id(source)
                    }
                }
                screenButton("Исправить выбранные", action: replace).actionButton(.primary)
                    .disabled(!canReplace)
            } else {
                SupportingText("Выберите кандидата или найдите слово в расшифровке")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, PisyaDesign.Spacing.content)
    }

    private func occurrenceRow(_ occurrence: TermOccurrence, segment: TranscriptSegment, meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenToggle("\(timecode(segment.start)) · \(segment.speaker)", isOn: Binding(
                    get: { selectedIDs.contains(occurrence.id) },
                    set: { if $0 { selectedIDs.insert(occurrence.id) } else { selectedIDs.remove(occurrence.id) } }
                ))
                Spacer(minLength: 0)
                if !meeting.audioFiles.isEmpty {
                    screenButton(state.playingSegmentID == segment.id ? "Остановить" : "Послушать") {
                        state.play(segment, in: meeting)
                    }.actionButton(size: .small).disabled(state.recording || state.demo)
                }
            }
            context(occurrence, segment: segment)
                .textStyle(PisyaDesign.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if selectedIDs.contains(occurrence.id), !term.isEmpty, occurrence.text != term {
                SupportingText("«\(occurrence.text)» → «\(term)»", style: PisyaDesign.Typography.caption)
            }
        }
    }

    private func context(_ occurrence: TermOccurrence, segment: TranscriptSegment) -> Text {
        guard let range = Range(occurrence.range, in: segment.text) else { return screenText(segment.text) }
        let before = segment.text[..<range.lowerBound]
        let after = segment.text[range.upperBound...]
        let left = (before.count > 80 ? "…" : "") + before.suffix(80)
        let right = String(after.prefix(100)) + (after.count > 100 ? "…" : "")
        let word = screenText(segment.text[range].description).bold().foregroundColor(.moss)
        return Text("\(screenText(left))\(word)\(screenText(right))")
    }

    private var footer: some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            if let notice { SupportingText(notice) }
            Spacer(minLength: 0)
            if state.canUndoTermReplacement(meetingID: meeting.id) {
                screenButton("Отменить исправление", action: undo).actionButton()
            }
        }
    }

    private func search() {
        guard let currentMeeting, !searchTerm.isEmpty else { return }
        select(searchTerm, occurrences: TranscriptTerms.matches(searchTerm, in: currentMeeting.segments))
    }

    private func select(_ text: String, occurrences: [TermOccurrence]) {
        source = text
        replacement = text
        self.occurrences = occurrences
        selectedIDs.removeAll()
        notice = nil
    }

    private func refresh() {
        let segments = currentMeeting?.segments ?? []
        segmentsByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        refreshCandidates()
        if let source { occurrences = TranscriptTerms.matches(source, in: segments) }
        selectedIDs.removeAll()
    }

    private func refreshCandidates() {
        candidates = TranscriptTerms.candidates(in: currentMeeting?.segments ?? [], vocabulary: state.preferences.vocabulary)
    }

    private func replace() {
        let chosen = occurrences.filter { selectedIDs.contains($0.id) && $0.text != term }
        guard !chosen.isEmpty else { return }
        do {
            try state.replaceTerms(chosen, with: term, meetingID: meeting.id)
            selectedIDs.removeAll()
            notice = "Исправлено: \(chosen.count)"
        } catch { notice = error.localizedDescription }
    }

    private func undo() {
        do {
            try state.undoTermReplacement(meetingID: meeting.id)
            notice = "Исправление отменено"
        } catch { notice = error.localizedDescription }
    }

    private func addTerm() {
        do {
            try state.addRecognitionTerm(term)
            notice = "«\(term)» добавлен в словарь"
        } catch { notice = error.localizedDescription }
    }
}
