import XCTest
@testable import PisyaCore

final class SpokenVocabularyTests: XCTestCase {
    func testPhoneticAbbreviationFormsKeepObservedEndings() {
        let vocabulary = SpokenVocabulary("LLM, AI, API, GR")
        XCTAssertEqual(vocabulary.apply(to: "с элэлэмом, об AIем и к джиару"), "с LLM'ом, об AI'ем и к GR'у")
        XCTAssertEqual(vocabulary.apply(to: "LLM и AI"), "LLM и AI")
    }
    func testDecodingVocabularyAddsOnlyBoundedNumericAcronymForms() {
        let base = "Марина, 7АБВ, 7АБВ'а, CRM"
        let text = SpokenVocabulary(base).decodingVocabulary
        XCTAssertEqual(text, base + ", 7АБВ'ом, 7АБВ'е, 7АБВ'у")
        XCTAssertEqual(SpokenVocabulary("CRM, Марина, 21АБВ").decodingVocabulary, "CRM, Марина, 21АБВ")
        let many = "1АБВ, 2АБВ, 3АБВ, 4АБВ, 5АБВ"
        let output = SpokenVocabulary(many).decodingVocabulary
        let extra = String(output.dropFirst(many.count + 2)).components(separatedBy: ", ")
        XCTAssertEqual(extra.count, 16)
        XCTAssertFalse(extra.contains(where: { $0.hasPrefix("5АБВ") }))
        XCTAssertEqual(Set(extra).count, extra.count)
        XCTAssertEqual(SpokenVocabulary("7АБВ, 7АБВ’а, 7АБВ").decodingVocabulary,
            "7АБВ, 7АБВ’а, 7АБВ, 7АБВ'ом, 7АБВ'е, 7АБВ'у")
    }
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

    func testMissingRepeatedInitialismLetterIsOnlyAnExplicitAudioHint() {
        let vocabulary = SpokenVocabulary("АМПП")
        XCTAssertEqual(vocabulary.apply(to: "Встреча AMP."), "Встреча AMP.")
        XCTAssertEqual(vocabulary.promptHypothesis("Встреча AMP."), "Встреча АМПП.")
        XCTAssertTrue(vocabulary.hasCyrillicHints(in: "Встреча AMP."))
        XCTAssertEqual(SpokenVocabulary("ККРТ").promptHypothesis("Встреча KRT."), "Встреча ККРТ.")
    }

    func testRepeatedLetterHintDoesNotInferMissingDistinctLettersOrOverrideKnownAcronyms() {
        for dictionary in ["", "АМПП, AMP", "АМПП, ААМП", "АМПП, АМП"] {
            XCTAssertEqual(SpokenVocabulary(dictionary).promptHypothesis("Встреча AMP."), "Встреча AMP.")
        }
        XCTAssertEqual(SpokenVocabulary("АМПП").promptHypothesis("Встреча amp и АМП."), "Встреча amp и АМП.")
        XCTAssertEqual(SpokenVocabulary("АКМП").promptHypothesis("Встреча AMP."), "Встреча AMP.")
        XCTAssertEqual(SpokenVocabulary("Гавермент").apply(to: "Гаверман ответил."), "Гаверман ответил.")
    }

    func testExplicitInitialismHandlesContractedAdjacentLetterNames() {
        let vocabulary = SpokenVocabulary("GR")
        XCTAssertEqual(vocabulary.apply(to: "Вопрос к Джару. Джар может ответить. ДЖИАР ответил."), "Вопрос к GR'у. GR может ответить. GR ответил.")
        XCTAssertEqual(SpokenVocabulary("AGR").apply(to: "Вопрос к эйджару."), "Вопрос к AGR'у.")
        XCTAssertEqual(vocabulary.apply(to: "Жар, жару, пар и подарок."), "Жар, жару, пар и подарок.")
        XCTAssertEqual(SpokenVocabulary("").apply(to: "Вопрос к Джару."), "Вопрос к Джару.")
    }

    func testContractedInitialismPreservesExplicitCompetingNameAndItsEnding() {
        XCTAssertEqual(SpokenVocabulary("GR, Джар").apply(to: "Джар ответил. Вопрос к Джару."), "Джар ответил. Вопрос к Джару.")
    }

