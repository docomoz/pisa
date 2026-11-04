import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 270)
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                if state.recording { recordingBanner }
                if state.demo { screenText("ДЕМОНСТРАЦИЯ · вымышленные реплики, не настоящая запись").font(.appFont(size: 11, weight: .medium)).foregroundStyle(Color.moss).padding(10).frame(maxWidth: .infinity).background(Color.moss.opacity(0.08)) }
                if let meeting = state.selected { MeetingView(meeting: meeting).id(meeting.id) } else { welcome }
            }.background(Color.paper)
        }
        .background(SlimScrollbars().allowsHitTesting(false))
        .background(ClickToUnfocus())
        .font(.appFont(size: 14))
        .foregroundStyle(Color.ink)
        .tint(Color.brandAccent)
        .confirmationDialog(typographicText("Расшифровать встречу заново? Текущий текст, исправления и разметка участников будут заменены. Аудио сохранится"), isPresented: Binding(get: { state.reprocessTarget != nil }, set: { if !$0 { state.reprocessTarget = nil } })) {
            if let meeting = state.reprocessTarget { screenButton("Расшифровать заново") { state.enqueue(meeting.id, reprocess: true); state.reprocessTarget = nil } }
            screenButton("Отмена", role: .cancel) { state.reprocessTarget = nil }
        }
        .sheet(item: $state.renameTarget) { meeting in NameEditor(title: "Переименовать запись", initial: meeting.title) { state.rename(meeting, to: $0) } }
        .sheet(item: $state.voiceMeeting) { meeting in VoiceManager(meetingID: meeting.id).environmentObject(state) }
    }
    private var sidebar: some View { LibrarySidebar() }
    private var topbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(nsImage: BrandMark.headerIcon).resizable().frame(width: 24, height: 24)
                BrandMoodView()
            }.accessibilityElement(children: .combine)
            Spacer()
            HStack(spacing: 10) {
                Button { state.showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.appFont(size: 14, weight: .medium))
                }.actionButton().screenHelp("Настройки · ⌘,").accessibilityLabel("Настройки")
                Button { state.importAudio() } label: {
                    screenLabel("Импорт", systemImage: "arrow.down.doc").font(.appFont(size: 14, weight: .medium))
                }.actionButton().disabled(state.demo)
                Button { Task { if state.recording { await state.stopRecording(manual: true) } else { await state.startRecording() } } } label: {
                    screenLabel(state.starting ? (state.recordingStarted == nil ? "Подготовка…" : "Сохраняю…") : state.recording ? "Остановить запись" : "Начать запись", systemImage: state.recording ? "stop.fill" : "record.circle")
                        .font(.appFont(size: 14, weight: .semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }.actionButton(.recording)
                    .disabled(state.starting || state.demo)
            }.controlSize(.large)

        }.padding(.horizontal, 28).frame(height: 76)
    }
    private var recordingBanner: some View {
        RecordingWaveformView(monitor: state.recordingMonitor, started: state.recordingStarted)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76).padding(.bottom, 27)
            screenText("Вы разговариваете.\nPisya записывает.").font(.appFont(size: 40, weight: .medium)).tracking(-0.8).lineSpacing(2)
            screenText("Записывайте встречи и находите нужное в расшифровке.\nАудио и распознавание — на вашем Mac.").font(.appFont(size: 15)).foregroundStyle(Color.mutedInk).lineSpacing(6).padding(.top, 20)
            HStack(spacing: 12) {
                Button { state.showingSettings = true } label: { screenText(state.modelReady ? "Настроить автозапись" : "Подготовить к первой встрече").font(.appFont(size: 14, weight: .medium)) }.actionButton(.primary)
            }.padding(.top, 30)
            Spacer()
            HStack(alignment: .top, spacing: 28) {
                feature("headphones", "Запись звонков", "Микрофон и звук приложений или браузера")
                feature("doc.text", "Экспорт расшифровок", "Markdown в выбранную папку, Dropbox или Obsidian")
                feature("lock", "Локальное распознавание", "Аудио обрабатывается на этом Mac")
            }.padding(.bottom, 40)
        }.padding(.horizontal, 54).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) { Image(systemName: icon).font(.appFont(size: 18)).foregroundStyle(Color.moss); screenText(title).font(.appFont(size: 12, weight: .medium)); screenText(detail).font(.appFont(size: 11)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MeetingView: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    @State private var editing: TranscriptSegment?
    @State private var speakerName = ""
    @State private var speakerToRename: String?
    @State private var title = ""
    @State private var confirmDeleteAudio = false
    @State private var transcriptSearch = ""
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, search }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !meeting.hasAutomaticTitle { screenText(meetingDateLabel(meeting.date)); screenText("·") }
                screenText(meeting.source)
                screenText("·")
                screenText(timecode(meeting.duration)).monospacedDigit()
                Spacer()
                if meeting.status == .ready { screenLabel("Готово", systemImage: "checkmark.circle") }
                if state.demo { screenButton("Закрыть пример") { state.showDemo() } }
            }.font(.appFont(size: 14)).foregroundStyle(Color.mutedInk).padding(.bottom, 14)
            TextField("Название встречи", text: $title).textFieldStyle(.plain)
                .font(.appFont(size: 29, weight: meeting.hasAutomaticTitle ? .regular : .semibold)).focused($focusedField, equals: .title)
                .disabled(!state.canModify(meeting))
                .onSubmit { saveTitle(); focusedField = nil }
                .onChange(of: focusedField) { old, new in if old == .title && new != .title { saveTitle() } }
                .onAppear { title = meeting.title }.onChange(of: meeting.title) { _, value in title = value }
                .onDisappear { if title != meeting.title { state.rename(meeting, to: title) } }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { meetingControls; Spacer(minLength: 0); exportControl }
                VStack(alignment: .leading, spacing: 10) { meetingControls; exportControl }
            }.actionControls().font(.appFont(size: 14, weight: .medium)).controlSize(.large).padding(.top, 22).padding(.bottom, 20)
            if !meeting.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(meeting.speakers, id: \.self) { speaker in
                            Button { state.voiceMeeting = meeting } label: {
                                screenLabel(speaker, systemImage: "person.crop.circle").font(.appFont(size: 13))
                            }.speakerChip()
                        }
                    }
                }.background(HorizontalWheelScroll()).padding(.bottom, 24)
            }
            HStack { screenText("РАСШИФРОВКА").tracking(1.5); Spacer(); screenText(fragmentCount(meeting.segments.count)) }.font(.appFont(size: 12, weight: .medium)).foregroundStyle(Color.mutedInk)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedInk)
                TextField("Поиск внутри записи", text: $transcriptSearch).textFieldStyle(.plain).focused($focusedField, equals: .search)
                if !transcriptSearch.isEmpty { Button { transcriptSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.shapeAwarePlainButton(Circle()) }
            }.font(.appFont(size: 14)).padding(.horizontal, 12).padding(.vertical, 10)
                .background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                .padding(.bottom, 12).disabled(meeting.segments.isEmpty || state.recordingMeetingID == meeting.id)
            Divider()
            if state.recordingMeetingID == meeting.id && state.processingID == meeting.id {
                HStack {
                    screenText(state.liveStatus).foregroundStyle(Color.mutedInk)
                    Spacer()
                    screenButton(state.livePaused ? "Продолжить расшифровку" : "Приостановить расшифровку") { state.toggleLivePause() }.actionButton(size: .small)
                }.font(.appFont(size: 13)).padding(.vertical, 14)
            } else if state.processingID == meeting.id && !state.liveStatus.isEmpty {
                HStack { screenText(state.liveStatus); Spacer(); screenButton("Остановить обработку") { state.cancelProcessing() }.actionButton(size: .small) }.font(.appFont(size: 13)).padding(.vertical, 14)
            } else if state.processingID == meeting.id {
                VStack(alignment: .leading, spacing: 12) { screenText(state.phase).font(.appFont(size: 13)); ProgressView(value: state.progress); screenButton("Остановить обработку") { state.cancelProcessing() }.font(.appFont(size: 13)).actionButton(size: .small) }.padding(.vertical, 24)
            }
            if meeting.status == .failed && meeting.liveCommittedUntil != nil && !meeting.segments.isEmpty && !state.recording {
                HStack { screenText("Расшифровка не завершена").foregroundStyle(Color.mutedInk); Spacer(); screenButton("Продолжить расшифровку") { state.enqueue(meeting.id) }.actionButton(.primary, size: .small) }.font(.appFont(size: 13)).padding(.vertical, 14)
            }
            if meeting.segments.isEmpty {
                VStack(spacing: 18) {
                    Spacer()
                    if state.recordingMeetingID != meeting.id { Image(systemName: meeting.status == .failed ? "exclamationmark.waveform" : "waveform").font(.appFont(size: 34, weight: .light)).foregroundStyle(Color.moss) }
                    screenText(state.recordingMeetingID == meeting.id ? (state.processingID == meeting.id ? "Здесь появится черновик" : "Расшифровка появится после записи") : meeting.status == .processing ? "Слушаю и превращаю в текст" : meeting.status == .failed ? (state.hasAudio(meeting) ? "Обработка не завершена" : "Запись не началась") : "Аудио сохранено").font(.appFont(size: 21, weight: .medium))
                    if let error = meeting.error { screenText(error == "The user declined TCCs for application, window, display capture" ? CapturePermission.screen.localizedDescription : error).font(.appFont(size: 12)).foregroundStyle(Color.mutedInk).multilineTextAlignment(.center).frame(maxWidth: 420) }
                    if !state.recording && meeting.status != .processing && state.hasAudio(meeting) { screenButton(state.modelReady ? (meeting.liveCommittedUntil == nil ? "Расшифровать" : "Продолжить расшифровку") : "Добавить модель") { state.enqueue(meeting.id) }.actionButton(.primary).controlSize(.large) }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(meeting.segments.filter { transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearch) || $0.speaker.localizedCaseInsensitiveContains(transcriptSearch) }) { segment in
                            HStack(alignment: .top, spacing: 22) {
                                Button { state.play(segment, in: meeting) } label: { VStack(spacing: 7) { screenText(timecode(segment.start)).font(.appFont(size: 13)); Image(systemName: state.playingSegmentID == segment.id ? "stop.fill" : "play.fill").font(.appFont(size: 12)) }.frame(width: 56, alignment: .leading).padding(.top, 3) }.buttonStyle(AccentIconStyle()).contentShape(.focusEffect, RoundedRectangle(cornerRadius: 8)).disabled(state.demo || state.recording || meeting.audioFiles.isEmpty).screenHelp("Прослушать фрагмент")
                                VStack(alignment: .leading, spacing: 9) {
                                    screenText(segment.speaker).font(.appFont(size: 14, weight: .semibold)).foregroundStyle(segment.speaker == "Я" ? Color.moss : Color.ink)
                                    screenText(typographicText(segment.text)).font(.appFont(size: 16)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button { editing = segment } label: { Image(systemName: "pencil").font(.appFont(size: 14)) }.buttonStyle(AccentIconStyle()).contentShape(.focusEffect, Circle()).disabled(state.recordingMeetingID == meeting.id || state.processingID == meeting.id).screenHelp("Исправить реплику")
                            }
                        }
                    }.padding(.vertical, 27).padding(.trailing, 10)
                }
            }
            HStack { Image(systemName: "lock.shield"); screenText("Локальная расшифровка"); Spacer(); screenText("Только на этом Mac") }.font(.appFont(size: 12)).foregroundStyle(Color.mutedInk).padding(.vertical, 16)
        }.padding(.horizontal, 38).padding(.top, 32)
        .background(SlimScrollbars().allowsHitTesting(false))
        .background(ClickToUnfocus())
        .onExitCommand { focusedField = nil; NSApp.keyWindow?.makeFirstResponder(nil) }
        .confirmationDialog(typographicText("Удалить аудио этой встречи без возможности восстановления? Текст и сохранённые голосовые признаки останутся, переслушать или заново распознать запись будет нельзя"), isPresented: $confirmDeleteAudio) {
            screenButton("Удалить аудио", role: .destructive) { state.deleteAudio(meeting) }
            screenButton("Отмена", role: .cancel) {}
        }
        .sheet(item: $editing) { segment in SegmentEditor(segment: segment) { edited in var m = meeting; if let i = m.segments.firstIndex(where: { $0.id == edited.id }) { m.segments[i] = edited; state.update(m) }; editing = nil } }
        .alert("Имя участника", isPresented: Binding(get: { speakerToRename != nil }, set: { if !$0 { speakerToRename = nil } })) {
            TextField("Имя", text: $speakerName)
            screenButton("Сохранить") { if let old = speakerToRename { state.renameSpeaker(old, to: speakerName, meeting: meeting) }; speakerToRename = nil }
            if !state.demo && meeting.segments.contains(where: { $0.speaker == speakerToRename && $0.embedding != nil }) {
                screenButton("Сохранить имя и запомнить голос") { if let old = speakerToRename { state.rememberVoice(old, name: speakerName, meeting: meeting); state.renameSpeaker(old, to: speakerName, meeting: meeting) }; speakerToRename = nil }
            }
            screenButton("Отмена", role: .cancel) { speakerToRename = nil }
        } message: { screenText("Имя изменится в этой встрече. «Запомнить голос» сохраняет локальный образец для следующих встреч; выбирайте только проверенные реплики") }
    }
    private func saveTitle() {
        if title != meeting.title { state.rename(meeting, to: title) }
        title = state.meetings.first(where: { $0.id == meeting.id })?.title ?? meeting.title
    }
    private var meetingControls: some View {
        HStack(spacing: 12) {
            Button { state.voiceMeeting = meeting } label: { screenLabel("Разметить голоса", systemImage: "person.wave.2") }
                .disabled(meeting.segments.isEmpty || !state.canModify(meeting))
            Menu {
                screenButton("Без папки") { state.move(meeting, to: nil) }
                Divider()
                ForEach(state.folders) { folder in Button { state.move(meeting, to: folder.id) } label: { screenLabel(folder.name, systemImage: folder.iconName) } }
            } label: {
                screenLabel(state.folders.first(where: { $0.id == meeting.folderID })?.name ?? "Папка", systemImage: state.folders.first(where: { $0.id == meeting.folderID })?.iconName ?? "folder")
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
            }.disabled(!state.canModify(meeting)).fixedSize()
                .screenHelp(state.folders.first(where: { $0.id == meeting.folderID })?.name ?? "Переместить в папку")
        }
    }
    private var exportControl: some View {
        HStack(spacing: 12) {
            Button { state.exportSelected() } label: { screenLabel("Поделиться", systemImage: "square.and.arrow.up") }
                .disabled(state.demo || meeting.segments.isEmpty)
            Menu {
                MeetingActions(meeting: meeting)
                if !meeting.audioFiles.isEmpty && meeting.status == .ready {
                    Divider()
                    screenButton("Удалить аудио…", role: .destructive) { confirmDeleteAudio = true }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24) }.actionButton().fixedSize().disabled(!state.canModify(meeting))
        }
    }

}
private struct SegmentEditor: View {
    @State var segment: TranscriptSegment
    var save: (TranscriptSegment) -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            screenText("Исправить реплику").font(.appFont(size: 20, weight: .semibold))
            TextField("Участник", text: $segment.speaker).textFieldStyle(PisyaTextFieldStyle())
            TextEditor(text: $segment.text).font(.appFont(size: 15)).frame(height: 180).border(.quaternary)
            HStack { screenButton("Отмена") { dismiss() }.actionButton(); Spacer(); screenButton("Сохранить") { save(segment) }.actionButton(.primary) }
        }.font(.appFont(size: 15)).actionControls().padding(28).frame(width: 520).popupCanvas()
    }
}


