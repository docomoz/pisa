import AVFoundation
import Combine
import SwiftUI

struct SegmentAudioPlayer: View {
    @EnvironmentObject private var state: AppState
    let segment: TranscriptSegment
    let meeting: Meeting

    @State private var player = AVPlayer()
    @State private var item: AVPlayerItem?
    @State private var observer: Any?
    @State private var duration: TimeInterval = 0
    @State private var position: TimeInterval = 0
    @State private var peaks: [Float] = []
    @State private var loading = true
    @State private var playing = false
    @GestureState private var dragPosition: TimeInterval?

    private var shownPosition: TimeInterval { dragPosition ?? position }

    var body: some View {
        Group {
            if item != nil {
                VStack(spacing: PisaDesign.Spacing.inline) {
                    GeometryReader { geometry in
                        Canvas { context, size in
                            SavedAudioPlayer.drawWaveform(context, size: size, peaks: peaks, fraction: shownPosition / duration)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($dragPosition) { value, result, _ in
                                result = time(at: value.location.x, width: geometry.size.width)
                            }
                            .onEnded { seek(to: time(at: $0.location.x, width: geometry.size.width)) })
                    }
                    .frame(height: 48)
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.leftArrow) { seek(to: position - 1); return .handled }
                    .onKeyPress(.rightArrow) { seek(to: position + 1); return .handled }
                    .pointingHandCursor()
                    .accessibilityRepresentation {
                        Slider(value: Binding(get: { shownPosition }, set: seek(to:)), in: 0...duration) {
                            screenText("Позиция воспроизведения")
                        }
                        .accessibilityValue("\(recordingTimecode(shownPosition)) из \(recordingTimecode(duration))")
                    }
                    HStack(spacing: PisaDesign.Spacing.inline) {
                        let label = playing ? "Пауза" : "Воспроизвести"
                        Button(action: togglePlayback) {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .textStyle(PisaDesign.Typography.detailMedium)
                                .frame(width: PisaDesign.Metrics.labelIconWidth)
                        }
                        .actionButton(size: .small)
                        .accessibilityLabel(label)
                        .screenHelp(label)
                        Spacer()
                        HStack(spacing: PisaDesign.Spacing.compact) {
                            screenText(verbatim: recordingTimecode(shownPosition)).foregroundStyle(Color.ink)
                            screenText("/")
                            screenText(verbatim: recordingTimecode(duration))
                        }
                        .textStyle(PisaDesign.Typography.code)
                        .foregroundStyle(Color.mutedInk)
                        .accessibilityHidden(true)
                    }
                }
                .disabled(state.recording || state.starting)
            } else {
                screenText(loading ? "Загружаем аудио…" : "Аудио этого фрагмента недоступно")
                    .textStyle(PisaDesign.Typography.secondary)
                    .foregroundStyle(Color.mutedInk)
            }
        }
        .onAppear { state.segmentAudioPreviews.insert(meeting.id) }
        .task { await prepare() }
        .onDisappear {
            reset()
            state.segmentAudioPreviews.remove(meeting.id)
        }
        .onChange(of: state.recording || state.starting) { _, busy in
            if busy { player.pause() }
        }
        .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
            playing = status != .paused
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main)) { notification in
            if let item, notification.object as? AVPlayerItem === item { position = duration }
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(1, max(0, x / width)) * duration
    }

    private func seek(to value: TimeInterval) {
        guard item != nil else { return }
        position = min(duration, max(0, value))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayback() {
        guard item != nil, !state.recording, !state.starting else { return }
        if playing {
            player.pause()
        } else {
            state.stopPlayback()
            if position >= duration { seek(to: 0) }
            player.play()
        }
    }

    private func prepare() async {
        defer { loading = false }
        guard !state.demo, !state.recording,
              let name = segment.audioFile ?? meeting.audioFiles.first(where: { segment.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") }) ?? meeting.audioFiles.first,
              meeting.audioFiles.contains(name), let url = try? state.library.audioURL(name),
              SavedVoiceAudio.isRegularAudio(url, in: state.library.audioDirectory) else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let trackRange = try? await track.load(.timeRange),
              trackRange.start.isNumeric, trackRange.duration.isNumeric,
              let range = SegmentAudioRange(start: segment.start, end: segment.end,
                                            offset: meeting.audioOffsets[name] ?? 0, duration: trackRange.duration.seconds),
              !Task.isCancelled else { return }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        let start = trackRange.start + CMTime(seconds: range.start, preferredTimescale: 48_000)
        let length = CMTime(seconds: range.duration, preferredTimescale: 48_000)
        do { try target.insertTimeRange(CMTimeRange(start: start, duration: length), of: track, at: .zero) }
        catch { return }
        guard !Task.isCancelled else { return }
        let preparedItem = AVPlayerItem(asset: composition)
        duration = range.duration
        item = preparedItem
        player.replaceCurrentItem(with: preparedItem)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            MainActor.assumeIsolated {
                guard time.seconds.isFinite else { return }
                position = min(duration, max(0, time.seconds))
            }
        }
        let result = await AudioFileWaveform.load(from: [RecordingAudioSource(url: url, offset: -range.start)], duration: range.duration)
        if !Task.isCancelled { peaks = result }
    }

    private func reset() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        item = nil
    }
}
