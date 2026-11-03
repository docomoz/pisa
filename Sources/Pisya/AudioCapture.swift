import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import CoreGraphics
import OSLog

struct CaptureMeterSample: Sendable {
    var peak: Float = 0
    var seconds: Double = 0
    var lastWrite: Double?
}
struct CaptureResult { var files: [String]; var offsets: [String: Double]; var duration: Double; var warning: String? }
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var microphoneErrorObserver: NSObjectProtocol?
    private let sessionQueue = DispatchQueue(label: "com.docomoz.pisya.microphone", qos: .userInitiated)
    private let queue = DispatchQueue(label: "com.docomoz.pisya.audio", qos: .userInitiated)
    private var writers: [SCStreamOutputType: AVAudioFile] = [:]
    private var paths: [SCStreamOutputType: URL] = [:]
    private var firstTimes: [SCStreamOutputType: Double] = [:]
    private var started = Date()
    private var writeError: Error?
    private var meters: [SCStreamOutputType: CaptureMeterSample] = [:]
    var onFailure: ((String) -> Void)?
    private let logger = Logger(subsystem: "com.docomoz.pisya", category: "CaptureAccess")
    @MainActor
    func prepare() async throws -> SCContentFilter {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CapturePermission.microphone }
        let permitted = CGPreflightScreenCaptureAccess()
        logger.notice("Screen capture preflight: \(permitted, privacy: .public)")
        if !permitted {
            let requested = CGRequestScreenCaptureAccess()
            logger.notice("Screen capture request: \(requested, privacy: .public)")
            guard requested else { throw CapturePermission.screen }
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch {
            let ns = error as NSError
            logger.error("Shareable content failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            throw CapturePermission.translate(error)
        }
        guard let display = content.displays.first else { throw PisyaError.message("Нет доступного дисплея для захвата звука") }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        return filter
    }
    func start(folder: URL, id: UUID, filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.captureMicrophone = false
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 24000; config.channelCount = 1
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        paths = [.audio: folder.appendingPathComponent("\(id.uuidString)-remote.caf"), .microphone: folder.appendingPathComponent("\(id.uuidString)-mic.caf")]
        writers = [:]; firstTimes = [:]; writeError = nil; meters = [:]
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture; started = Date()
        do {
            try await startMicrophone()
            try await capture.startCapture()
        } catch {
            await stopMicrophone()
            stream = nil
            throw CapturePermission.translate(error)
        }
    }
    private func startMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    guard let device = AVCaptureDevice.default(for: .audio) else { throw PisyaError.message("Не найден микрофон. Подключите его и повторите запись") }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw PisyaError.message("Не удалось подключить микрофон «\(device.localizedName)»") }
                    session.beginConfiguration()
                    session.addInput(input); session.addOutput(output)
                    session.commitConfiguration()
                    self.microphoneSession = session
                    self.microphoneErrorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
                        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Микрофон перестал записывать звук"
                        self?.onFailure?(message)
                    }
                    session.startRunning()
                    guard session.isRunning else { throw PisyaError.message("Не удалось запустить микрофон «\(device.localizedName)»") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func stopMicrophone() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if let observer = self.microphoneErrorObserver { NotificationCenter.default.removeObserver(observer) }
                self.microphoneErrorObserver = nil
                self.microphoneSession?.stopRunning()
                // Drain queued microphone callbacks before releasing their synchronization clock.
                self.queue.async {
                    self.microphoneSession = nil
                    continuation.resume()
                }
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time: CMTime
        if let clock = microphoneSession?.synchronizationClock {
            time = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        } else { time = sampleBuffer.presentationTimeStamp }
        write(sampleBuffer, type: .microphone, timestamp: time.seconds)
    }
    func meterSnapshot() async -> (CaptureMeterSample, CaptureMeterSample) {
        await withCheckedContinuation { continuation in
            queue.async {
                let mic = self.meters[.microphone] ?? CaptureMeterSample()
                let system = self.meters[.audio] ?? CaptureMeterSample()
                self.meters[.microphone]?.peak = 0
                self.meters[.audio]?.peak = 0
                continuation.resume(returning: (mic, system))
            }
        }
    }
    /// Publish completed writes only; copying is performed elsewhere and never
    /// blocks this queue. Wait for both tracks so AEC never runs ahead of its
    /// reference, including when ScreenCaptureKit omits silent buffers.
    func transcriptionBoundary(requireBoth: Bool = true) async -> [CaptureTrackBoundary]? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let first = self.firstTimes.values.min() else {
                    continuation.resume(returning: nil); return
                }
                let tracks: [CaptureTrackBoundary] = [SCStreamOutputType.microphone, .audio].compactMap { type in
                    guard let writer = self.writers[type], let url = self.paths[type], let time = self.firstTimes[type] else { return nil }
                    return CaptureTrackBoundary(url: url, offset: time - first, frames: writer.length, sampleRate: writer.processingFormat.sampleRate)
                }
                continuation.resume(returning: requireBoth && tracks.count != 2 ? nil : tracks)
            }
        }
    }
    private func rms(_ pcm: AVAudioPCMBuffer) -> Float {
        let count = Int(pcm.frameLength)
        guard count > 0 else { return 0 }
        var sum: Double = 0
        for channel in 0..<Int(pcm.format.channelCount) {
            for frame in 0..<count {
                let index = frame * pcm.stride
                let value: Double
                if let samples = pcm.floatChannelData { value = Double(samples[channel][index]) }
                else if let samples = pcm.int16ChannelData { value = Double(samples[channel][index]) / 32768 }
                else if let samples = pcm.int32ChannelData { value = Double(samples[channel][index]) / 2147483648 }
                else { return 0 }
                if value.isFinite { sum += value * value }
            }
        }
        return Float(sqrt(sum / Double(count * Int(pcm.format.channelCount))))
    }
    func stop() async throws -> CaptureResult {
        var stopError: Error?
        do { if let stream { try await stream.stopCapture() } } catch { stopError = error }
        await stopMicrophone()
        stream = nil
        if let stopError { onFailure?(stopError.localizedDescription) }
        let stopWarning = stopError?.localizedDescription
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                for writer in self.writers.values { writer.close() }
                self.writers = [:]
                let minimum = self.firstTimes.values.min() ?? 0
                let files = self.paths.values.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent).sorted()
                var offsets: [String: Double] = [:]
                for (type, time) in self.firstTimes { if let name = self.paths[type]?.lastPathComponent { offsets[name] = time - minimum } }
                continuation.resume(returning: CaptureResult(files: files, offsets: offsets, duration: Date().timeIntervalSince(self.started), warning: self.writeError?.localizedDescription ?? stopWarning))
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        write(sampleBuffer, type: type, timestamp: sampleBuffer.presentationTimeStamp.seconds)
    }
    private func write(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType, timestamp: Double) {
        guard (type == .audio || type == .microphone), sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), let desc = sampleBuffer.formatDescription, let path = paths[type] else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        do {
            guard timestamp.isFinite else { throw PisyaError.message("Источник звука передал некорректное время. Запись остановлена, полученное аудио сохранено") }
            let listSize = MemoryLayout<AudioBufferList>.size + max(0, Int(format.channelCount) - 1) * MemoryLayout<AudioBuffer>.size
            let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
            defer { raw.deallocate() }
            var block: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
            guard status == noErr, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: UnsafePointer(list), deallocator: nil) else { return }
            if writers[type] == nil {
                writers[type] = try AVAudioFile(forWriting: path, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                firstTimes[type] = timestamp
            }
            try withExtendedLifetime(block) {
                guard let writer = writers[type], let first = firstTimes[type] else { return }
                let gap = AudioTimeline.adjustment(timestamp: timestamp, firstTimestamp: first, framesWritten: writer.length, sampleRate: format.sampleRate)
                let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                guard timestamp <= hostNow + 5 else { throw PisyaError.message("Источник звука передал неверную временную метку. Полученное аудио сохранено") }
                // ScreenCaptureKit can omit silent system buffers for a long time.
                // Fill those gaps; only a microphone dropout ends capture.
                guard type != .microphone || abs(gap) <= Int64(format.sampleRate * 3) else { throw PisyaError.message("Микрофон прервался больше чем на 3 секунды. Запись остановлена, полученное аудио сохранено") }
                if gap > 0 {
                    let zero = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                    var remaining = gap
                    while remaining > 0 {
                        let n = AVAudioFrameCount(min(remaining, 4096)); zero.frameLength = n
                        for buffer in UnsafeMutableAudioBufferListPointer(zero.mutableAudioBufferList) {
                            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                        }
                        try writer.write(from: zero); remaining -= Int64(n)
                    }
                }
                // Ignore fully duplicated buffers; preserve ordinary sub-10ms clock jitter.
                if gap <= -Int64(pcm.frameLength) { return }
                if gap < 0 {
                    let skip = Int(-gap), keep = Int(pcm.frameLength) - skip
                    let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(keep))!
                    trimmed.frameLength = AVAudioFrameCount(keep)
                    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                    let source = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                    let destination = UnsafeMutableAudioBufferListPointer(trimmed.mutableAudioBufferList)
                    for channel in source.indices {
                        if let src = source[channel].mData, let dst = destination[channel].mData {
                            memcpy(dst, src.advanced(by: skip * bytesPerFrame), keep * bytesPerFrame)
                        }
                    }
                    try writer.write(from: trimmed)
                } else { try writer.write(from: pcm) }
                guard pcm.frameLength > 0 else { return }
                var meter = meters[type] ?? CaptureMeterSample()
                meter.peak = max(meter.peak, rms(pcm))
                meter.seconds = Double(writer.length) / format.sampleRate
                meter.lastWrite = ProcessInfo.processInfo.systemUptime
                meters[type] = meter
            }
        } catch { if writeError == nil { writeError = error; onFailure?(error.localizedDescription) } }
    }
}