private struct RecordingWaveformView: View {
    @ObservedObject var monitor: RecordingMonitor
    let started: Date?
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                screenText("Идёт запись").font(.appFont(size: 16, weight: .semibold))
                Spacer()
                if let started { screenText(started, style: .timer).font(.appFont(size: 16)).monospacedDigit() }
            }
            lane("Микрофон", icon: "mic", track: monitor.microphone, color: .moss)
            lane("Системный звук", icon: "speaker.wave.2", track: monitor.system, color: Color(white: 0.48))
        }.padding(.horizontal, 28).padding(.vertical, 18).background(Color.moss.opacity(0.045))
    }
    private func lane(_ title: String, icon: String, track: AudioMeterTrack, color: Color) -> some View {
        let fresh = track.isFresh(now: monitor.now)
        let waiting = monitor.now - monitor.began < 3
        let status = !fresh && !waiting ? "Нет новых данных" : ""
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                screenLabel(title, systemImage: icon).font(.appFont(size: 14, weight: .medium))
                if !status.isEmpty { screenText(status).font(.appFont(size: 12)).foregroundStyle(Color.orange) }
            }.frame(width: 190, alignment: .leading)
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                Canvas { context, size in
                    // Position by capture time, not by polling index: late samples never reset scrolling.
                    let now = monitor.now + max(0, timeline.date.timeIntervalSince(monitor.updatedAt))
                    for (index, value) in track.history.enumerated() {
                        let x = size.width - 1.5 - CGFloat(now - track.historyTimes[index]) * 105
                        guard x >= -2, x <= size.width else { continue }
                        let height = max(2, CGFloat(value) * (size.height - 4))
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: 1.5, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(color.opacity(value > 0 ? 0.85 : 0.18)))
                    }
                }
            }.frame(height: 64).clipped().accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 5) {
                screenText(timecode(track.seconds)).font(.appFont(size: 12)).monospacedDigit()
                screenText("записано").font(.appFont(size: 12)).foregroundStyle(Color.mutedInk)
            }.frame(width: 66, alignment: .trailing)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title). \(status). Записано \(timecode(track.seconds))")
            .screenHelp("Уровень звука после записи в аудиофайл. Нет новых данных — проверьте источник; системный звук может отсутствовать, когда приложения молчат.")
    }
}
