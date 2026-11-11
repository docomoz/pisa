import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var showingMeetingPhrase = false
    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.none) {
            sidebar.frame(width: 270)
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            VStack(spacing: PisyaDesign.Spacing.none) {
                topbar
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
        .sheet(isPresented: $showingMeetingPhrase) { MeetingPhraseView() }
        .sheet(item: $state.reprocessTarget) { meeting in
            ConfirmationSheet(
                title: "Расшифровать встречу заново?",
                message: "Текущий текст, исправления и разметка участников будут заменены. Аудио сохранится.",
                actionTitle: "Расшифровать заново"
            ) { state.enqueue(meeting.id, reprocess: true) }
        }
        .sheet(item: $state.renameTarget) { meeting in NameEditor(title: "Переименовать запись", initial: meeting.title) { state.rename(meeting, to: $0) } }
        .sheet(item: $state.voiceMeeting) { meeting in VoiceManager(meetingID: meeting.id).environmentObject(state) }
        .sheet(item: $state.newFolderMeeting) { meeting in
            FolderEditor(folder: nil) { name, symbol in
                state.moveToNewFolder(meeting, name: name, symbol: symbol)
            }
        }
    }
    private var sidebar: some View { LibrarySidebar() }
    private var topbar: some View {
        HStack(alignment: .top, spacing: PisyaDesign.Spacing.related) {
            if state.recording, let started = state.recordingStarted {
                RecordingIndicator(monitor: state.recordingMonitor, started: started)
                    .frame(minHeight: PisyaDesign.Metrics.regularHeight)
                    .padding(.top, PisyaDesign.Spacing.content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(TitleBarZoom().allowsHitTesting(false))
            } else {
                HStack(spacing: PisyaDesign.Spacing.inline) {
                    Image(nsImage: BrandMark.headerIcon).resizable().frame(width: 24, height: 24)
                    BrandMoodView()
                }
                .accessibilityElement(children: .combine)
                .frame(minHeight: PisyaDesign.Metrics.regularHeight)
                .padding(.top, PisyaDesign.Spacing.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TitleBarZoom().allowsHitTesting(false))
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                Button { showingMeetingPhrase = true } label: {
                    Text("🤦").font(PisyaDesign.Typography.Icon.medium)
                }.actionButton().screenHelp("Фраза для созвона").accessibilityLabel("Фраза для созвона")
                Button { state.showingSettings = true } label: {
                    Image(systemName: "gearshape").textStyle(PisyaDesign.Typography.detailMedium)
                }.actionButton().screenHelp("Настройки · ⌘,").accessibilityLabel("Настройки")
                Button { state.importAudio() } label: {
                    screenLabel("Импорт", systemImage: "tray.and.arrow.down")
                }.actionButton().disabled(state.demo)
                    .screenHelp("Импортировать аудио").accessibilityLabel("Импортировать аудио")
                Button { Task { if state.recording { await state.stopRecording(manual: true) } else { await state.startRecording() } } } label: {
                    screenLabel(state.starting ? (state.recordingStarted == nil ? "Подготовка…" : "Сохраняю…") : state.recording ? "Остановить запись" : "Начать запись", systemImage: state.recording ? "stop.fill" : "record.circle")
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }.actionButton(.recording)
                    .disabled(state.starting || state.demo)
            }.controlSize(.large).fixedSize(horizontal: true, vertical: false)
                .padding(.top, PisyaDesign.Spacing.content)
        }.padding(.horizontal, PisyaDesign.Spacing.page).frame(height: 76)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76).padding(.bottom, PisyaDesign.Spacing.section)
            screenText("Вы разговариваете.\nPisya записывает.").textStyle(PisyaDesign.Typography.hero)
            screenText("Записывайте встречи и находите нужное в расшифровке.\nАудио и распознавание — на вашем Mac.").textStyle(PisyaDesign.Typography.secondary).foregroundStyle(Color.mutedInk).padding(.top, PisyaDesign.Spacing.content)
            HStack(spacing: PisyaDesign.Spacing.related) {
                Button { state.showingSettings = true } label: { screenText("Настроить") }.actionButton(.primary)
            }.padding(.top, PisyaDesign.Spacing.section)
            Spacer()
            HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
                feature("lock", "Локальное распознавание", "Расшифровывайте аудио на своём Mac")
                feature("doc.text", "Экспорт расшифровок", "Сохраняйте Markdown в папку на Mac, в Dropbox или в Obsidian")
                feature("link", "Работа через MCP", "Получайте от ИИ‑ассистента итоги встреч и список задач")
            }.padding(.bottom, PisyaDesign.Spacing.page)
        }.padding(.horizontal, PisyaDesign.Spacing.page).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            Image(systemName: icon).font(PisyaDesign.Typography.Icon.medium).foregroundStyle(Color.moss)
            SectionHeading(title, subtitle: detail, style: .feature)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TitleBarZoom: NSViewRepresentable {
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ nsView: Observer, context: Context) {}

    final class Observer: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window, event.window === window,
                      event.clickCount == 2, window.attachedSheet == nil,
                      !window.styleMask.contains(.fullScreen) else { return event }

                let location = event.locationInWindow
                guard location.y >= window.contentLayoutRect.maxY ||
                        bounds.contains(convert(location, from: nil)) else { return event }

                // Let the traffic lights handle their own clicks inside the title bar.
                let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                guard !buttons.contains(where: { type in
                    guard let button = window.standardWindowButton(type), !button.isHidden else { return false }
                    return button.bounds.contains(button.convert(location, from: nil))
                }) else { return event }

                window.zoom(nil)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct MeetingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appTextScale) private var textScale
    let meeting: Meeting
    @State private var editing: TranscriptSegment?
    @State private var reviewingTerms = false
    @State private var title = ""
    @State private var confirmDeleteAudio = false
    @State private var transcriptSearch = ""
    @State private var showsSavedAudio = false
    @State private var showsMeetingDetails = false
    @State private var showsDetailsKeyboardFocus = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, search }
    // Keep at least this much space for the transcript and the gap beside it.
    private static let transcriptWidthWithDetails: CGFloat = 529
    private static let detailsColumnWidth: CGFloat = 228
    private var isRecording: Bool { state.recordingMeetingID == meeting.id }
    private var isSaving: Bool { state.savingMeetingID == meeting.id }
    private var isQueued: Bool { state.isQueued(meeting.id) }
    private var isTranscribing: Bool { meeting.status == .processing && state.processingID == meeting.id }
    private var canStartLiveTranscription: Bool { isRecording && state.canStartLiveTranscription }
    private var showsTranscriptTools: Bool { meeting.status == .ready && !isRecording && !isSaving && !isQueued }
    private var showsAutomaticPlayer: Bool { !showsTranscriptTools && meeting.segments.isEmpty }
    private var showsTranscriptStatus: Bool { isSaving || isTranscribing || isQueued || (meeting.status == .failed && !meeting.segments.isEmpty) }
    private var needsTitleSpacing: Bool { showsTranscriptTools || (!showsTranscriptStatus && !isRecording) }
    private var finishesRecording: Bool {
        !state.isReprocessing && (meeting.liveCommittedUntil != nil || meeting.source == state.source)
    }
    private var transcriptQuery: String { showsTranscriptTools ? transcriptSearch : "" }
    private var titleInput: Binding<String> {
        Binding(get: { title }, set: { value in
            title = value
            state.stageRecordingTitle(value, for: meeting)
        })
    }
    var body: some View {
        let hasAudio = !isRecording && !isSaving && state.hasAudio(meeting)
        let audioSources = !isRecording && !isSaving && !state.demo && (showsAutomaticPlayer || hasAudio)
            ? MeetingAudioExport.playbackSources(for: meeting, in: state.library) : []
        let canToggleAudio = !showsAutomaticPlayer && !audioSources.isEmpty
        let visibleAudioSources = showsAutomaticPlayer || (canToggleAudio && showsSavedAudio) ? audioSources : []
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenText(meetingDateLabel(meeting.date))
                screenText("·")
                screenText(meeting.source)
                if !isRecording && !isSaving {
                    screenText("·")
                    screenText(timecode(meeting.duration)).monospacedDigit()
                    screenText("·")
                    audioStatus(hasAudio: hasAudio, canToggleAudio: canToggleAudio)
                }
                Spacer()
                if showsTranscriptTools { screenLabel("Готово", systemImage: "checkmark.circle") }
                if state.demo { screenButton("Закрыть пример") { state.showDemo() }.actionButton(size: .small) }
            }.textStyle(PisyaDesign.Typography.detail).foregroundStyle(Color.mutedInk).padding(.bottom, PisyaDesign.Spacing.related)
            TextField("Название встречи", text: titleInput).textFieldStyle(.plain)
                .textStyle(PisyaDesign.Typography.pageTitle).focused($focusedField, equals: .title)
                .layoutPriority(1)
                .disabled(!state.canRename(meeting))
                .onSubmit { saveTitle(resetIfEmpty: true); focusedField = nil }
                .onChange(of: focusedField) { old, new in if old == .title && new != .title { saveTitle() } }
                .onAppear { title = meeting.headingTitle }.onChange(of: meeting.headingTitle) { old, value in
                    if focusedField != .title || title == old { title = value }
                }
                .onDisappear { if title != meeting.headingTitle { state.rename(meeting, to: title) } }
            GeometryReader { geometry in
                let extraWidth = Self.detailsColumnWidth * (max(1, textScale) - 1)
                let showsColumn = showsTranscriptTools && geometry.size.width >= Self.transcriptWidthWithDetails + Self.detailsColumnWidth + extraWidth
                HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
                    transcriptColumn(showsDetailsButton: !showsColumn, audioSources: visibleAudioSources)
                    if showsColumn {
                        ScrollView {
                            meetingDetails(buttonSize: .regular)
                                .padding(.leading, PisyaDesign.Spacing.content)
                        }
                        .frame(width: Self.detailsColumnWidth + extraWidth)
                        .background(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
                        }
                    }
                }
                .onChange(of: showsColumn) { _, visible in
                    if visible { showsMeetingDetails = false }
                }
            }
            .padding(.top, needsTitleSpacing ? PisyaDesign.Spacing.related : PisyaDesign.Spacing.none)
            HStack(spacing: PisyaDesign.Spacing.inline) { Image(systemName: "lock.shield"); screenText("Локальная расшифровка"); Spacer(); screenText("Только на этом Mac") }.textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk).padding(.vertical, PisyaDesign.Spacing.content)
        }.padding(.horizontal, PisyaDesign.Spacing.page).padding(.top, PisyaDesign.Spacing.page)
        .background(SlimScrollbars().allowsHitTesting(false))
        .background(ClickToUnfocus())
        .onChange(of: canToggleAudio) { _, enabled in
            if !enabled { showsSavedAudio = false }
        }
        .onChange(of: showsTranscriptTools) { _, visible in
            if !visible {
                transcriptSearch = ""
                showsMeetingDetails = false
            }
        }
        .onExitCommand {
            showsMeetingDetails = false
            focusedField = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .sheet(isPresented: $confirmDeleteAudio) {
            ConfirmationSheet(
                title: "Удалить аудио этой встречи?",
                message: "Аудио удалится навсегда. Текст и сохранённые голосовые признаки останутся. Прослушать запись или расшифровать её заново будет нельзя.",
                actionTitle: "Удалить аудио",
                role: .destructive
            ) { state.deleteAudio(meeting) }
        }
        .sheet(item: $editing) { segment in
            SegmentEditor(segment: segment) { text in
                state.editSegmentText(text, from: segment, meetingID: meeting.id)
                editing = nil
            }
        }
        .sheet(isPresented: $reviewingTerms) { TermReview(meeting: meeting).environmentObject(state) }
    }

    @ViewBuilder
    private func audioStatus(hasAudio: Bool, canToggleAudio: Bool) -> some View {
        if canToggleAudio {
            Button { showsSavedAudio.toggle() } label: {
                HStack(spacing: PisyaDesign.Spacing.compact) {
                    screenLabel("Аудио сохранено", systemImage: "waveform")
                    Image(systemName: showsSavedAudio ? "chevron.up" : "chevron.down")
                        .textStyle(PisyaDesign.Typography.footnoteMedium)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, PisyaDesign.Spacing.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(AccentIconStyle())
            .onKeyPress(.space) {
                showsSavedAudio.toggle()
                return .handled
            }
            .controlKeyboardFocus()
            .fixedSize()
            .accessibilityValue(showsSavedAudio ? "Плеер открыт" : "Плеер закрыт")
            .screenHelp(showsSavedAudio ? "Свернуть плеер" : "Показать плеер")
        } else {
            screenLabel(hasAudio ? "Аудио сохранено" : "Без аудио", systemImage: "waveform")
                .fixedSize()
        }
    }

    private func transcriptColumn(showsDetailsButton: Bool, audioSources: [RecordingAudioSource]) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.none) {
            if showsTranscriptTools {
                transcriptTools(showsDetailsButton: showsDetailsButton, audioSources: audioSources)
            } else {
                transcriptStatus
                    .padding(.top, PisyaDesign.Spacing.content)
                    .padding(.bottom, PisyaDesign.Spacing.related)
                if !showsAutomaticPlayer && !audioSources.isEmpty {
                    SavedAudioPlayer(sources: audioSources, isInline: true)
                        .padding(.bottom, PisyaDesign.Spacing.related)
                }
            }
            Divider()
                .padding(.top, isRecording && !showsTranscriptStatus ? PisyaDesign.Spacing.content : PisyaDesign.Spacing.none)
            if showsAutomaticPlayer && !audioSources.isEmpty {
                SavedAudioPlayer(sources: audioSources)
            }
            if meeting.segments.isEmpty {
                VStack(spacing: PisyaDesign.Spacing.section) {
                    Spacer()
                    if isRecording || isSaving || isTranscribing || isQueued {
                        SectionHeading(isRecording && isTranscribing ? "Здесь появится черновик" : "Здесь появится расшифровка")
                        if canStartLiveTranscription && !showsTranscriptStatus {
                            liveTranscriptionButton.controlSize(.large)
                        }
                    } else {
                        if audioSources.isEmpty {
                            Image(systemName: meeting.status == .failed ? "exclamationmark.waveform" : "waveform")
                                .font(PisyaDesign.Typography.Icon.emptyState).foregroundStyle(Color.moss)
                        }
                        SectionHeading(meeting.status == .failed ? (state.hasAudio(meeting) ? "Обработка не завершена" : "Запись не началась") : "Аудио сохранено", style: .dialog)
                        if let error = meeting.error {
                            SupportingText(
                                error == "The user declined TCCs for application, window, display capture" ? CapturePermission.systemAudio.localizedDescription : error,
                                style: PisyaDesign.Typography.secondary
                            )
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        }
                        if state.hasAudio(meeting) { screenButton(state.modelReady ? (meeting.liveCommittedUntil == nil ? "Расшифровать" : "Продолжить расшифровку") : "Добавить модель") { state.enqueue(meeting.id) }.actionButton(.primary).controlSize(.large) }
                    }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        ForEach(meeting.segments.filter { transcriptQuery.isEmpty || !transcriptSearchRanges(in: typographicText($0.text), query: transcriptQuery).isEmpty || !transcriptSearchRanges(in: typographicText($0.speaker), query: transcriptQuery).isEmpty }) { segment in
                            let timecodeWidth = 56 * max(1, textScale)
                            HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
                                if isRecording {
                                    screenText(timecode(segment.start)).textStyle(PisyaDesign.Typography.caption)
                                        .frame(width: timecodeWidth, alignment: .leading).padding(.top, PisyaDesign.Spacing.compact)
                                } else {
                                    Button { state.play(segment, in: meeting) } label: { VStack(spacing: PisyaDesign.Spacing.inline) { screenText(timecode(segment.start)).textStyle(PisyaDesign.Typography.caption); Image(systemName: state.playingSegmentID == segment.id ? "stop.fill" : "play.fill").textStyle(PisyaDesign.Typography.footnote) }.frame(width: timecodeWidth, alignment: .leading).padding(.top, PisyaDesign.Spacing.compact) }.buttonStyle(AccentIconStyle()).controlKeyboardFocus().focusEffectDisabled().disabled(state.demo || state.recording || isSaving || meeting.audioFiles.isEmpty).screenHelp("Прослушать фрагмент")
                                }
                                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                                    screenText(segment.speaker, highlighting: transcriptQuery).textStyle(PisyaDesign.Typography.detailStrong).foregroundStyle(segment.speaker == "Я" ? Color.moss : Color.ink)
                                    screenText(segment.displayText, highlighting: transcriptQuery).textStyle(PisyaDesign.Typography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if showsTranscriptTools {
                                    Button { editing = segment } label: { Image(systemName: "pencil").textStyle(PisyaDesign.Typography.detail) }.buttonStyle(AccentIconStyle()).controlKeyboardFocus().focusEffectDisabled().disabled(state.processingID == meeting.id).screenHelp("Исправить реплику…")
                                }
                            }
                            .id(segment.id)
                            .background(state.sourceReveal?.meetingID == meeting.id && state.sourceReveal?.segmentID == segment.id ? Color.moss.opacity(0.12) : Color.clear)
                        }
                    }.padding(.vertical, PisyaDesign.Spacing.section).padding(.trailing, PisyaDesign.Spacing.related)
                        .opacity(isTranscribing && state.isReprocessing ? 0.6 : 1)
                }
                .onAppear { revealSource(using: proxy) }
                .onChange(of: state.sourceReveal) { _, _ in revealSource(using: proxy) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func revealSource(using proxy: ScrollViewProxy) {
        guard let reveal = state.sourceReveal, reveal.meetingID == meeting.id else { return }
        transcriptSearch = ""
        focusedField = nil
        // Wait for the cleared search and the newly selected meeting to enter the layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard state.sourceReveal == reveal else { return }
            withAnimation { proxy.scrollTo(reveal.segmentID, anchor: .center) }
        }
    }

    private func transcriptTools(showsDetailsButton: Bool, audioSources: [RecordingAudioSource]) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            if !audioSources.isEmpty {
                SavedAudioPlayer(sources: audioSources, isInline: true)
            }
            if !meeting.segments.isEmpty || showsDetailsButton {
                HStack(spacing: PisyaDesign.Spacing.inline) {
                    if !meeting.segments.isEmpty {
                        SearchField(title: "Поиск внутри записи", text: $transcriptSearch)
                            .focused($focusedField, equals: .search)
                    }
                    if showsDetailsButton { detailsButton }
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: PisyaDesign.Spacing.inline) {
                screenText("РАСШИФРОВКА").textStyle(PisyaDesign.Typography.transcriptHeading)
                Spacer()
                screenText(fragmentCount(meeting.segments.count))
            }.textStyle(PisyaDesign.Typography.footnoteMedium).foregroundStyle(Color.mutedInk)
        }.padding(.bottom, PisyaDesign.Spacing.related)
    }

    private var detailsButton: some View {
        Button {
            showsDetailsKeyboardFocus = PopupKeyboardNavigation.openedWithKeyboard
            showsMeetingDetails.toggle()
        } label: {
            screenLabel("Детали", systemImage: "sidebar.right").fixedSize()
        }
        .actionButton()
        .accessibilityValue(showsMeetingDetails ? "Открыто" : "Закрыто")
        .popover(isPresented: $showsMeetingDetails, attachmentAnchor: .point(.bottomLeading), arrowEdge: .top) {
            ViewThatFits(in: .vertical) {
                meetingDetails(buttonSize: .small).fixedSize(horizontal: false, vertical: true)
                ScrollView { meetingDetails(buttonSize: .small) }
            }
            .padding(PisyaDesign.Spacing.content)
            .frame(width: 256 * max(1, textScale))
            .frame(maxHeight: 360)
            .popupCanvas()
            .modifier(PopupKeyboardNavigation(showsFocus: $showsDetailsKeyboardFocus))
        }
    }

    @ViewBuilder
    private var transcriptStatus: some View {
        if showsTranscriptStatus {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                HStack(spacing: PisyaDesign.Spacing.related) {
                    if isRecording && isTranscribing {
                        screenText(transcriptStatusTitle)
                            .textStyle(PisyaDesign.Typography.detail)
                            .foregroundStyle(Color.mutedInk)
                    } else {
                        SectionHeading(transcriptStatusTitle, subtitle: transcriptionDetail)
                    }
                    Spacer(minLength: PisyaDesign.Spacing.none)
                    if meeting.status == .failed && meeting.deletedAt == nil
                        && !isSaving && state.canModify(meeting) && state.hasAudio(meeting) {
                        if meeting.liveCommittedUntil != nil {
                            screenButton("Продолжить расшифровку") { state.enqueue(meeting.id) }.actionButton(.primary)
                        } else {
                            screenButton("Расшифровать заново") { state.reprocessTarget = meeting }.actionButton(.primary)
                        }
                    }
                    if isRecording && isTranscribing {
                        screenButton(state.livePaused ? "Продолжить" : "Пауза") { state.toggleLivePause() }
                            .actionButton()
                            .accessibilityLabel(state.livePaused ? "Продолжить расшифровку" : "Приостановить расшифровку")
                    } else if canStartLiveTranscription {
                        liveTranscriptionButton
                    } else if isQueued {
                        screenButton("Убрать из очереди") { state.cancelQueued(meeting.id) }.actionButton()
                    } else if isTranscribing && !isSaving {
                        screenButton("Остановить обработку") { state.cancelProcessing() }.actionButton()
                    }
                }
                if isSaving || (isTranscribing && !isRecording && !state.livePaused) {
                    let isLive = !isSaving && !state.liveStatus.isEmpty
                    let fraction = isSaving ? nil : isLive ? liveAudioProgress : processingProgress
                    TranscriptionProgress(fraction: fraction,
                                          label: isSaving ? "Сохранение записи" : isLive ? "Доля обработанного аудио" : "Ход расшифровки",
                                          roundsDown: isLive)
                }
            }
        }
    }
    private var liveTranscriptionButton: some View {
        screenButton((meeting.liveCommittedUntil ?? 0) > 0 ? "Продолжить расшифровку" : "Начать расшифровку") {
            state.enqueue(meeting.id)
        }.actionButton(.primary)
    }
    private var transcriptStatusTitle: String {
        if isSaving { return "Сохраняю запись" }
        if isQueued { return "В очереди на расшифровку" }
        if isTranscribing {
            if state.isReprocessing { return "Расшифровываю заново" }
            if !state.liveStatus.isEmpty { return state.liveStatus }
            return finishesRecording ? "Завершаю расшифровку" : "Расшифровываю аудио"
        }
        return "Расшифровка не завершена"
    }
    private var transcriptionDetail: String? {
        guard isTranscribing, !isRecording, !isSaving else { return nil }
        if !state.liveStatus.isEmpty { return liveAudioProgress == nil ? nil : "Доля обработанного аудио" }
        if !state.phase.isEmpty { return state.phase }
        return finishesRecording ? "Запись сохранена" : nil
    }
    private var liveAudioProgress: Double? {
        LiveTranscriptionSchedule.audioProgress(committed: meeting.liveCommittedUntil, duration: state.liveAudioDuration)
    }
    private var processingProgress: Double? { state.phase.isEmpty ? nil : state.progress }
    private func saveTitle(resetIfEmpty: Bool = false) {
        let savedTitle = state.meetings.first(where: { $0.id == meeting.id })?.headingTitle ?? meeting.headingTitle
        if title != savedTitle { state.rename(meeting, to: title, resetIfEmpty: resetIfEmpty) }
        title = state.meetings.first(where: { $0.id == meeting.id })?.headingTitle ?? meeting.headingTitle
    }
    private func meetingDetails(buttonSize: ActionButtonSize) -> some View {
        let folder = state.folders.first { $0.id == meeting.folderID }
        return VStack(alignment: .leading, spacing: buttonSize == .small ? PisyaDesign.Spacing.content : PisyaDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                SectionHeading("ДЕЙСТВИЯ", style: .feature).foregroundStyle(Color.mutedInk)
                VStack(spacing: PisyaDesign.Spacing.inline) {
                    Button {
                        showsMeetingDetails = false
                        state.voiceMeeting = meeting
                    } label: {
                        detailsActionLabel("Разметить голоса", systemImage: "person.wave.2")
                    }
                    .actionButton(size: buttonSize)
                    .disabled(meeting.segments.isEmpty || !state.canModify(meeting))

                    Button {
                        showsMeetingDetails = false
                        reviewingTerms = true
                    } label: {
                        detailsActionLabel("Разметить термины", systemImage: "text.magnifyingglass")
                    }
                    .actionButton(size: buttonSize)
                    .disabled(!state.canReviewTerms(meeting))

                    NativeActionMenu {
                        MeetingActionSet(state: state, meeting: meeting).folderMenuItems { showsMeetingDetails = false }
                    } label: {
                        detailsActionLabel(folder?.name ?? "Папка", systemImage: folder?.iconName ?? "folder", hasMenu: true)
                    }
                    .actionButton(size: buttonSize)
                    .disabled(!state.canModify(meeting))
                    .screenHelp(folder?.name ?? "Переместить в папку")

                    NativeActionMenu {
                        [
                            NativeActionMenuItem("Расшифровка…", enabled: state.canExport(meeting)) {
                                showsMeetingDetails = false
                                state.exportTranscript(meeting)
                            },
                            NativeActionMenuItem("Аудио…", enabled: state.canExportAudio(meeting)) {
                                showsMeetingDetails = false
                                Task { await state.exportAudio(meeting) }
                            }
                        ]
                    } label: {
                        detailsActionLabel("Поделиться", systemImage: "square.and.arrow.up", hasMenu: true)
                    }
                    .actionButton(size: buttonSize)
                    .disabled(!state.canExport(meeting) && !state.canExportAudio(meeting))

                    NativeActionMenu {
                        meetingMenuItems
                    } label: {
                        detailsActionLabel("Ещё", systemImage: "ellipsis", hasMenu: true)
                    }
                    .actionButton(size: buttonSize)
                    .disabled(!state.canModify(meeting))
                }
            }
            if !meeting.speakers.isEmpty {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                    SectionHeading("СОБЕСЕДНИКИ", style: .feature).foregroundStyle(Color.mutedInk)
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        ForEach(meeting.speakers, id: \.self) { speaker in
                            screenLabel(speaker, systemImage: "person.crop.circle")
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                        }
                    }.textStyle(PisyaDesign.Typography.detail).foregroundStyle(Color.mutedInk)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .controlSize(.large)
    }

    private var meetingMenuItems: [NSMenuItem] {
        let actions = MeetingActionSet(state: state, meeting: meeting)
        var items = meeting.deletedAt == nil
            ? [actions.rename.nativeItem, .separator(), actions.reprocess.nativeItem, .separator(), actions.trash.nativeItem]
            : [actions.restore.nativeItem]
        if !meeting.audioFiles.isEmpty {
            if meeting.deletedAt != nil { items.append(.separator()) }
            items.append(NativeActionMenuItem("Удалить аудио") {
                showsMeetingDetails = false
                confirmDeleteAudio = true
            })
        }
        return items
    }

    private func detailsActionLabel(_ title: String, systemImage: String, hasMenu: Bool = false) -> some View {
        HStack(spacing: PisyaDesign.Spacing.inline) {
            Label {
                screenText(title).textStyle(PisyaDesign.Typography.smallButton)
            } icon: {
                let icon = Image(systemName: systemImage)
                ViewThatFits(in: .horizontal) {
                    icon.fixedSize()
                    icon.resizable().scaledToFit()
                        .frame(width: PisyaDesign.Metrics.labelIconWidth)
                        .fixedSize()
                }
            }
            .labelStyle(AlignedIconLabelStyle())
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasMenu {
                Image(systemName: "chevron.down").font(PisyaDesign.Typography.Icon.disclosure)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct TranscriptionProgress: View {
    let fraction: Double?
    let label: String
    var roundsDown = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        HStack(spacing: PisyaDesign.Spacing.related) {
            GeometryReader { geometry in
                let width = geometry.size.width
                Capsule().fill(Color.moss.opacity(0.12))
                    .overlay(alignment: .leading) {
                        if let fraction {
                            Capsule().fill(Color.brandAccent).frame(width: width * fraction)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
                        } else {
                            let segmentWidth = width * 0.25
                            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                                let offset = reduceMotion ? (width - segmentWidth) / 2 : (width + segmentWidth) * cycle - segmentWidth
                                Capsule().fill(Color.brandAccent).frame(width: segmentWidth).offset(x: offset)
                            }
                        }
                    }
                    .clipShape(Capsule())
            }
            .frame(height: PisyaDesign.Metrics.progressHeight)
            if let fraction {
                screenText(fraction.formatted(.percent.precision(.fractionLength(0))
                    .rounded(rule: roundsDown ? .down : .toNearestOrEven).locale(locale)))
                    .textStyle(PisyaDesign.Typography.detailStrong)
                    .monospacedDigit()
                    .foregroundStyle(Color.moss)
                    .frame(minWidth: PisyaDesign.Metrics.progressValueWidth, alignment: .trailing)
                    .fixedSize()
            }
        }
        .accessibilityRepresentation {
            ProgressView(value: fraction).accessibilityLabel(label)
        }
    }
}

private struct SegmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    private let speaker: String
    private let save: (String) -> Void

    init(segment: TranscriptSegment, save: @escaping (String) -> Void) {
        speaker = segment.speaker
        _text = State(initialValue: segment.text)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Исправить реплику", style: .dialog)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
                screenText(speaker).textStyle(PisyaDesign.Typography.detailStrong)
                FormTextEditor(text: $text).accessibilityLabel("Текст реплики")
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена") { dismiss() }.actionButton()
                Spacer()
                screenButton("Сохранить") { save(text) }.actionButton(.primary)
            }
        }.dialogContent().frame(width: 520)
    }
}


