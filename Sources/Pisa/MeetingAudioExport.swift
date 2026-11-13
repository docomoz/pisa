import AVFoundation
import Foundation

struct RecordingAudioSource: Hashable, Sendable {
    let url: URL
    let offset: TimeInterval
}

enum MeetingAudioExport {
    static func sources(for meeting: Meeting, in library: MeetingLibrary) throws -> [URL] {
        // Echo cancellation can store an additional copy of the microphone track.
        try meeting.audioFiles.filter { !$0.contains(".clean.") }
            .map { try library.audioURL($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func playbackSources(for meeting: Meeting, in library: MeetingLibrary) -> [RecordingAudioSource] {
        let directory = library.audioDirectory.resolvingSymlinksInPath()
        return meeting.audioFiles.filter { !$0.contains(".clean.") }.compactMap { name in
            let offset = meeting.audioOffsets[name] ?? 0
            guard offset.isFinite, let url = try? library.audioURL(name),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  url.resolvingSymlinksInPath().deletingLastPathComponent() == directory else { return nil }
            return RecordingAudioSource(url: url, offset: offset)
        }
    }

    static func preparePlayback(_ sources: [RecordingAudioSource]) async
        -> (asset: AVAsset, duration: TimeInterval, sources: [RecordingAudioSource])? {
        let composition = AVMutableComposition()
        var available: [RecordingAudioSource] = []
        for source in sources {
            guard !Task.isCancelled else { return nil }
            do {
                try await insert(source, into: composition, clipBeforeStart: true)
                available.append(source)
            } catch {
                if Task.isCancelled { return nil }
            }
        }
        let duration = composition.duration.seconds
        guard !Task.isCancelled, !available.isEmpty, duration.isFinite, duration > 0 else { return nil }
        return (composition, duration, available)
    }

    private static func insert(_ source: RecordingAudioSource, into composition: AVMutableComposition,
                               clipBeforeStart: Bool = false) async throws {
        let asset = AVURLAsset(url: source.url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PisaError.message("Не удалось прочитать дорожку записи")
        }
        var range = try await track.load(.timeRange)
        var start = CMTime(seconds: source.offset, preferredTimescale: 48_000)
        if clipBeforeStart {
            try Task.checkCancellation()
            guard start.isNumeric, range.start.isNumeric, range.duration.isNumeric,
                  range.duration > .zero, range.duration + min(start, .zero) > .zero else {
                throw PisaError.message("Аудиодорожка встречи пуста")
            }
            if start < .zero {
                range = CMTimeRange(start: range.start - start, duration: range.duration + start)
                start = .zero
            }
        }
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PisaError.message("Не удалось прочитать дорожку записи")
        }
        do {
            try target.insertTimeRange(range, of: track, at: start)
        } catch {
            composition.removeTrack(target)
            throw error
        }
    }

    static func write(_ meeting: Meeting, from library: MeetingLibrary, to destination: URL) async throws {
        let sources = try sources(for: meeting, in: library)
        guard !sources.isEmpty else { throw PisaError.message("Аудио этой встречи недоступно") }
        let destinationPath = destination.resolvingSymlinksInPath()
        guard !sources.contains(where: { $0.resolvingSymlinksInPath() == destinationPath }) else {
            throw PisaError.message("Выберите другое имя для экспортируемого файла")
        }

        let composition = AVMutableComposition()
        for source in sources {
            let offset = meeting.audioOffsets[source.lastPathComponent] ?? 0
            try await insert(RecordingAudioSource(url: source, offset: offset), into: composition)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw PisaError.message("Не удалось подготовить экспорт аудио")
        }

        let files = FileManager.default
        let replacesExistingFile = files.fileExists(atPath: destination.path)
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: staging) }
        let output = staging.appendingPathComponent("Audio.m4a")
        try await exporter.export(to: output, as: .m4a)
        if replacesExistingFile {
            _ = try files.replaceItemAt(destination, withItemAt: output)
        } else {
            try files.moveItem(at: output, to: destination)
        }
    }
}
