import XCTest
@testable import PisaCore

final class RussianRecognitionTests: XCTestCase {
    /// Every existing accepted repair is also a regression case for retry
    /// selection: skipping its decode must never hide a valid correction.
    private func revisedText(original: String, candidate: String, corroboration: String,
                             hypothesis: String, vocabulary: String, usesCyrillicHints: Bool,
                             dictionaryCorroboration: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) -> String? {
        let result = RussianRecognition.revisedText(original: original, candidate: candidate,
            corroboration: corroboration, hypothesis: hypothesis, vocabulary: vocabulary,
            usesCyrillicHints: usesCyrillicHints, dictionaryCorroboration: dictionaryCorroboration)
        if let result, result != original {
            XCTAssertTrue(RussianRecognition.canRevise(original: original, corroboration: corroboration,
                hypothesis: hypothesis, vocabulary: vocabulary, dictionaryCorroboration: dictionaryCorroboration),
                "An accepted correction must remain eligible for its audio retry", file: file, line: line)
        }
        return result
    }

    func testNumericEndingRepairChangesOnlyIndependentlyDecodedEnding() {
        let original = "Проверим поиск внутри 7АБВ и обсудим результаты."
        let candidate = "Проверим поиск внутри 7АБВ'а и обсудим другое."
        XCTAssertEqual(RussianRecognition.restoringNumericEndings(original: original, candidate: candidate, vocabulary: "7АБВ"),
            "Проверим поиск внутри 7АБВ'а и обсудим результаты.")
        XCTAssertTrue(SpokenVocabulary("7АБВ").needsNumericEndingCheck(in: original))
        XCTAssertFalse(SpokenVocabulary("7АБВ").needsNumericEndingCheck(in: "Проверим поиск внутри 7АБВ'а и обсудим результаты."))
        XCTAssertFalse(SpokenVocabulary("7АБВ").needsNumericEndingCheck(in: "Внутри 7АБВ и обсудим результаты."))
        let second = "Проверим поиск внутри 3XYZ и обсудим результаты."
        XCTAssertEqual(RussianRecognition.restoringNumericEndings(original: second,
            candidate: "Проверим поиск внутри 3XYZ'ом и обсудим результаты.", vocabulary: "3XYZ"),
            "Проверим поиск внутри 3XYZ'ом и обсудим результаты.")
        for (source, retry, glossary) in [
            (original, original, "7АБВ"),
            (original, "Проверим поиск внутри 8АБВ'а и обсудим результаты.", "7АБВ, 8АБВ"),
            (original, "Проверим что внутри 7АБВ'а и обсудим результаты.", "7АБВ"),
            (original, "Проверим поиск внутри 7АБВ'а и сравним результаты.", "7АБВ"),
            ("Проверим поиск внутри «7АБВ» и обсудим результаты.", candidate, "7АБВ"),
            ("Проверим поиск внутри 7АБВ'у и обсудим результаты.", candidate, "7АБВ"),
            (original + " " + original, candidate, "7АБВ"),
            (original, candidate, "7АБВ, 7АБВ'а"),
            (original, candidate, "7АБВ, поиск внутри 7АБВ"),
            ("Внутри 7АБВ и обсудим результаты.", "Внутри 7АБВ'а и обсудим результаты.", "7АБВ")
        ] {
            XCTAssertNil(RussianRecognition.restoringNumericEndings(original: source, candidate: retry, vocabulary: glossary), source)
        }
    }
    func testLocalRepairNeverEditsQuotedCodeOrURLContent() {
        let candidate = "Мы говорили с Анжелой по этому вопросу."
        for original in ["Мы говорили «Санджелой по этому вопросу»." ,
                         "Мы говорили `Санджелой по этому вопросу`.",
                         "Мы говорили https://example.com/Санджелой по этому вопросу."] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate,
                corroboration: candidate, vocabulary: "Анжела"), original)
        }
        let plain = "Мы говорили Санджелой по этому вопросу."
        for literal in ["Мы говорили «с Анжелой по этому вопросу».",
                        "Мы говорили `с Анжелой по этому вопросу`."] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: plain, candidate: literal,
                corroboration: candidate, vocabulary: "Анжела"), literal)
            XCTAssertNil(RussianRecognition.localizedRepair(original: plain, candidate: candidate,
                corroboration: literal, vocabulary: "Анжела"), literal)
        }
        let acronym = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        for original in ["Вчера говорили с руководителем «PRTS». Мы можем обсудить сроки.",
                         "Вчера говорили с руководителем `PRTS`. Мы можем обсудить сроки.",
                         "Вчера говорили с руководителем https://example.com/PRTS. Мы можем обсудить сроки."] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: acronym,
                corroboration: acronym, vocabulary: ""), original)
        }
    }
    func testPhoneticGlossaryEvidenceRequiresIndependentAgreement() {
        let dictionary = SpokenVocabulary("YClients, Retail Media")
        let source = "Передадим данные вай-клиенты, обсудим Retail Media."
        let raw = "Передадим данные в Vie Clince, обсудим Rity Media."
        let candidate = "Передадим данные в YClients, обсудим Retail Media."
        XCTAssertEqual(dictionary.promptHypothesis(source), "Передадим данные YClients, обсудим Retail Media.")
        XCTAssertEqual(revisedText(original: source, candidate: candidate, corroboration: raw,
            hypothesis: dictionary.promptHypothesis(raw), vocabulary: "YClients, Retail Media", usesCyrillicHints: false),
            "Передадим данные в YClients, обсудим Retail Media.")
        for (original, confirmed, context) in [
            ("Передадим данные новым клиентам, обсудим Retail Media.", raw, "YClients, Retail Media"),
            (source, "Передадим данные в другой сервис, обсудим Retail Media.", "YClients, Retail Media"),
            (source, raw, "YClients, Retail Media, вай-клиенты"),
            ("Передадим данные «вай-клиенты», обсудим Retail Media.", raw, "YClients, Retail Media")
        ] {
            let guessed = SpokenVocabulary(context).promptHypothesis(confirmed)
            XCTAssertNil(revisedText(original: original, candidate: candidate, corroboration: confirmed,
                hypothesis: guessed, vocabulary: context, usesCyrillicHints: false), original)
        }
        let wrongPreposition = "Передадим данные с YClients, обсудим Retail Media."
        XCTAssertNil(revisedText(original: source, candidate: wrongPreposition, corroboration: raw,
            hypothesis: wrongPreposition, vocabulary: "YClients, Retail Media", usesCyrillicHints: false))
        for original in ["Передадим данные не вай-клиенты, обсудим Retail Media.",
                         "Передадим данные `вай-клиенты`, обсудим Retail Media.",
                         "Передадим данные к вай-клиенты, обсудим Retail Media."] {
            XCTAssertNil(revisedText(original: original, candidate: candidate, corroboration: raw,
                hypothesis: dictionary.promptHypothesis(raw), vocabulary: "YClients, Retail Media", usesCyrillicHints: false), original)
        }
    }

    func testPhoneticRepairPreservesSourceWhenBothDecodersAddConjunction() {
        let original = "Передадим данные вай-клиенты, обсудим Retail Media."
        let raw = "Передадим данные в Vie Clints и обсудим Rity Media."
        let candidate = "Передадим данные в YClients и обсудим Retail Media."
        let vocabulary = "YClients, Retail Media"
        let hypothesis = "Передадим данные в YClients и обсудим Retail Media."
        XCTAssertEqual(revisedText(original: original, candidate: candidate, corroboration: raw,
            hypothesis: hypothesis, vocabulary: vocabulary, usesCyrillicHints: false),
            "Передадим данные в YClients, обсудим Retail Media.")
        XCTAssertNil(revisedText(original: original, candidate: candidate, corroboration: raw,
            hypothesis: "Передадим данные в YClients обсудим Retail Media.", vocabulary: vocabulary,
            usesCyrillicHints: false))
        XCTAssertNil(revisedText(original: original,
            candidate: "Передадим данные в YClients или обсудим Retail Media.", corroboration: raw,
            hypothesis: "Передадим данные в YClients или обсудим Retail Media.", vocabulary: vocabulary,
            usesCyrillicHints: false))
    }
    func testDictionaryAcronymCaseEndingNeedsAgreementAndUniqueAnchors() {
        let original = "Это команда 2ГИС перед запуском."
        let candidate = "Это команда 2ГИС'а перед запуском."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: candidate,
            hypothesis: candidate, vocabulary: "2ГИС"), candidate)
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: candidate, candidate: original,
            hypothesis: original, vocabulary: "2ГИС"), original)
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: candidate,
            hypothesis: original, vocabulary: "2ГИС"))
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original + " " + original, candidate: candidate,
            hypothesis: candidate, vocabulary: "2ГИС"))
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: candidate,
            hypothesis: candidate, vocabulary: "2ГИС, 2ГИС'а"))
    }
    func testFusedDictionaryNameCanUseTwoEditsWithIndependentAgreement() {
        let original = "Обсуждали это с B2C, Санджело допустим, или с Сергеенко?"
        let candidate = "Обсуждали это с Бетусси, с Анжелой допустим, или с Сергеем?"
        let raw = "Обсуждали это с BTS, с Анжелой, допустим, или с Сергеем?"
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate,
            corroboration: raw, vocabulary: "B2C, Анжела"),
            "Обсуждали это с B2C, с Анжелой допустим, или с Сергеенко?")
        XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate,
            corroboration: raw, vocabulary: "B2C, Анжела, Анджела"))
        XCTAssertNil(RussianRecognition.localizedRepair(original: original.replacingOccurrences(of: "Санджело", with: "Сандреем"),
            candidate: candidate, corroboration: raw, vocabulary: "Анжела"))
        XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate,
            corroboration: original, vocabulary: "Анжела"))
    }
    func testDictionaryRepairAcceptsOnlyAgreedExplicitHyphenatedCompound() {
        let original = "Мы создаём профиль сегодня и обсуждаем запуск."
        let heard = "Мы соцдем-профиль сегодня и обсуждаем запуск."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "соцдем-профиль"), heard)
        for (source, candidate, evidence, glossary) in [
            (original, heard, original, "соцдем-профиль"),
            (original, "Мы соцдем профиль сегодня и обсуждаем запуск.", "Мы соцдем профиль сегодня и обсуждаем запуск.", "соцдем-профиль"),
            (original, heard, heard, "соцдем профиль"),
            ("Мы не профиль сегодня и обсуждаем запуск.", heard, heard, "соцдем-профиль"),
            ("Мы создаём профиль сегодня и обсуждаем запуск.", heard, heard, "соцдем-профиль, профиль")
        ] {
            XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: source, candidate: candidate,
                hypothesis: evidence, vocabulary: glossary), candidate)
        }
    }
    func testNearbyDictionarySurnameMayRepairAnUnknownName() {
        let original = "Мы говорили с Максимом Магнатовым, там будет встреча."
        let heard = "Мы говорили с Максимом Игнатовым, там будет встреча."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "Игнатов"), heard)
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: "Мы говорили с Максимом Сидоровым, там будет встреча.",
            candidate: heard, hypothesis: heard, vocabulary: "Игнатов"))
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "Игнатов, Магнатов"))
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: original, vocabulary: "Игнатов"))
    }
    func testRepeatedDictionaryTermRepairsOnlyAgreedAdjacentRun() {
        let original = "Возник вопрос ГИС, ГИС может здесь помочь."
        let agreed = "Возник вопрос к ZX. ZX может здесь помочь."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: agreed,
            hypothesis: agreed, vocabulary: "ZX"), agreed)
        let other = "Возник вопрос к AB. AB может здесь помочь."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: other,
            hypothesis: other, vocabulary: "AB"), other)
        for (source, candidate, hypothesis, vocabulary) in [
            (original, agreed, original, "ZX"),
            (original, "Возник вопрос к ZX. Да ZX может здесь помочь.", "Возник вопрос к ZX. Да ZX может здесь помочь.", "ZX"),
            ("Возник вопрос не ГИС может здесь помочь.", agreed, agreed, "ZX"),
            ("Возник вопрос Анна ГИС может здесь помочь.", agreed, agreed, "ZX"),
            (original, agreed, agreed, "ZX, ГИС"),
            (original + " " + original, agreed, agreed, "ZX"),
            ("Возник вопрос «ГИС, ГИС» может здесь помочь.", agreed, agreed, "ZX"),
            (original, agreed, "Возник вопрос к ZX, ZX может здесь помочь.", "ZX")
        ] {
            XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: source, candidate: candidate,
                hypothesis: hypothesis, vocabulary: vocabulary), source)
        }
    }
    func testGeneralDictionaryRepairReplacesTwoCorruptedWordsWithTerm() {
        let original = "Настя делает все знает, что будет заезд."
        let heard = "Настя Дёгтева знает, что будет заезд."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "Дёгтева"), heard)
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: "Настя не все знает, что будет заезд.", candidate: heard,
            hypothesis: heard, vocabulary: "Дёгтева"))
    }

    func testGeneralDictionaryRepairAllowsUnrelatedQuotation() {
        let original = "Вопрос ГИС ГИС может здесь помочь, обсуждаем «социальную полезность»."
        let heard = "Вопрос ГИС GR может здесь помочь, обсуждаем «социальную полезность»."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "GR"), heard)
    }

    func testGeneralDictionaryRepairKeepsApostropheCaseEnding() {
        let original = "Мы работали с гизом перед запуском."
        let heard = "Мы работали с 2ГИС'ом перед запуском."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "2ГИС"), heard)
    }

    func testInstrumentalEmRequiresAcousticAgreementAndPreservesExplicitForms() {
        for acronym in ["API", "QX"] {
            let original = "Мы работали с \(acronym) перед запуском."
            let heard = "Мы работали с \(acronym)'ем перед запуском."
            XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
                hypothesis: heard, vocabulary: acronym), heard)
            XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
                hypothesis: original, vocabulary: acronym))

            let otherEnding = "Мы работали с \(acronym)'ом перед запуском."
            XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: otherEnding, candidate: heard,
                hypothesis: heard, vocabulary: acronym), heard)
            XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: otherEnding, candidate: heard,
                hypothesis: heard, vocabulary: "\(acronym), \(acronym)'ом"))
        }
    }

    func testGeneralDictionaryRepairSplitsFusedPrepositionOnlyOnAgreement() {
        let original = "Потом будут обращения ПАПИ причём они продолжатся."
        let heard = "Потом будут обращения по API причём они продолжатся."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: heard, vocabulary: "API"), heard)
        XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: heard,
            hypothesis: "Потом будут обращения к API причём они продолжатся.", vocabulary: "API"))
    }
    func testGeneralDictionaryRepairOnlyChangesAgreedTermAtSameAnchors() {
        let original = "Вопрос ГИС ГИС может здесь помочь."
        let hypothesis = "Вопрос ГИС GR может здесь помочь."
        let candidate = "Вопрос ГИС GR может здесь работать."
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: original, candidate: candidate,
            hypothesis: hypothesis, vocabulary: "GR"), "Вопрос ГИС GR может здесь помочь.")
        XCTAssertEqual(RussianRecognition.generalDictionaryRepair(original: "Настя делает все знает про это.",
            candidate: "Настя делает Дёгтева знает про это.", hypothesis: "Настя делает Дёгтева знает про это.",
            vocabulary: "Дёгтева"), "Настя делает Дёгтева знает про это.")
    }

    func testGeneralDictionaryRepairUsesRawIndependentAudioNotPromptHint() {
        let original = "Вопрос ГИС ГИС может здесь помочь."
        let candidate = "Вопрос ГИС GR может здесь помочь."
        XCTAssertEqual(revisedText(original: original, candidate: candidate,
            corroboration: "Вопрос ГИС джар может здесь помочь.", hypothesis: candidate,
            vocabulary: "GR", usesCyrillicHints: false), candidate)
        XCTAssertNil(revisedText(original: original, candidate: candidate,
            corroboration: original, hypothesis: candidate, vocabulary: "GR", usesCyrillicHints: false))
        XCTAssertEqual(revisedText(original: original, candidate: candidate,
            corroboration: "Вопрос ГИС pronunciation может здесь помочь.", hypothesis: candidate,
            vocabulary: "GR", usesCyrillicHints: false, dictionaryCorroboration: candidate), candidate)
    }

    func testGeneralDictionaryRepairRejectsUnconfirmedAmbiguousOrProtectedSpans() {
        let source = "Вопрос ГИС ГИС может здесь помочь."
        let revised = "Вопрос ГИС GR может здесь помочь."
        for (original, candidate, hypothesis, vocabulary) in [
            (source, revised, source, "GR"),
            (source + " " + source, revised, revised, "GR"),
            (source, revised, revised, "GR, ГИС"),
            ("Вопрос карта сайта может здесь помочь.", "Вопрос карта GR может здесь помочь.",
                "Вопрос карта GR может здесь помочь.", "GR, карта сайта"),
            ("Вопрос ГИС 24 может здесь помочь.", revised, revised, "GR"),
            ("Вопрос ГИС не может здесь помочь.", revised, revised, "GR"),
            ("Вопрос ГИС «ГИС» может здесь помочь.", revised, revised, "GR"),
            ("Вопрос ГИС /ГИС может здесь помочь.", revised, revised, "GR"),
            ("Вопрос ГИС Анна может здесь помочь.", revised, revised, "GR")
        ] {
            XCTAssertNil(RussianRecognition.generalDictionaryRepair(original: original, candidate: candidate,
                hypothesis: hypothesis, vocabulary: vocabulary), original)
        }
    }
    func testDictionaryRepairRequiresFreshAudioAgreementForAnOmittedRepeatedLetter() {
        let original = "Она ходила в AMP и недавно мы получили ответ."
        let candidate = "Она ходила в АМПП и недавно мы получили ответ."
        XCTAssertEqual(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
            hypothesis: candidate, vocabulary: "АМПП"), candidate)
        for vocabulary in ["", "АМПП, AMP", "АМПП, АМП", "АМПП, ААМП"] {
            XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
                hypothesis: candidate, vocabulary: vocabulary), vocabulary)
        }
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
            hypothesis: original, vocabulary: "АМПП"))
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: "Она ходила в AMX и недавно мы получили ответ.",
            candidate: candidate, hypothesis: candidate, vocabulary: "АМПП"))
    }

    func testDictionaryGuidedRetryCannotRewriteTheWholeTurn() {
        let original = "Мы её знакомили с руководителем PRTS. Мы можем онлайн сделать встречу."
        let hypothesis = "Мы её знакомили с руководителем ЦРТС. Мы можем онлайн сделать встречу."
        let candidate = "Мы её познакомили с руководителем ЦРТС. Мы можем онлайн организовать встречу."
        XCTAssertEqual(revisedText(original: original, candidate: candidate, corroboration: original,
            hypothesis: hypothesis, vocabulary: "ЦРТС", usesCyrillicHints: true), hypothesis)
        XCTAssertNil(revisedText(original: original,
            candidate: "Мы её познакомили с новым руководителем ЦРТС. Завтра будем онлайн обсуждать новую встречу.",
            corroboration: original, hypothesis: hypothesis, vocabulary: "ЦРТС", usesCyrillicHints: true))
    }

    func testUnhintedAcousticRecheckRetainsExistingAcceptanceRules() {
        let original = "Мы обсудим сроки запуска в четверг."
        let candidate = "Мы обсудим сроки запуска уже в четверг."
        XCTAssertEqual(revisedText(original: original, candidate: candidate, corroboration: candidate,
            hypothesis: candidate, vocabulary: "", usesCyrillicHints: false), candidate)
    }

    func testUnhintedRetryPreservesAnIndependentlyRecognizedNameAndPreposition() {
        let original = "Вчера мы обсуждали это с B2C, с Анжелой допустим, или с Сергеем после встречи."
        let corroboration = "Вчера мы обсудили это с BTS, с Анжелой, допустим, или с Сергеем после встречи."
        for candidate in [
            "Вчера мы обсуждали это с B2C, Санджело допустим, или с Сергеенко после встречи.",
            "Вчера мы обсуждали это с B2C, Анжелой допустим, или с Сергеем после встречи.",
            "Вчера мы обсуждали это с B2C, допустим, или с Сергеем после встречи.",
            "Вчера мы обсуждали это с B2C, с Анжелой около офиса или с Сергеем после встречи.",
        ] {
            XCTAssertNil(revisedText(original: original, candidate: candidate, corroboration: corroboration,
                hypothesis: corroboration, vocabulary: "Анжела, B2C", usesCyrillicHints: false), candidate)
        }
        let improved = "Вчера мы обсудили это с B2C, с Анжелой, допустим, или с Сергеем после встречи."
        XCTAssertEqual(revisedText(original: original, candidate: improved, corroboration: corroboration,
            hypothesis: corroboration, vocabulary: "Анжела, B2C", usesCyrillicHints: false),
            original.replacingOccurrences(of: "обсуждали", with: "обсудили"))
    }

    func testUnhintedRetryPreservesEachConfirmedAcronymOccurrence() {
        let original = "Мы работали с отделом ЦРТС. Мы можем назвать итог. Вчера говорили с отделом ЦРТС. Мы можем повторить."
        let candidate = "Мы работали с отделом ЦРТС. Мы можем назвать итог. Вчера говорили с отделом PRTS. Мы можем повторить."
        XCTAssertNil(revisedText(original: original, candidate: candidate, corroboration: original,
            hypothesis: original, vocabulary: "", usesCyrillicHints: false))
    }

    func testOnlyRussianUtterancesWithDifferentWordsAreRechecked() {
        XCTAssertTrue(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Поговорили с Анной и Столей", alternative: "Поговорили с Анной и с Толей"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "English", duration: 4, original: "We talked about the launch", alternative: "Мы говорили о запуске"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 1, original: "Да", alternative: "Ну да"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Всё готово, да.", alternative: "Все готово — да!"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Обсудили сроки запуска", alternative: ""))
    }

    func testUnrelatedOrInvalidAlternativesDoNotBiasRecognition() {
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Обсудили сроки запуска проекта", alternative: "Да"))
        XCTAssertFalse(RussianRecognition.shouldRecheck(language: "Russian", duration: 4, original: "Обсудили сроки запуска проекта", alternative: "Обсудили сроки запуска 项目"))
    }

    func testRecheckPreservesRecognizedVocabularyPhrases() {
        let original = "Проверим Северный Атлас и Геопэй в четверг"
        XCTAssertFalse(RussianRecognition.accepts(candidate: "Проверим северный адрес и геопий в четверг", original: original, vocabulary: "Северный Атлас, Геопэй"))
        XCTAssertTrue(RussianRecognition.accepts(candidate: "Проверим Северный Атлас и Геопэй уже в четверг.", original: original, vocabulary: "Северный Атлас, Геопэй"))
        XCTAssertTrue(RussianRecognition.accepts(candidate: "Проверим сроки запуска уже в четверг.", original: "Проверим сроки запуска в четверг", vocabulary: "Северный Атлас, Геопэй"))
    }

    func testARecheckCannotReplaceSpeechWithEmptyForeignOrTruncatedText() {
        let original = "Мы договорились проверить показатели перед запуском нового проекта"
        for text in ["", "Мы договорились", "Мы договорились проверить показатели перед запуском 新项目"] {
            XCTAssertFalse(RussianRecognition.accepts(candidate: text, original: original, vocabulary: ""))
        }
    }

    func testVocabularyMatchingUsesWholeWordsAndPhrases() {
        XCTAssertTrue(RussianRecognition.accepts(candidate: "На улице уже наступила весна", original: "На улице уже наступила весна", vocabulary: "Ли, Нау"))
        XCTAssertFalse(RussianRecognition.accepts(candidate: "Проверим новый атлас сегодня", original: "Проверим Северный Атлас сегодня", vocabulary: "Северный Атлас\nГеопэй"))
    }

    func testLocalRepairSplitsNameWithoutChangingVocabularyOrCopyingOverlappingSpeech() {
        let original = "Кто обсуждал это с B2C, Санджелой допустим или с Сергеем?"
        let candidate = "Кто обсудил это с BTUC, с Анжелой, допустим, или с Сергеем Петровым?"
        let corroboration = "Кто обсуждал это с BTUC, с Анжелой, допустим, или с Сергеем Петровым?"
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: "B2C"),
                       "Кто обсуждал это с B2C, с Анжелой допустим или с Сергеем?")
    }

    func testLocalRepairRestoresMissingPrepositionWithoutRepeatingIt() {
        let original = "Кто обсуждал это с B2C, Анжелой допустим, или с Сергеем?"
        let candidate = "Кто обсуждал это с BTUC, с Анжелой допустим, или с Сергеем?"
        let corroboration = "Кто обсудил это с BTUC, с Анжелой, допустим, или с Сергеем?"
        let corrected = "Кто обсуждал это с B2C, с Анжелой допустим, или с Сергеем?"
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: "B2C"), corrected)
        XCTAssertNil(RussianRecognition.localizedRepair(original: corrected, candidate: candidate, corroboration: corroboration, vocabulary: "B2C"))
    }

    func testLocalRepairKeepsExistingPrepositionsAndConjunctions() {
        let candidate = "Мы обсуждали вопрос с Анжелой и Сергеем перед встречей."
        for preceding in ["между", "перед", "над", "со", "и"] {
            let original = "Мы обсуждали вопрос \(preceding) Анжелой и Сергеем перед встречей."
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: ""), original)
        }
    }

    func testLocalRepairCorrectsAcronymWithoutCopyingAnExtraPrefix() {
        let original = "Вчера говорили с руководителем PRTS. Мы можем обсудить сроки."
        let candidate = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        let corroboration = "Вчера говорили с руководителем PR-ЦРТС. Мы можем обсудить сроки."
        let expected = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: ""), expected)
        XCTAssertEqual(RussianRecognition.localizedRepair(original: original, candidate: corroboration, corroboration: corroboration, vocabulary: ""), expected)
    }

    func testDictionaryRepairChangesOnlyExplicitAcronymAtConfirmedLocation() {
        let original = "Вчера говорили с руководителем PRTS. Мы можем обсудить сроки."
        let candidate = "Недавно встретились с руководителем ЦРТС. Мы можем обсудить другое."
        let hypothesis = "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки."
        XCTAssertEqual(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate, hypothesis: hypothesis, vocabulary: "B2C; ЦРТС"),
                       "Вчера говорили с руководителем ЦРТС. Мы можем обсудить сроки.")

        for vocabulary in ["", "цртс", "ЦРТС Новгорода", "ЦРТС, PRTS"] {
            XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate, hypothesis: hypothesis, vocabulary: vocabulary))
        }
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
            hypothesis: "Вчера говорили с коллегой ЦРТС. Мы можем обсудить сроки.", vocabulary: "ЦРТС"))
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original + " " + original, candidate: candidate,
            hypothesis: hypothesis, vocabulary: "ЦРТС"))
    }

    func testDictionaryRepairDoesNotTreatPromptedNamesAsAcousticEvidence() {
        let original = "Вчера мы говорили Санджелой по этому вопросу."
        let candidate = "Вчера мы говорили с Анжелой по этому вопросу."
        XCTAssertNil(RussianRecognition.localizedDictionaryRepair(original: original, candidate: candidate,
            hypothesis: candidate, vocabulary: "Анжела, с Анжелой"))
    }

    func testLocalRepairRequiresIndependentAgreementAtTheSameOccurrence() {
        let original = "Мы уже говорили с Анной и Столей по этому вопросу."
        let candidate = "Мы уже говорили с Анной и с Толей по этому вопросу."
        for corroboration in [
            "Мы уже говорили с Анной и с Колей по этому вопросу.",
            "С Толей разговаривали вчера. Мы уже говорили с Анной и Столей по этому вопросу.",
            "Мы уже говорили с Анной и с. Толей по этому вопросу.",
        ] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: corroboration, vocabulary: ""))
        }
    }

    func testLocalRepairLeavesAmbiguousOccurrencesUnchanged() {
        let original = "Вчера говорили Столей по этому вопросу, сегодня говорили Столей по этому вопросу."
        let candidate = "Вчера говорили с Толей по этому вопросу, сегодня говорили с Толей по этому вопросу."
        XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: ""))
    }

    func testLocalRepairProtectsEachDictionaryOccurrence() {
        let original = "Мы уже говорили с Анной и Столей по этому вопросу. Это был Столей."
        let candidate = "Мы уже говорили с Анной и с Толей по этому вопросу. Это был Столей."
        XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: "Столей"))
    }

    func testLocalRepairLeavesEnglishAndUnrelatedAcronymsUnchanged() {
        for (original, candidate) in [
            ("We discussed PRTS in the report.", "We discussed ЦРТС in the report."),
            ("Мы обсуждали с командой NASA. Завтра будет новая встреча.", "Мы обсуждали с командой ЦРТС. Завтра будет новая встреча."),
            ("Мы обсуждали PRTS с командой вчера.", "Мы обсуждали PRTS с командой вчера. ЦРТС тоже присутствовали."),
        ] {
            XCTAssertNil(RussianRecognition.localizedRepair(original: original, candidate: candidate, corroboration: candidate, vocabulary: ""))
        }
    }
    func testNumericNearMissNeedsFreshAnchoredAudioAndPreservesEnding() {
        let vocabulary = SpokenVocabulary("2ГИС, 7АБВ")
        let source = "Ты пересекался с Дугисом до этого много."
        XCTAssertEqual(vocabulary.numericRepairContext(in: source), "2ГИС'ом")
        XCTAssertEqual(vocabulary.restoringNumericName(original: source, candidate: "Ты пересекался с 2ГИС'ом до этого давно."),
                       "Ты пересекался с 2ГИС'ом до этого много.")
        let other = "Мы вчера говорили в Семабве про наш план."
        XCTAssertEqual(vocabulary.numericRepairContext(in: other), "7АБВ'е")
        XCTAssertEqual(vocabulary.restoringNumericName(original: other, candidate: "Мы вчера говорили в 7АБВ'е про наш план."),
                       "Мы вчера говорили в 7АБВ'е про наш план.")
        for candidate in ["Ты пересекался с 2ГИС до этого много.", "Ты пересекался с 2ГИС'е до этого много.",
                          "Ты общался с 2ГИС'ом до этого много.", "Ты пересекался с 2ГИС'ом после этого много.",
                          "Ты пересекался с `2ГИС'ом` до этого много.",
                          "Ты пересекался с 2ГИС'ом до этого и ты пересекался с 2ГИС'ом до этого много."] {
            XCTAssertNil(vocabulary.restoringNumericName(original: source, candidate: candidate), candidate)
        }
    }

    func testNumericNearMissRejectsAmbiguityWeakFormsAndProtectedText() {
        for (source, glossary) in [
            ("Ты пересекался с Дугисом до этого много.", "2ГИС, Дугис"),
            ("Ты пересекался с Дугисом до этого много.", "2ГИС, 2ГИС'ом"),
            ("Ты пересекался с Дугисом до этого много.", "2ГИС, пересекался с Дугисом"),
            ("Мы говорили про Дагестан до этого много.", "2ГИС"),
            ("Мы говорили про Догес до этого много.", "2ГИС"),
            ("Ты пересекался с «Дугисом» до этого много.", "2ГИС"),
            ("Ты пересекался с `Дугисом` до этого много.", "2ГИС"),
            ("Ты пересекался с https://example.com/Дугисом до этого много.", "2ГИС"),
            ("Ты пересекался с 2ГИС'ом до этого много.", "2ГИС"),
            ("Ты пересекался с Дугисом до этого и ты пересекался с Дугисом до этого.", "2ГИС")
        ] {
            XCTAssertNil(SpokenVocabulary(glossary).numericRepairContext(in: source), source)
        }
    }

}