/// Process-level audio state; no screen inspection, keystrokes, or window titles.
enum CallAudioProbe {
    static func isActive() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }
        for process in processes {
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &property, 0, nil, &bundleSize, &bundle) == noErr, !(bundle as String).isEmpty, !(bundle as String).hasPrefix(Bundle.main.bundleIdentifier ?? "com.docomoz.pisya") else { continue }
            // Microphone use is a heuristic for calls, including browser calls. Playback alone must not start recording.
            for selector in [kAudioProcessPropertyIsRunningInput] {
                property.mSelector = selector; var running: UInt32 = 0; var count = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(process, &property, 0, nil, &count, &running) == noErr, running != 0 { return true }
            }
        }
        return false
    }
}


enum CapturePermission: Error, LocalizedError {
    case microphone, screen
    var errorDescription: String? {
        switch self {
        case .microphone: return "Нет доступа к микрофону. Включите Pisya в Системных настройках → Конфиденциальность и безопасность → Микрофон, затем повторите запись."
        case .screen: return "Нет доступа к звуку собеседников. Включите Pisya в Системных настройках → Конфиденциальность и безопасность → Запись экрана и системного аудио. Если macOS предложит перезапустить приложение, согласитесь, затем повторите запись. Видео экрана Pisya не сохраняет."
        }
    }
    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (self == .screen ? "Privacy_ScreenCapture" : "Privacy_Microphone"))!
    }
    static func translate(_ error: Error) -> Error {
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue ? CapturePermission.screen : error
    }
}
