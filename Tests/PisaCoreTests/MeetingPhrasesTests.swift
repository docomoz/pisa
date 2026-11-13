import XCTest
@testable import PisaCore

final class MeetingPhrasesTests: XCTestCase {
    func testGeneratedPhrasesAreLongEnoughAndDoNotRepeatImmediately() {
        var generator = MeetingPhraseGenerator()
        var previous = generator.next()
        for _ in 0..<2_000 {
            let current = generator.next()
            XCTAssertGreaterThanOrEqual(current.count, 75, current)
            XCTAssertGreaterThanOrEqual(current.split(whereSeparator: \.isWhitespace).count, 10, current)
            XCTAssertNotEqual(current, previous)
            previous = current
        }
    }

    func testCuratedPhrasesAreLongAndDoNotRepeatUntilTheDeckIsExhausted() {
        var generator = MeetingPhraseGenerator()
        XCTAssertGreaterThanOrEqual(MeetingPhraseGenerator.curated.count, 100)
        var seen = Set<String>()
        var last = ""
        for _ in MeetingPhraseGenerator.curated {
            let phrase = generator.nextCurated()
            XCTAssertTrue(seen.insert(phrase).inserted, phrase)
            XCTAssertGreaterThanOrEqual(phrase.count, 75, phrase)
            XCTAssertGreaterThanOrEqual(phrase.split(whereSeparator: \.isWhitespace).count, 10, phrase)
            last = phrase
        }
        XCTAssertNotEqual(generator.nextCurated(), last)
    }

