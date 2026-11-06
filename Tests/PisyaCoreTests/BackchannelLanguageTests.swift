import XCTest
@testable import PisyaCore

final class BackchannelLanguageTests: XCTestCase {
    private func segment(_ start: Double, _ text: String, mic: Bool = true) -> TranscriptSegment {
        var value = TranscriptSegment(start: start, end: start + 1, speaker: mic ? "Я" : "Собеседники", text: text)
        value.audioFile = mic ? "test-mic.caf" : "test-remote.caf"
        return value
    }

    func testBackchannelUsesRussianFromFollowingSpeech() {
        let short = segment(0, "Uh huh.")
        let speech = segment(5, "Давайте проверим показатели перед запуском проекта")
        let result = BackchannelLanguage.resolve([short, speech], alternatives: [short.id: "Угу."], preceding: [])
        XCTAssertEqual(result[0].text, "Угу.")
    }

    func testEnglishAndUnknownContextRemainUnchanged() {
        let short = segment(0, "Uh huh.")
        let english = segment(3, "Please send the report before Friday")
        XCTAssertEqual(BackchannelLanguage.resolve([short, english], alternatives: [short.id: "Угу."], preceding: [])[0].text, "Uh huh.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Угу."], preceding: [])[0].text, "Uh huh.")
        XCTAssertFalse(BackchannelLanguage.shouldRecheck("Uh huh, please send the report", duration: 3))
    }

    func testLiveWindowsUseRecentSpeechFromTheSameTrack() {
        let short = segment(16, "Hmm.")
        let russian = segment(5, "Давайте проверим показатели перед запуском проекта")
        let english = segment(15, "Please send the report before Friday", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([english, short], alternatives: [short.id: "Хм."], preceding: [russian])[1].text, "Хм.")
        let late = segment(100, "Hmm.")
        XCTAssertEqual(BackchannelLanguage.resolve([late], alternatives: [late.id: "Хм."], preceding: [russian])[0].text, "Hmm.")
    }

    func testOnlyAcousticallyRecognizedRussianBackchannelsAreAccepted() {
        XCTAssertTrue(BackchannelLanguage.acceptsAlternative("Угу."))
        XCTAssertFalse(BackchannelLanguage.acceptsAlternative("Давайте проверим проект"))
        XCTAssertFalse(BackchannelLanguage.acceptsAlternative(""))
    }

    func testShortWordsNeedIndependentRussianAcousticAgreement() {
        XCTAssertTrue(BackchannelLanguage.shouldRecheck("And what?", duration: 0.7))
        XCTAssertFalse(BackchannelLanguage.shouldRecheck("Please send the report", duration: 2))
        XCTAssertFalse(BackchannelLanguage.shouldRecheck("And what?", duration: 5))
        XCTAssertEqual(BackchannelLanguage.alternative(original: "And what?", russian: "Я вот.", corroboration: "Вот."), "Я вот.")
        XCTAssertNil(BackchannelLanguage.alternative(original: "And what?", russian: "И что?", corroboration: "An what."))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Friends.", russian: "Правильно.", corroboration: "Пац."))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Thank you.", russian: "Спасибо.", corroboration: "Thanks."))
    }

    func testVocalAcknowledgmentCanUseForcedRussianAudioDecode() {
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh huh.", russian: "угу", corroboration: "Нет."), "угу")
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh huh.", russian: "Да.", corroboration: "Угу."), "Угу.")
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh huh.", russian: "Нет.", corroboration: "Нет."))
        XCTAssertEqual(BackchannelLanguage.alternative(original: "uh-huh, yeah.", russian: "Угу, да.", corroboration: "Угу."), "Угу, да.")
    }

    func testCompoundAcknowledgmentUsesIndependentAudioInRussianContext() {
        var short = segment(71.6798125, "uh-huh, yeah.", mic: false)
        short.end = 72.9878125
        let russian = segment(68, "Теперь обсудим следующий вопрос проекта", mic: false)
        let english = segment(68, "Let us discuss the next question", mic: false)
        XCTAssertTrue(BackchannelLanguage.shouldRecheck(short.text, duration: short.end - short.start))
        // Automatic Qwen, forced Russian Qwen, and GigaAM outputs on the exact audio fragment.
        let alternative = BackchannelLanguage.alternative(original: short.text, russian: "Да.", corroboration: "Угу. Да.")
        XCTAssertEqual(alternative, "Угу. Да.")
        let alternatives = alternative.map { [short.id: $0] } ?? [:]
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [russian])[0].text, "Угу. Да.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [english])[0].text, short.text)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [])[0].text, short.text)
    }

    func testRepeatedAcknowledgmentsAreRetriedWithoutBecomingLanguageAnchors() {
        let repeated = segment(70, "Uh-huh, uh-huh.")
        let short = segment(71, "Hmm.")
        let russian = segment(74, "Теперь обсудим следующий вопрос проекта")
        XCTAssertTrue(BackchannelLanguage.shouldRecheck(repeated.text, duration: 2))
        XCTAssertFalse(BackchannelLanguage.shouldRecheck(repeated.text, duration: 4))
        XCTAssertEqual(BackchannelLanguage.alternative(original: repeated.text, russian: "Угу, угу.", corroboration: nil), "Угу, угу.")
        let result = BackchannelLanguage.resolve([repeated, short, russian], alternatives: [repeated.id: "Угу, угу.", short.id: "Хм."], preceding: [])
        XCTAssertEqual(result.map(\.text), ["Угу, угу.", "Хм.", russian.text])
    }

    func testOpenVowelFillersUseRussianAudioInRussianContext() {
        for (start, end, original, forced, independent) in [
            (11.607, 12.400, "Um.", "а.", "А"),
            (684.219, 685.164, "Ah.", "аа", "А"),
            (684.219, 685.164, "Ah-ah.", "А-а.", "А"),
        ] {
            var short = segment(start, original, mic: false)
            short.end = end
            let russian = segment(start - 3, "Теперь обсудим следующий вопрос проекта", mic: false)
            let english = segment(start - 3, "Let us discuss the next question", mic: false)
            let alternative = BackchannelLanguage.alternative(original: original, russian: forced, corroboration: independent)
            XCTAssertEqual(alternative, forced)
            let alternatives = alternative.map { [short.id: $0] } ?? [:]
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [russian])[0].text, forced)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [english])[0].text, original)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [])[0].text, original)
        }
    }

    func testOpenVowelsDoNotDisplaceConfirmedAcknowledgmentsOrDictionaryTerms() {
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh-huh.", russian: "А.", corroboration: "Угу."), "Угу.")
        XCTAssertNil(BackchannelLanguage.alternative(original: "Ah.", russian: "А.", corroboration: "А", vocabulary: "Ah"))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Hmm.", russian: "Вот.", corroboration: nil))
    }

    func testCompoundAcknowledgmentDoesNotRelaxChecksForEnglishWordsOrDictionaryTerms() {
        XCTAssertNil(BackchannelLanguage.alternative(original: "Yeah.", russian: "Да.", corroboration: nil))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh-huh, John.", russian: "Угу.", corroboration: nil))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh-huh, yeah.", russian: "Угу, да.", corroboration: "Угу.", vocabulary: "Yeah"))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh-huh, yeah.", russian: "Угу, нет.", corroboration: nil))
    }

    func testVerifiedShortWordStillRequiresRussianConversation() {
        let short = segment(30, "And what?", mic: false)
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта", mic: false)
        let english = segment(25, "Let us discuss the next question", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Вот."], preceding: [russian])[0].text, "Вот.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Вот."], preceding: [english])[0].text, "And what?")
    }

    func testShortLanguageRetryCannotUndoDictionarySpelling() {
        XCTAssertNil(BackchannelLanguage.alternative(original: "Confluence.", russian: "Конфлюенс.", corroboration: "Конфлюенс.", vocabulary: "Confluence"))
        XCTAssertNil(BackchannelLanguage.alternative(original: "Hmm.", russian: "Хм.", corroboration: "Хм.", vocabulary: "Hmm"))
        XCTAssertEqual(BackchannelLanguage.alternative(original: "Uh huh.", russian: "Угу.", corroboration: "Нет.", vocabulary: "Confluence"), "Угу.")
    }
}
