import SwiftUI

struct VoiceManager: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    @State private var selected: UUID?
    @State private var name = ""
    @State private var allMatching = true
    @State private var remember = true
    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }
    private var sample: TranscriptSegment? { meeting?.segments.first { $0.id == selected } }
    private var automaticSample: TranscriptSegment? {
        guard let meeting, let selected else { return nil }
        return state.voiceSample(for: selected, in: meeting, allMatching: allMatching)
    }
    private func select(_ segment: TranscriptSegment) {
        name = voiceNameForSelection(currentID: selected, currentName: name, segment: segment)
        selected = segment.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            HStack(spacing: PisyaDesign.Spacing.inline) { SectionHeading("Голоса встречи", subtitle: "Послушайте фрагмент, назначьте имя и сохраните образец для следующих встреч", style: .dialog); Spacer(); screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        if let meeting {
                            ForEach(meeting.speakers, id: \.self) { speaker in
                                LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                    screenText(speaker).textStyle(PisyaDesign.Typography.bodyStrong)
                                    ForEach(voiceSamples(for: speaker, in: meeting.segments)) { segment in
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
                                TextField("Имя участника", text: $name).textFieldStyle(PisyaTextFieldStyle())
                            }
                            if !state.voiceProfiles.isEmpty { savedVoices }
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
                                screenButton("Применить имя") {
                                    state.assignVoice(meetingID: meetingID, segmentID: sample.id, name: name, allMatching: allMatching, remember: remember && automaticSample != nil)
                                }.actionButton(.primary).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } else { screenText("Выберите фрагмент слева").foregroundStyle(Color.mutedInk) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(selected).textStyle(PisyaDesign.Typography.secondary).padding(.leading, PisyaDesign.Spacing.section).frame(width: 350)
            }
        }.dialogContent().frame(width: 940, height: 660).background(ClickToUnfocus()).onDisappear { state.stopPlayback() }
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

    private var savedVoices: some View {
        FormSection("Сохранённые голоса") {
            ForEach(state.voiceProfiles) { profile in
                HStack(spacing: PisyaDesign.Spacing.inline) {
                    Button { name = profile.name } label: {
                        HStack(spacing: PisyaDesign.Spacing.inline) {
                            screenText(profile.name).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: PisyaDesign.Spacing.none)
                            if name == profile.name {
                                Image(systemName: "checkmark").font(PisyaDesign.Typography.Icon.checkmark)
                            }
                        }
                        .padding(.horizontal, PisyaDesign.Spacing.related)
                        .padding(.vertical, PisyaDesign.Spacing.inline)
                        .frame(maxWidth: .infinity, minHeight: PisyaDesign.Metrics.regularHeight, alignment: .leading)
                        .background(name == profile.name ? PisyaDesign.Colors.selection : PisyaDesign.Colors.secondary,
                                    in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                    }.shapeAwarePlainButton()
                        .accessibilityValue(name == profile.name ? "Выбрано" : "")
                        .screenHelp("Выбрать имя «\(profile.name)»")
                    if let example = profile.examples?.last {
                        Button { state.playExample(example) } label: {
                            Image(systemName: state.playingSegmentID == example.id ? "stop.fill" : "play.fill")
                        }.actionButton().disabled(state.recording)
                            .accessibilityLabel("\(state.playingSegmentID == example.id ? "Остановить" : "Послушать") образец «\(profile.name)»")
                            .screenHelp("Послушать сохранённый образец «\(profile.name)»")
                    }
                }
            }
        }
    }
}
