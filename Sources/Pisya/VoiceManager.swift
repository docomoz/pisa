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
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 5) { screenText("Голоса встречи").font(.appFont(size: 22, weight: .semibold)); screenText("Послушайте фрагмент, назначьте имя и сохраните образец для следующих встреч").font(.appFont(size: 15)).foregroundStyle(Color.mutedInk) }; Spacer(); screenButton("Готово") { dismiss() }.plainButton(prominent: true).keyboardShortcut(.cancelAction) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if let meeting {
                            ForEach(meeting.speakers, id: \.self) { speaker in
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    screenText(speaker).font(.appFont(size: 16, weight: .semibold))
                                    ForEach(meeting.segments.filter { $0.speaker == speaker }) { segment in
                                        HStack(alignment: .top, spacing: 10) {
                                            Button { select(segment); state.preview(segment, in: meeting) } label: { Image(systemName: state.playingSegmentID == segment.id ? "stop.circle.fill" : "play.circle.fill").font(.appFont(size: 22, weight: .semibold)) }.buttonStyle(AccentIconStyle()).contentShape(.focusEffect, Circle()).disabled(meeting.audioFiles.isEmpty || state.recording).screenHelp("Прослушать до 8 секунд")
                                            Button { select(segment) } label: {
                                                VStack(alignment: .leading, spacing: 4) { screenText("\(timecode(segment.start)) · \(timecode(segment.end - segment.start))").font(.appFont(size: 12)); screenText(segment.text).font(.appFont(size: 15)).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
                                            }.shapeAwarePlainButton()
                                        }.padding(10).background(selected == segment.id ? Color.moss.opacity(0.12) : Color.sidebarTint.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    }.padding(.trailing, 14)
                }.frame(minWidth: 340)
                VStack(alignment: .leading, spacing: 16) {
                    screenText("Кто говорит?").font(.appFont(size: 16, weight: .semibold))
                    if let sample {
                        screenText("Фрагмент \(timecode(sample.start)) · сейчас «\(sample.speaker)»").font(.appFont(size: 15)).foregroundStyle(Color.mutedInk)
                        TextField("Имя участника", text: $name).textFieldStyle(.roundedBorder)
                        screenMenu("Выбрать сохранённое имя") { ForEach(state.voiceProfiles) { profile in screenButton(profile.name) { name = profile.name } } }
                        screenToggle("Все реплики «\(sample.speaker)»", isOn: $allMatching)
                        screenToggle("Запомнить голос для будущих встреч", isOn: $remember)
                            .disabled(sample.embedding == nil || sample.end - sample.start < 2 || meeting?.audioFiles.isEmpty == true)
                        screenText("Сохраняется выбранный образец до 8 секунд и голосовой слепок. Они останутся после удаления аудио встречи. Выбирайте речь одного человека без наложений.").font(.appFont(size: 13)).foregroundStyle(Color.mutedInk)
                        screenButton("Применить имя") {
                            state.assignVoice(meetingID: meetingID, segmentID: sample.id, name: name, allMatching: allMatching, remember: remember && sample.embedding != nil && sample.end - sample.start >= 2 && meeting?.audioFiles.isEmpty == false)
                        }.plainButton(prominent: true).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else { screenText("Выберите фрагмент слева").foregroundStyle(Color.mutedInk) }
                    Divider()
                    screenText("Сохранённые голоса").font(.appFont(size: 16, weight: .semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(state.voiceProfiles) { profile in
                                HStack { screenText(profile.name); Spacer(); if let example = profile.examples?.last { Button { state.playExample(example) } label: { Image(systemName: state.playingSegmentID == example.id ? "stop.fill" : "play.fill") }.screenHelp("Послушать сохранённый образец") } else { screenText("слепок").font(.appFont(size: 12)).foregroundStyle(Color.mutedInk) } }
                            }
                        }
                    }
                }.font(.appFont(size: 15)).padding(.leading, 18).frame(width: 350)
            }
        }.font(.appFont(size: 15)).controlSize(.large).padding(26).frame(width: 940, height: 660).plainControls().popupCanvas().background(ClickToUnfocus()).onDisappear { state.stopPlayback() }
    }
}