private struct RecordingIndicator: View {
    @ObservedObject var monitor: RecordingMonitor
    let started: Date
    @State private var showsWaveforms = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            indicator(compact: false)
            indicator(compact: true)
        }
    }

    private func indicator(compact: Bool) -> some View {
        HStack(spacing: PisyaDesign.Spacing.related) {
            HStack(spacing: PisyaDesign.Spacing.inline) {
                Circle().fill(Color.recordingRed).frame(width: 7, height: 7)
                    .accessibilityLabel("Идёт запись")
                    .accessibilityHidden(!compact)
                HStack(alignment: .firstTextBaseline, spacing: PisyaDesign.Spacing.inline) {
                    if !compact {
                        screenText("Идёт запись")
                            .textStyle(PisyaDesign.Typography.detailStrong)
                            .foregroundStyle(Color.recordingRed)
                    }
                    RecordingElapsed(started: started)
                }
            }
            .accessibilityElement(children: .combine)
            Button { showsWaveforms.toggle() } label: {
                Group {
                    if compact {
                        Image(systemName: "waveform")
                    } else {
                        HStack(spacing: PisyaDesign.Spacing.related) {
                            meter("mic", track: monitor.microphone)
                            meter("speaker.wave.2", track: monitor.system)
                        }
                    }
                }.accessibilityHidden(true)
            }
            .actionButton(size: .small)
            .accessibilityLabel("Уровни записи")
            .accessibilityValue("Микрофон: \(signalDescription(monitor.microphone)). Системный звук: \(signalDescription(monitor.system))")
            .screenHelp("Показать дорожки микрофона и системного звука")
            .popover(isPresented: $showsWaveforms, arrowEdge: .bottom) {
                RecordingWaveformView(monitor: monitor)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func missingSignal(_ track: AudioMeterTrack) -> Bool {
        monitor.now - monitor.began >= 3 && !track.isFresh(now: monitor.now)
    }
    private func signalDescription(_ track: AudioMeterTrack) -> String {
        if missingSignal(track) { return "Нет новых данных" }
        return "Записано \(timecode(track.seconds))"
    }
    private func meter(_ icon: String, track: AudioMeterTrack) -> some View {
        HStack(spacing: PisyaDesign.Spacing.compact) {
            Image(systemName: icon).textStyle(PisyaDesign.Typography.footnote)
            Group {
                if missingSignal(track) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                } else {
                    Capsule().fill(Color.moss.opacity(0.17)).overlay(alignment: .leading) {
                        Capsule().fill(Color.moss).frame(width: 18 * CGFloat(track.level))
                    }.frame(height: 4)
                }
            }.frame(width: 18).textStyle(PisyaDesign.Typography.footnote)
        }
    }
}

private struct RecordingWaveformView: View {
    @ObservedObject var monitor: RecordingMonitor
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            SectionHeading("Уровни записи")
            lane("Микрофон", icon: "mic", track: monitor.microphone, color: .moss)
            lane("Системный звук", icon: "speaker.wave.2", track: monitor.system, color: Color(white: 0.48))
        }.padding(PisyaDesign.Spacing.section).frame(width: 500).popupCanvas()
    }
    private func lane(_ title: String, icon: String, track: AudioMeterTrack, color: Color) -> some View {
        let fresh = track.isFresh(now: monitor.now)
        let waiting = monitor.now - monitor.began < 3
        let status = !fresh && !waiting ? "Нет новых данных" : ""
        return HStack(spacing: PisyaDesign.Spacing.related) {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.compact) {
                screenLabel(title, systemImage: icon).textStyle(PisyaDesign.Typography.detailMedium)
                if !status.isEmpty { screenText(status).textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.orange) }
            }.frame(width: 156 * max(1, textScale), alignment: .leading)
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
            }.frame(height: 40).clipped().accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: PisyaDesign.Spacing.compact) {
                screenText(timecode(track.seconds)).textStyle(PisyaDesign.Typography.footnote).monospacedDigit()
                screenText("записано").textStyle(PisyaDesign.Typography.footnote).foregroundStyle(Color.mutedInk)
            }.frame(width: 66 * max(1, textScale), alignment: .trailing)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title). \(status). Записано \(timecode(track.seconds))")
            .screenHelp("Уровень звука после записи в аудиофайл. Нет новых данных — проверьте источник; системный звук может отсутствовать, когда приложения молчат.")
    }
}
