import XCTest
@testable import PisyaCore

final class SpokenVocabularyTests: XCTestCase {
    private let pronunciations = """
    clients K L AY1 AH0 N T S
    retail R IY1 T EY2 L
    media M IY1 D IY0 AH0
    sales S EY1 L Z
    force F AO1 R S
    cloud K L AW1 D
    gate G EY1 T
    """

    func testBaseAcronymsHandleSpokenLettersAndRussianEndings() {
        let vocabulary = SpokenVocabulary("PNL, B2C, CRM")
        XCTAssertEqual(vocabulary.apply(to: "Посчитаем пианельку и пенельку, затем пнлку."), "Посчитаем PNL'ку и PNL'ку, затем PNL'ку.")
        XCTAssertEqual(vocabulary.apply(to: "В пи эн эл и PNL'ке. Это би ту си-продукт и Bitusi продукт."), "В PNL и PNL'ке. Это B2C-продукт и B2C продукт.")
        XCTAssertEqual(vocabulary.apply(to: "Открой си ар эм."), "Открой CRM.")
    }

    func testDictionaryNamesUsePronunciationWithoutSavedInflections() {
        let vocabulary = SpokenVocabulary("YClients, Retail Media, sales-force, CloudGate", pronunciations: pronunciations)
        XCTAssertEqual(vocabulary.apply(to: "В айклаинсе и вай клиентс. Через iклаинса, iClience и IClyens."), "В YClients и YClients. Через YClients, YClients и YClients.")
        XCTAssertEqual(vocabulary.apply(to: "Ритейл медиа и ретейл медиа. Сейлс форс. Клауд гейт."), "Retail Media и Retail Media. sales-force. CloudGate.")
        XCTAssertEqual(vocabulary.apply(to: "Работаем сайклаинсом."), "Работаем с YClients.")
        XCTAssertEqual(vocabulary.apply(to: "С ним циклансом. Проверь циклон и циклится."), "С ним с YClients. Проверь циклон и циклится.")
        XCTAssertEqual(vocabulary.apply(to: "Я айклаинс проверю. Ритейл медиа я обсуждал."), "Я YClients проверю. Retail Media я обсуждал.")
    }

    func testUnrelatedWordsAndAmbiguousDictionaryEntriesArePreserved() {
        let vocabulary = SpokenVocabulary("YClients, PNL, B2C, Retail Media", pronunciations: pronunciations)
        let text = "Наши клиенты и два клиента. Панелька, панель, пенал. BFC, BBC и ABC. Велосипед, циклится, каналы."
        XCTAssertEqual(vocabulary.apply(to: text), text)
        XCTAssertEqual(SpokenVocabulary("").apply(to: "пианельку и айклаинса"), "пианельку и айклаинса")
        XCTAssertEqual(SpokenVocabulary("IClients, YClients", pronunciations: pronunciations).apply(to: "айклаинс"), "айклаинс")
    }

    func testPhoneticNearMissIsOnlyAnAudioHint() {
        let vocabulary = SpokenVocabulary("YClients, B2C", pronunciations: pronunciations)
        XCTAssertEqual(vocabulary.apply(to: "Мы работаем с Wirklience и BFC."), "Мы работаем с Wirklience и BFC.")
        XCTAssertEqual(vocabulary.promptHypothesis("Мы работаем с Wirklience и BFC."), "Мы работаем с YClients и BFC.")
        XCTAssertEqual(vocabulary.promptHypothesis("Мы работаем Сайклань."), "Мы работаем с YClients.")
        XCTAssertEqual(vocabulary.promptHypothesis("Мы обсуждаем погоду и обычные слова."), "Мы обсуждаем погоду и обычные слова.")
        XCTAssertEqual(vocabulary.promptHypothesis("Наши клиенты, clients и Clients."), "Наши клиенты, clients и Clients.")
        XCTAssertEqual(vocabulary.promptHypothesis("Передадим данные в Vie Clince."), "Передадим данные в YClients.")
    }

    func testExplicitCyrillicInitialismCanGuideAudioWithoutReplacingTranscript() {
        let vocabulary = SpokenVocabulary("ЦРТС")
        XCTAssertEqual(vocabulary.apply(to: "Поговорили с PRTS."), "Поговорили с PRTS.")
        XCTAssertEqual(vocabulary.promptHypothesis("Поговорили с PRTS."), "Поговорили с ЦРТС.")
        XCTAssertEqual(SpokenVocabulary("КРТС").promptHypothesis("Ответил KRTZ."), "Ответил КРТС.")
    }

