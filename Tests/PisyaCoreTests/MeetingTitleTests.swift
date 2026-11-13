import XCTest
@testable import PisyaCore

final class MeetingTitleTests: XCTestCase {
    private func completed() -> Meeting {
        var meeting = Meeting(title: "", source: "Системный звук")
        meeting.title = meeting.defaultTitle; meeting.automaticTitle = meeting.title
        meeting.status = .ready
        meeting.segments = [.init(start: 0, end: 20, speaker: "Анна", text: "Обсудили запуск нового поиска и договорились выпустить его в декабре.")]
        return meeting
    }

    func testGeneratedTitleSurvivesDateRefreshAndLibraryReload() throws {
        var meeting = completed()
        XCTAssertTrue(meeting.applyGeneratedTitle("«Запуск нового поиска»."))
        XCTAssertEqual(meeting.title, "Запуск нового поиска")
        XCTAssertFalse(meeting.hasAutomaticTitle)
        XCTAssertFalse(meeting.refreshAutomaticTitle())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        try library.save(meeting)
        var reloaded = try library.read(meeting.id)
        XCTAssertFalse(reloaded.refreshAutomaticTitle())
        XCTAssertEqual(reloaded.title, "Запуск нового поиска")
        XCTAssertTrue(reloaded.applyGeneratedTitle("Новый поиск: сроки выпуска"))
        XCTAssertTrue(MarkdownExporter.render(reloaded).contains("# Новый поиск: сроки выпуска"))
    }

    func testManualRenamePreventsReplacementEvenWhenItMatchesOldTitle() throws {
        var meeting = completed()
        XCTAssertTrue(meeting.applyGeneratedTitle("Запуск поиска"))
        XCTAssertTrue(meeting.rename(to: "  Запуск поиска \n"))
        var reloaded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertFalse(reloaded.applyGeneratedTitle("Другое название"))
        XCTAssertFalse(reloaded.refreshAutomaticTitle())
        XCTAssertEqual(reloaded.title, "Запуск поиска")
        XCTAssertFalse(reloaded.rename(to: " \n "))
        XCTAssertEqual(reloaded.title, "Запуск поиска")
    }

    func testLegacyCustomNameAndManuallyChosenDateArePreserved() {
        var legacy = completed(); legacy.title = "Наш план"; legacy.automaticTitle = nil
        XCTAssertFalse(legacy.applyGeneratedTitle("Релиз поиска"))
        var dated = completed()
        let title = dated.title
        XCTAssertTrue(dated.rename(to: title))
        XCTAssertFalse(dated.applyGeneratedTitle("Релиз поиска"))
        XCTAssertFalse(dated.hasAutomaticTitle)
        XCTAssertEqual(dated.title, title)
    }

    func testResettingCustomTitleRestoresDefaultAndAllowsGeneration() {
        var meeting = completed()
        XCTAssertTrue(meeting.rename(to: "Планы команды"))

        XCTAssertTrue(meeting.rename(to: " \n ", resetIfEmpty: true))
        XCTAssertEqual(meeting.headingTitle, "Созвон")
        XCTAssertEqual(meeting.title, meeting.defaultTitle)
        XCTAssertTrue(meeting.applyGeneratedTitle("Запуск нового поиска"))
    }

    func testOnlyCompleteNonemptyTranscriptsCanReceiveTitles() {
        for status in [MeetingStatus.recorded, .processing, .failed] {
            var meeting = completed(); meeting.status = status
            XCTAssertFalse(meeting.applyGeneratedTitle("Релиз поиска"))
        }
        var draft = completed(); draft.liveCommittedUntil = 20
        XCTAssertFalse(draft.applyGeneratedTitle("Релиз поиска"))
        var empty = completed(); empty.segments[0].text = " \n "
        XCTAssertFalse(empty.applyGeneratedTitle("Релиз поиска"))
        var meeting = completed()
        for output in ["", "   ", "<think>Нужно подумать", "Первая строка\nВторая строка", String(repeating: "длинное ", count: 40)] {
            XCTAssertFalse(meeting.applyGeneratedTitle(output), output)
            XCTAssertTrue(meeting.hasAutomaticTitle)
        }
    }

    func testTitleCleanupRemovesFormattingAndReasoning() {
        XCTAssertEqual(MeetingTitleComposer.cleanTitle("<think>Reasoning</think>\nНазвание: **«Релиз поиска»**."), "Релиз поиска")
        XCTAssertEqual(MeetingTitleComposer.cleanTitle("# Search launch."), "Search launch")
        XCTAssertEqual(MeetingTitleComposer.cleanTitle("Название встречи: Запуск поиска"), "Запуск поиска")
        XCTAssertNil(MeetingTitleComposer.cleanTitle("<think>Unfinished"))
        XCTAssertNil(MeetingTitleComposer.cleanTitle("12345"))
    }

