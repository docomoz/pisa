import XCTest
@testable import PisyaCore
final class CoreTests: XCTestCase {
    func testTranscriptSearchFindsEveryCaseInsensitiveSubstring() {
        let text = "😀 Смерцы, СМЕРЦЫ и смерцы"
        let ranges = transcriptSearchRanges(in: text, query: "смер")
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["Смер", "СМЕР", "смер"])
        XCTAssertEqual(ranges.first?.location, 3) // Emoji occupies two UTF-16 code units.
        XCTAssertTrue(transcriptSearchRanges(in: text, query: "").isEmpty)
        XCTAssertTrue(transcriptSearchRanges(in: text, query: "другое").isEmpty)
    }

    func testTranscriptSearchMatchesAcrossTypographicSpacesWithoutChangingOffsets() {
        let text = typographicText("Я в Москве, а в Москве ещё снег")
        let ranges = transcriptSearchRanges(in: text, query: "в Москве")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["в\u{00a0}Москве", "в\u{00a0}Москве"])
        XCTAssertEqual(transcriptSearchRanges(in: "Я в Москве", query: "в\u{00a0}Москве").count, 1)
        XCTAssertEqual(transcriptSearchRanges(in: "Спикер 1", query: "СПИКЕР"), [NSRange(location: 0, length: 6)])
    }

    func testReselectingVoiceSamplePreservesUnappliedName() {
        let sample = TranscriptSegment(start: 0, end: 2, speaker: "Спикер 1", text: "Текст")
        XCTAssertEqual(voiceNameForSelection(currentID: sample.id, currentName: "Мария", segment: sample), "Мария")
        XCTAssertEqual(voiceNameForSelection(currentID: UUID(), currentName: "Мария", segment: sample), "Спикер 1")
        XCTAssertEqual(voiceNameForSelection(currentID: nil, currentName: "", segment: sample), "Спикер 1")
    }

    func testRecordingCounterSwitchesToHoursAtOneHour() {
        XCTAssertEqual(recordingTimecode(0), "00:00")
        XCTAssertEqual(recordingTimecode(9), "00:09")
        XCTAssertEqual(recordingTimecode(10), "00:10")
        XCTAssertEqual(recordingTimecode(3599), "59:59")
        XCTAssertEqual(recordingTimecode(3600), "01:00:00")
        XCTAssertEqual(recordingTimecode(6000), "01:40:00")
        XCTAssertEqual(recordingTimecode(3601), "01:00:01")
        XCTAssertEqual(recordingTimecode(45296), "12:34:56")
    }
    func testCaptureTimelinePreservesDropoutsAndDetectsDuplicateBuffers() {
        XCTAssertEqual(AudioTimeline.adjustment(timestamp: 12, firstTimestamp: 10, framesWritten: 16000, sampleRate: 16000), 16000)
        XCTAssertEqual(AudioTimeline.adjustment(timestamp: 10.5, firstTimestamp: 10, framesWritten: 16000, sampleRate: 16000), -8000)
        XCTAssertEqual(AudioTimeline.adjustment(timestamp: 11.001, firstTimestamp: 10, framesWritten: 16000, sampleRate: 16000), 0)
    }
    func testPurgeOnlyTrashedAndRetainsSharedAudioAndVoiceSamples() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var active = Meeting(title: "Keep", source: "Synthetic")
        active.audioFiles = ["shared.caf"]; try lib.save(active)
        var trashed = Meeting(title: "Delete", source: "Synthetic")
        trashed.audioFiles = ["shared.caf", "private.caf"]; trashed.deletedAt = Date(); try lib.save(trashed)
        for name in trashed.audioFiles { try Data([1,2]).write(to: lib.audioURL(name)) }
        try lib.saveVoices([VoiceProfile(name: "Kept", samples: [[1,0]])])
        XCTAssertThrowsError(try lib.purgeTrashed(active.id))
        try lib.purgeTrashed(trashed.id)
        XCTAssertEqual(try lib.all(includeDeleted: true).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try lib.audioURL("shared.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try lib.audioURL("private.caf").path))
        XCTAssertEqual(try lib.voices().count, 1)
    }
    func testMeetingWideSpeakerCentroidsDoNotMultiplyAcrossWindows() {
        var segments: [TranscriptSegment] = []
        for i in 0..<150 {
            var a = TranscriptSegment(start: Double(i * 4), end: Double(i * 4 + 3), speaker: "Собеседники", text: "Fixture")
            a.embedding = i % 2 == 0 ? [1, Float(i % 5) * 0.04, 0] : [0, Float(i % 7) * 0.03, 1]
            segments.append(a)
        }
        let output = SpeakerClustering.assign(segments, profiles: [])
        XCTAssertEqual(Set(output.map(\.speaker)).count, 2)
        XCTAssertEqual(Set(stride(from: 0, to: 150, by: 2).map { output[$0].speaker }).count, 1)
        XCTAssertNotEqual(output[0].speaker, output[1].speaker)
    }
    func testShortAndInvalidVoicesDoNotCreatePeopleAndMicRemainsMe() {
        var short = TranscriptSegment(start: 0, end: 1, speaker: "Собеседники", text: "Да")
        short.embedding = [1,0]
        var invalid = short; invalid.embedding = [.nan,0]; invalid.end = 5
        var mic = short; mic.speaker = "Я"; mic.end = 4
        let result = SpeakerClustering.assign([short, invalid, mic], profiles: [VoiceProfile(name: "Remote", samples: [[1,0]])])
        XCTAssertEqual(result.map(\.speaker), ["Remote", "Собеседники", "Я"])
        XCTAssertEqual(SpeakerClustering.assign([short], profiles: []).first?.speaker, "Собеседники")
    }
    func testLegacyPreferencesDefaultToQuietProcessing() throws {
        let data = try JSONEncoder().encode(Preferences())
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: data).usesQuietProcessing)
        var preferences = Preferences(); preferences.quietProcessing = false
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).usesQuietProcessing)
    }
    func testFolderIconBackwardCompatibilityAndPersistence() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Работа\"}".utf8)
        let folder = try JSONDecoder().decode(MeetingFolder.self, from: legacy)
        XCTAssertEqual(folder.iconName, "folder")
        XCTAssertEqual(folder.id, id)
        var changed = folder
        changed.symbol = "briefcase"
        let restored = try JSONDecoder().decode(MeetingFolder.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored, changed)
        XCTAssertEqual(restored.iconName, "briefcase")
    }

    func testEchoRequiresSignalAndPreservesDoubleTalk() {
        var seed: UInt64 = 42
        func noise(_ count: Int) -> [Float] {
            (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) * 0.2
            }
        }
        let reference = noise(37600)
        let echo = Array(reference[4000..<36000]).map { $0 * 0.4 }
        XCTAssertTrue(EchoDetector.isEcho(microphone: echo, reference: reference))
        let voice = noise(32000)
        XCTAssertFalse(EchoDetector.isEcho(microphone: zip(echo, voice).map(+), reference: reference))
        XCTAssertFalse(EchoDetector.isEcho(microphone: voice, reference: reference))
        XCTAssertFalse(EchoDetector.isEcho(microphone: Array(repeating: 0, count: 32000), reference: reference))
        XCTAssertTrue(EchoDetector.sameWords("Вот такой простой пример.", "А вот такой простой пример сегодня"))
        XCTAssertFalse(EchoDetector.sameWords("Вот такой другой пример", "Вот такой простой пример"))
        XCTAssertFalse(EchoDetector.sameWords("Да", "Да"))
    }
    func testAutomaticTitleAndRenamedMetadata() {
        var meeting = Meeting(title: "", source: "System")
        meeting.title = "Встреча · " + meeting.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))
        XCTAssertTrue(meeting.hasAutomaticTitle)
        meeting.automaticTitle = meeting.title
        meeting.title = "Планирование"
        XCTAssertFalse(meeting.hasAutomaticTitle)
        meeting.title = meeting.automaticTitle!
        XCTAssertTrue(meeting.hasAutomaticTitle)
    }
    func testAutomaticNamesFollowAudioSourceAndPreserveCustomNames() {
        var call = Meeting(title: "", source: "Системный звук")
        call.title = "Встреча · " + call.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))
        XCTAssertTrue(call.refreshAutomaticTitle())
        XCTAssertTrue(call.title.hasPrefix("Созвон · "))
        XCTAssertTrue(call.hasAutomaticTitle)
        XCTAssertFalse(call.refreshAutomaticTitle())
        call.title = "Планирование"
        XCTAssertFalse(call.refreshAutomaticTitle())
        XCTAssertEqual(call.title, "Планирование")
        var imported = Meeting(title: "", source: "Аудиофайл")
        imported.title = imported.defaultTitle; imported.automaticTitle = imported.title
        XCTAssertTrue(imported.title.hasPrefix("Запись · "))
        XCTAssertTrue(imported.hasAutomaticTitle)
    }
    func testDateYearAppearsAtCalendarAnniversary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 11, 3)
        XCTAssertFalse(meetingDateLabel(date(2026, 11, 3), now: now, calendar: calendar).contains("2026"))
        XCTAssertFalse(meetingDateLabel(date(2025, 11, 4), now: now, calendar: calendar).contains("2025"))
        XCTAssertTrue(meetingDateLabel(date(2025, 11, 3), now: now, calendar: calendar).contains("2025"))
        XCTAssertTrue(meetingDateLabel(date(2024, 2, 29), now: date(2025, 2, 28), calendar: calendar).contains("2024"))
        XCTAssertFalse(meetingDateLabel(date(2027, 1, 1), now: now, calendar: calendar).contains("2027"))
    }
    func testScreenTypographyBindsShortWordsDatesAndUnitsWithoutChangingCode() {
        XCTAssertEqual(typographicText("В папку отправляется текст для встречи"), "В\u{00a0}папку отправляется текст для\u{00a0}встречи")
        XCTAssertEqual(typographicText("3 ноября · 45 секунд · 16 кГц · 25%"), "3\u{00a0}ноября · 45\u{00a0}секунд · 16\u{00a0}кГц · 25\u{00a0}%")
        XCTAssertEqual(typographicText("команда\nи результат"), "команда\nи\u{00a0}результат")
        XCTAssertEqual(typographicText("https://example.com/a/b?x=1"), "https://example.com/a/b?x=1")
        XCTAssertEqual(typographicText("https://example.com/a?x=25%20"), "https://example.com/a?x=25%20")
        let text = "А в папку для записи — через 45 секунд"
        XCTAssertEqual(typographicText(typographicText(text)), typographicText(text))
    }
    func temporaryLibrary() throws -> MeetingLibrary { try MeetingLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    func testFailedStartupDiscardsOnlyEmptyJournal() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var meeting = Meeting(title: "Отказ в доступе", source: "Толк")
        meeting.audioFiles = ["sample.caf"]
        try lib.save(meeting)
        try lib.discardEmptyDraft(meeting)
        XCTAssertTrue(try lib.all().isEmpty)
        try lib.save(meeting)
        try Data([1]).write(to: lib.audioURL("sample.caf"))
        try lib.discardEmptyDraft(meeting)
        XCTAssertEqual(try lib.all().count, 1)
        try FileManager.default.removeItem(at: lib.audioURL("sample.caf"))
        meeting.segments = [.init(start: 0, end: 1, speaker: "Я", text: "Текст")]
        try lib.save(meeting)
        try lib.discardEmptyDraft(meeting)
        XCTAssertEqual(try lib.all().count, 1)
    }
    func testLegacyMeetingsFoldersAndTrash() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var m = Meeting(title: "Old meeting", source: "Talk")
        m.segments = [.init(start: 0, end: 3, speaker: "Me", text: "Hello")]
        let legacy = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Meeting.self, from: legacy)
        XCTAssertNil(decoded.folderID); XCTAssertNil(decoded.deletedAt); XCTAssertNil(decoded.segments[0].audioFile)
        let folder = MeetingFolder(name: "Work")
        try lib.saveFolders([folder]); XCTAssertEqual(try lib.folders(), [folder])
        m.folderID = folder.id; m.deletedAt = Date(); try lib.save(m)
        XCTAssertTrue(try lib.all().isEmpty)
        XCTAssertEqual(try lib.all(includeDeleted: true).count, 1)
        m.deletedAt = nil; try lib.save(m)
        XCTAssertEqual(try lib.all().first?.folderID, folder.id)
        XCTAssertEqual(try lib.all().first?.segments, decoded.segments)
    }
    func testVoiceExamplesRoundTripAndIdentify() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let m = Meeting(title: "Meeting", source: "System")
        var profile = VoiceProfile(name: "Person", samples: [[1, 0]])
        profile.examples = [VoiceExample(file: "example.caf", meetingID: m.id, segmentID: UUID(), embedding: [1, 0])]
        try lib.saveVoices([profile]); try lib.save(m)
        let saved = try lib.voices()
        XCTAssertEqual(saved[0].examples?.first?.meetingID, m.id)
        XCTAssertEqual(VoiceMatcher.identify([1, 0], profiles: saved), "Person")
    }
    func testMeterDistinguishesSilentBuffersFromMissingBuffers() {
        var track = AudioMeterTrack()
        track.update(peak: 0, seconds: 1, lastWrite: 10, now: 10)
        XCTAssertTrue(track.isFresh(now: 10)); XCTAssertEqual(track.level, 0)
        track.update(peak: 0.1, seconds: 2, lastWrite: 11, now: 11)
        XCTAssertGreaterThan(track.level, 0)
        track.update(peak: 0.1, seconds: 2, lastWrite: 11, now: 15)
        XCTAssertFalse(track.isFresh(now: 15)); XCTAssertEqual(track.level, 0)
        XCTAssertEqual(track.seconds, 2)
        for _ in 0..<track.history.count { track.update(peak: 0, seconds: 2, lastWrite: 11, now: 16) }
        XCTAssertEqual(track.history.count, 512)
        XCTAssertEqual(track.historyTimes.count, track.history.count)
        XCTAssertEqual(track.historyTimes.last, 16)
        XCTAssertTrue(track.history.allSatisfy { $0 == 0 })
        XCTAssertEqual(AudioMeterTrack.displayLevel(.nan), 0)
        XCTAssertEqual(AudioMeterTrack.displayLevel(2), 1)
        XCTAssertEqual(AudioMeterTrack.displayLevel(0.0001), 0)
    }
    func testDetectorDoesNotStopBeforeCallAndIgnoresShortActivity() {
        var detector = CallDetector(); let now = Date()
        XCTAssertEqual(detector.update(active: false, now: now), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(300)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(301)), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(302)), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(360)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(361)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(365)), .start)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(366)), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(411)), .stop)
    }
    func testDetectorDebouncesReconnectAndManualStop() {
        var detector = CallDetector(); let now = Date()
        XCTAssertEqual(detector.update(active: true, now: now), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(3)), .start)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(5)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(30)), .none)
        detector.manuallyStopped()
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(60)), .none)
        _ = detector.update(active: false, now: now.addingTimeInterval(61))
        _ = detector.update(active: false, now: now.addingTimeInterval(107))
        _ = detector.update(active: true, now: now.addingTimeInterval(110))
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(114)), .start)
        _ = detector.update(active: false, now: now.addingTimeInterval(115))
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(161)), .stop)
    }
    func testTypographyBindsShortWordsWithoutBreakingParagraphs() {
        XCTAssertEqual(typographicText("а в четверг"), "а\u{00a0}в\u{00a0}четверг")
        XCTAssertEqual(typographicText("Привет.\nСледующая строка"), "Привет.\nСледующая строка")
    }
    func testVoiceMatcherRejectsAmbiguityAndDifferentDimensions() {
        XCTAssertEqual(VoiceMatcher.similarity([1, 0], [0, 1]), 0)
        XCTAssertEqual(VoiceMatcher.similarity([1], [1, 0]), -1)
        let profiles = [VoiceProfile(name: "A", samples: [[1, 0]]), VoiceProfile(name: "B", samples: [[0.99, 0.01]])]
        XCTAssertNil(VoiceMatcher.identify([1, 0], profiles: profiles))
        XCTAssertEqual(VoiceMatcher.identify([1, 0], profiles: [profiles[0]]), "A")
        XCTAssertNil(VoiceMatcher.identify([0, 1], profiles: [profiles[0]]))
    }
    func testRoundTripAndSafeExport() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var m = Meeting(title: "../Встреча\nтест", source: "Толк")
        m.segments = [.init(start: 12, end: 20, speaker: "Даша", text: "Проверка сохранения")]
        try lib.save(m); XCTAssertEqual(try lib.read(m.id), m)
        let first = try MarkdownExporter.export(m, to: lib.root)
        m.title = "Новое название"; let second = try MarkdownExporter.export(m, to: lib.root)
        XCTAssertEqual(first, second); XCTAssertEqual(first.deletingLastPathComponent().path, lib.root.path)
        XCTAssertTrue(try String(contentsOf: second).contains("00:12 · Даша"))
        XCTAssertThrowsError(try lib.audioURL("../secret"))
    }
    func testMCPEnabledByDefaultAndRevokesDuringSession() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let m = Meeting(title: "Встреча", source: "Толк"); try lib.save(m)
        let handler = MCPHandler(library: lib)
        func call(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] { handler.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])! }
        XCTAssertNotNil(call("tools/list")["error"])
        XCTAssertNotNil(call("initialize")["result"])
        XCTAssertNotNil(call("tools/list")["result"])
        XCTAssertNotNil(call("tools/call", ["name": "list_meetings"])["result"])
        XCTAssertNotNil(call("tools/call", ["name": "read_transcript", "arguments": ["meeting_id": "../../etc/passwd"]])["error"])
        var deleted = m; deleted.deletedAt = Date(); try lib.save(deleted)
        XCTAssertNotNil(call("tools/call", ["name": "read_transcript", "arguments": ["meeting_id": m.id.uuidString]])["error"])
        var prefs = try lib.preferences(); prefs.mcpEnabled = false; try lib.savePreferences(prefs)
        XCTAssertNotNil(call("tools/list")["error"])
        XCTAssertNotNil(call("tools/call", ["name": "list_meetings"])["error"])
        prefs.mcpEnabled = true; try lib.savePreferences(prefs)
        XCTAssertNotNil(call("tools/list")["result"])
    }
    func testMCPPreferencesPreserveSavedAccessChoice() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        XCTAssertTrue(try lib.preferences().mcpEnabled)
        var prefs = Preferences(); prefs.mcpEnabled = false; try lib.savePreferences(prefs)
        let reopened = try MeetingLibrary(root: lib.root)
        XCTAssertFalse(try reopened.preferences().mcpEnabled)
        prefs.mcpEnabled = true; try reopened.savePreferences(prefs)
        XCTAssertTrue(try lib.preferences().mcpEnabled)
    }
}
