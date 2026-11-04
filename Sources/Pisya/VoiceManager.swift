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
                                    screenText(speaker).font(PisyaDesign.Typography.bodyStrong)
                                    ForEach(voiceSamples(for: speaker, in: meeting.segments)) { segment in
                                        HStack(alignment: .top, spacing: PisyaDesign.Spacing.related) {
                                            Button { select(segment); state.preview(segment, in: meeting) } label: { Image(systemName: state.playingSegmentID == segment.id ? "stop.circle.fill" : "play.circle.fill").font(PisyaDesign.Typography.Icon.featured) }.buttonStyle(AccentIconStyle()).controlKeyboardFocus().focusEffectDisabled().disabled(meeting.audioFiles.isEmpty || state.recording).screenHelp("Прослушать до 8 секунд")
                                            Button { select(segment) } label: {
                                                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) { screenText("\(timecode(segment.start)) · \(timecode(segment.end - segment.start))").font(PisyaDesign.Typography.footnote); screenText(segment.text).font(PisyaDesign.Typography.secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
                                            }.shapeAwarePlainButton()
                                        }.padding(PisyaDesign.Spacing.related).background(selected == segment.id ? PisyaDesign.Colors.selection : PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                                    }
                                }
                            }
                        }
                    }.padding(.trailing, PisyaDesign.Spacing.section)
                }.frame(minWidth: 340)
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                    SectionHeading("Кто говорит?")
                    if let sample {
                        screenText("Фрагмент \(timecode(sample.start)) · сейчас «\(sample.speaker)»").font(PisyaDesign.Typography.secondary).foregroundStyle(Color.mutedInk)
                        TextField("Имя участника", text: $name).textFieldStyle(PisyaTextFieldStyle())
                        screenMenu("Выбрать сохранённое имя") { ForEach(state.voiceProfiles) { profile in screenButton(profile.name) { name = profile.name } } }.actionButton()
                        screenToggle("Все реплики «\(sample.speaker)»", isOn: $allMatching)
                        screenToggle("Запомнить голос для будущих встреч", isOn: $remember)
                            .disabled(sample.embedding == nil || sample.end - sample.start < 2 || meeting?.audioFiles.isEmpty == true)
                        screenText("Сохраняется выбранный образец до 8 секунд и голосовой слепок. Они останутся после удаления аудио встречи. Выбирайте речь одного человека без наложений.").font(PisyaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                        screenButton("Применить имя") {
                            state.assignVoice(meetingID: meetingID, segmentID: sample.id, name: name, allMatching: allMatching, remember: remember && sample.embedding != nil && sample.end - sample.start >= 2 && meeting?.audioFiles.isEmpty == false)
                        }.actionButton(.primary).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else { screenText("Выберите фрагмент слева").foregroundStyle(Color.mutedInk) }
                    Divider()
                    SectionHeading("Сохранённые голоса")
                    ScrollView {
                        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                            ForEach(state.voiceProfiles) { profile in
                                HStack(spacing: PisyaDesign.Spacing.inline) { screenText(profile.name); Spacer(); if let example = profile.examples?.last { Button { state.playExample(example) } label: { Image(systemName: state.playingSegmentID == example.id ? "stop.fill" : "play.fill") }.actionButton().screenHelp("Послушать сохранённый образец") } else { screenText("слепок").font(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk) } }
                            }
                        }
                    }
                }.font(PisyaDesign.Typography.secondary).padding(.leading, PisyaDesign.Spacing.section).frame(width: 350)
            }
        }.dialogContent().frame(width: 940, height: 660).background(ClickToUnfocus()).onDisappear { state.stopPlayback() }
    }
}
