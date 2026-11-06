import XCTest
@testable import PisyaCore

final class MCPContextTests: XCTestCase {
    private var library: MeetingLibrary!
    private var handler: MCPHandler!

    override func setUpWithError() throws {
        library = try MeetingLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        handler = MCPHandler(library: library)
        _ = handler.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: library.root)
    }

    private func response(_ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        handler.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": ["name": tool, "arguments": arguments]])!
    }

    private func payload(_ tool: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let reply = response(tool, arguments)
        let result = try XCTUnwrap(reply["result"] as? [String: Any], String(describing: reply))
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if let structured = result["structuredContent"] as? [String: Any] {
            XCTAssertEqual(NSDictionary(dictionary: structured), NSDictionary(dictionary: decoded))
        }
        return decoded
    }

    @discardableResult private func fixture(folder: UUID? = nil) throws -> Meeting {
        var meeting = Meeting(title: "Планы проекта", source: "Тест")
        meeting.date = ISO8601DateFormatter().date(from: "2026-11-05T10:00:00Z")!
        meeting.folderID = folder
        meeting.duration = 30
        meeting.status = .ready
        meeting.segments = [
            TranscriptSegment(start: 0, end: 5, speaker: "Борис", text: "Обсудим запуск."),
            TranscriptSegment(start: 8, end: 14, speaker: "Анна", text: "Пилот: бюджет 50 тысяч."),
            TranscriptSegment(start: 20, end: 25, speaker: "Борис", text: "Согласуем до пятницы.")
        ]
        try library.save(meeting)
        return meeting
    }

    func testSearchReturnsExactQuotesContextAndUsableFolderFilters() throws {
        let folder = MeetingFolder(name: "Бронирование")
        try library.saveFolders([folder])
        let meeting = try fixture(folder: folder.id)
        _ = try fixture()
        var deleted = try fixture(folder: folder.id)
        deleted.deletedAt = Date()
        try library.save(deleted)

        let result = try payload("search_transcripts", [
            "query": "бюджет пилот", "speaker": "анна", "folder_id": folder.id.uuidString,
            "date_from": "2026-11-05T09:00:00Z", "date_to": "2026-11-05T11:00:00Z"
        ])
        XCTAssertEqual(result["total"] as? Int, 1)
        XCTAssertEqual(result["complete"] as? Bool, true)
        let hits = try XCTUnwrap(result["matches"] as? [[String: Any]])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit["meeting_id"] as? String, meeting.id.uuidString)
        let segment = try XCTUnwrap(hit["segment"] as? [String: Any])
        XCTAssertEqual(segment["id"] as? String, meeting.segments[1].id.uuidString)
        XCTAssertEqual(segment["text"] as? String, "Пилот: бюджет 50 тысяч.")
        XCTAssertEqual(segment["index"] as? Int, 1)
        XCTAssertEqual((hit["context_before"] as? [[String: Any]])?.first?["text"] as? String, "Обсудим запуск.")
        XCTAssertEqual((hit["context_after"] as? [[String: Any]])?.first?["text"] as? String, "Согласуем до пятницы.")
        let summaries = try XCTUnwrap(result["meetings"] as? [[String: Any]])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?["folder_id"] as? String, folder.id.uuidString)
    }

    func testReadReturnsStableLinksAndDoesNotExposePrivateStorage() throws {
        var meeting = try fixture()
        meeting.segments[1].embedding = [0.5, 0.8]
        meeting.segments[1].audioFile = "private-track.caf"
        try library.save(meeting)
        let result = try payload("read_transcript", ["meeting_id": meeting.id.uuidString])
        let segments = try XCTUnwrap(result["segments"] as? [[String: Any]])
        let components = try XCTUnwrap(URLComponents(string: try XCTUnwrap(segments[1]["source_url"] as? String)))
        XCTAssertEqual(components.scheme, "pisya")
        XCTAssertEqual(components.host, "meeting")
        XCTAssertEqual(components.path.lowercased(), "/\(meeting.id.uuidString.lowercased())")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "segment" })?.value?.lowercased(),
                       meeting.segments[1].id.uuidString.lowercased())
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-track.caf"))
        XCTAssertFalse(encoded.contains(library.root.path))
        XCTAssertFalse(encoded.contains("embedding"))
    }

    func testPaginationNeverClaimsWholeTranscriptForASinglePage() throws {
        let meeting = try fixture()
        let first = try payload("read_transcript", ["meeting_id": meeting.id.uuidString, "limit": 1])
        XCTAssertEqual(first["total_segments"] as? Int, 3)
        XCTAssertEqual(first["returned"] as? Int, 1)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(first["next_offset"] as? Int, 1)
        XCTAssertEqual(first["complete"] as? Bool, false)
        XCTAssertEqual(first["consistency"] as? String, "per_request")
        let last = try payload("read_transcript", ["meeting_id": meeting.id.uuidString, "offset": 2, "limit": 1])
        XCTAssertEqual(last["has_more"] as? Bool, false)
        XCTAssertTrue(last["next_offset"] is NSNull)
        XCTAssertEqual(last["complete"] as? Bool, false)
        let whole = try payload("read_transcript", ["meeting_id": meeting.id.uuidString])
        XCTAssertEqual(whole["complete"] as? Bool, true)
    }

    func testSearchPaginationAndExactPhraseMode() throws {
        let firstMeeting = try fixture()
        _ = try fixture()
        let first = try payload("search_transcripts", ["query": "пилот бюджет", "limit": 1, "context": 0])
        XCTAssertEqual(first["total"] as? Int, 2)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        let second = try payload("search_transcripts", ["query": "пилот бюджет", "offset": 1, "limit": 1, "context": 0])
        let firstHits = try XCTUnwrap(first["matches"] as? [[String: Any]])
        let secondHits = try XCTUnwrap(second["matches"] as? [[String: Any]])
        XCTAssertNotEqual(firstHits.first?["meeting_id"] as? String, secondHits.first?["meeting_id"] as? String)
        XCTAssertEqual((firstHits.first?["context_before"] as? [[String: Any]])?.count, 0)
        let exact = try payload("search_transcripts", ["query": "бюджет пилот", "mode": "exact_phrase",
                                                     "meeting_id": firstMeeting.id.uuidString])
        XCTAssertEqual(exact["total"] as? Int, 0)
    }

    func testListFoldersAndExistingToolsKeepWorking() throws {
        let folder = MeetingFolder(name: "Проект")
        try library.saveFolders([folder])
        let meeting = try fixture(folder: folder.id)
        _ = try fixture()
        let folders = try payload("list_folders")
        let entries = try XCTUnwrap(folders["folders"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["id"] as? String, folder.id.uuidString)
        XCTAssertEqual(entries.first?["meeting_count"] as? Int, 1)
        let list = try payload("list_meetings", ["folder_id": folder.id.uuidString])
        XCTAssertEqual(list["total"] as? Int, 1)
        let matches = try payload("search_meetings", ["query": "планы", "speaker": "АННА"])
        XCTAssertEqual(matches["total"] as? Int, 2)
        let read = try payload("read_transcript", ["meeting_id": meeting.id.uuidString])
        XCTAssertEqual((read["segments"] as? [[String: Any]])?.count, 3)
    }

    func testLegacySearchKeepsWhitespaceInTheSubstring() throws {
        let matching = Meeting(title: "Выпуск API завтра", source: "Тест")
        try library.save(matching)
        try library.save(Meeting(title: "Выпуск Capitol завтра", source: "Тест"))

        let result = try payload("search_meetings", ["query": " api "])
        let meetings = try XCTUnwrap(result["meetings"] as? [[String: Any]])
        XCTAssertEqual(meetings.compactMap { $0["id"] as? String }, [matching.id.uuidString])
    }

    func testDateFiltersApplyTimezoneAndPreserveSubmillisecondBounds() throws {
        var matching = try fixture()
        let base = matching.date
        matching.date = base.addingTimeInterval(0.123457)
        try library.save(matching)
        var earlier = try fixture()
        earlier.date = base.addingTimeInterval(0.123455)
        try library.save(earlier)
        var later = try fixture()
        later.date = base.addingTimeInterval(0.123459)
        try library.save(later)

        let result = try payload("list_meetings", [
            "date_from": "2026-11-05T15:30:00.123456000+05:30",
            "date_to": "2026-11-05T03:00:00.123458000-07:00",
        ])
        let meetings = try XCTUnwrap(result["meetings"] as? [[String: Any]])
        XCTAssertEqual(meetings.compactMap { $0["id"] as? String }, [matching.id.uuidString])
    }

    func testImpossibleDatesAndOffsetsReturnInvalidArguments() {
        for timestamp in [
            "2026-02-29T00:00:00Z",
            "2024-04-31T00:00:00Z",
            "2026-11-05T24:00:00Z",
            "2026-11-05T00:00:00+05:60",
            "2026-11-05T00:00:00-24:00",
            "2026-11-05T00:00:00.1234567890Z",
        ] {
            let error = response("list_meetings", ["date_from": timestamp])["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? Int, -32602, timestamp)
        }
    }

    func testDraftAndUnknownSpeakerQualitySurvivesMCPSerialization() throws {
        var meeting = try fixture()
        meeting.status = .processing
        meeting.liveCommittedUntil = 12
        meeting.segments[1].speaker = "Спикер 1"
        try library.save(meeting)
        let result = try payload("read_transcript", ["meeting_id": meeting.id.uuidString])
        let summary = try XCTUnwrap(result["meeting"] as? [String: Any])
        let quality = try XCTUnwrap(summary["quality"] as? [String: Any])
        XCTAssertEqual(quality["transcript_complete"] as? Bool, false)
        XCTAssertEqual(quality["recording_coverage"] as? String, "unknown")
        XCTAssertEqual(quality["recognition_confidence"] as? String, "not_measured")
        let segments = try XCTUnwrap(result["segments"] as? [[String: Any]])
        let segmentQuality = try XCTUnwrap(segments[1]["quality"] as? [String: Any])
        XCTAssertEqual(segmentQuality["speaker_identification"] as? String, "unidentified")
        XCTAssertEqual(result["complete"] as? Bool, true, "A complete response can contain an unfinished transcript")
    }

    func testInvalidArgumentsAreRejectedRatherThanSilentlyBroadeningAccess() throws {
        let cases: [(String, [String: Any])] = [
            ("list_meetings", ["limit": 0]),
            ("list_meetings", ["limit": true]),
            ("list_meetings", ["offset": -1]),
            ("list_meetings", ["limit": 1.5]),
            ("list_meetings", ["folder_id": "../../elsewhere"]),
            ("list_meetings", ["speaker": "   "]),
            ("list_meetings", ["date_from": "2026-11-05"]),
            ("list_meetings", ["date_from": "2026-11-06T00:00:00Z", "date_to": "2026-11-05T00:00:00Z"]),
            ("search_meetings", ["query": "   "]),
            ("search_transcripts", ["query": "   "]),
            ("search_transcripts", ["query": "пилот", "mode": "semantic"]),
            ("search_transcripts", ["query": "пилот", "context": 4]),
            ("search_transcripts", ["query": "пилот", "unknown": true]),
            ("read_transcript", ["meeting_id": UUID().uuidString, "offset": "1"])
        ]
        for (name, args) in cases {
            let error = response(name, args)["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? Int, -32602, "\(name): \(args)")
        }
    }

    func testNewToolsRespectRevocationAndTrash() throws {
        var meeting = try fixture()
        meeting.deletedAt = Date()
        try library.save(meeting)
        XCTAssertEqual(try payload("search_transcripts", ["query": "бюджет"])["total"] as? Int, 0)
        XCTAssertNotNil(response("read_transcript", ["meeting_id": meeting.id.uuidString])["error"])
        var prefs = try library.preferences()
        prefs.mcpEnabled = false
        try library.savePreferences(prefs)
        for name in ["search_transcripts", "list_folders"] {
            XCTAssertEqual((response(name, ["query": "бюджет"])["error"] as? [String: Any])?["code"] as? Int, -32001)
        }
    }
}
