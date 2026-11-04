import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.none) {
            sidebar.frame(width: 270)
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            VStack(spacing: PisyaDesign.Spacing.none) {
                topbar
                if state.recording { recordingBanner }
                if state.demo { screenText("ДЕМОНСТРАЦИЯ · вымышленные реплики, не настоящая запись").textStyle(PisyaDesign.Typography.microMedium).foregroundStyle(Color.moss).padding(PisyaDesign.Spacing.related).frame(maxWidth: .infinity).background(Color.moss.opacity(0.08)) }
                if let meeting = state.selected { MeetingView(meeting: meeting).id(meeting.id) } else { welcome }
            }.background(Color.paper)
        }
        .background(SlimScrollbars().allowsHitTesting(false))
        .background(ClickToUnfocus())
        .textStyle(PisyaDesign.Typography.detail)
        .foregroundStyle(Color.ink)
        .tint(Color.brandAccent)
        .focusEffectDisabled()
        .confirmationDialog(typographicText("Расшифровать встречу заново? Текущий текст, исправления и разметка участников будут заменены. Аудио сохранится"), isPresented: Binding(get: { state.reprocessTarget != nil }, set: { if !$0 { state.reprocessTarget = nil } })) {
            if let meeting = state.reprocessTarget { screenButton("Расшифровать заново") { state.enqueue(meeting.id, reprocess: true); state.reprocessTarget = nil } }
            screenButton("Отмена", role: .cancel) { state.reprocessTarget = nil }
        }
        .sheet(item: $state.renameTarget) { meeting in NameEditor(title: "Переименовать запись", initial: meeting.title) { state.rename(meeting, to: $0) } }
        .sheet(item: $state.voiceMeeting) { meeting in VoiceManager(meetingID: meeting.id).environmentObject(state) }
    }
    private var sidebar: some View { LibrarySidebar() }
    private var topbar: some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            HStack(spacing: PisyaDesign.Spacing.inline) {
                Image(nsImage: BrandMark.headerIcon).resizable().frame(width: 24, height: 24)
                BrandMoodView()
            }.accessibilityElement(children: .combine).layoutPriority(-1)
            Spacer()
            HStack(spacing: PisyaDesign.Spacing.related) {
                Button { state.showingSettings = true } label: {
                    Image(systemName: "gearshape").textStyle(PisyaDesign.Typography.detailMedium)
                }.actionButton().screenHelp("Настройки · ⌘,").accessibilityLabel("Настройки")
                Button { state.importAudio() } label: {
                    screenLabel("Импорт", systemImage: "arrow.down.doc")
                }.actionButton().disabled(state.demo)
                Button { Task { if state.recording { await state.stopRecording(manual: true) } else { await state.startRecording() } } } label: {
                    screenLabel(state.starting ? (state.recordingStarted == nil ? "Подготовка…" : "Сохраняю…") : state.recording ? "Остановить запись" : "Начать запись", systemImage: state.recording ? "stop.fill" : "record.circle")
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }.actionButton(.recording)
                    .disabled(state.starting || state.demo)
            }.controlSize(.large).fixedSize(horizontal: true, vertical: false)

        }.padding(.horizontal, PisyaDesign.Spacing.page).frame(height: 76)
    }
    private var recordingBanner: some View {
        RecordingWaveformView(monitor: state.recordingMonitor, started: state.recordingStarted)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76).padding(.bottom, PisyaDesign.Spacing.section)
            screenText("Вы разговариваете.\nPisya записывает.").textStyle(PisyaDesign.Typography.hero)
            screenText("Записывайте встречи и находите нужное в расшифровке.\nАудио и распознавание — на вашем Mac.").textStyle(PisyaDesign.Typography.secondary).foregroundStyle(Color.mutedInk).padding(.top, PisyaDesign.Spacing.content)
            HStack(spacing: PisyaDesign.Spacing.related) {
                Button { state.showingSettings = true } label: { screenText(state.modelReady ? "Настроить автозапись" : "Подготовить к первой встрече") }.actionButton(.primary)
            }.padding(.top, PisyaDesign.Spacing.section)
            Spacer()
            HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
                feature("headphones", "Запись звонков", "Микрофон и звук приложений или браузера")
                feature("doc.text", "Экспорт расшифровок", "Markdown в выбранную папку, Dropbox или Obsidian")
                feature("lock", "Локальное распознавание", "Аудио обрабатывается на этом Mac")
            }.padding(.bottom, PisyaDesign.Spacing.page)
        }.padding(.horizontal, PisyaDesign.Spacing.page).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) { Image(systemName: icon).font(PisyaDesign.Typography.Icon.medium).foregroundStyle(Color.moss); screenText(title).textStyle(PisyaDesign.Typography.footnoteMedium); screenText(detail).textStyle(PisyaDesign.Typography.micro).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                if !meeting.hasAutomaticTitle { screenText(meetingDateLabel(meeting.date)); screenText("·") }
                screenText(meeting.source)
                screenText("·")
                screenText(timecode(meeting.duration)).monospacedDigit()
                Spacer()
                if meeting.status == .ready { screenLabel("Готово", systemImage: "checkmark.circle") }
                if state.demo { screenButton("Закрыть пример") { state.showDemo() }.actionButton(size: .small) }
            }.textStyle(PisyaDesign.Typography.detail).foregroundStyle(Color.mutedInk).padding(.bottom, PisyaDesign.Spacing.related)
            TextField("Название встречи", text: $title).textFieldStyle(.plain)
                .textStyle(meeting.hasAutomaticTitle ? PisyaDesign.Typography.automaticTitle : PisyaDesign.Typography.pageTitle).focused($focusedField, equals: .title)
                .disabled(!state.canModify(meeting))
                .onSubmit { saveTitle(); focusedField = nil }
                .onChange(of: focusedField) { old, new in if old == .title && new != .title { saveTitle() } }
                .onAppear { title = meeting.title }.onChange(of: meeting.title) { _, value in title = value }
                .onDisappear { if title != meeting.title { state.rename(meeting, to: title) } }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PisyaDesign.Spacing.related) { meetingControls; Spacer(minLength: 0); exportControl }
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) { meetingControls; exportControl }
            }.actionControls().textStyle(PisyaDesign.Typography.detailMedium).controlSize(.large).padding(.top, PisyaDesign.Spacing.section).padding(.bottom, PisyaDesign.Spacing.section)
            if !meeting.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PisyaDesign.Spacing.section) {
                        ForEach(meeting.speakers, id: \.self) { speaker in
                            screenLabel(speaker, systemImage: "person.crop.circle")
                                .fixedSize()
                                .accessibilityElement(children: .combine)
                        }
                    }.textStyle(PisyaDesign.Typography.detail).foregroundStyle(Color.mutedInk)
                }.background(HorizontalWheelScroll()).padding(.bottom, PisyaDesign.Spacing.section)
            }
            HStack(spacing: PisyaDesign.Spacing.inline) { screenText("РАСШИФРОВКА").textStyle(PisyaDesign.Typography.transcriptHeading); Spacer(); screenText(fragmentCount(meeting.segments.count)) }.textStyle(PisyaDesign.Typography.footnoteMedium).foregroundStyle(Color.mutedInk).padding(.bottom, PisyaDesign.Spacing.related)
            SearchField(title: "Поиск внутри записи", text: $transcriptSearch).focused($focusedField, equals: .search)
                .padding(.bottom, PisyaDesign.Spacing.related).disabled(meeting.segments.isEmpty || state.recordingMeetingID == meeting.id)
            Divider()
            if state.recordingMeetingID == meeting.id && state.processingID == meeting.id {
                HStack(spacing: PisyaDesign.Spacing.inline) {
                    screenText(state.liveStatus).foregroundStyle(Color.mutedInk)
                    Spacer()
                    screenButton(state.livePaused ? "Продолжить расшифровку" : "Приостановить расшифровку") { state.toggleLivePause() }.actionButton(size: .small)
                }.textStyle(PisyaDesign.Typography.caption).padding(.vertical, PisyaDesign.Spacing.content)
            } else if state.processingID == meeting.id && !state.liveStatus.isEmpty {
                HStack(spacing: PisyaDesign.Spacing.inline) { screenText(state.liveStatus); Spacer(); screenButton("Остановить обработку") { state.cancelProcessing() }.actionButton(size: .small) }.textStyle(PisyaDesign.Typography.caption).padding(.vertical, PisyaDesign.Spacing.content)
            } else if state.processingID == meeting.id {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) { screenText(state.phase).textStyle(PisyaDesign.Typography.caption); ProgressView(value: state.progress); screenButton("Остановить обработку") { state.cancelProcessing() }.actionButton(size: .small) }.padding(.vertical, PisyaDesign.Spacing.section)
            }
            if meeting.status == .failed && meeting.liveCommittedUntil != nil && !meeting.segments.isEmpty && !state.recording {
                HStack(spacing: PisyaDesign.Spacing.inline) { screenText("Расшифровка не завершена").foregroundStyle(Color.mutedInk); Spacer(); screenButton("Продолжить расшифровку") { state.enqueue(meeting.id) }.actionButton(.primary, size: .small) }.textStyle(PisyaDesign.Typography.caption).padding(.vertical, PisyaDesign.Spacing.content)
            }
            if meeting.segments.isEmpty {
                VStack(spacing: PisyaDesign.Spacing.section) {
                    Spacer()
                    if state.recordingMeetingID != meeting.id { Image(systemName: meeting.status == .failed ? "exclamationmark.waveform" : "waveform").font(PisyaDesign.Typography.Icon.emptyState).foregroundStyle(Color.moss) }
                    screenText(state.recordingMeetingID == meeting.id ? (state.processingID == meeting.id ? "Здесь появится черновик" : "Расшифровка появится после записи") : meeting.status == .processing ? "Слушаю и превращаю в текст" : meeting.status == .failed ? (state.hasAudio(meeting) ? "Обработка не завершена" : "Запись не началась") : "Аудио сохранено").textStyle(PisyaDesign.Typography.dialogTitle)
                    if let error = meeting.error { screenText(error == "The user declined TCCs for application, window, display capture" ? CapturePermission.systemAudio.localizedDescription : error).textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk).multilineTextAlignment(.center).frame(maxWidth: 420) }
                    if !state.recording && meeting.status != .processing && state.hasAudio(meeting) { screenButton(state.modelReady ? (meeting.liveCommittedUntil == nil ? "Расшифровать" : "Продолжить расшифровку") : "Добавить модель") { state.enqueue(meeting.id) }.actionButton(.primary).controlSize(.large) }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        ForEach(meeting.segments.filter { transcriptSearch.isEmpty || !transcriptSearchRanges(in: typographicText($0.text), query: transcriptSearch).isEmpty || !transcriptSearchRanges(in: typographicText($0.speaker), query: transcriptSearch).isEmpty }) { segment in
                            HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
                                Button { state.play(segment, in: meeting) } label: { VStack(spacing: PisyaDesign.Spacing.inline) { screenText(timecode(segment.start)).textStyle(PisyaDesign.Typography.caption); Image(systemName: state.playingSegmentID == segment.id ? "stop.fill" : "play.fill").textStyle(PisyaDesign.Typography.footnote) }.frame(width: 56, alignment: .leading).padding(.top, PisyaDesign.Spacing.compact) }.buttonStyle(AccentIconStyle()).controlKeyboardFocus().focusEffectDisabled().disabled(state.demo || state.recording || meeting.audioFiles.isEmpty).screenHelp("Прослушать фрагмент")
                                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                    screenText(segment.speaker, highlighting: transcriptSearch).textStyle(PisyaDesign.Typography.detailStrong).foregroundStyle(segment.speaker == "Я" ? Color.moss : Color.ink)
                                    screenText(segment.text, highlighting: transcriptSearch).textStyle(PisyaDesign.Typography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button { editing = segment } label: { Image(systemName: "pencil").textStyle(PisyaDesign.Typography.detail) }.buttonStyle(AccentIconStyle()).controlKeyboardFocus().focusEffectDisabled().disabled(state.recordingMeetingID == meeting.id || state.processingID == meeting.id).screenHelp("Исправить реплику")
                            }
                        }
                    }.padding(.vertical, PisyaDesign.Spacing.section).padding(.trailing, PisyaDesign.Spacing.related)
                }
            }
            HStack(spacing: PisyaDesign.Spacing.inline) { Image(systemName: "lock.shield"); screenText("Локальная расшифровка"); Spacer(); screenText("Только на этом Mac") }.textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk).padding(.vertical, PisyaDesign.Spacing.content)
        }.padding(.horizontal, PisyaDesign.Spacing.page).padding(.top, PisyaDesign.Spacing.page)
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
        HStack(spacing: PisyaDesign.Spacing.related) {
            Button { state.voiceMeeting = meeting } label: { screenLabel("Разметить голоса", systemImage: "person.wave.2") }
                .actionButton()
                .disabled(meeting.segments.isEmpty || !state.canModify(meeting))
            Menu {
                screenButton("Без папки") { state.move(meeting, to: nil) }
                Divider()
                ForEach(state.folders) { folder in Button { state.move(meeting, to: folder.id) } label: { screenLabel(folder.name, systemImage: folder.iconName) } }
            } label: {
                screenLabel(state.folders.first(where: { $0.id == meeting.folderID })?.name ?? "Папка", systemImage: state.folders.first(where: { $0.id == meeting.folderID })?.iconName ?? "folder")
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
            }.actionButton().disabled(!state.canModify(meeting)).fixedSize()
                .screenHelp(state.folders.first(where: { $0.id == meeting.folderID })?.name ?? "Переместить в папку")
        }
    }
    private var exportControl: some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            Button { state.exportSelected() } label: { screenLabel("Поделиться", systemImage: "square.and.arrow.up") }
                .actionButton()
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
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Исправить реплику", style: .dialog)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                TextField("Участник", text: $segment.speaker).textFieldStyle(PisyaTextFieldStyle())
                FormTextEditor(text: $segment.text)
            }
            HStack(spacing: PisyaDesign.Spacing.related) { screenButton("Отмена") { dismiss() }.actionButton(); Spacer(); screenButton("Сохранить") { save(segment) }.actionButton(.primary) }
        }.dialogContent().frame(width: 520)
    }
}


