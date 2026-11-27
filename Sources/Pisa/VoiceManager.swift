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
        field.font = .systemFont(ofSize: PisaDesign.Typography.bodyStrong.size * textScale, weight: .semibold)
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
    @State private var nameFocused = false
    @State private var suggestionSelection = FormSuggestionSelection()
    @State private var suggestionListFocused = false
    @State private var caretEndRequest: UUID?
    @State private var allMatching = true
    @State private var remember = true
    @State private var assignment: Task<Void, Never>?
    @State private var assignmentError: String?
    @State private var expandedGroups: Set<String> = []
    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }
    private var sample: TranscriptSegment? {
        meeting?.segments.first { $0.id == selected && $0.speaker != TranscriptSegment.unidentifiedSpeaker }
    }
    private var canApplyName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var automaticName: Bool { isAutomaticSpeakerName(name) }
    private var suggestions: [String] {
        guard suggestionSelection.isOpen else { return [] }
        return voiceNameSuggestions(query: name, meetingNames: meeting?.segments.map(\.speaker) ?? [], savedNames: state.voiceProfiles.map(\.name))
    }
    private var automaticSample: TranscriptSegment? {
        guard let meeting, let selected else { return nil }
        return state.voiceSample(for: selected, in: meeting)
    }
    private func select(_ segment: TranscriptSegment) {
        assignmentError = nil
        suggestionSelection.close()
        suggestionListFocused = false
        let currentSpeaker = sample?.speaker
        if currentSpeaker != segment.speaker {
            remember = true
        }
        name = voiceNameForSelection(currentSpeaker: currentSpeaker, currentName: name, segment: segment)
        selected = segment.id
    }

    private func editName(_ newName: String) {
        name = newName
        assignmentError = nil
        suggestionListFocused = false
        suggestionSelection.open()
    }

    private func chooseSuggestion(_ suggestion: String) {
        name = suggestion
        assignmentError = nil
        suggestionSelection.close()
        suggestionListFocused = false
        caretEndRequest = UUID()
        nameFocused = true
    }

    private func dismissSuggestions() -> Bool {
        guard nameFocused else { return false }
        return suggestionSelection.dismiss(matches: suggestions)
    }

    private func applyName(rememberVoice: Bool) {
        guard assignment == nil, canApplyName, let selected else { return }
        suggestionSelection.close()
        suggestionListFocused = false
        assignmentError = nil
        let name = name
        let allMatching = allMatching
        let canRememberName = !automaticName
        let rememberVoice = rememberVoice && canRememberName
        assignment = Task {
            defer { assignment = nil }
            do {
                try await state.assignVoice(meetingID: meetingID, segmentID: selected, name: name,
                                            allMatching: allMatching, remember: rememberVoice)
                if !rememberVoice, canRememberName, automaticSample != nil { remember = false }
            } catch is CancellationError {
                return
            } catch {
                assignmentError = error.localizedDescription
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            HStack(spacing: PisaDesign.Spacing.inline) {
                SectionHeading("Голоса встречи", subtitle: "Послушайте реплики и назначьте имена участникам", style: .dialog)
                Spacer()
                screenButton("Готово") { dismiss() }
                    .actionButton(.primary).keyboardShortcut(.cancelAction).disabled(assignment != nil)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                        if let meeting {
                            let groups = Dictionary(grouping: meeting.segments, by: \.speaker)
                            ForEach(voiceGroupAnchors(in: meeting.segments)) { anchor in
                                voiceGroup(anchor.speaker, replies: groups[anchor.speaker] ?? [], in: meeting)
                            }
                        }
                    }.padding(.trailing, PisaDesign.Spacing.section)
                }.frame(minWidth: 340)
                ScrollView {
                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                        if let sample {
                            let automaticSample = automaticSample
                            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                                SectionHeading("Кто говорит?", subtitle: "Фрагмент \(timecode(sample.start)) · сейчас «\(sample.speaker)»")
                                nameEditor
                            }
                            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                                screenToggle("Все реплики «\(sample.speaker)»", isOn: $allMatching, alignment: .top)
                                    .textStyle(PisaDesign.Typography.controlLabel)
                                    .measuredForInterfaceTest(.voiceAllMatching)
                                screenToggle("Сохранить образец голоса",
                                             isOn: Binding(get: { remember && !automaticName }, set: { remember = $0 }),
                                             alignment: .top)
                                    .textStyle(PisaDesign.Typography.controlLabel)
                                    .disabled(automaticSample == nil || automaticName)
                                    .measuredForInterfaceTest(.voiceRememberSample)
                                if automaticName, automaticSample != nil {
                                    screenText("Введите имя участника, чтобы сохранить образец голоса")
                                        .textStyle(PisaDesign.Typography.caption)
                                        .foregroundStyle(Color.mutedInk)
                                } else if let automaticSample, remember, let meeting {
                                    screenButton("Послушать образец · \(timecode(automaticSample.start))–\(timecode(automaticSample.end))") {
                                        state.preview(automaticSample, in: meeting)
                                    }.actionButton().disabled(state.recording || state.demo)
                                        .measuredForInterfaceTest(.voicePreviewSample)
                                    screenText("Образец берётся из выбранного фрагмента, без отмеченных наложений других голосов. Он и голосовой слепок останутся после удаления аудио встречи.").textStyle(PisaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                                } else if automaticSample == nil {
                                    screenText("В выбранном фрагменте нет 2 секунд доступного аудио без отмеченных наложений. Имя можно применить без сохранения образца.").textStyle(PisaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                                }
                                screenButton(assignment == nil ? "Применить имя" : "Сохраняем…") {
                                    applyName(rememberVoice: remember && automaticSample != nil)
                                }.actionButton(.primary).disabled(!canApplyName)
                                if let assignmentError {
                                    screenText(assignmentError)
                                        .textStyle(PisaDesign.Typography.caption)
                                        .foregroundStyle(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if remember, automaticSample != nil {
                                        screenButton("Применить только к этой встрече") {
                                            applyName(rememberVoice: false)
                                        }.actionButton()
                                    }
                                }
                            }
                        } else { screenText("Выберите фрагмент слева").foregroundStyle(Color.mutedInk) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlayPreferenceValue(FormSuggestionFieldBounds.self, alignment: .topLeading) { anchor in
                    FormSuggestionOverlay(anchor: anchor, matches: suggestions, selectedIndex: suggestionSelection.selectedIndex,
                                          element: InterfaceLayoutElement.voiceSuggestion, choose: chooseSuggestion,
                                          keyboardFocus: $suggestionListFocused, onListCommand: handleSuggestionCommand)
                }
                .id(selected)
                .textStyle(PisaDesign.Typography.secondary)
                .padding(.leading, PisaDesign.Spacing.section)
                .frame(width: 350 * max(1, textScale))
            }
            .disabled(assignment != nil)
        }.dialogContent().frame(width: 940, height: 660)
            .interactiveDismissDisabled(assignment != nil)
            .onChange(of: allMatching) { assignmentError = nil }
            .onChange(of: remember) { assignmentError = nil }
            .background(ClickToUnfocus(onEscape: dismissSuggestions))
            .onDisappear { assignment?.cancel(); state.stopPlayback() }
    }

    private var nameEditor: some View {
        // Keep the suggestions in sync with AppKit's input before the next key event.
        FormTextField(title: "Имя участника", text: Binding(get: { name }, set: editName), isFocused: $nameFocused,
                      onSubmit: submitName, onCommand: handleNameCommand, caretEndRequest: caretEndRequest)
            .anchorPreference(key: FormSuggestionFieldBounds.self, value: .bounds) { $0 }
            .measuredForInterfaceTest(.voiceName)
    }

    private func handleNameCommand(_ command: Selector) -> Bool {
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
            nameFocused = true
            return true
        default:
            return suggestionSelection.handle(command, matches: matches)
        }
    }

    private func submitName() {
        if let suggestion = suggestionSelection.selected(in: suggestions) {
            chooseSuggestion(suggestion)
        } else {
            applyName(rememberVoice: remember && automaticSample != nil)
        }
    }

    private func voiceGroup(_ speaker: String, replies: [TranscriptSegment], in meeting: Meeting) -> some View {
        let previews = voiceSamples(for: speaker, in: replies)
        let expanded = expandedGroups.contains(speaker)
        return LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
            SelectableVoiceName(name: speaker)
            if replies.count > previews.count {
                screenButton(expanded ? "Свернуть реплики" : "Показать все реплики (\(replies.count))") {
                    if expanded { expandedGroups.remove(speaker) }
                    else { expandedGroups.insert(speaker) }
                }.actionButton(size: .small)
            }
            ForEach(expanded ? replies : previews) { segment in
                fragmentCard(segment, in: meeting)
            }
        }
    }

    private func fragmentCard(_ segment: TranscriptSegment, in meeting: Meeting) -> some View {
        let canPlay = !meeting.audioFiles.isEmpty && !state.recording && !state.demo
        let isPlaying = state.playingSegmentID == segment.id
        let isSelected = selected == segment.id
        let shape = RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)

        return Button {
            select(segment)
            if canPlay { state.preview(segment, in: meeting) }
        } label: {
            HStack(alignment: .top, spacing: PisaDesign.Spacing.related) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(PisaDesign.Typography.Icon.featured)
                    .foregroundStyle(canPlay ? Color.moss : Color.disabledInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    screenText("\(timecode(segment.start)) · \(timecode(segment.end - segment.start))")
                        .textStyle(PisaDesign.Typography.footnote)
                    screenText(segment.text).textStyle(PisaDesign.Typography.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(PisaDesign.Spacing.related)
            .background(isSelected ? PisaDesign.Colors.selection : PisaDesign.Colors.secondary, in: shape)
            .contentShape(shape)
        }
        .shapeAwarePlainButton()
        .measuredForInterfaceTest(.voiceSample(segment.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .screenHelp(canPlay ? (isPlaying ? "Остановить фрагмент" : "Прослушать до 8 секунд") : "Выбрать фрагмент")
    }
}
