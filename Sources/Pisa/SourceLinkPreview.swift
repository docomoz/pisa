import AppKit
import SwiftUI
import AVFoundation

/// Disposable source-link fixture for exercising the actual application views.
@MainActor
final class SourceLinkPreview: NSObject {
    let state: AppState
    let meeting: Meeting
    let window: NSWindow
    let root: URL
    let delegate = PisaDelegate()

    override init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Link-" + UUID().uuidString)
        state = AppState(rootURL: root)
        var fixture = Meeting(title: "Проверка ссылки на фрагмент", source: "Тестовое аудио")
        fixture.status = .ready
        fixture.duration = 26
        fixture.segments = (0..<25).map { i in
            TranscriptSegment(start: Double(i), end: Double(i + 1), speaker: "Участник", text: "Реплика \(i + 1). Обсуждаем результаты и дальнейшие шаги.")
        }
        let filename = "source-preview-mic.caf"
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 416000)!
        buffer.frameLength = 416000
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1) * 0.05) }
        if let audioURL = try? state.library.audioURL(filename), let file = try? AVAudioFile(forWriting: audioURL, settings: format.settings) {
            try? file.write(from: buffer); file.close(); fixture.audioFiles = [filename]
        }
        meeting = fixture
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        state.update(fixture)
        window.title = "Pisa · Проверка ссылки"
        let hosting = NSHostingView(rootView: SourceLinkPreviewRoot(state: state))
        hosting.sizingOptions = []
        window.contentView = hosting
    }
    func link(_ segment: TranscriptSegment, id: UUID? = nil) -> URL {
        TranscriptLink(meetingID: meeting.id, segmentID: id ?? segment.id, time: segment.start)!.url
    }
    @objc func showLink(_ sender: NSMenuItem) {
        state.sourceNotice = nil
        var fixture = meeting
        if sender.tag == 2 { fixture.audioFiles = [] }
        state.update(fixture)
        state.openSource(link(meeting.segments[20], id: sender.tag == 1 ? UUID() : nil))
    }
    static func test() throws {
        let app = NSApplication.shared
        let fixture = SourceLinkPreview()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = fixture.state, meeting = fixture.meeting, segment = meeting.segments[20]
        state.search = "скрыто"; state.showingTrash = true
        fixture.delegate.application(app, open: [fixture.link(segment)])
        guard state.sourceReveal == nil else { throw PisaError.message("Pending link opened before connection") }
        fixture.delegate.connect(state, openMain: {})
        guard state.selection == meeting.id, state.sourceReveal?.segmentID == segment.id,
              state.search.isEmpty, !state.showingTrash, state.playingSegmentID == segment.id else { throw PisaError.message("Source link did not reveal and play") }
        state.openSource(fixture.link(segment))
        guard state.playingSegmentID == segment.id else { throw PisaError.message("Repeated link stopped playback") }
        state.sourceNotice = nil
        state.openSource(fixture.link(segment, id: UUID()))
        guard state.sourceReveal?.segmentID == segment.id, state.sourceNotice?.message.contains("ближайший") == true,
              state.playingSegmentID == nil else { throw PisaError.message("Approximate link did not warn") }
        var missingTrack = meeting
        missingTrack.segments[20].audioFile = "missing-mic.caf"
        state.update(missingTrack)
        state.sourceNotice = nil; state.openSource(fixture.link(segment))
        guard state.sourceNotice?.message.contains("недоступно") == true, state.playingSegmentID == nil else { throw PisaError.message("Missing target track was not reported") }
        var invalidTime = meeting
        invalidTime.segments[20].audioFile = meeting.audioFiles.first
        invalidTime.segments[20].start = 30; invalidTime.segments[20].end = 31
        state.update(invalidTime)
        state.sourceNotice = nil; state.openSource(fixture.link(segment))
        guard state.sourceNotice?.message.contains("недоступно") == true, state.playingSegmentID == nil else { throw PisaError.message("Invalid target time was not reported") }
        var withoutAudio = meeting; withoutAudio.audioFiles = []; state.update(withoutAudio)
        state.sourceNotice = nil; state.openSource(fixture.link(segment))
        guard state.sourceNotice?.message.contains("недоступно") == true else { throw PisaError.message("Missing audio was not reported") }
        state.trash(withoutAudio)
        state.sourceNotice = nil
        state.openSource(fixture.link(segment))
        guard state.sourceNotice?.message.contains("корзине") == true, state.playingSegmentID == nil else { throw PisaError.message("Trashed meeting opened") }
    }
    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = SourceLinkPreview()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        app.delegate = fixture.delegate
        fixture.delegate.connect(fixture.state, openMain: { fixture.window.makeKeyAndOrderFront(nil) })
        print("SOURCE_LINK_PREVIEW_URL \(fixture.link(fixture.meeting.segments[20]).absoluteString)")
        let menu = NSMenu(), item = NSMenuItem(title: "Проверка", action: nil, keyEquivalent: ""), submenu = NSMenu()
        for (tag, title) in ["Открыть реплику", "Открыть приблизительное совпадение", "Открыть без аудио"].enumerated() {
            let entry = submenu.addItem(withTitle: title, action: #selector(showLink(_:)), keyEquivalent: "")
            entry.target = fixture; entry.tag = tag
        }
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Завершить просмотр", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        fixture.window.center(); fixture.window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        fixture.showLink(NSMenuItem())
        withExtendedLifetime(fixture) { app.run() }
    }
}

private struct SourceLinkPreviewRoot: View {
    @ObservedObject var state: AppState
    var body: some View {
        MainView().environmentObject(state).preferredColorScheme(.light)
            .sheet(item: $state.sourceNotice) { notice in
                SourceNoticeView(message: notice.message)
            }
            .sheet(isPresented: $state.showingSettings) { SettingsView().environmentObject(state) }
    }
}