    func testDisplayedPhrasesUseReviewedCorpusAndDoNotRepeatWithinOneCycle() {
        var generator = MeetingPhraseGenerator()
        var seen = Set<String>()
        for _ in MeetingPhraseGenerator.curated {
            let phrase = generator.next()
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(phrase), phrase)
            XCTAssertTrue(seen.insert(phrase).inserted, phrase)
        }
        XCTAssertEqual(seen.count, MeetingPhraseGenerator.curated.count)
    }

    func testConsecutivePhrasesVaryTheirOpeningWhenPossible() {
        var generator = MeetingPhraseGenerator()
        var remaining = Set(MeetingPhraseGenerator.curated)
        var previousOpening: String?
        for _ in MeetingPhraseGenerator.curated {
            let phrase = generator.next()
            let opening = String(phrase.split(whereSeparator: \.isWhitespace).first ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let previousOpening, remaining.contains(where: { candidate in
                String(candidate.split(whereSeparator: \.isWhitespace).first ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters) != previousOpening
            }) {
                XCTAssertNotEqual(opening, previousOpening, phrase)
            }
            remaining.remove(phrase)
            previousOpening = opening
        }
    }

    func testReviewedPhrasesHaveNoTrailingFullStop() {
        for phrase in MeetingPhraseGenerator.curated {
            XCTAssertFalse(phrase.hasSuffix("."), phrase)
        }
    }


    func testPersonalizationUsesArbitraryEntriesAndKeepsThreeOrdinaryPhrasesBetweenThem() throws {
        var generator = MeetingPhraseGenerator()
        generator.updateVocabulary("OpenTelemetry; План отката")
        let request = try XCTUnwrap(generator.personalizationRequest())
        XCTAssertEqual(Set(request.terms), ["OpenTelemetry", "План отката"])
        let suggestions = [
            "OpenTelemetry": "Мы видим в {{TERM}} весь путь запроса, осталось назначить встречу, чтобы определить, на чьём участке его перестали видеть пользователи",
            "План отката": "Предлагаю показать документ «{{TERM}}» на следующем созвоне, чтобы успеть согласовать условия возврата до того, как согласуем сам запуск"
        ]
        generator.acceptPersonalization(response(for: request, suggestions: suggestions), for: request)

        var seen = Set<String>()
        for index in 1...16 {
            let phrase = generator.next()
            if [4, 8].contains(index) {
                let term = try XCTUnwrap(request.terms.first(where: { phrase.contains($0) }))
                XCTAssertTrue(seen.insert(term).inserted)
                XCTAssertFalse(MeetingPhraseGenerator.curated.contains(phrase))
            } else {
                XCTAssertTrue(MeetingPhraseGenerator.curated.contains(phrase), phrase)
            }
        }
        XCTAssertEqual(seen, Set(request.terms))
    }

    func testNewVocabularyInvalidatesBothCachedAndInFlightPhrases() throws {
        var generator = MeetingPhraseGenerator()
        generator.updateVocabulary("OpenTelemetry")
        let initial = try XCTUnwrap(generator.personalizationRequest())
        let reply = response(for: initial, suggestions: [
            "OpenTelemetry": "В {{TERM}} всё уже видно, предлагаю созвониться завтра и согласовать, кто теперь отвечает за просмотр этих данных"
        ])
        generator.acceptPersonalization(reply, for: initial)

        generator.updateVocabulary("Argo CD")
        generator.acceptPersonalization(reply, for: initial)
        let current = try XCTUnwrap(generator.personalizationRequest())
        XCTAssertEqual(current.terms, ["Argo CD"])
        for _ in 0..<4 {
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(generator.next()))
        }
        generator.acceptPersonalization(response(for: current, suggestions: [
            "Argo CD": "В {{TERM}} приложение уже синхронизировано, осталось договориться, считаем ли мы релиз завершённым до того, как его увидят пользователи"
        ]), for: current)
        XCTAssertTrue(generator.next().contains("Argo CD"))
    }

    func testBuiltInTermsAreExcludedAndModelMaySkipUnknownTerms() throws {
        var generator = MeetingPhraseGenerator()
        generator.updateVocabulary(Preferences().vocabulary + ", ШФР-7; Вжухмодуль; вжухмодуль")
        let request = try XCTUnwrap(generator.personalizationRequest())
        XCTAssertEqual(request.terms, ["Вжухмодуль"])
        generator.acceptPersonalization([], for: request)
        XCTAssertNil(generator.personalizationRequest())
        for _ in 0..<12 {
            XCTAssertTrue(MeetingPhraseGenerator.curated.contains(generator.next()))
        }
    }

    func testModelResponseRejectsUnknownIDsInvalidTemplatesAndDuplicateRows() throws {
        var generator = MeetingPhraseGenerator()
        generator.updateVocabulary("План Отката; Redis; Vault")
        let request = try XCTUnwrap(generator.personalizationRequest())
        let expected = try XCTUnwrap(request.terms.firstIndex(of: "План Отката"))
        let redis = try XCTUnwrap(request.terms.firstIndex(of: "Redis"))
        let vault = try XCTUnwrap(request.terms.firstIndex(of: "Vault"))
        let valid = "Предлагаю показать «план отката» на следующем созвоне и отдельно согласовать, кто будет согласовывать возвращение к предыдущей версии"
        let redisPhrase = "Предлагаю открыть Redis на следующем созвоне и отдельно согласовать, кто проверит время жизни ключей после нашего согласования"
        let rows: [MeetingPhraseGenerator.PersonalizationRequest.Suggestion] = [
            .init(id: 99, phrase: valid),
            .init(id: redis, phrase: redisPhrase + " в Redis"),
            .init(id: redis, phrase: redisPhrase + " через Vault"),
            .init(id: vault, phrase: valid),
            .init(id: expected, phrase: valid + "."),
            .init(id: expected, phrase: valid)
        ]
        generator.acceptPersonalization(rows, for: request)
        let phrases = (0..<10).map { _ in generator.next() }.filter { !MeetingPhraseGenerator.curated.contains($0) }
        XCTAssertEqual(phrases, [valid.replacingOccurrences(of: "план отката", with: "План Отката")])
    }

    func testAddingATermDoesNotRepeatOneAlreadyShown() throws {
        var generator = MeetingPhraseGenerator()
        generator.updateVocabulary("Argo CD")
        let request = try XCTUnwrap(generator.personalizationRequest())
        generator.acceptPersonalization(response(for: request, suggestions: [
            "Argo CD": "В {{TERM}} приложение уже синхронизировано, осталось договориться, считаем ли мы релиз завершённым до того, как его увидят пользователи"
        ]), for: request)
        for _ in 0..<3 { _ = generator.next() }
        XCTAssertTrue(generator.next().contains("Argo CD"))
        generator.updateVocabulary("ARGO CD; OpenTelemetry")
        XCTAssertEqual(generator.personalizationRequest()?.terms, ["OpenTelemetry"])
    }

    func testSemanticActionCanUseAnArbitraryTermWithoutRepeatingIt() throws {
        var generator = MeetingPhraseGenerator()
        generator.updateVocabulary("Redis; ШФР-7")
        let request = try XCTUnwrap(generator.personalizationRequest())
        XCTAssertEqual(request.terms, ["Redis"])
        let modelResponse = #"{"ideas":[{"id":0,"meaning":"хранилище данных в памяти","action":"сохранить сессию пользователя в Redis"}]}"#
        let suggestion = try XCTUnwrap(request.suggestion(from: modelResponse, for: 0))
        generator.acceptPersonalization([suggestion], for: request)
        for _ in 0..<3 { _ = generator.next() }
        let result = generator.next()
        XCTAssertTrue(result.contains("сохранить сессию пользователя"))
        XCTAssertEqual(result.components(separatedBy: "Redis").count, 2)
    }

    private func response(for request: MeetingPhraseGenerator.PersonalizationRequest,
                          suggestions: [String: String]) -> [MeetingPhraseGenerator.PersonalizationRequest.Suggestion] {
        request.terms.enumerated().compactMap { index, term in
            suggestions[term].map { .init(id: index, phrase: $0.replacingOccurrences(of: "{{TERM}}", with: term)) }
        }
    }
}