    func testInitialismHintsRequireUniqueExplicitEvidence() {
        for dictionary in ["", "ЦРТС, PRTS", "ЦРТС, ПРТК"] {
            XCTAssertEqual(SpokenVocabulary(dictionary).promptHypothesis("Встреча PRTS."), "Встреча PRTS.")
        }
        XCTAssertEqual(SpokenVocabulary("ЦРТС, КРТС").promptHypothesis("Встреча CRTS."), "Встреча CRTS.")
        let vocabulary = SpokenVocabulary("ЦРТС")
        for text in ["Встреча prts.", "Встреча PARTS.", "Встреча BFC.", "Встреча ПРТС."] {
            XCTAssertEqual(vocabulary.promptHypothesis(text), text)
        }
    }

    func testFusedPrepositionAndExplicitNameCanGuideAudioWithInflection() {
        let vocabulary = SpokenVocabulary("Анжела")
        let text = "Обсудим Санджелой детали."
        XCTAssertEqual(vocabulary.apply(to: text), text)
        XCTAssertEqual(vocabulary.promptHypothesis(text), "Обсудим с Анжелой детали.")
        XCTAssertEqual(SpokenVocabulary("Марина").promptHypothesis("Обсудим Смаринойй детали."), "Обсудим с Мариной детали.")
    }

    func testNameHintsDoNotRewriteCompetingNamesOrOrdinaryWords() {
        for dictionary in ["", "Анжела, Анджела", "Анжела, Андела"] {
            XCTAssertEqual(SpokenVocabulary(dictionary).promptHypothesis("Обсудим Санджелой детали."), "Обсудим Санджелой детали.")
        }
        let vocabulary = SpokenVocabulary("Анжела")
        for text in ["Обсудим с Анджелой детали.", "Анджела ответила.", "Обсудим сандалии.", "Обсудим Сангрию."] {
            XCTAssertEqual(vocabulary.promptHypothesis(text), text)
        }
        XCTAssertEqual(SpokenVocabulary("Маша").promptHypothesis("Обсудим Смашей детали."), "Обсудим Смашей детали.")
    }

    func testCyrillicHintSignalDistinguishesNewHintsFromEnglishAndUnchangedText() {
        XCTAssertTrue(SpokenVocabulary("ЦРТС").hasCyrillicHints(in: "Поговорили с PRTS."))
        XCTAssertTrue(SpokenVocabulary("Анжела").hasCyrillicHints(in: "Обсудим Санджелой детали."))
        XCTAssertFalse(SpokenVocabulary("YClients", pronunciations: pronunciations).hasCyrillicHints(in: "Работаем с Wirklience."))
        XCTAssertFalse(SpokenVocabulary("ЦРТС, ПРТК").hasCyrillicHints(in: "Встреча PRTS."))
        XCTAssertFalse(SpokenVocabulary("").hasCyrillicHints(in: "PRTS и Санджелой."))
        XCTAssertFalse(SpokenVocabulary("ЦРТС, Анжела").hasCyrillicHints(in: "Обсудим с Анжелой и ЦРТС."))
    }

    func testFocusedNameHintUsesOnlyExactIndependentExplicitNamePhrase() {
        let vocabulary = SpokenVocabulary("Анжела, Марина")
        XCTAssertEqual(vocabulary.focusedNameHypothesis(original: "Обсудим Санджело детали.",
            corroboration: "Вообще завтра обсудим с Анжелой другие детали."), "с Анжелой")
        XCTAssertEqual(vocabulary.focusedNameHypothesis(original: "Обсудим с Мариной и Санджело.",
            corroboration: "Обсудим с Анжелой и с Мариной."), "с Анжелой")
    }

    func testFocusedNameHintRejectsAbsentVocabularyCompetingNamesAndPartialWords() {
        let vocabulary = SpokenVocabulary("Анжела")
        XCTAssertNil(vocabulary.focusedNameHypothesis(original: "Обсудим с анжелой детали.", corroboration: "Обсудим с Анжелой."))
        for raw in ["Обсудим с Анджелой.", "Обсудим без Анжелой.", "Обсудим с Анжелойтовой.", "Обсудим с. Анжелой."] {
            XCTAssertNil(vocabulary.focusedNameHypothesis(original: "Обсудим Санджело.", corroboration: raw))
        }
        XCTAssertNil(SpokenVocabulary("").focusedNameHypothesis(original: "Обсудим Санджело.", corroboration: "Обсудим с Анжелой."))
    }
}