    func testRejectsSummaryProseInsteadOfAShortTitle() {
        XCTAssertNil(MeetingTitleComposer.cleanTitle("Ошибка в сценариях адреса и названия. Решение: перенести запуск на декабрь"))
        XCTAssertEqual(MeetingTitleComposer.cleanTitle("Запуск поиска: проверка качества, исправление ошибок"), "Запуск поиска: проверка качества, исправление ошибок")
    }

    func testTitleRejectsForeignWritingSystems() {
        XCTAssertNil(MeetingTitleComposer.cleanTitle("Обсуждение поиска 搜索"))
        XCTAssertNil(MeetingTitleComposer.cleanTitle("Αναζήτηση"))
        XCTAssertEqual(MeetingTitleComposer.cleanTitle("2ГИС API для партнёров"), "2ГИС API для партнёров")
    }

    func testTitleUsesSpeechWithoutSpeakerLabelsAndSkipsCorruptedSegments() async throws {
        let composer = MeetingTitleComposer { request in
            guard request.kind == .title, request.text == "Обсудили запуск нового поиска." else {
                throw TestFailure.unexpectedInput
            }
            return "Запуск нового поиска"
        }
        let title = try await composer.title(for: [
            .init(start: 0, end: 1, speaker: "Пётр", text: "对。"),
            .init(start: 1, end: 7, speaker: "Анна", text: "Обсудили запуск нового поиска.")
        ])
        XCTAssertEqual(title, "Запуск нового поиска")
    }

    func testShortTranscriptGeneratesATitleAndEmptyTranscriptSkipsModel() async throws {
        let composer = MeetingTitleComposer { request in
            guard request.kind == .title, request.text.contains("нового поиска") else { throw TestFailure.unexpectedInput }
            return "Запуск нового поиска"
        }
        let title = try await composer.title(for: completed().segments)
        XCTAssertEqual(title, "Запуск нового поиска")
        let empty = try await composer.title(for: [])
        XCTAssertNil(empty)
    }

    func testLongTranscriptIncludesLastPartThroughMultipleSummaryLevels() async throws {
        // The decisive topic appears at the end, beyond the first context window.
        let segments = (0..<100).map { index -> TranscriptSegment in
            let start = Double(index)
            let end = Double(index + 1)
            let text = index == 99
                ? "Итог: монетизация поиска"
                : "Обсудили подробности плана, результаты проверки и следующие шаги команды."
            return TranscriptSegment(start: start, end: end, speaker: "Анна", text: text)
        }
        let composer = MeetingTitleComposer(characterLimit: 256) { request in
            let hasTopic = request.text.contains("монетизация")
            return request.kind == .summary ? (hasTopic ? "монетизация поиска" : "планы команды") : (hasTopic ? "Монетизация поиска" : "Планы команды")
        }
        let title = try await composer.title(for: segments)
        XCTAssertEqual(title, "Монетизация поиска")
    }

    func testMediumTranscriptKeepsAgendaAndFollowUpInTheSameModelRequest() async throws {
        let background = String(repeating: "Участники обменялись новостями по другим проектам. ", count: 96)
        let agenda = "Хочу обсудить запись в сервис через приложение."
        let followUp = "Сравним стоимость своей реализации и поддержки у партнёра."
        let composer = MeetingTitleComposer { request in
            if request.kind == .summary {
                guard request.text.contains(agenda), request.text.contains(followUp) else {
                    throw TestFailure.unexpectedInput
                }
                return "Запись в сервис через приложение, сравнение вариантов реализации."
            }
            guard request.text == "Запись в сервис через приложение, сравнение вариантов реализации." else {
                throw TestFailure.unexpectedInput
            }
            return "Интеграция записи в сервис"
        }
        let title = try await composer.title(for: [
            .init(start: 0, end: 300, speaker: "Я", text: background),
            .init(start: 300, end: 305, speaker: "Я", text: agenda),
            .init(start: 305, end: 325, speaker: "Собеседник", text: String(repeating: "Обсудили реализацию. ", count: 10)),
            .init(start: 325, end: 330, speaker: "Я", text: followUp)
        ])
        XCTAssertEqual(title, "Интеграция записи в сервис")
    }

    func testGenerationFailureDoesNotMutateMeeting() async throws {
        let original = completed()
        var meeting = original
        let composer = MeetingTitleComposer { _ in throw TestFailure.unavailable }
        do {
            if let title = try await composer.title(for: meeting.segments) { meeting.applyGeneratedTitle(title) }
            XCTFail("Expected model failure")
        } catch TestFailure.unavailable {}
        XCTAssertEqual(meeting, original)
        XCTAssertEqual(meeting.status, .ready)
    }

    func testCancellationStopsBeforeModelCall() async {
        let composer = MeetingTitleComposer { _ in throw TestFailure.unexpectedInput }
        let segments = completed().segments
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await composer.title(for: segments)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private enum TestFailure: Error { case unexpectedInput, unavailable }
}