    func testMixedScriptNamesAndEnglishPronunciationsKeepTheirExistingPath() {
        XCTAssertEqual(SpokenVocabulary("Сбер2B").apply(to: "СберТуби"), "Сбер2B")
        let fuel = SpokenVocabulary("FuelUp", pronunciations: "fuel F Y UW1 AH0 L\nup AH1 P")
        XCTAssertEqual(fuel.apply(to: "Fuy Lap"), "FuelUp")
        XCTAssertEqual(fuel.apply(to: "Fullab"), "Fullab")
        XCTAssertEqual(fuel.promptHypothesis("Fullab"), "FuelUp")
        XCTAssertEqual(SpokenVocabulary("LinkedIn Premium, KPI, АЗС, Игнатов").apply(to: "Linked& Premium, KII, AZ, Игнатьовым"),
                       "Linked& Premium, KII, AZ, Игнатьовым")
    }

    func testRepeatedAcronymLettersAndExplicitCaseEndingsRemainDistinct() {
        let vocabulary = SpokenVocabulary("LLM, LMM, AI")
        XCTAssertEqual(vocabulary.apply(to: "ЛЛМки, ЛММки и ЛЛМами."), "LLM'ки, LMM'ки и LLM'ами.")
        XCTAssertEqual(vocabulary.apply(to: "С AIем, с AI'ем и с AI’ем."), "С AI'ем, с AI'ем и с AI'ем.")
        XCTAssertEqual(SpokenVocabulary("LLM").apply(to: "ЛМки и ЛММки."), "ЛМки и ЛММки.")
        XCTAssertEqual(SpokenVocabulary("LLM, ЛЛМ").apply(to: "ЛЛМки"), "ЛЛМки")
        XCTAssertEqual(vocabulary.apply(to: "AIM, aim и аи."), "AIM, aim и аи.")
    }

    func testForeignTermsRetainExistingSplitAndInflectionSupportWithoutSemanticGuessing() {
        let vocabulary = SpokenVocabulary("API, GLM, ChatGPT, Delphi, Visual Basic", pronunciations: "delphi D EH1 L F AY0")
        XCTAssertEqual(vocabulary.apply(to: "по АПе, G L M и чат GPT"), "по API, GLM и ChatGPT")
        XCTAssertEqual(vocabulary.apply(to: "в Дельфе программировал"), "в Delphi программировал")
        XCTAssertEqual(vocabulary.apply(to: "вижу Басик"), "вижу Басик")
    }

    func testPromptOnlyMatchesAmpersandAndDeclinedForeignNearMisses() {
        let vocabulary = SpokenVocabulary("LinkedIn Premium, FuelUp", pronunciations: "linkedin L IH1 NG K T IH2 N\npremium P R IY1 M IY0 AH0 M\nfuel F Y UW1 AH0 L\nup AH1 P")
        XCTAssertEqual(vocabulary.apply(to: "Linked&Premium и Фуйлабом"), "Linked&Premium и Фуйлабом")
        XCTAssertEqual(vocabulary.promptHypothesis("Linked&Premium"), "LinkedIn Premium")
        XCTAssertEqual(vocabulary.promptHypothesis("Фуйлабом"), "FuelUp")
        XCTAssertEqual(vocabulary.promptHypothesis("https://example.com/Linked&Premium"), "https://example.com/Linked&Premium")
        XCTAssertEqual(vocabulary.promptHypothesis("`Linked&Premium`"), "`Linked&Premium`")
        XCTAssertEqual(SpokenVocabulary("FuelUp, Фуйлаб", pronunciations: "fuel F Y UW1 AH0 L\nup AH1 P").promptHypothesis("Фуйлабом"), "Фуйлабом")
        XCTAssertEqual(vocabulary.promptHypothesis("Я вижу обычные слова и AIM."), "Я вижу обычные слова и AIM.")
    }

