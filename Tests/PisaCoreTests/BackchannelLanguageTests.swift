import XCTest
@testable import PisaCore

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
            (2112, 2113, "Uh.", "Аааа.", "А"),
            (2112, 2113, "Uh.", "А-а-а-а.", "А"),
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
        XCTAssertNil(BackchannelLanguage.alternative(original: "Uh.", russian: "Аааа, да.", corroboration: nil))
    }

    func testRussianConversationLocalizesKnownFillersWithoutAnAudioAlternative() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта", mic: false)
        for (original, expected) in [
            ("Uh.", "Аааа."), ("Um.", "Ааа."), ("Ah!", "А!"), ("Hmm?", "Хм?"),
            ("Uh-huh.", "Угу."), ("Mhm.", "Угу."), ("Yeah.", "Да."), ("Yep.", "Да."),
            ("Yes.", "Да."), ("Da da da.", "Да, да, да."), ("Okay.", "Окей."), ("Sorry.", "Сорри."),
            ("Uh-huh, yeah.", "Угу, да."), ("Yeah,", "Да,"),
            ("Uh-huh, uh-huh.", "Угу, угу."),
        ] {
            let short = segment(30, original, mic: false)
            let result = BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian])
            XCTAssertEqual(result[0].text, expected, original)
        }
    }

    func testFillerFallbackPreservesEnglishSpeechAndUnknownContext() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let english = segment(27, "Let us discuss the next question", mic: false)
        let short = segment(30, "Yeah.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian, english])[0].text, short.text)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [])[0].text, short.text)
        let apology = segment(30, "Sorry.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([apology], alternatives: [:], preceding: [russian, english])[0].text, "Sorry.")
        let latinRepetition = segment(30, "Da da da.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([latinRepetition], alternatives: [:], preceding: [english]), [latinRepetition])
        let quotedRepetition = segment(30, "«Da da da».")
        XCTAssertEqual(BackchannelLanguage.resolve([quotedRepetition], alternatives: [:], preceding: [russian]), [quotedRepetition])
        for text in ["Yeah, send the report.", "Uh-huh, John.", "Sorry, I cannot attend.", "Focus.", "Y-1."] {
            let speech = segment(30, text)
            XCTAssertEqual(BackchannelLanguage.resolve([speech], alternatives: [:], preceding: [russian])[0].text, text)
        }
    }

    func testClippedQuestionAndNamesDoNotHideAcknowledgmentsInRussianConversation() {
        var discussion = segment(10, "Давайте проверим сроки и обсудим наши дальнейшие действия.")
        discussion.end = 30
        let single = segment(13, "Mm-hmm.", mic: false)
        let fragment = segment(15, "Is this", mic: false)
        let named = segment(18, "Иван Петров — это кто?", mic: false)
        let repeated = segment(20, "Mm-hmm, mm-hmm.", mic: false)
        let acknowledgment = segment(24, "Ajá.", mic: false)
        let result = BackchannelLanguage.resolve([single, fragment, named, repeated, acknowledgment],
            alternatives: [:], preceding: [discussion])
        XCTAssertEqual(result.map(\.text), ["Угу.", "Is this", named.text, "Угу, угу.", "Ага."])
        let jargon = segment(12, "Ой, я уже как бы протранслировал это в текущем состоянии доапрува.", mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([single], alternatives: [:], preceding: [jargon])[0].text, "Угу.")

        for foreign in ["Is this?", "Are you ready?", "¿Puedes revisar el informe mañana?"] {
            let anchor = segment(12, foreign, mic: false)
            XCTAssertEqual(BackchannelLanguage.resolve([single, acknowledgment], alternatives: [:],
                preceding: [discussion, anchor]), [single, acknowledgment], foreign)
        }
        XCTAssertEqual(BackchannelLanguage.resolve([acknowledgment], alternatives: [:], preceding: []), [acknowledgment])
        for literal in ["«Ajá.»", "Ajá, seguimos mañana."] {
            let quoted = segment(16, literal, mic: false)
            XCTAssertEqual(BackchannelLanguage.resolve([quoted], alternatives: [:], preceding: [discussion]), [quoted])
        }
    }

    func testVocalAcknowledgmentsUseOverlappingRussianSpeechOnTheOtherTrack() {
        for (mic, text, expected, competingTurn) in [
            (true, "Mm-hmm.", "Угу.", "Что тр."),
            (false, "Mm-hmm, mm-hmm.", "Угу, угу.", "Ми сьогодні переглянемо зміни."),
            (true, "Hmm.", "Хм.", "We can discuss the next question."),
        ] {
            let reply = segment(20, text, mic: mic)
            var speech = segment(13, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: !mic)
            speech.end = 24
            let distant = segment(28, competingTurn, mic: mic)
            let resolved = BackchannelLanguage.resolve([speech, reply, distant], alternatives: [:], preceding: [])
            var localized = reply
            localized.text = expected
            XCTAssertEqual(resolved, [speech, localized, distant])

            for foreign in ["Are you ready?", "Ми сьогодні переглянемо зміни."] {
                let switchOfLanguage = segment(21.5, foreign, mic: mic)
                let mixed = BackchannelLanguage.resolve([speech, reply, switchOfLanguage], alternatives: [:], preceding: [])
                XCTAssertEqual(mixed, [speech, reply, switchOfLanguage], foreign)
            }
            XCTAssertEqual(BackchannelLanguage.resolve([speech, reply, distant], alternatives: [:], preceding: [],
                vocabulary: text)[1], reply)

            speech.end = reply.start
            XCTAssertEqual(BackchannelLanguage.resolve([speech, reply, distant], alternatives: [:], preceding: [])[1], reply)
        }

        var speech = segment(13, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: false)
        speech.end = 24
        let foreign = segment(28, "We can discuss the next question.")
        for text in ["«Mm-hmm».", "Mm-hmm, I agree.", "Ajá.", "Yeah."] {
            let reply = segment(20, text)
            XCTAssertEqual(BackchannelLanguage.resolve([speech, reply, foreign], alternatives: [:], preceding: [])[1], reply)
        }
    }

    func testCorroboratedAffirmationUsesOverlappingRussianContext() {
        var russianSpeech = segment(10, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: false)
        russianSpeech.end = 25
        let english = segment(16, "Are you ready?")
        let reply = segment(20, "Yeah.")
        let source = [russianSpeech, english, reply]
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], preceding: []).last?.text, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [reply.id: "Да."], preceding: []).last?.text, "Да.")
        let nearbyEnglish = segment(19, english.text)
        XCTAssertEqual(BackchannelLanguage.resolve([russianSpeech, nearbyEnglish, reply],
            alternatives: [reply.id: "Да."], preceding: []).last?.text, "Yeah.")
    }

    func testCorroboratedLexicalTurnUsesOverlappingRussianContext() {
        var russianSpeech = segment(10, "Сейчас мы обсудим оставшиеся вопросы проекта.", mic: false)
        russianSpeech.end = 25
        let distantTurn = segment(2, "Что тр.")
        let reply = segment(20, "Then you probably back.")
        let reading = "Это не правда так."
        let source = [distantTurn, russianSpeech, reply]
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], uncertain: [reply.id],
            preceding: []).last?.text, reply.text)
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], lexicalAlternatives: [reply.id: reading],
            preceding: []).last?.text, reading)
        let nearbyEnglish = segment(19, "Are you ready?")
        XCTAssertEqual(BackchannelLanguage.resolve([russianSpeech, nearbyEnglish, reply], alternatives: [:],
            lexicalAlternatives: [reply.id: reading], preceding: []).last?.text, reply.text)
    }

    func testIndependentEquivalentAcknowledgmentsPreserveEverySoundAndSentenceBoundary() {
        let primary = "Mm-hmm, mm hmm. Okay."
        XCTAssertTrue(BackchannelLanguage.confirmsFillerSequence(original: primary, reread: "Uh huh. Uh huh. Okay.", corroboration: "Угу, угу. О'кей."))
        XCTAssertTrue(BackchannelLanguage.confirmsFillerSequence(original: "Okay.", reread: "okei.", corroboration: "О’кей."))
        for (reread, acoustic) in [("Uh huh. Okay.", "Угу, угу. Окей."), ("Uh huh. Uh huh. Okay.", "Окей."), ("Is this?", "Угу, угу. Окей.")] {
            XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: primary, reread: reread, corroboration: acoustic))
        }
        XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: "Okko.", reread: "Okay.", corroboration: "Окей."))
        XCTAssertFalse(BackchannelLanguage.confirmsFillerSequence(original: "Okay.", reread: "okei.", corroboration: nil))
        let speech = segment(1, "Давайте обсудим оставшиеся вопросы.")
        let turn = segment(3, primary, mic: false)
        XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], preceding: [speech])[0].text, "Угу, угу. Окей.")
        XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], preceding: [segment(1, "We can discuss the remaining questions.")])[0], turn)
    }

    func testFillerRereadPreservesTheNumberOfAcknowledgments() throws {
        let spelling = try XCTUnwrap(BackchannelLanguage.russianSpelling(ofFiller: "Mm-hmm, mm-hmm, okay."))
        XCTAssertTrue(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: spelling, candidate: "Ага, угу. О'кей."))
        XCTAssertFalse(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: spelling, candidate: "Угу, окей."))
        XCTAssertFalse(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: spelling, candidate: "Да, я согласен."))
        XCTAssertFalse(BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: "угу", candidate: "Угу, угу."))
    }

    func testFillerChainWithOneUnknownSyllableDoesNotEstablishTheLanguageOfNeighboringReplies() {
        let russian = segment(1, "Давайте обсудим оставшиеся вопросы.")
        let repeated = segment(3, "Mm-hmm.", mic: false)
        let chain = segment(5, "Uhum, tá, ok, ok.", mic: false)
        let result = BackchannelLanguage.resolve([repeated, chain], alternatives: [:], preceding: [russian])
        XCTAssertEqual(result.map(\.text), ["Угу.", chain.text])
    }

    func testLeadingVocalizationBeforeUnpunctuatedRussianSpeech() {
        XCTAssertEqual(TranscriptOrthography.normalize("Uh по каким"), "Аааа по каким")
        XCTAssertEqual(TranscriptOrthography.normalize("Uh значит работа."), "Аааа значит работа.")
        for text in ["Uh I know.", "Uh ne знаю trend of", "Uh і", "Okay сегодня идёт дождь",
                     "«Uh значит работа».", "Uh то ми по"] {
            XCTAssertEqual(TranscriptOrthography.normalize(text), text)
        }
        XCTAssertEqual(TranscriptOrthography.normalize("Uh значит работа.", vocabulary: "Uh"), "Uh значит работа.")
    }

    func testMixedFillerChainsKeepRussianWordsAndSentencePunctuation() {
        let russian = segment(79, "Теперь обсудим следующий вопрос проекта")
        let english = segment(79, "Let us discuss the next question")
        for (original, expected) in [
            ("Uh huh. Да.", "Угу. Да."),
            ("Да, uh-huh! Хм? Okay…", "Да, угу! Хм? Окей…"),
            ("Hmm. Угу, yeah?", "Хм. Угу, да?"),
            ("Да. Uh. Huh?", "Да. Аааа. А?"),
        ] {
            let short = segment(75, original)
            XCTAssertFalse(BackchannelLanguage.shouldRecheck(original, duration: 1))
            XCTAssertEqual(BackchannelLanguage.resolve([short, russian], alternatives: [:], preceding: [])[0].text, expected)
            XCTAssertEqual(BackchannelLanguage.resolve([short, english], alternatives: [:], preceding: [])[0].text, original)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [])[0].text, original)
        }
        for original in ["Да, Uh huh, John.", "Угу. Please continue.", "«Uh huh». Да.", "Да. Хм!"] {
            let short = segment(75, original)
            XCTAssertEqual(BackchannelLanguage.resolve([short, russian], alternatives: [:], preceding: [])[0].text, original)
        }
        let protected = segment(75, "Uh huh. Да.")
        XCTAssertEqual(BackchannelLanguage.resolve([protected, russian], alternatives: [:], preceding: [], vocabulary: "Uh huh")[0].text, protected.text)
    }

    func testNearbyShortEnglishSentenceOutweighsOlderRussianSpeech() {
        let russian = segment(0, "Теперь обсудим следующий вопрос проекта")
        let english = segment(10, "Are you ready?")
        let name = segment(10, "John Patrick Doe.")
        let short = segment(12, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian, english])[0].text, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian, name])[0].text, "Да.")
        XCTAssertEqual(BackchannelLanguage.resolve([english], alternatives: [english.id: "Вы готовы?"], preceding: [russian])[0].text, "Вы готовы?")
    }

    func testUnconfirmedEnglishTurnsDoNotSetLanguageForAdjacentAcknowledgments() {
        for (mic, text, filler, expected) in [
            (true, "Then you probably back.", "Yeah.", "Да."),
            (false, "I don't know if it's", "Mm-hmm, mm-hmm.", "Угу, угу."),
        ] {
            let russian = segment(10, "Сегодня мы обсудим последние изменения проекта.", mic: !mic)
            var foreign = segment(14, text, mic: mic)
            foreign.independentRecognitionLanguage = false
            let reply = segment(16, filler, mic: mic)
            var localized = reply
            localized.text = expected

            XCTAssertEqual(BackchannelLanguage.resolve([foreign, reply], alternatives: [:], preceding: [russian]),
                [foreign, localized], text)
            XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:], preceding: [russian, foreign]),
                [localized], text)

            foreign.independentRecognitionLanguage = true
            XCTAssertEqual(BackchannelLanguage.resolve([foreign, reply], alternatives: [:], preceding: [russian]),
                [foreign, reply], text)
        }
    }

    func testVerifiedRussianTurnDoesNotBlockAnAdjacentFiller() {
        let russian = segment(10, "Обсудим план работы команды на неделю.")
        let mistranscribed = segment(12, "Well, I think.")
        let filler = segment(13, "Yeah.")

        let result = BackchannelLanguage.resolve([russian, mistranscribed, filler],
            alternatives: [:], lexicalAlternatives: [mistranscribed.id: "Ну, я думаю."], preceding: [])

        XCTAssertEqual(result.map(\.text), [russian.text, "Ну, я думаю.", "Да."])
    }

    func testLexicalRecheckIncludesLongerShortTurnsAndContractions() {
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Yeah, I could send the notes after lunch because it's nearly ready", duration: 3.9))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Let me check later.", duration: 1.9))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("It’s all right.", duration: 2.8))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Yeah, I think that's a good", duration: 3.23))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Oh, you can, what’s the capital?", duration: 1.37))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("It’s all right.", duration: 6.01))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("I really think you had the right answer when we first spoke yesterday.", duration: 5))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Please pass me the drawing after this meeting.", duration: 12))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Red Green Blue Yellow", duration: 9))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Please pass me the drawing after this meeting.", duration: 30.01))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Русский текст с English words.", duration: 3))
    }

    func testShortEnglishReadingsCanBeRecheckedWithoutReplacingTheirWordsFromContext() {
        let russian = segment(10, "Сегодня мы обсудим последние изменения проекта.")
        for text in ["Why not?", "And that's", "Didn't make IT.", "Then you probably back.",
                     "No, it's a chance.", "I don't know if it's"] {
            let turn = segment(12, text)
            XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(text, duration: turn.end - turn.start), text)
            XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], preceding: [russian]), [turn], text)
            XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: text, russian: "Давайте обсудим.",
                corroboration: "Давайте проверим."), text)
        }
    }

    func testEnglishContractionsDoNotMatchDictionaryAcronyms() {
        let anchor = segment(5, "Сейчас мы обсудим оставшиеся вопросы проекта.")
        for text in ["No, it's a chance.", "It’s a chance.", "I don't know if it's"] {
            let turn = segment(7, text)
            XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(text, duration: 0.7, vocabulary: "IT"), text)
            let candidate = BackchannelLanguage.lexicalAlternative(original: text, russian: "Ну, не знаю.",
                corroboration: "ну не знаю", vocabulary: "IT")
            XCTAssertEqual(candidate, "Ну, не знаю.", text)
            XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:], uncertain: [turn.id],
                preceding: [anchor], vocabulary: "IT").first?.text, "Неразборчиво", text)
        }
        for (text, vocabulary) in [("Didn't make IT.", "IT"), ("Ask about IT's roadmap.", "IT"),
                                   ("No, it's a chance.", "it's"), ("Confluence’s roadmap.", "Confluence")] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(text, duration: 0.7, vocabulary: vocabulary), text)
        }
    }

    func testFormattingAnEnglishPronounDoesNotProtectAnUnverifiedEnglishSentence() {
        let russian = segment(1, "Сегодня мы обсуждаем новую задачу.")
        for (primary, formatted) in [
            ("That's it for now.", "That's IT for now."), ("They saved it.", "They saved IT."),
            ("Part of it grew.", "Part of IT grew."), ("It fits in the box.", "IT fits in the box."),
        ] {
            let source = BackchannelLanguage.sourceForLanguageCheck(primary: primary, formatted: formatted, duration: 2, vocabulary: "IT")
            XCTAssertEqual(source, primary)
            XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(source, duration: 2, vocabulary: "IT"))
            let turn = segment(4, source)
            let alternative = BackchannelLanguage.lexicalAlternative(original: source, russian: "Мы вернёмся.",
                corroboration: "мы вернемся", vocabulary: "IT")
            XCTAssertEqual(alternative, "Мы вернёмся.")
            XCTAssertEqual(BackchannelLanguage.resolve([turn], alternatives: [:],
                lexicalAlternatives: alternative.map { [turn.id: $0] } ?? [:], preceding: [russian], vocabulary: "IT")[0].text, alternative)
        }
        for protected in ["IT needs a new server.", "it", "Please ask Jira about it."] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(protected, duration: 2, vocabulary: "IT, Jira"))
        }
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("We discussed it today.", duration: 2, vocabulary: "it"))
    }

    func testShortForeignScriptNeedsTwoAudioReadingsAndIndependentConversationContext() {
        let russian = segment(1, "Сегодня мы обсуждаем новую задачу.")
        let foreign = segment(1, "Ми сьогодні обговорюємо нову задачу.")
        for text in ["Tämä käy.", "Nie, to się udało.", "Строить ну такі башти.", "Зелененьку ялинку різали."] {
            XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(text, duration: 2, vocabulary: ""), text)
            let source = segment(4, text)
            let heard = BackchannelLanguage.corroboratedScriptReread("Вернёмся чуть позже.", corroboration: "вернемся чуть позже")
            XCTAssertEqual(heard, "Вернёмся чуть позже.")
            let alternatives = heard.map { [source.id: $0] } ?? [:]
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: alternatives,
                preceding: [russian])[0].text, heard)
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: alternatives,
                preceding: [foreign]), [source])
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], preceding: [russian]), [source])
        }
        XCTAssertNil(BackchannelLanguage.corroboratedScriptReread("Вернёмся чуть позже.", corroboration: "вернемся завтра"))
        XCTAssertNil(BackchannelLanguage.corroboratedScriptReread("Вернёмся чуть позже.", corroboration: nil))
        XCTAssertTrue(BackchannelLanguage.confirmsCyrillicSource(original: "Їдемо на зустріч.", reread: "їдемо на зустріч", language: nil))
        XCTAssertTrue(BackchannelLanguage.confirmsCyrillicSource(original: "Їдемо на зустріч.", reread: "їду на зустріч", language: "Ukrainian"))
        XCTAssertFalse(BackchannelLanguage.confirmsCyrillicSource(original: "Їдемо на зустріч.", reread: "идем на встречу", language: "Russian"))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("«Їдемо на зустріч».", duration: 2, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Вітаємо Андрія.", duration: 2, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Їдемо на зустріч.", duration: 2, vocabulary: "зустріч"))
    }

    func testLocalCyrillicCorrectionRetainsAClippedOnsetWhenBothDecodersAgreeInsideTheTurn() {
        let original = "Носить вот такі перчатки."
        let reread = "Носить вот такие перчатки."
        func repair(_ language: String, _ independent: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: original, language: language, reread: reread, corroboration: independent)
        }
        XCTAssertEqual(repair("Russian", "Приносить вот такие перчатки."), reread)
        XCTAssertNil(repair("Russian", "Приносить вот те перчатки."))
        XCTAssertNil(repair("Russian", "Приносить вот такие коробки."))
        XCTAssertNil(repair("Ukrainian", "Приносить вот такие перчатки."))
    }

    func testLexicalAlternativeRequiresIndependentAgreementOnRussianWords() {
        let original = "Yeah, I think that’s a good"
        let decoded = "Да, я ещё тогда об этом говорил."
        let heard = "да я еще тогда об этом говорил"
        XCTAssertEqual(BackchannelLanguage.lexicalAlternative(original: original, russian: decoded, corroboration: heard), decoded)
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: decoded, corroboration: nil))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: decoded, corroboration: "да я еще об этом говорил"))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: original, corroboration: heard))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: original, russian: original, corroboration: original))
    }

    func testLexicalRereadAllowsOneInternalWordBoundaryWithIdenticalSounds() {
        let primary = "Then you probably back."
        let candidate = "Это не правда так."
        XCTAssertEqual(BackchannelLanguage.lexicalAlternative(original: primary, russian: candidate,
            corroboration: "Это неправда так."), candidate)
        for disagreement in ["Это неправильно так.", "Неправда так.", "Это просто неправда."] {
            XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: primary, russian: candidate,
                corroboration: disagreement), disagreement)
        }
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: primary, russian: "Не правда так.",
            corroboration: "Неправда так."))
    }

    func testLanguageForcedRereadRetainsOnlyWordsAlsoHeardByTheAcousticRecognizer() {
        let original = "Can you still hear us?"
        func resolve(_ candidate: String, _ independent: String) -> String? {
            BackchannelLanguage.russianRereadAlternative(original: original, russian: candidate,
                corroboration: independent, vocabulary: "")
        }
        XCTAssertEqual(resolve("И здесь.", "и здесь"), "И здесь.")
        XCTAssertEqual(resolve("Нет, получилось.", "нет"), "Нет…")
        XCTAssertEqual(resolve("Откроем окно после обеда.", "откроем окно утром"), "Откроем окно…")
        XCTAssertNil(resolve("И получилось.", "и замолчал"))
        XCTAssertNil(resolve("Можно рисовать.", ""))
        XCTAssertNil(resolve("Да, получилось.", "Не слышно"))
        XCTAssertNil(resolve("Флимбикс шнупкор.", "флимбикс шнупкор"))
        XCTAssertNil(BackchannelLanguage.russianRereadAlternative(original: "«Can you still hear us?»", russian: "Нет.",
            corroboration: "Нет", vocabulary: ""))
    }

    func testLongForeignSentenceRecognizedWithASmallDifferenceRemainsEnglish() {
        let sentence = "We will mail you the updated schedule after our next meeting."
        XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: sentence,
            reread: "We'll mail you the updated schedule after our next meeting."))
        XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: sentence,
            reread: "We will mail you the schedule after our next meeting."))
        XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: sentence, reread: "We may talk after this call."))
        XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: "Can we?", reread: "Can you?"))
    }

    func testNoSpeechRequiresExplicitAbstentionAndAnEmptyIndependentResult() {
        XCTAssertTrue(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: " \n", corroboration: " \t"))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: nil, text: "", corroboration: ""))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: "", corroboration: nil))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "English", text: "", corroboration: ""))
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "Chinese", text: "", corroboration: ""))
    }

    func testConflictingSubsecondHesitationRetainsAudioWithoutInventingAnEnglishWord() {
        let russian = segment(1, "Давайте вернёмся к обсуждению проекта", mic: false)
        let english = segment(1, "Please send the report before Friday", mic: false)
        var hesitation = segment(4, "Well.", mic: false)
        hesitation.end = 4.4
        let confirmed = BackchannelLanguage.resolve([hesitation], alternatives: [:], preceding: [russian])
        XCTAssertEqual(confirmed, [hesitation])
        let uncertain = BackchannelLanguage.resolve([hesitation], alternatives: [:], uncertain: [hesitation.id], preceding: [russian])
        var expected = hesitation
        expected.text = "Неразборчиво"
        XCTAssertEqual(uncertain, [expected])
        XCTAssertEqual(BackchannelLanguage.resolve([hesitation], alternatives: [:], uncertain: [hesitation.id], preceding: [english]), [hesitation])
        XCTAssertEqual(BackchannelLanguage.resolve([hesitation], alternatives: [:], uncertain: [hesitation.id], preceding: [russian], vocabulary: "Well"), [hesitation])
    }

    func testAnyRecognizedSpeechPreventsNoSpeechRejection() {
        XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: "", corroboration: "да"))
        for text in ["Угу.", "Well.", "好。"] {
            XCTAssertFalse(BackchannelLanguage.hasNoSpeechEvidence(language: "None", text: text, corroboration: ""), text)
        }
    }

    func testIndependentAgreementPreservesForeignLatinSpeech() {
        for (original, reread) in [("Bonjour!", "bonjour."), ("Hola, buenos dias.", "HOLA BUENOS DIAS"),
                                    ("Ça va?", "ça va."), ("It's fine.", "It’s fine!")] {
            XCTAssertTrue(BackchannelLanguage.confirmsLatinSource(original: original, reread: reread), original)
        }
        for (original, reread) in [("Bonjour.", "Hello."), ("Hola, buenos dias.", "Hola."),
                                    ("Да.", "Да."), ("Good, да.", "Good, да."), ("好。", "好。"),
                                    ("…", "…"), ("2026", "2026"), ("Well.", "")] {
            XCTAssertFalse(BackchannelLanguage.confirmsLatinSource(original: original, reread: reread), original)
        }
    }

    func testUnconfirmedTurnsUseRussianContextAndKeepTheirAudio() {
        let russian = segment(10, "Обсудим план работы команды на неделю.", mic: false)
        for mic in [true, false] {
            let unclear = segment(12, "I mean.", mic: mic)
            let filler = segment(13, "Yeah.", mic: mic)
            let uncertain: Set<UUID> = [unclear.id, filler.id]
            var marked = unclear
            marked.text = "Неразборчиво"
            var localized = filler
            localized.text = "Да."

            var overlappingMic = segment(12, "Давайте обсудим следующий вопрос проекта")
            overlappingMic.end = 15
            let result = BackchannelLanguage.resolve([unclear, filler], alternatives: [:], uncertain: uncertain, preceding: [russian, overlappingMic])
            XCTAssertEqual(result, [marked, localized])

            let withFiller = BackchannelLanguage.resolve([unclear, filler], alternatives: [:], uncertain: [unclear.id], preceding: [russian, overlappingMic])
            XCTAssertEqual(withFiller, [marked, localized])
        }
    }

    func testDisputedRemoteTurnUsesNearbySameTrackLanguageWithoutMicrophoneOverlap() {
        let remote = segment(14, "Let me check later.", mic: false)
        let russian = segment(11, "Давайте обсудим следующий вопрос проекта")
        let sameTrack = segment(14, russian.text, mic: false)
        var unclear = remote
        unclear.text = "Неразборчиво"
        XCTAssertEqual(BackchannelLanguage.resolve([remote], alternatives: [:], uncertain: [remote.id],
            preceding: [sameTrack]), [unclear])
        for other in [segment(14, "Hmm."), segment(14, "We could discuss the next question.")] {
            let result = BackchannelLanguage.resolve([remote], alternatives: [:], uncertain: [remote.id], preceding: [other])
            XCTAssertEqual(result, [remote])
        }
    }

    func testSharedAlphabetShortReplyNeedsTwoAudioReadingsAndRussianConversation() {
        let short = segment(14, "Це такое?", mic: false)
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical(short.text, duration: 0.574))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(short.text, duration: 2.1))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(short.text, duration: 0.574, vocabulary: "Це"))
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("«Це такое?»", duration: 0.574))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: short.text, russian: "Что такое.", corroboration: "Что там?"))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: short.text, russian: "Что тогда.", corroboration: "Что тогда."))
        let alternative = BackchannelLanguage.lexicalAlternative(original: short.text, russian: "что такое.", corroboration: "Что такое!")
        XCTAssertEqual(alternative, "Что такое?")
        let choices = alternative.map { [short.id: $0] } ?? [:]
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], lexicalAlternatives: choices, preceding: []), [short])
        let russian = segment(11, "Давайте обсудим следующий вопрос проекта")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], lexicalAlternatives: choices, preceding: [russian])[0].text, "Что такое?")
    }

    func testUnconfirmedTurnsNeedIndependentRussianContext() {
        let russian = segment(10, "Обсудим план работы команды на неделю.", mic: false)
        let english = segment(12, "Are you ready?", mic: false)
        let unclear = segment(14, "I mean.", mic: false)
        let filler = segment(15, "Yeah.", mic: false)
        let uncertain: Set<UUID> = [unclear.id, filler.id]
        let source = [unclear, filler]
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], uncertain: uncertain, preceding: [russian, english]), source)
        XCTAssertEqual(BackchannelLanguage.resolve(source, alternatives: [:], uncertain: uncertain, preceding: []), source)
    }

    func testUnconfirmedLongSentenceWithRussianContextKeepsAudioAndProtectsGlossaryAndQuotes() {
        let russian = segment(10, "Обсудим план работы команды на неделю.")
        let quoted = segment(12, "«I mean».")
        let named = segment(14, "Well, Jira.")
        var long = segment(16, "Please send this one later.")
        long.end = 23
        let source = [quoted, named, long]
        let actual = BackchannelLanguage.resolve(source, alternatives: [:], uncertain: Set(source.map(\.id)),
            preceding: [russian], vocabulary: "Jira")
        XCTAssertEqual(actual.map(\.text), [quoted.text, named.text, "Неразборчиво"])
        XCTAssertEqual(actual[2].audioFile, long.audioFile)
        XCTAssertEqual(actual[2].id, long.id)
    }

    func testResumeUsesSavedLanguageEvidenceAndOnlySafeLegacyAnchors() throws {
        var independent = segment(10, "Сегодня проверим новый рисунок.")
        independent.independentRecognitionLanguage = true
        var disputed = segment(11, "Сегодня проверим другой рисунок.")
        disputed.independentRecognitionLanguage = false
        var legacy = segment(13, "Сегодня проверим все доступные рисунки.")
        legacy.end = 20
        let legacyShort = segment(21, "Сегодня проверим цвет.")
        let source = [independent, disputed, legacy, legacyShort]
        let restored = try JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored.filter(BackchannelLanguage.canRestoreLanguageAnchor), [independent, legacy])
        let turn = segment(23, "Can you still hear us?")
        let result = BackchannelLanguage.resolve([turn], alternatives: [:],
            lexicalAlternatives: [turn.id: "Сейчас проверим."], preceding: restored.filter(BackchannelLanguage.canRestoreLanguageAnchor))
        XCTAssertEqual(result[0].text, "Сейчас проверим.")
    }

    func testAudioAlternativesOutrankTheUnclearMarker() {
        let russian = segment(10, "Обсудим план работы команды на неделю.")
        let lexical = segment(12, "I mean.")
        let vocal = segment(14, "Um.")
        let actual = BackchannelLanguage.resolve([lexical, vocal], alternatives: [lexical.id: "Я имею в виду.", vocal.id: "Эм."],
            lexicalAlternatives: [lexical.id: "Я думаю."], uncertain: [lexical.id, vocal.id], preceding: [russian])
        XCTAssertEqual(actual.map(\.text), ["Я думаю.", "Эм."])
    }

    func testLexicalRecheckPreservesQuotesIdentifiersAndGlossary() {
        for text in ["‘Right’", "“It’s all right”", "\"Good\"", "«Well»", "`Well`", "well.example", "well_right", "C++", "Right/Good"] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(text, duration: 2), text)
            XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: text, russian: "Да.", corroboration: "да"), text)
        }
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Well, Jira.", duration: 2, vocabulary: "Jira"))
        XCTAssertNil(BackchannelLanguage.lexicalAlternative(original: "Well, Jira.", russian: "Ну, Джира.", corroboration: "ну джира", vocabulary: "Jira"))
    }

    func testStandaloneTechnicalTermsKeepTheirSpellingEvenWithoutAPersonalDictionary() {
        let russian = segment(10, "Сегодня проверяем новый проект.")
        for term in ["MCP Figma", "API", "GraphQL", "proof of concept"] {
            XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical(term, duration: 2), term)
            XCTAssertFalse(BackchannelLanguage.shouldRecheck(term, duration: 2), term)
            let source = segment(12, term)
            XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id], preceding: [russian]), [source])
        }
        XCTAssertFalse(BackchannelLanguage.shouldRecheckLexical("Apple Music", duration: 2, vocabulary: "Apple Music"))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Sort of weird.", duration: 2))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Oh No.", duration: 2))
        XCTAssertTrue(BackchannelLanguage.shouldRecheckLexical("Can you see the screen?", duration: 2))
    }

    func testCompactTransliterationNeedsFullRussianAcousticAgreementAndIndependentContext() {
        let russian = segment(10, "Сегодня обсудим цвет новой картинки.")
        let source = segment(12, "Переdaча novogo risunka.")
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(source.text, duration: 2, vocabulary: ""))
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript("Otóż tak było.", duration: 2, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript(source.text, duration: 7, vocabulary: ""))
        for protected in ["«Otóż tak było».", "Witaj Jan Kowalski.", "Сегодня пишем proof of concept.", "Проверили MCP Figma."] {
            XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript(protected, duration: 2, vocabulary: ""), protected)
        }
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Witaj żuraw.", duration: 2, vocabulary: "żuraw"))
        let heard = BackchannelLanguage.agreedRussianText("Передача нового рисунка.", corroboration: "передача нового рисунка")
        XCTAssertEqual(heard, "Передача нового рисунка.")
        XCTAssertNil(BackchannelLanguage.agreedRussianText("Передача нового рисунка.", corroboration: "нового рисунка"))
        XCTAssertNil(BackchannelLanguage.agreedRussianText("Передача нового рисунка.", corroboration: nil))
        let alternatives = heard.map { [source.id: $0] } ?? [:]
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:],
            lexicalAlternatives: alternatives, preceding: [russian])[0].text, heard)
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], uncertain: [source.id], preceding: [russian]), [source])
        XCTAssertEqual(BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: alternatives, preceding: []), [source])
    }

    func testMixedTurnCorroboratesTheLeadingAcknowledgmentAndOmitsUnfinishedTail() {
        func heard(_ source: String, _ candidate: String, _ corroboration: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: source, language: "Russian", reread: candidate, corroboration: corroboration)
        }
        XCTAssertEqual(heard("Mm-hmm, zrób to.", "Записала.", "Угу. Записала."), "Угу. Записала.")
        XCTAssertEqual(heard("Uh widzę снимок.", "Уже видела снимок и", "А-а, уже видела снимок и ка..."), "Уже видела снимок…")
        XCTAssertEqual(heard("Uh po вам", "По вам.", "А по нам опять"), "По вам.")
        XCTAssertNil(heard("Uh go мы", "Го мы.", "А го не туда"))
        XCTAssertNil(heard("Mm-hmm, zrób to.", "Записала.", "Не записала."))
        XCTAssertNil(heard("Uh widzę снимок.", "Уже видела снимок", "А-а, уже меняла снимок."))
        XCTAssertNil(heard("Uh po вам", "По ним.", "А по нам опять"))
        XCTAssertNil(heard("Uh po вам", "По вам.", "А при вас опять"))
    }

    func testVocalizationBeforeOneRussianWordNeedsTheSameOnsetAndWordFromAudio() {
        let source = "Uh готов."
        XCTAssertTrue(BackchannelLanguage.shouldVerifyShortScript(source, duration: 0.8, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("«Uh готов»", duration: 0.8, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript("Uh Артём", duration: 0.8, vocabulary: ""))
        XCTAssertFalse(BackchannelLanguage.shouldVerifyShortScript(source, duration: 0.8, vocabulary: "Uh"))
        func result(_ acoustic: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: source, language: "None", reread: "", corroboration: acoustic)
        }
        XCTAssertEqual(result("А-а, готов."), "А-а, готов.")
        XCTAssertNil(result("А-а, готова."))
        XCTAssertNil(result("Угу, готов."))
        XCTAssertNil(result("Готов."))
    }

    func testWordWithTwoScriptsKeepsItsRussianNeighborsAndNeedsTwoAcousticReadings() throws {
        let primary = "Это гpaфика."
        let index = try XCTUnwrap(BackchannelLanguage.mixedWordIndex(primary, duration: 0.7, vocabulary: ""))
        let revised = BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "То графика.", corroboration: "Это графика.")
        XCTAssertEqual(revised, "Это графика.")
        XCTAssertEqual(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "То графика.",
            corroboration: "Это графика.", isolatedCorroboration: "Графика."), revised)
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "То графика.",
            corroboration: "Это графика.", isolatedCorroboration: "Графика потом."))
        XCTAssertTrue(BackchannelLanguage.confirmsOriginalMixedWordContext(original: primary, rendered: "EtO гpaфика.",
            index: index, corroboration: "Это графика."))
        XCTAssertFalse(BackchannelLanguage.confirmsOriginalMixedWordContext(original: primary, rendered: "EtO гpaфика.",
            index: index, corroboration: "Там графика."))
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "Это график.", corroboration: "Это графика."))
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "Это графика.", corroboration: "Там графика."))
        XCTAssertNil(BackchannelLanguage.restoredMixedWord(primary, index: index, reread: "Это кошка.", corroboration: "Это кошка."))
        let short = "Uh смеna"
        let second = try XCTUnwrap(BackchannelLanguage.mixedWordIndex(short, duration: 0.6, vocabulary: ""))
        XCTAssertEqual(BackchannelLanguage.restoredMixedWord(short, index: second, reread: "Смена.", corroboration: "А-а, смена"), "смена")
        for protected in ["Это гpaФика.", "Это «гpaфика».", "Это гpaфика.exe", "Это iCloud графика.", "Это гpaфика V2."] {
            XCTAssertNil(BackchannelLanguage.mixedWordIndex(protected, duration: 1, vocabulary: ""), protected)
        }
        XCTAssertNil(BackchannelLanguage.mixedWordIndex(primary, duration: 1, vocabulary: "гpaфика"))
        XCTAssertNil(BackchannelLanguage.mixedWordIndex(primary, duration: 6, vocabulary: ""))
        let source = segment(2, primary)
        let context = segment(0, "Сегодня обсудим новый рисунок.")
        let resolved = BackchannelLanguage.resolve([source], alternatives: [:], lexicalAlternatives: [source.id: try XCTUnwrap(revised)],
            preceding: [context])
        XCTAssertEqual(resolved[0].text, "Это графика.")
    }

    func testMixedFillerRequiresTwoFullReadingsAndPreservesMultiplicity() {
        func heard(_ source: String, _ candidate: String, _ corroboration: String) -> String? {
            BackchannelLanguage.mixedRussianAlternative(original: source, language: "English", reread: candidate, corroboration: corroboration)
        }
        let source = "Uhum, ža, okay, ok."
        let check = "Uh huh. Da okay, okay."
        XCTAssertEqual(heard(source, check, "Угу. Да, окей, о’кей."), "Угу. Да, окей, окей.")
        XCTAssertNil(heard(source, check, "Угу. Да, окей."))
        XCTAssertNil(heard(source, "Okay, da okay, okay.", "Угу. Да, окей, окей."))
        XCTAssertNil(heard("Проект, ža, okay, ok.", check, "Угу. Да, окей, окей."))
        XCTAssertNil(heard("Uhum, ža, okay, ok.", check, "Uh huh. Da okay, okay."))
        XCTAssertNil(heard("Uhum, но, okay, ok.", check, "Угу. Да, окей, окей."))
    }

    func testLexicalCorrectionsDoNotEstablishConversationLanguage() {
        let first = segment(20, "Well, I think.")
        var second = segment(22, "Yeah, I think that’s a good")
        second.end = 25.23
        let filler = segment(26, "Yeah.")
        let turns = [first, second, filler]
        let alternatives = [first.id: "Ну, я думаю.", second.id: "Да, я тоже так считаю."]
        let result = BackchannelLanguage.resolve(turns, alternatives: [:], lexicalAlternatives: alternatives, preceding: [])
        XCTAssertEqual(result.map(\.text), turns.map(\.text))

        let russian = segment(15, "Обсудим план работы команды на неделю.")
        let english = segment(19, "Are you ready?")
        let withEnglish = BackchannelLanguage.resolve(turns, alternatives: [:], lexicalAlternatives: alternatives, preceding: [russian, english])
        XCTAssertEqual(withEnglish.map(\.text), turns.map(\.text))

        let withRussian = BackchannelLanguage.resolve(turns, alternatives: [:], lexicalAlternatives: alternatives, preceding: [russian])
        XCTAssertEqual(withRussian.map(\.text), ["Ну, я думаю.", "Да, я тоже так считаю.", "Да."])
    }

    func testFillerFallbackPreservesQuotedAndPathLikeLiterals() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        for text in ["`Yes`", "«Yes»", "\"Yes\"", "'Yes'.", "yes/yes", "yes.yes", "Yeah 2", "Okay+"] {
            let short = segment(30, text)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian])[0].text, text)
            XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Да."], preceding: [russian])[0].text, text)
        }
        let filler = segment(30, "Uh-huh,yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([filler], alternatives: [:], preceding: [russian])[0].text, "Угу, да.")
        let quotedApology = segment(30, "«Sorry».")
        XCTAssertEqual(BackchannelLanguage.resolve([quotedApology], alternatives: [quotedApology.id: "Сорри."], preceding: [russian])[0].text, "«Sorry».")
    }

    func testForeignCyrillicTurnsAreNotRussianAnchors() {
        let earlier = segment(0, "Сегодня мы проверим новый проект.")
        let reply = segment(12, "I mean.")
        for anchor in ["Ми сьогодні перевіряємо новий проєкт.", "Мы працуем над новым праектам.", "Мы працуем над планам.",
                       "Мы сёння ўдакладняем тэрміны сустрэчы."] {
            let result = BackchannelLanguage.resolve([reply], alternatives: [:],
                lexicalAlternatives: [reply.id: "Ну да."], preceding: [earlier, segment(10, anchor)])
            XCTAssertEqual(result[0], reply, anchor)
            let acknowledgment = segment(12, "Mm-hmm.")
            XCTAssertEqual(BackchannelLanguage.resolve([acknowledgment], alternatives: [:],
                preceding: [earlier, segment(10, anchor)]), [acknowledgment], anchor)
        }
        let quote = segment(10, "«Сегодня мы проверим новый проект».")
        XCTAssertEqual(BackchannelLanguage.resolve([reply], alternatives: [:],
            lexicalAlternatives: [reply.id: "Ну да."], preceding: [quote])[0], reply)
    }

    func testEqualDistanceConflictingLanguagesDoNotRewriteTheReply() {
        let left = segment(10, "Сегодня мы проверим новый проект.")
        let right = segment(14, "Let us review this project.")
        let reply = segment(12, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([left, reply, right], alternatives: [:], preceding: [])[1], reply)
    }

    func testTechnicalNamesInTheFollowingRussianTurnDoNotVetoAudioEvidence() {
        let before = segment(10, "Давайте обсудим последние изменения.", mic: false)
        var disputed = segment(11, "Yeah, they can see that.", mic: false)
        disputed.end = 12.28
        let after = segment(disputed.end, "В Luma и Demo добавили акварель.", mic: false)
        let heard = "Сейчас проверим."
        let turns = [before, disputed, after]
        XCTAssertEqual(BackchannelLanguage.resolve(turns, alternatives: [:],
            lexicalAlternatives: [disputed.id: heard], preceding: [])[1].text, heard)
        XCTAssertEqual(BackchannelLanguage.resolve(turns, alternatives: [:],
            uncertain: [disputed.id], preceding: [])[1].text, "Неразборчиво")
        XCTAssertEqual(BackchannelLanguage.resolve(turns, alternatives: [:], preceding: []), turns)
    }

    func testUncertainCyrillicAnchorUsesNearbyIndependentSpeechOnBothSides() {
        let left = segment(18, "Давайте начнём с нового рисунка.")
        let weak = segment(19, "Что тр.")
        let reply = segment(20, "Oh, look.")
        let right = segment(23, "Сейчас выберем подходящий цвет.")
        func resolved(_ context: [TranscriptSegment], uncertain: Bool = false) -> String {
            BackchannelLanguage.resolve([reply], alternatives: [:],
                lexicalAlternatives: uncertain ? [:] : [reply.id: "Тут."],
                uncertain: uncertain ? [reply.id] : [], preceding: context)[0].text
        }
        XCTAssertEqual(resolved([left, weak, right]), "Тут.")
        XCTAssertEqual(resolved([left, weak, right], uncertain: true), "Неразборчиво")
        for context in [[weak], [left, weak], [weak, right], [left, weak, segment(55, right.text)],
                        [left, weak, segment(23, "We should move on.")], [left, segment(19, "Are we ready?"), right],
                        [left, segment(19, "Ми сьогодні переглянемо зміни."), right]] {
            XCTAssertEqual(resolved(context), reply.text)
        }
    }

    func testRepeatedRussianFillersDoNotEstablishLanguageInFollowingWindows() {
        let repeated = segment(25, "Да, да, да, да.")
        let short = segment(30, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [repeated])[0].text, short.text)
    }

    func testLongFillerSequenceLocalizesWithoutRequestingAnAudioRetry() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let english = segment(25, "Let us discuss the next question")
        var short = segment(30, "Yeah! Yeah! Yeah! Yeah!")
        short.end = 34.1
        XCTAssertFalse(BackchannelLanguage.shouldRecheck(short.text, duration: short.end - short.start))
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian])[0].text, "Да, да, да, да!")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [english])[0].text, short.text)
    }

    func testAudioAlternativeTakesPrecedenceOverFillerFallback() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let short = segment(30, "Um.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Эм."], preceding: [russian])[0].text, "Эм.")
    }

    func testFillerFallbackAndAudioKeepDictionarySpelling() {
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта")
        let short = segment(30, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [:], preceding: [russian], vocabulary: "Yeah")[0].text, "Yeah.")
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: [short.id: "Да."], preceding: [russian], vocabulary: "Yeah")[0].text, "Yeah.")
        let apology = segment(30, "Sorry.")
        XCTAssertEqual(BackchannelLanguage.resolve([apology], alternatives: [:], preceding: [russian], vocabulary: "Sorry")[0].text, "Sorry.")
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
    func testUnresolvedShortReplyRetriesWithLeadingSilenceWithoutChangingAudio() {
        let samples: [Float] = [0.2, -0.4, 0.1]
        let retry = BackchannelLanguage.retryAudio(samples)
        XCTAssertEqual(retry.count, samples.count + 2_000)
        XCTAssertTrue(retry.prefix(2_000).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(retry.suffix(samples.count)), samples)
    }

    func testRetriedLexicalReplyRequiresAgreementAndRussianContext() {
        let original = "Yeah, right."
        let candidate = "Давай, давай."
        XCTAssertNil(BackchannelLanguage.alternative(original: original, russian: candidate, corroboration: "Давай."))
        let alternative = BackchannelLanguage.alternative(original: original, russian: candidate, corroboration: "Давай давай.")
        XCTAssertEqual(alternative, candidate)
        let short = segment(30, original, mic: false)
        let russian = segment(25, "Теперь обсудим следующий вопрос проекта", mic: false)
        let english = segment(25, "Let us discuss the next question", mic: false)
        let alternatives = [short.id: candidate]
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [russian])[0].text, candidate)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [english])[0].text, original)
        XCTAssertEqual(BackchannelLanguage.resolve([short], alternatives: alternatives, preceding: [])[0].text, original)
    }

}
