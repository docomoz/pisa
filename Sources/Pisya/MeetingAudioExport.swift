import AVFoundation
import Foundation

enum MeetingAudioExport {
    static func sources(for meeting: Meeting, in library: MeetingLibrary) throws -> [URL] {
        // Echo cancellation can store an additional copy of the microphone track.
        try meeting.audioFiles.filter { !$0.contains(".clean.") }
            .map { try library.audioURL($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func write(_ meeting: Meeting, from library: MeetingLibrary, to destination: URL) async throws {
        let sources = try sources(for: meeting, in: library)
        guard !sources.isEmpty else { throw PisyaError.message("Аудио этой встречи недоступно") }
        let destinationPath = destination.resolvingSymlinksInPath()
        guard !sources.contains(where: { $0.resolvingSymlinksInPath() == destinationPath }) else {
            throw PisyaError.message("Выберите другое имя для экспортируемого файла")
        }

        let composition = AVMutableComposition()
        for source in sources {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PisyaError.message("Не удалось прочитать дорожку записи")
            }
            let offset = meeting.audioOffsets[source.lastPathComponent] ?? 0
            try target.insertTimeRange(
                try await track.load(.timeRange), of: track,
                at: CMTime(seconds: offset, preferredTimescale: 48_000)
            )
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw PisyaError.message("Не удалось подготовить экспорт аудио")
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
