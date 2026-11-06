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
}
