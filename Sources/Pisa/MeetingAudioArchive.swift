import Darwin
import Foundation

/// Stages native capture tracks on their destination volume, then replaces each by an atomic rename.
enum MeetingAudioArchive {
    fileprivate struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let bytes: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Self.fileError(url) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
            device = info.st_dev
            inode = info.st_ino
            bytes = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }

        static func fileError(_ url: URL) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSURLErrorKey: url])
        }
    }

    struct Replacement: Sendable {
        let name: String
        fileprivate let original: Identity
        fileprivate let staged: URL

        func discard() { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
    }

    private static func names(for meeting: Meeting) -> [String] {
        guard meeting.audioArchive == .pending, meeting.status == .ready, meeting.liveCommittedUntil == nil,
              meeting.deletedAt == nil else { return [] }
        return ["\(meeting.id.uuidString)-mic.caf", "\(meeting.id.uuidString)-remote.caf"].filter(meeting.audioFiles.contains)
    }

    static func prepare(_ meeting: Meeting, in library: MeetingLibrary) async throws -> [Replacement] {
        let files = FileManager.default
        var replacements: [Replacement] = []
        do {
            for name in names(for: meeting) {
                try Task.checkCancellation()
                let source = try library.audioURL(name)
                let original: Identity
                do { original = try Identity(source) }
                catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { continue }
                let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: source, create: true)
                let replacement = Replacement(name: name, original: original, staged: directory.appendingPathComponent(name))
                do {
                    if try await AudioArchiveCodec.encode(source, to: replacement.staged) {
                        replacements.append(replacement)
                    } else {
                        replacement.discard()
                    }
                } catch {
                    replacement.discard()
                    throw error
                }
            }
            try Task.checkCancellation()
            return replacements
        } catch {
            for replacement in replacements { replacement.discard() }
            throw error
        }
    }

    @MainActor static func install(_ replacements: [Replacement], for meeting: Meeting, in library: MeetingLibrary) throws {
        let latest = try library.read(meeting.id)
        guard latest.audioArchive == .pending, latest.status == .ready, latest.liveCommittedUntil == nil,
              latest.deletedAt == nil, latest.audioFiles == meeting.audioFiles,
              latest.audioOffsets == meeting.audioOffsets else {
            throw CocoaError(.fileWriteUnknown)
        }
        let names = names(for: latest)
        let targets = try replacements.map { replacement in
            let destination = try library.audioURL(replacement.name)
            guard names.contains(replacement.name), try Identity(destination) == replacement.original else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
            }
            return (replacement.staged, destination)
        }
        for (staged, destination) in targets {
            // The old name always resolves to a complete file, including if the app quits between tracks.
            guard Darwin.rename(staged.path, destination.path) == 0 else { throw Identity.fileError(destination) }
        }
    }
}
