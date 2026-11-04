import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published var folders: [MeetingFolder] = []
    @Published var folderFilter: UUID?
    @Published var showingTrash = false
    @Published var unfiledOnly = false
    @Published var renameTarget: Meeting?
    @Published var voiceMeeting: Meeting?
    @Published var reprocessTarget: Meeting?
    private var searchIndex: [UUID: String] = [:]
    @Published var preferences = Preferences()
    @Published var search = ""
    @Published var recording = false
    @Published var starting = false
    @Published var recordingStarted: Date?
    @Published var processingID: UUID?
    @Published var progress: Double = 0
    @Published var phase = ""
    @Published var permissionIssue: CapturePermission?
    @Published var message: String?
    @Published var showingSettings = false
    @Published var callActive = false
    @Published var livePaused = false
    @Published var liveStatus = ""
    let source = "Системный звук"
    @Published var demo = false
    @Published var voiceProfiles: [VoiceProfile] = []
    let library: MeetingLibrary
    @Published var playingSegmentID: UUID?
    private var player: AVAudioPlayer?
    private var playbackEnd: Double = 0
    private var playbackTimer: Timer?
    private let capture = AudioCapture()
    let recordingMonitor = RecordingMonitor()
    private var meterTask: Task<Void, Never>?
    private var offsetTask: Task<Void, Never>?
    private let transcriber = Transcriber()
    private var processingTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveStopped = false
    private var timer: Timer?
    private var detector = CallDetector()
    private var activeMeeting: Meeting?
    var recordingMeetingID: UUID? { recording ? activeMeeting?.id : nil }
    private var automaticallyStarted = false
    private var pending: [UUID] = []
    private var pendingReprocessing: Set<UUID> = []
    var selected: Meeting? { meetings.first { $0.id == selection } }
    var filtered: [Meeting] {
        meetings.filter { m in
            (showingTrash ? m.deletedAt != nil : m.deletedAt == nil) &&
            (showingTrash || (folderFilter == nil || m.folderID == folderFilter) && (!unfiledOnly || m.folderID == nil)) &&
            (search.isEmpty || (searchIndex[m.id] ?? m.title).localizedCaseInsensitiveContains(search))
        }
    }
    func select(_ id: UUID?) { stopPlayback(); selection = id }
    func openFolder(_ id: UUID? = nil, trash: Bool = false, unfiled: Bool = false) {
        folderFilter = id; showingTrash = trash; unfiledOnly = unfiled
        select(filtered.first?.id)
    }
    func canModify(_ m: Meeting) -> Bool { !demo && activeMeeting?.id != m.id && processingID != m.id && !pending.contains(m.id) }
    func rename(_ m: Meeting, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, canModify(m), var latest = meetings.first(where: { $0.id == m.id }) else { return }
        latest.title = title; update(latest)
    }
    func move(_ m: Meeting, to folder: UUID?) {
        guard canModify(m), var latest = meetings.first(where: { $0.id == m.id }) else { return }
        latest.folderID = folder; update(latest)
        if !filtered.contains(where: { $0.id == selection }) { select(filtered.first?.id) }
    }
    func trash(_ m: Meeting, restore: Bool = false) {
        guard canModify(m), var latest = meetings.first(where: { $0.id == m.id }) else { return }
        stopPlayback(); latest.deletedAt = restore ? nil : Date()
        do { try library.save(latest); upsert(latest); select(filtered.first?.id) } catch { message = error.localizedDescription }
    }
    var canEmptyTrash: Bool {
        !demo && meetings.contains { $0.deletedAt != nil } && meetings.filter { $0.deletedAt != nil }.allSatisfy { canModify($0) }
    }
    func emptyTrash() {
        guard canEmptyTrash else { return }
        stopPlayback()
        do {
            for m in meetings where m.deletedAt != nil { try library.purgeTrashed(m.id) }
        } catch { message = error.localizedDescription }
        do {
            meetings = try library.all(includeDeleted: true)
            for index in meetings.indices {
                if meetings[index].refreshAutomaticTitle() {
                    do { try library.save(meetings[index]) }
                    catch { message = "Не удалось сохранить новое название: " + error.localizedDescription }
                }
            }
            searchIndex = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.searchableText) })
            select(filtered.first?.id)
        } catch { message = error.localizedDescription }
    }
    func saveFolder(_ name: String, id: UUID? = nil, symbol: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty, !demo else { return }
        var updated = folders
        if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].name = name; if let symbol { updated[index].symbol = symbol } }
        else { updated.append(MeetingFolder(name: name, symbol: symbol)) }
        do { try library.saveFolders(updated); folders = updated } catch { message = error.localizedDescription }
    }
    func removeFolder(_ folder: MeetingFolder) {
        guard !demo else { return }
        do {
            for var m in meetings where m.folderID == folder.id { m.folderID = nil; try library.save(m); upsert(m) }
            let updated = folders.filter { $0.id != folder.id }; try library.saveFolders(updated); folders = updated
            if folderFilter == folder.id { openFolder() }
        } catch { message = error.localizedDescription }
    }
    lazy var modelSetup = ModelSetup(root: library.root.appendingPathComponent("Models"), customModel: { [weak self] in self?.modelURL() }, usesCustomModel: { [weak self] in self?.preferences.modelBookmark != nil })
    private var modelSetupObservation: AnyCancellable?
    var modelReady: Bool { modelSetup.ready }
    func modelInstallationCompleted() {
        if !modelSetup.installedUsingCustom { preferences.modelBookmark = nil; preferences.modelDisplayPath = nil; savePreferences() }
    }
    var mcpPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pisya-mcp").path }
    init(rootURL: URL? = nil) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisya", isDirectory: true)
        do { library = try MeetingLibrary(root: root) } catch { fatalError("Не удалось открыть библиотеку: \(error.localizedDescription)") }
        do {
            preferences = try library.preferences()
            voiceProfiles = try library.voices()
            meetings = try library.all(includeDeleted: true)
            for index in meetings.indices {
                if meetings[index].refreshAutomaticTitle() {
                    do { try library.save(meetings[index]) }
                    catch { message = "Не удалось сохранить новое название: " + error.localizedDescription }
                }
            }
            folders = try library.folders()
            searchIndex = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.searchableText) })
            for index in meetings.indices where meetings[index].status == .processing {
                meetings[index].status = .failed
                meetings[index].error = "Обработка прервалась. Аудио сохранено — можно повторить"
                try library.save(meetings[index])
            }
            selection = filtered.first?.id
        } catch { message = error.localizedDescription }
        modelSetupObservation = modelSetup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        capture.onFailure = { [weak self] error in Task { @MainActor in self?.message = error; if self?.recording == true { await self?.stopRecording() } } }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollCall() } }
    }
    func hasAudio(_ meeting: Meeting) -> Bool {
        meeting.audioFiles.contains { name in
            guard let url = try? library.audioURL(name), FileManager.default.fileExists(atPath: url.path), let file = try? AVAudioFile(forReading: url) else { return false }
            return file.length > 0
        }
    }
    func savePreferences() { do { try library.savePreferences(preferences) } catch { message = error.localizedDescription } }
    func setAutomatic(_ enabled: Bool) { preferences.automaticRecording = enabled; detector.reset(); savePreferences() }
    func setBackgroundTranscription(_ enabled: Bool) { preferences.backgroundTranscription = enabled; savePreferences() }
    func toggleLivePause() { livePaused.toggle(); liveStatus = livePaused ? "Расшифровка на паузе" : "Готовлю черновик" }
    private func pollCall() {
        if let player, player.isPlaying, player.currentTime >= playbackEnd { player.stop(); playingSegmentID = nil }
        if let player, !player.isPlaying { playingSegmentID = nil }
        guard preferences.automaticRecording, !demo, !modelSetup.presented, !modelSetup.busy else { return }
        Task {
            let active = await Task.detached(priority: .utility) { CallAudioProbe.isActive() }.value
            guard preferences.automaticRecording else { return }
            if callActive != active { callActive = active }
            handleCallActivity(active)
        }
    }
    private func handleCallActivity(_ active: Bool) {
        switch detector.update(active: active, now: Date()) {
        case .start:
            if recording { automaticallyStarted = true } // Arm stop only after a call actually appears.
            else if !starting { Task { await startRecording(automatic: true) } }
        case .stop: if automaticallyStarted && recording { Task { await stopRecording() } }
        case .none: break
        }
    }
    func startRecording(automatic: Bool = false) async {
        guard !recording, !starting, !demo else { return }
        guard !modelSetup.busy, !modelSetup.presented else { modelSetup.presented = true; return }
        player?.stop(); playingSegmentID = nil
        starting = true; defer { starting = false }
        let selectedSource = source
        var m = Meeting(title: "", source: selectedSource)
        m.title = m.defaultTitle; m.automaticTitle = m.title
        let runLive = preferences.usesBackgroundTranscription && modelReady && processingID == nil
        if runLive { m.status = .processing; m.liveCommittedUntil = 0; processingID = m.id }
        // Journal expected paths before capture, so interrupted sessions remain discoverable.
        m.audioFiles = ["\(m.id.uuidString)-mic.caf", "\(m.id.uuidString)-remote.caf"]
        do {
            try await capture.prepare()
            try library.save(m)
            try await capture.start(folder: library.audioDirectory, id: m.id)
            activeMeeting = m; recording = true; recordingStarted = Date(); automaticallyStarted = automatic
            recordingMonitor.reset()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let sample = await self.capture.meterSnapshot()
                    guard !Task.isCancelled else { return }
                    self.recordingMonitor.update(microphone: sample.0, system: sample.1)
                    do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
                }
            }
            let recordingID = m.id
            offsetTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let tracks = await self.capture.transcriptionBoundary(requireBoth: false)
                    guard !Task.isCancelled, self.recording, self.activeMeeting?.id == recordingID else { return }
                    if let tracks {
                        let offsets = Dictionary(uniqueKeysWithValues: tracks.map { ($0.url.lastPathComponent, $0.offset) })
                        if var latest = try? self.library.read(recordingID), latest.audioOffsets != offsets {
                            latest.audioOffsets = offsets
                            do { try self.library.save(latest); self.upsert(latest) }
                            catch { self.message = error.localizedDescription }
                        }
                    }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
            showingTrash = false; folderFilter = nil; unfiledOnly = false
            upsert(m); selection = m.id
            if runLive, let model = modelURL() {
                livePaused = false; liveStopped = false; liveStatus = "Готовлю черновик"
                processingID = m.id
                liveTask = Task(priority: .utility) { await self.runLiveTranscription(id: m.id, model: model) }
            }
        } catch {
            if runLive { processingID = nil; runNext() }
            m.status = .failed; m.error = error.localizedDescription
            if hasAudio(m) { try? library.save(m); upsert(m) }
            else { try? library.discardEmptyDraft(m) }
            if let permission = error as? CapturePermission { permissionIssue = permission }
            else { message = error.localizedDescription }
            detector.manuallyStopped()
        }
    }
    func stopRecording(manual: Bool = false) async {
        guard recording, var m = activeMeeting else { return }
        meterTask?.cancel(); meterTask = nil
        offsetTask?.cancel(); offsetTask = nil
        recording = false; starting = true; defer { starting = false }
        if manual { detector.manuallyStopped() }
        automaticallyStarted = false
        do {
            let result = try await capture.stop()
            m = (try? library.read(m.id)) ?? m
            m.audioFiles = result.files; m.audioOffsets = result.offsets; m.duration = result.duration
            guard !result.files.isEmpty else { throw PisyaError.message("Звук не получен. Проверьте разрешения и выбранное приложение") }
            try library.save(m); upsert(m)
            if let warning = result.warning { message = warning }
            if liveTask != nil && processingID == m.id { liveStopped = true }
            else if result.warning == nil && modelReady { enqueue(m.id) }
            else if !modelReady { message = "Запись сохранена. Загрузите модели в настройках, чтобы расшифровать её" }
        } catch {
            if processingID == m.id { liveStopped = true; liveTask?.cancel() }
            m = (try? library.read(m.id)) ?? m
            m.status = .failed; m.error = error.localizedDescription
            try? library.save(m); upsert(m); message = error.localizedDescription
        }
        activeMeeting = nil; recordingStarted = nil
    }
    func importAudio() {
        guard !demo else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]; panel.message = "Записи iPhone, M4A, WAV, MP3 и другие аудиофайлы"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let file = try AVAudioFile(forReading: url)
                var m = Meeting(title: "", source: "Аудиофайл")
                m.title = m.defaultTitle; m.automaticTitle = m.title
                m.duration = Double(file.length) / file.processingFormat.sampleRate
                let name = "\(m.id.uuidString)-import.\(url.pathExtension)"
                try FileManager.default.copyItem(at: url, to: library.audioURL(name))
                m.audioFiles = [name]; try library.save(m); upsert(m); selection = m.id
                if modelReady { enqueue(m.id) }
            } catch { message = error.localizedDescription }
        }
    }
    private func runLiveTranscription(id: UUID, model: URL) async {
        let granted = model.startAccessingSecurityScopedResource()
        var schedule = LiveTranscriptionSchedule(committed: (try? library.read(id).liveCommittedUntil) ?? 0)
        var failedDuringCapture = false
        var boundaryExhausted = false
        do {
            while true {
                try Task.checkCancellation()
                let stopped = liveStopped
                let thermal = ProcessInfo.processInfo.thermalState
                if thermal == .serious || thermal == .critical {
                    liveStatus = "Обработка отложена до охлаждения"
                    try await Task.sleep(nanoseconds: 5_000_000_000); continue
                }
                if !stopped && (livePaused || failedDuringCapture || boundaryExhausted) {
                    liveStatus = livePaused ? "Расшифровка на паузе" : "Черновик продолжится после записи"
                    try await Task.sleep(nanoseconds: 1_000_000_000); continue
                }
                let tracks: [CaptureTrackBoundary]
                if stopped {
                    let meeting = try library.read(id)
                    tracks = try meeting.audioFiles.filter { !$0.contains(".clean.") }.compactMap { name in
                        let url = try library.audioURL(name)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            if meeting.audioOffsets[name] != nil { throw PisyaError.message("Аудиодорожка встречи недоступна") }
                            return nil // The expected second stream never started.
                        }
                        let file = try AVAudioFile(forReading: url)
                        guard file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0 else { throw PisyaError.message("Некорректный формат аудиодорожки") }
                        return CaptureTrackBoundary(url: url, offset: meeting.audioOffsets[name] ?? 0, frames: file.length, sampleRate: file.processingFormat.sampleRate)
                    }
                    guard !tracks.isEmpty else { throw PisyaError.message("Аудио этой встречи недоступно") }
                } else {
                    guard let boundary = await capture.transcriptionBoundary() else {
                        try await Task.sleep(nanoseconds: 1_000_000_000); continue
                    }
                    tracks = boundary
                }
                let ends = tracks.map { $0.offset + Double($0.frames) / $0.sampleRate }
                let available = stopped ? (ends.max() ?? 0) : (ends.min() ?? 0)
                guard available.isFinite else { throw PisyaError.message("Некорректная длительность аудиодорожки") }
                if stopped && available + 0.05 < schedule.committed { throw PisyaError.message("Сохранённый черновик выходит за доступную длину аудио") }
                // The two seconds after the proposed cut are uncommitted
                // lookahead, so a turn crossing the cut can move wholly to the
                // next window without ever rereading the committed prefix.
                let schedulable = stopped ? available : max(0, available - 2)
                guard let window = schedule.next(available: schedulable, stopped: stopped) else {
                    if stopped {
                        var latest = try library.read(id)
                        let availableNames = Set(tracks.map { $0.url.lastPathComponent })
                        guard latest.segments.allSatisfy({ $0.audioFile.map(availableNames.contains) ?? true }) else { throw PisyaError.message("Аудио черновика недоступно") }
                        latest.segments = SpeakerClustering.assign(latest.segments.sorted { $0.start < $1.start }, profiles: voiceProfiles)
                        latest.duration = max(latest.duration, available)
                        latest.status = .ready; latest.error = nil; latest.liveCommittedUntil = nil
                        try library.save(latest); upsert(latest); exportIfConfigured(latest)
                        break
                    }
                    liveStatus = "Готовлю черновик"
                    try await Task.sleep(nanoseconds: 1_000_000_000); continue
                }
                let startedAt = Date()
                do {
                    liveStatus = stopped ? "Завершаю расшифровку" : "Готовлю черновик"
                    var segments = try await transcribeWindow(tracks, window: window, end: min(available, window.end + 2), model: model, quiet: stopped ? preferences.usesQuietProcessing : true)
                    var committedEnd = LiveTranscriptionSchedule.safeBoundary(start: window.start, proposed: window.end, segments: segments)
                    if committedEnd <= window.start + 0.001 {
                        if !stopped {
                            boundaryExhausted = !schedule.deferBoundary(window)
                            let delay = min(10.0, max(1.0, Date().timeIntervalSince(startedAt)))
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            continue
                        }
                        // A continuous turn longer than a batch has no safe
                        // boundary. Recognize this still-uncommitted batch
                        // without lookahead and make progress after stop.
                        segments = try await transcribeWindow(tracks, window: window, end: window.end, model: model, quiet: preferences.usesQuietProcessing)
                        committedEnd = window.end
                    } else { segments.removeAll { $0.end > committedEnd } }
                    try Task.checkCancellation()
                    var latest = try library.read(id)
                    latest.segments.append(contentsOf: segments)
                    latest.segments.sort { $0.start < $1.start }
                    latest.liveCommittedUntil = committedEnd
                    for track in tracks { latest.audioOffsets[track.url.lastPathComponent] = track.offset }
                    latest.status = .processing; latest.error = nil
                    try library.save(latest) // cursor and text are one atomic file replacement
                    upsert(latest); schedule.commit(window, through: committedEnd)
                    if !stopped {
                        let delay = min(10.0, max(1.0, Date().timeIntervalSince(startedAt)))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                } catch {
                    schedule.fail(window)
                    if stopped || error is CancellationError { throw error }
                    failedDuringCapture = true
                }
            }
        } catch {
            var latest = (try? library.read(id))
            latest?.status = .failed
            latest?.error = error is CancellationError ? "Обработка остановлена. Аудио сохранено" : error.localizedDescription
            if let latest { try? library.save(latest); upsert(latest) }
        }
        await transcriber.finishLive()
        if granted { model.stopAccessingSecurityScopedResource() }
        liveTask = nil; liveStatus = ""; processingID = nil; phase = ""; runNext()
    }

    private func transcribeWindow(_ tracks: [CaptureTrackBoundary], window: LiveTranscriptionSchedule.Window, end: Double, model: URL, quiet: Bool) async throws -> [TranscriptSegment] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-window-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try await Task.detached(priority: .utility) {
            try CaptureWindow.copy(tracks, start: window.start, end: end, directory: directory)
        }.value
        guard !files.isEmpty else { return [] }
        let result = try await transcriber.transcribe(files: files.map { ($0.url, $0.offset) }, modelDirectory: model, context: preferences.vocabulary, speakerDirectory: library.root.appendingPathComponent("Models/Speakers"), profiles: voiceProfiles, quiet: quiet, live: true) { _, _ in }
        return try result.map { segment in
            var mapped = segment
            guard let temporaryName = segment.audioFile,
                  let file = files.first(where: { temporaryName.contains("-mic.") ? $0.original.lastPathComponent.contains("-mic.") : $0.original.lastPathComponent.contains("-remote.") }) else {
                throw PisyaError.message("Не удалось связать расшифровку с исходной записью")
            }
            mapped.audioFile = file.original.lastPathComponent
            return mapped
        }
    }
    func enqueue(_ id: UUID, reprocess: Bool = false) {
        guard !demo, id != processingID, !pending.contains(id) else { return }
        guard modelReady else { modelSetup.presented = true; return }
        if reprocess { pendingReprocessing.insert(id) }
        pending.append(id); runNext()
    }
    private func runNext() {
        guard processingID == nil, !pending.isEmpty else { return }
        let id = pending.removeFirst()
        let reprocess = pendingReprocessing.remove(id) != nil
        guard var m = meetings.first(where: { $0.id == id }), let model = modelURL() else { return }
        if case .resume(let committed) = LiveTranscriptionSchedule.processingMode(committed: m.liveCommittedUntil, reprocess: reprocess) {
            guard committed.isFinite, committed >= 0 else { m.status = .failed; m.error = "Некорректный курсор черновика"; try? library.save(m); upsert(m); runNext(); return }
            m.status = .processing; m.error = nil
            do { try library.save(m) } catch { message = error.localizedDescription; runNext(); return }
            upsert(m); processingID = id; progress = 0
            liveStopped = true; livePaused = false; liveStatus = "Завершаю расшифровку"
            liveTask = Task(priority: .utility) { await self.runLiveTranscription(id: id, model: model) }
            return
        }
        let granted = model.startAccessingSecurityScopedResource()
        m.status = .processing; m.error = nil; m.liveCommittedUntil = nil
        do { try library.save(m) } catch { message = error.localizedDescription; if granted { model.stopAccessingSecurityScopedResource() }; return }
        upsert(m); processingID = id; progress = 0
        let vocabulary = preferences.vocabulary
        processingTask = Task(priority: .utility) {
            defer {
                if granted { model.stopAccessingSecurityScopedResource() }
                processingID = nil; processingTask = nil; phase = ""; runNext()
            }
            do {
                let files = try m.audioFiles.map { (try library.audioURL($0), m.audioOffsets[$0] ?? 0) }.filter { FileManager.default.fileExists(atPath: $0.0.path) }
                guard !files.isEmpty else { throw PisyaError.message("Аудио этой встречи недоступно") }
                let result = try await transcriber.transcribe(files: files, modelDirectory: model, context: vocabulary, speakerDirectory: library.root.appendingPathComponent("Models/Speakers"), profiles: voiceProfiles, quiet: preferences.usesQuietProcessing) { [self] fraction, description in
                    await self.updateProcessingProgress(fraction, description)
                }
                let generated = try Set(result.compactMap(\.audioFile)).filter { $0.contains(".clean.") && !m.audioFiles.contains($0) }.map { try library.audioURL($0) }
                var persisted = false
                defer { if !persisted { for url in generated { try? FileManager.default.removeItem(at: url) } } }
                try Task.checkCancellation()
                var latest = try library.read(id)
                latest.segments = result; latest.status = .ready; latest.error = nil
                let referenced = Set(result.compactMap(\.audioFile))
                let obsolete = latest.audioFiles.filter { $0.contains(".clean.") && !referenced.contains($0) }
                latest.audioFiles.removeAll { obsolete.contains($0) }
                for name in obsolete { latest.audioOffsets[name] = nil }
                for segment in result {
                    if let name = segment.audioFile, name.contains(".clean."), !latest.audioFiles.contains(name) {
                        latest.audioFiles.append(name)
                        if let original = latest.audioFiles.first(where: { $0.contains("-mic.") && !$0.contains(".clean.") }) {
                            latest.audioOffsets[name] = latest.audioOffsets[original] ?? 0
                        }
                    }
                }
                try library.save(latest); persisted = true; upsert(latest); exportIfConfigured(latest)
                let shared = Set(meetings.filter { $0.id != id }.flatMap(\.audioFiles))
                for name in obsolete where !shared.contains(name) {
                    if let url = try? library.audioURL(name) { try? FileManager.default.removeItem(at: url) }
                }
            } catch {
                var latest = (try? library.read(id)) ?? m
                latest.status = .failed; latest.error = error is CancellationError ? "Обработка остановлена. Аудио сохранено" : error.localizedDescription
                try? library.save(latest); upsert(latest)
            }
        }
    }
    private func updateProcessingProgress(_ fraction: Double, _ description: String) {
        progress = fraction; phase = description
    }
    func stopPlayback() { player?.stop(); playingSegmentID = nil; playbackTimer?.invalidate(); playbackTimer = nil }
    func play(_ segment: TranscriptSegment, in meeting: Meeting) {
        guard !demo, !recording else { return }
        if playingSegmentID == segment.id { stopPlayback(); return }
        let name = segment.audioFile ?? meeting.audioFiles.first { segment.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") } ?? meeting.audioFiles.first
        guard let name else { return }
        do {
            player = try AVAudioPlayer(contentsOf: library.audioURL(name))
            let offset = meeting.audioOffsets[name] ?? 0
            player?.currentTime = max(0, segment.start - offset)
            playbackEnd = segment.end - offset
            player?.play(); playingSegmentID = segment.id
            schedulePlaybackStop()
        } catch { message = "Аудио недоступно: \(error.localizedDescription)" }
    }
    private func schedulePlaybackStop() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player?.isPlaying != true || (self.player?.currentTime ?? 0) >= self.playbackEnd { self.stopPlayback() }
            }
        }
    }
    func preview(_ segment: TranscriptSegment, in meeting: Meeting) {
        var clip = segment; clip.end = min(clip.end, clip.start + 8); play(clip, in: meeting)
    }
    func playExample(_ example: VoiceExample) {
        guard !recording else { return }
        if playingSegmentID == example.id { stopPlayback(); return }
        guard example.file == URL(fileURLWithPath: example.file).lastPathComponent else { return }
        do {
            player = try AVAudioPlayer(contentsOf: library.root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file))
            playbackEnd = player?.duration ?? 0; player?.play(); playingSegmentID = example.id; schedulePlaybackStop()
        } catch { message = "Образец голоса недоступен" }
    }
    func voiceSample(for segmentID: UUID, in meeting: Meeting, allMatching: Bool) -> TranscriptSegment? {
        var durations: [String: Double] = [:]
        for filename in meeting.audioFiles {
            guard let url = try? library.audioURL(filename), let file = try? AVAudioFile(forReading: url) else { continue }
            durations[filename] = Double(file.length) / file.processingFormat.sampleRate
        }
        return automaticVoiceSample(for: segmentID, in: meeting, allMatching: allMatching, audioDurations: durations)
    }
    func assignVoice(meetingID: UUID, segmentID: UUID, name: String, allMatching: Bool, remember: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var m = meetings.first(where: { $0.id == meetingID }), canModify(m),
              let sample = m.segments.first(where: { $0.id == segmentID }) else { return }
        if remember {
            do {
                guard let automatic = voiceSample(for: sample.id, in: m, allMatching: allMatching) else {
                    throw PisyaError.message("Не найден подходящий образец голоса от 2 секунд без отмеченных наложений. Можно применить имя без запоминания голоса")
                }
                try storeVoiceSample(automatic, name: clean, meeting: m)
            }
            catch { message = "Имя не сохранено: \(error.localizedDescription)"; return }
        }
        for index in m.segments.indices where m.segments[index].id == segmentID || (allMatching && m.segments[index].speaker == sample.speaker) {
            // Preserve the original track when a microphone label is renamed.
            if m.segments[index].audioFile == nil {
                m.segments[index].audioFile = m.audioFiles.first { m.segments[index].speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") } ?? m.audioFiles.first
            }
            m.segments[index].speaker = clean
        }
        update(m)
    }
    private func storeVoiceSample(_ segment: TranscriptSegment, name: String, meeting: Meeting) throws {
        guard let embedding = segment.embedding, segment.end - segment.start >= 2 else { throw PisyaError.message("Выберите фрагмент с голосовым слепком длительностью от 2 секунд") }
        guard let filename = segment.audioFile ?? meeting.audioFiles.first(where: { segment.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") }) ?? meeting.audioFiles.first else { throw PisyaError.message("Для сохранения образца нужно аудио встречи") }
        let file = try AVAudioFile(forReading: library.audioURL(filename))
        let offset = meeting.audioOffsets[filename] ?? 0
        let start = AVAudioFramePosition(max(0, segment.start - offset) * file.processingFormat.sampleRate)
        let available = max(0, file.length - start)
        let count = AVAudioFrameCount(min(available, Int64(min(8, segment.end - segment.start) * file.processingFormat.sampleRate)))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw PisyaError.message("Образец недоступен") }
        file.framePosition = start
        let folder = library.root.appendingPathComponent("VoiceSamples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clipName = UUID().uuidString + ".caf"
        let url = folder.appendingPathComponent(clipName)
        let output = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings)
        var written: AVAudioFrameCount = 0
        do {
            while written < count {
                try file.read(into: buffer, frameCount: count - written)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                written += buffer.frameLength
            }
            output.close()
            guard Double(written) / file.processingFormat.sampleRate >= 2 else { throw PisyaError.message("В файле осталось меньше 2 секунд для образца") }
        } catch { output.close(); try? FileManager.default.removeItem(at: url); throw error }
        var profiles = voiceProfiles
        // Correcting a previously saved sample must remove its old training assignment.
        for i in profiles.indices {
            let previous = profiles[i].examples?.filter { $0.meetingID == meeting.id && $0.segmentID == segment.id } ?? []
            for old in previous { profiles[i].samples.removeAll { $0 == old.embedding } }
            profiles[i].examples?.removeAll { $0.meetingID == meeting.id && $0.segmentID == segment.id }
        }
        if !profiles.contains(where: { $0.name == name }) { profiles.append(VoiceProfile(name: name, samples: [])) }
        let index = profiles.firstIndex(where: { $0.name == name })!
        profiles[index].samples = Array((profiles[index].samples + [embedding]).suffix(10))
        var examples = profiles[index].examples ?? []
        examples.append(VoiceExample(file: clipName, meetingID: meeting.id, segmentID: segment.id, embedding: embedding))
        profiles[index].examples = Array(examples.suffix(10))
        do { try library.saveVoices(profiles); let previous = voiceProfiles; voiceProfiles = profiles; cleanupVoiceExamples(previous: previous, current: profiles) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func cancelProcessing() { processingTask?.cancel(); if processingID != recordingMeetingID { liveTask?.cancel() } }
    func update(_ value: Meeting) {
        var meeting = value
        if let previous = meetings.first(where: { $0.id == meeting.id }) {
            let originals = Dictionary(uniqueKeysWithValues: previous.segments.map { ($0.id, $0) })
            for i in meeting.segments.indices where meeting.segments[i].audioFile == nil {
                let original = originals[meeting.segments[i].id] ?? meeting.segments[i]
                meeting.segments[i].audioFile = original.audioFile ?? meeting.audioFiles.first { original.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") } ?? meeting.audioFiles.first
            }
        }
        guard !demo else { upsert(meeting); return }
        do { try library.save(meeting); upsert(meeting); if meeting.status == .ready { exportIfConfigured(meeting) } } catch { message = error.localizedDescription }
    }
    func renameSpeaker(_ old: String, to new: String, meeting: Meeting) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        var m = meeting
        for index in m.segments.indices where m.segments[index].speaker == old { m.segments[index].speaker = name }
        update(m)
    }
    func rememberVoice(_ speaker: String, name: String, meeting: Meeting) {
        guard !demo else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let samples = meeting.segments.filter { $0.speaker == speaker && $0.end - $0.start >= 2 }.sorted { $0.end - $0.start > $1.end - $1.start }.prefix(5).compactMap(\.embedding)
        guard !clean.isEmpty, !samples.isEmpty else { message = "Для профиля нужен чистый фрагмент голоса длиной хотя бы 2 секунды"; return }
        if let index = voiceProfiles.firstIndex(where: { $0.name == clean }) { voiceProfiles[index].samples = Array((voiceProfiles[index].samples + samples).suffix(10)) }
        else { voiceProfiles.append(.init(name: clean, samples: samples)) }
        do { try library.saveVoices(voiceProfiles) } catch { message = error.localizedDescription }
    }
    func forgetVoice(_ id: UUID) {
        let previous = voiceProfiles
        let updated = voiceProfiles.filter { $0.id != id }
        do { try library.saveVoices(updated); voiceProfiles = updated; cleanupVoiceExamples(previous: previous, current: updated) }
        catch { message = error.localizedDescription }
    }
    private func cleanupVoiceExamples(previous: [VoiceProfile], current: [VoiceProfile]) {
        let retained = Set(current.flatMap { $0.examples ?? [] }.map(\.file))
        for example in previous.flatMap({ $0.examples ?? [] }) where !retained.contains(example.file) {
            guard example.file == URL(fileURLWithPath: example.file).lastPathComponent else { continue }
            try? FileManager.default.removeItem(at: library.root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file))
        }
    }
    private func upsert(_ m: Meeting) {
        searchIndex[m.id] = m.searchableText
        if let index = meetings.firstIndex(where: { $0.id == m.id }) { meetings[index] = m } else { meetings.insert(m, at: 0) }
    }
    func modelURL() -> URL? {
        if let data = preferences.modelBookmark { var stale = false; return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) }
        let local = library.root.appendingPathComponent("Models/Qwen3-ASR")
        return FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path) ? local : nil
    }
    func chooseModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Папка Qwen3-ASR в формате MLX. Все вычисления останутся на Mac"
        if panel.runModal() == .OK, let url = panel.url {
            do { preferences.modelBookmark = try url.bookmarkData(options: .withSecurityScope); preferences.modelDisplayPath = url.path; savePreferences(); modelSetup.check(presentWhenNeeded: false); objectWillChange.send() } catch { message = error.localizedDescription }
        }
    }
    func chooseExportFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Папка для Markdown. Если это Dropbox или iCloud, тексты будут синхронизироваться их приложением"
        if panel.runModal() == .OK, let url = panel.url {
            do { preferences.exportBookmark = try url.bookmarkData(options: .withSecurityScope); preferences.exportDisplayPath = url.path; savePreferences() } catch { message = error.localizedDescription }
        }
    }
    func exportIfConfigured(_ meeting: Meeting) {
        guard !demo, let data = preferences.exportBookmark else { return }
        do {
            var stale = false; let folder = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
            let granted = folder.startAccessingSecurityScopedResource(); defer { if granted { folder.stopAccessingSecurityScopedResource() } }
            if stale { preferences.exportBookmark = try folder.bookmarkData(options: .withSecurityScope); savePreferences() }
            _ = try MarkdownExporter.export(meeting, to: folder)
        } catch { message = "Экспорт не выполнен: \(error.localizedDescription). Расшифровка сохранена на Mac" }
    }
    func deleteAudio(_ meeting: Meeting) {
        guard !demo, meeting.status == .ready, processingID != meeting.id, activeMeeting?.id != meeting.id else { return }
        do {
            player?.stop(); playingSegmentID = nil
            for name in meeting.audioFiles {
                let url = try library.audioURL(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            var m = meeting; m.audioFiles = []; m.audioOffsets = [:]; update(m)
        } catch { message = "Не всё аудио удалось удалить: \(error.localizedDescription)" }
    }
    func exportSelected() {
        guard let meeting = selected, !demo else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(meeting.title.replacingOccurrences(of: "/", with: "-" )).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.isExtensionHidden = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { do { try MarkdownExporter.render(meeting).write(to: url, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription } }
    }
    func showDemo() {
        guard !recording, processingID == nil else { return }
        demo.toggle()
        if !demo { meetings = (try? library.all(includeDeleted: true)) ?? []; selection = filtered.first?.id; return }
        var m = Meeting(title: "Планы на неделю", source: "Толк"); m.duration = 1842; m.status = .ready
        m.segments = [
            .init(start: 12, end: 28, speaker: "Я", text: "Давайте сверим планы на неделю. Хочется сначала проверить основной сценарий и только потом добавлять новые возможности."),
            .init(start: 29, end: 48, speaker: "Даша", text: "Да, я подготовлю несколько примеров к среде. Посмотрим, где людям приходится делать лишние шаги."),
            .init(start: 49, end: 70, speaker: "Я", text: "Отлично. Тогда в четверг вместе посмотрим результаты. Если что-то не успеваем, сразу обсудим, что можно упростить."),
            .init(start: 72, end: 94, speaker: "Даша", text: "Договорились. Ещё соберу обратную связь от команды и принесу короткий список вопросов.")]
        meetings = [m]; selection = m.id
    }
}


@MainActor
final class RecordingMonitor: ObservableObject {
    var microphone = AudioMeterTrack()
    var system = AudioMeterTrack()
    @Published var now: Double = 0
    private(set) var updatedAt = Date()
    private(set) var began: Double = 0
    func reset() {
        microphone = AudioMeterTrack(); system = AudioMeterTrack()
        updatedAt = Date()
        began = ProcessInfo.processInfo.systemUptime; now = began
    }
    func update(microphone: CaptureMeterSample, system: CaptureMeterSample) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        self.microphone.update(peak: microphone.peak, seconds: microphone.seconds, lastWrite: microphone.lastWrite, now: timestamp)
        self.system.update(peak: system.peak, seconds: system.seconds, lastWrite: system.lastWrite, now: timestamp)
        updatedAt = Date()
        now = timestamp
    }
}
