import AVFoundation
import CoreAudio
import Foundation

/// Audio-only HAL input. Lifecycle calls run on AudioCapture's session queue;
/// samples are consumed synchronously on its writer queue while HAL owns them.
final class SystemAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?

    func start(queue: DispatchQueue, receive: @escaping (AVAudioPCMBuffer, Double) -> Void) throws {
        do {
            var pid = ProcessInfo.processInfo.processIdentifier
            var ownProcess = AudioObjectID(kAudioObjectUnknown)
            var address = property(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess))
            guard ownProcess != kAudioObjectUnknown else { throw PisyaError.message("Не удалось исключить звук Pisya из записи") }

            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcess])
            description.name = "Pisya · Системный звук"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap))

            var asbd = AudioStreamBasicDescription()
            address = property(kAudioTapPropertyFormat)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd))
            guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0 else {
                throw PisyaError.message("Системный звук передал неподдерживаемый формат")
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Pisya · Системный звук",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, input, time, _, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                      pcm.frameLength > 0 else { return }
                // The microphone is converted to this same monotonic host clock.
                let seconds = time.pointee.mFlags.contains(.hostTimeValid)
                    ? AVAudioTime.seconds(forHostTime: time.pointee.mHostTime) : .nan
                receive(pcm, seconds)
            })
            try check(AudioDeviceStart(device, ioProc))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        ioProc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        device = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            if status == kAudioDevicePermissionsError { throw CapturePermission.systemAudio }
            throw PisyaError.message("Не удалось подключить системный звук (код \(status)). Проверьте доступ Pisya к системному аудио в настройках конфиденциальности macOS и повторите запись")
        }
    }
}
