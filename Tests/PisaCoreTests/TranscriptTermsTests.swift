import XCTest
@testable import PisaCore

final class TranscriptTermsTests: XCTestCase {
    func testInitialCandidatesArriveBeforeLaterOccurrencesAreCounted() {
        let intro = [segment("Проверили B2B и ЛПР.")] + (0..<7).map { _ in segment("Продолжим разговор.") }
        let segments = intro + [segment("Ещё раз проверили B2B и сравнили с CI/CD.")]
        var updates: [[TermCandidate]] = []
        let complete = TranscriptTerms.candidates(in: segments, vocabulary: "ЛПР") { updates.append($0) }

        XCTAssertEqual(updates.map { $0.map(\.text) }, [["B2B"]])
        XCTAssertEqual(updates.first?.first?.occurrences.count, 1)
        XCTAssertEqual(complete.map(\.text), ["B2B", "CI/CD"])
        XCTAssertEqual(complete.first?.occurrences.count, 2)
    }

    func testCandidateRefreshDropsEditedSpansAndKeepsOtherOccurrencesThroughConsecutiveEdits() throws {
        let original = [segment("🎙 Проверили MapKit, CI/CD и ЛПР."), segment("Продолжили работу с MapKit.")]
        let initial = TranscriptTerms.candidates(in: original, vocabulary: "")
        let firstEdit = TranscriptTerms.matches("MapKit, CI/CD", in: original)
        XCTAssertEqual(firstEdit.count, 1)
        let edited = try XCTUnwrap(TranscriptTerms.replacing(firstEdit, with: "платформу", in: original))
        let candidates = TranscriptTerms.retainingCandidates(initial, afterReplacing: firstEdit, with: "платформу",
            in: Dictionary(uniqueKeysWithValues: edited.map { ($0.id, $0) }))
        XCTAssertEqual(Set(candidates.map(\.text)), ["MapKit", "ЛПР"])
        XCTAssertEqual(candidates.first { $0.text == "MapKit" }?.occurrences.map(\.segmentID), [original[1].id])

        let nextEdit = TranscriptTerms.matches("ЛПР", in: edited)
        let updated = try XCTUnwrap(TranscriptTerms.replacing(nextEdit, with: "команду", in: edited))
        XCTAssertEqual(TranscriptTerms.retainingCandidates(candidates, afterReplacing: nextEdit, with: "команду",
            in: Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })).map(\.text), ["MapKit"])
    }

    func testCancelledReviewDiscardsCandidatesAndMatches() async {
        let segments = [segment("Обсудили B2B, ЛПР и договор.")]
        let scan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return [
                TranscriptTerms.candidates(in: segments, vocabulary: "").count,
                TranscriptTerms.matches("B2B", in: segments).count,
                TranscriptTerms.matches("ЛПР", in: segments).count,
                TranscriptTerms.matches("договор", in: segments).count
            ]
        }
        let results = await scan.value
        XCTAssertEqual(results, [0, 0, 0, 0])
    }

    func testBuiltInMeetingTermsGroupObservedSpellingsAndKeepSearchRanges() throws {
        let segments = [segment("🎙 Для би ту би сравнили B2B и Б2Б'ом. Ещё работали с апишкой, GitHub и CI/CD. `битуби`.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["B2B", "API", "GitHub", "CI/CD"])
        let found = TranscriptTerms.matches("B2B", in: segments)
        XCTAssertEqual(found.map(\.text), ["би ту би", "B2B", "Б2Б'ом"])
        XCTAssertEqual(candidates.first { $0.text == "B2B" }?.occurrences.map(\.id), found.map(\.id))
        XCTAssertEqual(TranscriptTerms.matches("B2B'ом", in: segments).map(\.text), [], "A declined query stays literal")
        let corrected = try XCTUnwrap(TranscriptTerms.replacing(found, with: "B2B", in: segments))
        XCTAssertEqual(corrected[0].text, "🎙 Для B2B сравнили B2B и B2B'ом. Ещё работали с апишкой, GitHub и CI/CD. `битуби`.")
        XCTAssertEqual(TranscriptTerms.matches("API", in: segments).map(\.text), ["апишкой"])
        XCTAssertEqual(TranscriptTerms.replacement(for: try XCTUnwrap(TranscriptTerms.matches("API", in: segments).first), with: "API"), "API'шкой")
    }

    func testBuiltInTermsHonorPersonalVocabularyAndSkipCommonEnglishWords() {
        let segments = [segment("It is a rest day. Обсудили внутренний апи, битуби и ДЖИ ПИ ТИ. В Store внутренний Pull Request, C++ и .NET.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "Битуби, внутренний апи")
        XCTAssertTrue(Set(candidates.map(\.text)).isSuperset(of: ["GPT", "pull request", "C++", ".NET"]))
        XCTAssertTrue(Set(candidates.map(\.text)).isDisjoint(with: ["B2B", "API", "IT", "REST", "Битуби"]))
        XCTAssertTrue(TranscriptTerms.matches("B2B", in: segments, vocabulary: "Битуби").isEmpty)
        XCTAssertTrue(TranscriptTerms.matches("B2B", in: [segment("Сравнили би ту би и би-ту-би'ом.")], vocabulary: "Битуби").isEmpty)
    }

    func testPersonalCanonicalTermKeepsBuiltInAliasesOutOfCandidates() {
        let segments = [segment("Сравнили B2C, Б2С и би ту си.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(candidates.map(\.text), ["B2C"])
        XCTAssertEqual(candidates.first?.occurrences.map(\.text), ["B2C", "Б2С", "би ту си"])
        XCTAssertTrue(TranscriptTerms.candidates(in: segments, vocabulary: "B2C").isEmpty)
        XCTAssertEqual(TranscriptTerms.matches("B2C", in: segments, vocabulary: "B2C").map(\.text), ["B2C", "Б2С", "би ту си"])
        XCTAssertEqual(TranscriptTerms.matches("B2C", in: segments, vocabulary: "B2C, Б2С").map(\.text), ["B2C", "би ту си"])
    }

    func testInflectableBuiltInNameKeepsObservedEndingsInReview() throws {
        let segments = [segment("Сравнили HeadHunter и нашли резюме на хедхантере.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        let candidate = try XCTUnwrap(candidates.first { $0.text == "HeadHunter" })
        XCTAssertEqual(candidate.occurrences.map(\.text), ["HeadHunter", "хедхантере"])
        let changed = try XCTUnwrap(TranscriptTerms.replacing(candidate.occurrences, with: "HeadHunter", in: segments))
        XCTAssertEqual(changed[0].text, "Сравнили HeadHunter и нашли резюме на HeadHunter'е.")
        let declined = try XCTUnwrap(candidate.occurrences.last)
        XCTAssertEqual(TranscriptTerms.replacement(for: declined, with: "HH"), "HH'е")
        XCTAssertEqual(TranscriptTerms.replacement(for: declined, with: "HeadHunter’ом"), "HeadHunter'е")
        XCTAssertEqual(TranscriptTerms.replacementSearchTerm(for: candidate.occurrences, with: "HeadHunter’ом"), "HeadHunter")
        XCTAssertEqual(TranscriptTerms.dictionaryTerm("HeadHunter’ом"), "HeadHunter")
        XCTAssertNil(TranscriptTerms.replacement(for: declined, with: "Площадка"))
    }

    func testPersonalInflectableNameSearchIncludesCanonicalSuffixedForms() throws {
        let segments = [segment("HeadHunter. Проверили профиль на HeadHunter'е и резюме на HeadHunter’е.")]
        let found = TranscriptTerms.matches("HeadHunter", in: segments, vocabulary: "HeadHunter")
        XCTAssertEqual(found.map(\.text), ["HeadHunter", "HeadHunter'е", "HeadHunter’е"])
        let changed = try XCTUnwrap(TranscriptTerms.replacing(found, with: "HH", in: segments))
        XCTAssertEqual(changed[0].text, "HH. Проверили профиль на HH'е и резюме на HH'е.")
        XCTAssertEqual(TranscriptTerms.matches("HeadHunter", in: segments, vocabulary: "HeadHunter, HeadHunter'е").map(\.text),
                       ["HeadHunter"])
    }

    func testBranchTargetBufferAndBusinessToBusinessAreSeparateMeetingTerms() {
        let segments = [segment("Проверили би ти би и BTB, потом обсудили би ту би и B2B.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(candidates.first { $0.text == "BTB" }?.occurrences.map(\.text), ["би ти би", "BTB"])
        XCTAssertEqual(candidates.first { $0.text == "B2B" }?.occurrences.map(\.text), ["би ту би", "B2B"])
    }

    func testBuiltInReviewExcludesOrdinaryWordsSharingTheSameSpelling() {
        let segments = [segment("Используем REST и CI/CD. Обсудили компанию Apple."),
                        segment("It is a rest day. Grab the apple. CI/CD_internal. CI/CD/path. Pull\nRequest.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        for term in ["REST", "CI/CD", "Apple"] {
            XCTAssertEqual(candidates.first { $0.text == term }?.occurrences.map(\.text), [term])
            XCTAssertEqual(TranscriptTerms.matches(term, in: segments).map(\.text), [term])
        }
        XCTAssertEqual(TranscriptTerms.matches("rest", in: segments).map(\.text), ["REST", "rest"])
        XCTAssertTrue(TranscriptTerms.matches("rest", in: [segment("Проверили REST'ом.")]).isEmpty)
    }

    func testBuiltInCompanyPronunciationsGroupWrittenAndSpokenOccurrences() {
        let segments = [segment("Для майкрософт, Microsoft и гугл обсудили интеграции. Сравнили компания озон и Naumen."),
                        segment("Рядом выбросили озон из уравнения. Прочитали «гугл». В проекте работает наумен.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(candidates.first { $0.text == "Microsoft" }?.occurrences.map(\.text), ["майкрософт", "Microsoft"])
        XCTAssertEqual(candidates.first { $0.text == "Naumen" }?.occurrences.map(\.text), ["Naumen", "наумен"])
        XCTAssertEqual(TranscriptTerms.matches("Ozon", in: segments).map(\.text), ["озон"])
        XCTAssertEqual(TranscriptTerms.matches("Google", in: segments).map(\.text), ["гугл"])
    }

    func testAbbreviationFamiliesGroupFormsAndRecognizeKnownBase() {
        let segments = [segment("2ГИС'а, 2ГИС’е, 2ГИСом и 2ГИС. Также LLM'ки и LLM'ками.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["2ГИС", "LLM"])
        XCTAssertEqual(candidates.first { $0.text == "2ГИС" }?.occurrences.count, 4)
        XCTAssertTrue(TranscriptTerms.candidates(in: segments, vocabulary: "2ГИС, LLM").isEmpty)
    }

    func testBaseSearchAndReplacementPreserveEachObservedEnding() throws {
        let segments = [segment("2GIS'a, 2GIS'е, 2GISом, 2GIS и Супер2GIS. `2GIS'у`.")]
        let found = TranscriptTerms.matches("2GIS", in: segments)
        XCTAssertEqual(found.map(\.text), ["2GIS'a", "2GIS'е", "2GISом", "2GIS"])
        let changed = try XCTUnwrap(TranscriptTerms.replacing(found, with: "2ГИС", in: segments))
        XCTAssertEqual(changed[0].text, "2ГИС'а, 2ГИС'е, 2ГИС'ом, 2ГИС и Супер2GIS. `2GIS'у`.")
        XCTAssertEqual(TranscriptTerms.matches("2GIS'е", in: segments).map(\.text), ["2GIS'е"])
    }

    func testApostrophizedReplacementPreservesEachObservedEnding() throws {
        let segments = [segment("Позвали ЛПДов и обсудили с ЛПДом. Слово взял ЛПД.")]
        let found = TranscriptTerms.matches("ЛПД", in: segments)
        XCTAssertEqual(found.map(\.text), ["ЛПДов", "ЛПДом", "ЛПД"])

        let straight = "ЛПР'ов"
        XCTAssertEqual(found.map { TranscriptTerms.replacement(for: $0, with: straight) },
                       ["ЛПР'ов", "ЛПР'ом", "ЛПР"])
        let changed = try XCTUnwrap(TranscriptTerms.replacing(found, with: straight, in: segments))
        XCTAssertEqual(changed[0].text, "Позвали ЛПР'ов и обсудили с ЛПР'ом. Слово взял ЛПР.")
        let nextSearch = TranscriptTerms.replacementSearchTerm(for: found, with: straight)
        XCTAssertEqual(TranscriptTerms.matches(nextSearch, in: changed).map(\.text), ["ЛПР'ов", "ЛПР'ом", "ЛПР"])
        XCTAssertEqual(found.map { TranscriptTerms.replacement(for: $0, with: "ЛПР’ов") },
                       ["ЛПР'ов", "ЛПР'ом", "ЛПР"])
        XCTAssertNil(TranscriptTerms.replacing(found, with: "ЛПР'слово", in: segments))

        let exact = TranscriptTerms.matches("ЛПДом", in: segments)
        XCTAssertEqual(exact.map { TranscriptTerms.replacement(for: $0, with: straight) }, ["ЛПР'ов"])
        XCTAssertEqual(TranscriptTerms.replacementSearchTerm(for: exact, with: straight), straight)
    }

    func testAddingInflectedAbbreviationStoresOnlyBase() {
        XCTAssertEqual(TranscriptTerms.adding("2ГИС'ом", to: "API"), "API\n2ГИС")
        XCTAssertEqual(TranscriptTerms.adding("2ГИС'е", to: "2ГИС"), "2ГИС")
        XCTAssertEqual(TranscriptTerms.adding("LLM'ками", to: ""), "LLM")
        XCTAssertEqual(TranscriptTerms.adding("Марины", to: ""), "Марины")
    }

    func testCandidatesPreferMarkedTermsAndIgnoreKnownWordsAndLiterals() {
        let segments = [
            segment("Сегодня обсудили API, Геопэй и 7АБВ. Потом повторили Геопэй."),
            segment("Обычное слово, обычное слово. API и 7АБВ. `FAKE` и https://example.com/NOPE")
        ]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "api")
        XCTAssertEqual(Set(candidates.map(\.text)), ["Геопэй", "7АБВ"])
        XCTAssertEqual(candidates.first { $0.text == "7АБВ" }?.occurrences.count, 2)
    }

    func testCandidatesSkipOrdinaryRussianWordFormsDespiteCapitalizationAndHyphens() {
        let segments = [
            segment("Так, Давайте обсудим Семь Новогодних задач, потом Новогодний график и Послезавтрашнюю встречу."),
            segment("Ну, Во-первых, что-то и как-то, во-первых, почему-то и какие-то. Во‑вторых, с кем-нибудь."),
            segment("Спросили, почему-то снова что-то, как-то и какие-то. Во-вторых, с кем-нибудь и по-русски."),
            segment("Договорились работать по‑русски. Ну, Давай-ка и скажи-ка, давай-ка. Упомянули ДАО, ИДП, ЛПР, СДП, Иви, Геопэй и Qwen3-ASR.")
        ]

        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["ДАО", "ИДП", "ЛПР", "СДП", "Иви", "Геопэй", "Qwen3-ASR"])
        XCTAssertEqual(TranscriptTerms.matches("Давайте", in: segments).count, 1)
        XCTAssertEqual(TranscriptTerms.matches("что-то", in: segments).count, 2)
    }

    func testCandidatesSkipOrdinaryEnglishRepliesDespiteRepetitionAndCapitalization() {
        let segments = [
            segment("Well, Right, Good. I think PostgreSQL works well."),
            segment("I think you are right. We have a good API. I think so too.")
        ]

        XCTAssertEqual(Set(TranscriptTerms.candidates(in: segments, vocabulary: "").map(\.text)), ["PostgreSQL", "API"])
        XCTAssertEqual(TranscriptTerms.matches("think", in: segments).count, 3)
    }

    func testCandidatesSkipSystemPlanningTermsAndKeepManualSearch() {
        let segments = [segment("Обсудили Q1, Q2, Q3 и q4, затем Roadmap и Challenge. Сравнили роудмап, челлендж и кью три. Открыли API и Qwen3-ASR.")]
        XCTAssertEqual(Set(TranscriptTerms.candidates(in: segments, vocabulary: "").map(\.text)), ["API", "Qwen3-ASR"])
        XCTAssertEqual(TranscriptTerms.matches("Q3", in: segments).map(\.text), ["Q3", "кью три"])
        XCTAssertEqual(TranscriptTerms.matches("roadmap", in: segments).map(\.text), ["Roadmap", "роудмап"])
        XCTAssertEqual(TranscriptTerms.matches("challenge", in: segments).map(\.text), ["Challenge", "челлендж"])
    }

    func testCandidatesSkipRussianOrdinalNumeralsWithoutDroppingModelNames() {
        let segments = [segment("Встречи с 21-го по 25-го, к 3‐му и на 4‑й день. Обсудили 1-е и 5-х, 6-м и 7-ми, а также 8-я, 9-ю и 10-МУ. Проверили Qwen3-ASR, 2ГИС, Wi-Fi 6 и 1-Wire.")]
        XCTAssertEqual(Set(TranscriptTerms.candidates(in: segments, vocabulary: "").map(\.text)), ["Qwen3-ASR", "2ГИС", "Wi-Fi", "1-Wire"])
        XCTAssertEqual(TranscriptTerms.matches("21-го", in: segments).map(\.text), ["21-го"])
    }

    func testCandidatesKeepRussianFunctionWordsOutOfAcronymGroups() {
        let segments = [
            segment("По дороге поговорили по сути и по старинке. Решили делать по-новому, а не по-старому."),
            segment("Работали по‑новому и по‑старому. Позвонили до встречи и при необходимости."),
            segment("Обновили ПО. Его проверил PO. Отчёты отправили в ДО и ПРИ.")
        ]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["ПО", "PO", "ДО", "ПРИ"])
        for acronym in ["ПО", "PO", "ДО", "ПРИ"] {
            XCTAssertEqual(candidates.first { $0.text == acronym }?.occurrences.map(\.text), [acronym])
        }
    }

    func testRussianAcronymSearchSkipsFunctionWordsWithOrWithoutDictionaryEntry() {
        let segments = [segment("По дороге и по сути. Проверили ПО, ПО'ки и PO. Повторили по-старому.")]
        for vocabulary in ["", "ПО, PO"] {
            XCTAssertEqual(TranscriptTerms.matches("ПО", in: segments, vocabulary: vocabulary).map(\.text), ["ПО", "ПО'ки"])
            XCTAssertEqual(TranscriptTerms.matches("PO", in: segments, vocabulary: vocabulary).map(\.text), ["PO"])
        }
    }

    func testCandidatesSkipRegularInflectionsOfDictionaryTerms() {
        let text = "Для Сбера и со Сбером обсуждали API. Рассказали о Сбере."
        let segments = [segment(text)]
        let vocabulary = "Сбер"
        XCTAssertEqual(TranscriptTerms.candidates(in: segments, vocabulary: vocabulary).map(\.text), ["API"])
        XCTAssertEqual(TranscriptTerms.matches("Сбером", in: segments, vocabulary: vocabulary).map(\.text), ["Сбером"])
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Для сбера и со сбером обсуждали API. Рассказали о сбере.",
                                                   vocabulary: vocabulary), text)
    }

    func testCandidatesSkipNamesOfPeopleAndPlacesInRussian() {
        let segments = [
            segment("Про это говорили Дима, Макс, Анфиса, Кирилл и Алексей. По России, из Армении и Москвы."),
            segment("Мы звонили Диме, Максу, Анфисе, Кириллу и Алексею из Новосибирска и Армении."),
            segment("Команда показала ДФА, MapKit, Геопэй и Яндекс. Встретились в США и Санкт-Петербурге.")
        ]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["ДФА", "MapKit", "Геопэй", "Яндекс"])
        XCTAssertEqual(TranscriptTerms.matches("Дима", in: segments).map(\.text), ["Дима"])
        XCTAssertEqual(TranscriptTerms.matches("Москвы", in: segments).map(\.text), ["Москвы"])
    }

    func testCandidatesSkipTheNamedSpeakersEvenWithoutNameContext() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, speaker: "Спикер 1", text: "Отдельно обсудили Куделька, куделька и ДФА."),
            TranscriptSegment(start: 2, end: 4, speaker: "Анфиса Куделька", text: "Продолжим завтра.")
        ]
        XCTAssertEqual(TranscriptTerms.candidates(in: segments, vocabulary: "").map(\.text), ["ДФА"])
        XCTAssertEqual(TranscriptTerms.matches("Куделька", in: segments).count, 2)
        XCTAssertEqual(TranscriptTerms.adding("Куделька", to: ""), "Куделька")
    }

    func testCandidatesSkipMultiwordNamesInEnglish() {
        let segments = [segment("The team met Alice Smith in London and flew to New York with Bob. Later we tested PostgreSQL and the API.")]
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "")
        XCTAssertEqual(Set(candidates.map(\.text)), ["PostgreSQL", "API"])
    }

    func testFullFormSearchRemainsLiteralWhileBaseSearchFindsFamily() throws {
        let segments = [segment("LLM, LLM'ки и LLM’ки, а также API.")]
        let base = TranscriptTerms.matches("LLM", in: segments)
        XCTAssertEqual(base.map(\.text), ["LLM", "LLM'ки", "LLM’ки"])
        XCTAssertTrue(TranscriptTerms.matches("ки", in: segments).isEmpty)
        let full = TranscriptTerms.matches("LLM'ки", in: segments)
        XCTAssertEqual(full.map(\.text), ["LLM'ки", "LLM’ки"])
        let edited = try XCTUnwrap(TranscriptTerms.replacing(full, with: "ИИ", in: segments))
        XCTAssertEqual(edited[0].text, "LLM, ИИ и ИИ, а также API.")
        let candidates = TranscriptTerms.candidates(in: segments, vocabulary: "Внутренний API")
        XCTAssertTrue(candidates.contains { $0.text == "API" })
        XCTAssertEqual(candidates.first { $0.text == "LLM" }?.occurrences.count, 3)
        XCTAssertFalse(candidates.contains { $0.text == "LLM'ки" })
    }

    func testSelectedWholeTermReplacementPreservesOtherTextAndMetadata() throws {
        let segments = [
            segment("🎙 гео пэй и гео\u{00a0}пэй. Супергео пэй. `гео пэй`."),
            segment("Открыли Гео Пэй.")
        ]
        let occurrences = TranscriptTerms.matches("гео пэй", in: segments)
        XCTAssertEqual(occurrences.count, 3)
        let changed = try XCTUnwrap(TranscriptTerms.replacing(Array(occurrences.prefix(2)), with: "Геопэй", in: segments))
        XCTAssertEqual(changed.map(\.text), ["🎙 Геопэй и Геопэй. Супергео пэй. `гео пэй`.", "Открыли Гео Пэй."])
        var restored = changed
        restored[0].text = segments[0].text
        XCTAssertEqual(restored, segments)

        var stale = segments
        stale[0].text = "Сдвиг: " + stale[0].text
        XCTAssertNil(TranscriptTerms.replacing(occurrences, with: "Геопэй", in: stale))
    }

    func testDictionaryPreservesExistingEntriesAndAvoidsDuplicatesAndSeparators() {
        let vocabulary = "API, Северный Атлас\nЯндекс"
        XCTAssertEqual(TranscriptTerms.adding("северный\u{00a0}атлас", to: vocabulary), vocabulary)
        XCTAssertEqual(TranscriptTerms.adding("  Геопэй  ", to: vocabulary), vocabulary + "\nГеопэй")
        XCTAssertEqual(TranscriptTerms.adding("Одно, другое", to: vocabulary), vocabulary)
    }

    private func segment(_ text: String) -> TranscriptSegment {
        var segment = TranscriptSegment(start: 2, end: 4, speaker: "Участник", text: text)
        segment.audioFile = "recording.wav"
        segment.embedding = [0.5]
        return segment
    }
}