    func testRelevantTermsReturnsOnlyObservedCanonicalTermsFromEitherDecoder() {
        let vocabulary = SpokenVocabulary("Анжела, Наташа, Дёгтева, FuelUp, AI, Кинопоиск, Неизвестный", pronunciations: "fuel F Y UW1 AH0 L\nup AH1 P")
        XCTAssertEqual(vocabulary.relevantTerms(in: ["Наташка кивнула.", "Наташа кивнула. С Анжелой говорили о Дегтевой и Fullab."]), "Анжела, Наташа, Дёгтева, FuelUp")
        XCTAssertEqual(vocabulary.relevantTerms(in: ["Суперкинопоиск и AIM."]), "")
        XCTAssertEqual(vocabulary.relevantTerms(in: []), "")
        XCTAssertEqual(vocabulary.relevantTerms(in: ["Наташа", "Наташа"]), "Наташа")
    }

    func testRelevantTermsCapsTheCanonicalShortlistAtEight() {
        let terms = (1...12).map { "Project\($0)" }
        let vocabulary = SpokenVocabulary(terms.joined(separator: ", "))
        XCTAssertEqual(vocabulary.relevantTerms(in: [terms.joined(separator: ", ")]), terms.prefix(8).joined(separator: ", "))
    }

    func testNumericAcronymNearMissIsAnInflectedPromptOnlyHint() {
        let vocabulary = SpokenVocabulary("2ГИС, 7АБВ")
        XCTAssertEqual(vocabulary.apply(to: "В Догисе и с СемиАБДом."), "В Догисе и с СемиАБДом.")
        XCTAssertEqual(vocabulary.promptHypothesis("В Догисе и с СемиАБДом."), "В 2ГИС'е и с 7АБВ'ом.")
        XCTAssertTrue(vocabulary.hasCyrillicHints(in: "В Догисе."))
        XCTAssertEqual(vocabulary.relevantTerms(in: ["В Догисе."]), "2ГИС")
    }

    func testNumericHintsRejectAmbiguityCompetingNamesAndWeakPronunciations() {
        for dictionary in ["", "2ГИС, Догисе"] {
            XCTAssertEqual(SpokenVocabulary(dictionary).promptHypothesis("В Догисе."), "В Догисе.")
        }
        XCTAssertEqual(SpokenVocabulary("7АБВ, 7АБГ").promptHypothesis("С СемиАБДом."), "С СемиАБДом.")
        let vocabulary = SpokenVocabulary("2ГИС")
        for text in ["Дагестан", "Доге", "Догисев", "Двусом", "Дугисон", "Двух Гисоном", "до Гисе", "на ГИСе"] {
            XCTAssertEqual(vocabulary.promptHypothesis(text), text)
        }
    }
    func testLiteralRangesStayUntouchedAcrossVocabularyNormalizationAndHints() {
        let vocabulary = SpokenVocabulary("фокус-группа, 2ГИС, YClients", pronunciations: pronunciations)
        let source = """
        фокус группа и два ГИСа, в двух ГИСе; айклаинс.
        «фокус группа и два ГИСа, айклаинс»; `фокус группа, айклаинс`.
        https://site.ru/фокусгруппа и фокусгруппа@example.ru
        ```
        фокус группа и айклаинс
        ```
        """
        let expected = """
        фокус-группа и 2ГИС'а, в 2ГИС'е; YClients.
        «фокус группа и два ГИСа, айклаинс»; `фокус группа, айклаинс`.
        https://site.ru/фокусгруппа и фокусгруппа@example.ru
        ```
        фокус группа и айклаинс
        ```
        """
        XCTAssertEqual(vocabulary.apply(to: source), expected)
        XCTAssertEqual(vocabulary.promptHypothesis(source), expected)
    }

    func testLiteralRangesDoNotProducePromptHints() {
        let vocabulary = SpokenVocabulary("2ГИС, YClients", pronunciations: pronunciations)
        let source = "«Догисе и Wirklience»; `Догисе`; https://example.com/Догисе. В Догисе и Wirklience."
        let expected = "«Догисе и Wirklience»; `Догисе`; https://example.com/Догисе. В 2ГИС'е и YClients."
        XCTAssertEqual(vocabulary.promptHypothesis(source), expected)
        XCTAssertFalse(vocabulary.hasCyrillicHints(in: "«Догисе» и `Догисе`"))
        XCTAssertTrue(vocabulary.hasCyrillicHints(in: source))
    }

}
