import SwiftUI
import AppKit

private struct SelectableVoiceName: NSViewRepresentable {
    let name: String
    @Environment(\.appTextScale) private var textScale

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: name)
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.focusRingType = .none
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = name
        field.font = .systemFont(ofSize: PisyaDesign.Typography.bodyStrong.size * textScale, weight: .semibold)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.intrinsicContentSize.width
        return nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
    }
}

struct VoiceManager: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    let meetingID: UUID
    @State private var selected: UUID?
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var showSuggestions = false
    @State private var selectedSuggestion: Int?
    @State private var lastChosenName: String?
    @State private var allMatching = true
    @State private var remember = true
    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }
    private var sample: TranscriptSegment? {
        meeting?.segments.first { $0.id == selected && $0.speaker != TranscriptSegment.unidentifiedSpeaker }
    }
    private var canApplyName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var suggestions: [String] {
        guard showSuggestions else { return [] }
        return voiceNameSuggestions(query: name, meetingNames: meeting?.segments.map(\.speaker) ?? [], savedNames: state.voiceProfiles.map(\.name))
    }
    private var automaticSample: TranscriptSegment? {
        guard let meeting, let selected else { return nil }
        return state.voiceSample(for: selected, in: meeting, allMatching: allMatching)
    }
    private func select(_ segment: TranscriptSegment) {
        showSuggestions = false
        selectedSuggestion = nil
        name = voiceNameForSelection(currentID: selected, currentName: name, segment: segment)
        lastChosenName = name
        selected = segment.id
    }

    private func chooseSuggestion(_ suggestion: String) {
        lastChosenName = suggestion
        name = suggestion
        showSuggestions = false
        selectedSuggestion = nil
        nameFocused = true
    }

    private func dismissSuggestions() -> Bool {
        guard nameFocused, !suggestions.isEmpty else { return false }
        showSuggestions = false
        selectedSuggestion = nil
        return true
    }

    private func applyName() {
        guard canApplyName, let selected else { return }
        showSuggestions = false
        selectedSuggestion = nil
        state.assignVoice(meetingID: meetingID, segmentID: selected, name: name, allMatching: allMatching, remember: remember && automaticSample != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            HStack(spacing: PisyaDesign.Spacing.inline) { SectionHeading("Голоса встречи", subtitle: "Послушайте фрагмент, назначьте имя и сохраните образец для следующих встреч", style: .dialog); Spacer(); screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        if let meeting {
                            ForEach(voiceGroupAnchors(in: meeting.segments)) { anchor in
                                LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                    SelectableVoiceName(name: anchor.speaker)
                                    ForEach(voiceSamples(for: anchor.speaker, in: meeting.segments)) { segment in
                                        fragmentCard(segment, in: meeting)
                                    }
                                }
                            }
                        }
                    }.padding(.trailing, PisyaDesign.Spacing.section)
                }.frame(minWidth: 340)
                ScrollView {
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        if let sample {
                            let automaticSample = automaticSample
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                SectionHeading("Кто говорит?", subtitle: "Фрагмент \(timecode(sample.start)) · сейчас «\(sample.speaker)»")
                                nameEditor
                            }
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                screenToggle("Все реплики «\(sample.speaker)»", isOn: $allMatching)
                                screenToggle("Запомнить голос для будущих встреч", isOn: $remember)
                                    .disabled(automaticSample == nil)
                                if let automaticSample, remember, let meeting {
                                    screenButton("Послушать образец · \(timecode(automaticSample.start))–\(timecode(automaticSample.end))") {
                                        state.preview(automaticSample, in: meeting)
                                    }.actionButton().disabled(state.recording || state.demo)
                                    screenText("Образец до 8 секунд выбирается автоматически, без отмеченных наложений других голосов. Он и голосовой слепок останутся после удаления аудио встречи.").textStyle(PisyaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                                } else if automaticSample == nil {
                                    screenText("Нет подходящего образца от 2 секунд с голосовым слепком и доступным аудио без отмеченных наложений. Имя можно применить без запоминания голоса.").textStyle(PisyaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                                }
                                screenButton("Применить имя", action: applyName)
                                    .actionButton(.primary).disabled(!canApplyName)
                            }
                        } else { screenText("Выберите фрагмент слева").foregroundStyle(Color.mutedInk) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(selected).textStyle(PisyaDesign.Typography.secondary).padding(.leading, PisyaDesign.Spacing.section).frame(width: 350 * max(1, textScale))
            }
        }.dialogContent().frame(width: 940, height: 660)
            .background(ClickToUnfocus(onEscape: dismissSuggestions))
            .onDisappear { state.stopPlayback() }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.compact) {
            TextField("Имя участника", text: $name)
                // The native field editor is already baseline-aligned at 110%.
                .textFieldStyle(PisyaTextFieldStyle(isEditing: nameFocused && textScale != AppTextSize.factor(for: 110)))
                .focused($nameFocused)
                .onChange(of: name) { _, newName in
                    showSuggestions = nameFocused && newName != lastChosenName
                    selectedSuggestion = nil
                }
                .onKeyPress(.downArrow) {
                    let count = suggestions.count
                    guard count > 0 else { return .ignored }
                    selectedSuggestion = min((selectedSuggestion ?? -1) + 1, count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard let index = selectedSuggestion, !suggestions.isEmpty else { return .ignored }
                    selectedSuggestion = max(index - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) { dismissSuggestions() ? .handled : .ignored }
                .onSubmit {
                    let suggestions = suggestions
                    if let index = selectedSuggestion, suggestions.indices.contains(index) {
                        chooseSuggestion(suggestions[index])
                    } else {
                        applyName()
                    }
                }
            let matchingNames = suggestions
            if !matchingNames.isEmpty {
                suggestionList(matchingNames)
            }
        }
    }

    private func suggestionList(_ suggestions: [String]) -> some View {
        let shape = RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                        VoiceSuggestionRow(name: suggestion, selected: index == selectedSuggestion) {
                            chooseSuggestion(suggestion)
                        }
                        .id(index)
                    }
                }
            }
            .frame(height: min(CGFloat(suggestions.count) * PisyaDesign.Metrics.regularHeight, PisyaDesign.Metrics.editorHeight))
            .padding(PisyaDesign.Spacing.compact)
            .background {
                shape.fill(Color.paper)
                    .shadow(color: Color.ink.opacity(0.12), radius: PisyaDesign.Spacing.inline, y: PisyaDesign.Spacing.hairline)
            }
            .overlay {
                shape.strokeBorder(PisyaDesign.Colors.secondaryAction, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onChange(of: selectedSuggestion) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .background(SlimScrollbars().allowsHitTesting(false))
    }

    private func fragmentCard(_ segment: TranscriptSegment, in meeting: Meeting) -> some View {
        let canPlay = !meeting.audioFiles.isEmpty && !state.recording && !state.demo
        let isPlaying = state.playingSegmentID == segment.id
        let isSelected = selected == segment.id
        let shape = RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)

        return Button {
            select(segment)
            if canPlay { state.preview(segment, in: meeting) }
        } label: {
            HStack(alignment: .top, spacing: PisyaDesign.Spacing.related) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(PisyaDesign.Typography.Icon.featured)
                    .foregroundStyle(canPlay ? Color.moss : Color.disabledInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                    screenText("\(timecode(segment.start)) · \(timecode(segment.end - segment.start))")
                        .textStyle(PisyaDesign.Typography.footnote)
                    screenText(segment.text).textStyle(PisyaDesign.Typography.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(PisyaDesign.Spacing.related)
            .background(isSelected ? PisyaDesign.Colors.selection : PisyaDesign.Colors.secondary, in: shape)
            .contentShape(shape)
        }
        .shapeAwarePlainButton()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .screenHelp(canPlay ? (isPlaying ? "Остановить фрагмент" : "Прослушать до 8 секунд") : "Выбрать фрагмент")
    }
}

private struct VoiceSuggestionRow: View {
    let name: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if selected { return Color.moss.opacity(0.14) }
        return hovered ? PisyaDesign.Colors.secondaryHover : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)
        Button(action: choose) {
            screenText(name)
                .lineLimit(1)
                .padding(.horizontal, PisyaDesign.Spacing.inline)
                .frame(maxWidth: .infinity, minHeight: PisyaDesign.Metrics.regularHeight, alignment: .leading)
                .background(fill, in: shape)
                .contentShape(shape)
        }
        .shapeAwarePlainButton()
        .onHover { hovered = $0 }
        .screenHelp(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