private struct RecordingWaveformView: View {
    @ObservedObject var monitor: RecordingMonitor
    let started: Date?
    var body: some View {
        VStack(spacing: PisyaDesign.Spacing.content) {
            HStack(spacing: PisyaDesign.Spacing.inline) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                screenText("Идёт запись").textStyle(PisyaDesign.Typography.bodyStrong)
                Spacer()
                if let started { screenText(started, style: .timer).textStyle(PisyaDesign.Typography.body).monospacedDigit() }
            }
            lane("Микрофон", icon: "mic", track: monitor.microphone, color: .moss)
            lane("Системный звук", icon: "speaker.wave.2", track: monitor.system, color: Color(white: 0.48))
        }.padding(.horizontal, PisyaDesign.Spacing.page).padding(.vertical, PisyaDesign.Spacing.content).background(Color.moss.opacity(0.045))
    }
    private func lane(_ title: String, icon: String, track: AudioMeterTrack, color: Color) -> some View {
        let fresh = track.isFresh(now: monitor.now)
        let waiting = monitor.now - monitor.began < 3
        let status = !fresh && !waiting ? "Нет новых данных" : ""
        return HStack(spacing: PisyaDesign.Spacing.content) {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                screenLabel(title, systemImage: icon).textStyle(PisyaDesign.Typography.detailMedium)
                if !status.isEmpty { screenText(status).textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.orange) }
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
            VStack(alignment: .trailing, spacing: PisyaDesign.Spacing.inline) {
                screenText(timecode(track.seconds)).textStyle(PisyaDesign.Typography.footnote).monospacedDigit()
                screenText("записано").textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk)
            }.frame(width: 66, alignment: .trailing)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title). \(status). Записано \(timecode(track.seconds))")
            .screenHelp("Уровень звука после записи в аудиофайл. Нет новых данных — проверьте источник; системный звук может отсутствовать, когда приложения молчат.")
    }
}
