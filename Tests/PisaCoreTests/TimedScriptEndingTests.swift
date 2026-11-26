import XCTest
@testable import PisaCore

final class TimedScriptEndingTests: XCTestCase {
    private let source = "Мы подключаємо ти ви вчухолодільнику."
    private let opening = "Мы подключаем"
    private let right = "Теперь идём дальше"

    private func recover(_ original: String? = nil, wideNoun: String = "холодильнику",
                         wideVerifier: String = "тучухлодильнику", exactNoun: String = "холодильнику",
                         exactVerifier: String = "тучухлодильнику", exactSpelling: String = "похолодільнику",
                         language: String = "Russian", drift: Double = 0, neighbor: String? = nil,
                         middle: String = "та штука по", protect: Set<String> = []) -> String? {
        let plan = RecognitionContext.ContextualScriptRepair(source: original ?? source, terms: [], scriptMismatch: true,
            protectedKeys: protect, writtenKeys: protect)
        func timed(_ words: [String], starts: [Double], end: Double) -> RecognitionAcousticResult {
            .init(text: words.joined(separator: " "), words: words.enumerated().map { i, word in
                .init(text: word, start: starts[i], end: i + 1 < starts.count ? starts[i + 1] : end)
            })
        }
        let exactWords = ["Мы", "подключаем"] + middle.split(separator: " ").map(String.init) + [exactNoun]
        let wideWords = ["Раньше"] + exactWords + right.split(separator: " ").map(String.init)
        let narrow = timed(exactWords, starts: [0, 0.3, 0.9, 1.0, 1.3, 1.5 + drift], end: 2.1)
        let wide = timed(wideWords, starts: [0, 1.0, 1.3, 1.9, 2.0, 2.3, 2.5, 3.2, 3.4, 3.7], end: 4)
        return plan.timedFragments(acoustic: wide, target: 1..<3.1,
            primary: "Раньше " + opening + " там в " + wideNoun + " " + (neighbor ?? right),
            verifier: "Раньше " + opening + " там и " + wideVerifier + " " + right, language: "Russian",
            exact: { .init(acoustic: narrow, verifier: opening + " там и " + exactVerifier, language: language) },
            exactPrimary: { "Мы подключаємо ви " + exactSpelling })
    }

    func testTimedEndingSurvivesFusionButItsPrepositionNeedsIndependentWordBoundaries() {
        let text = "Мы подключаємо ти ви вчухолодільнику."
        XCTAssertEqual(recover(text), "Мы подключаем… холодильнику.")
        XCTAssertEqual(recover(text, wideNoun: "по холодильнику", wideVerifier: "по холодильнику",
                               exactVerifier: "по холодильнику"), "Мы подключаем… по холодильнику.")
        XCTAssertEqual(recover(text, wideNoun: "по холодильнику"), "Мы подключаем… холодильнику.")
    }

    func testCompoundsCaseEndingsNeighborsAndLanguageSwitchesVetoSplitting() {
        let text = "Мы подключаємо ти ви вчухолодільнику."
        XCTAssertNil(recover(text, wideNoun: "суперхолодильнику"))
        XCTAssertNil(recover("Мы подключаємо ти ви мініхолодільнику.", wideNoun: "мини-холодильнику",
                             wideVerifier: "минихолодильнику", exactVerifier: "минихолодильнику",
                             exactSpelling: "минихолодільнику"))
        XCTAssertNil(recover(text, exactSpelling: "похолодільника"))
        XCTAssertNil(recover(text, wideVerifier: "чухолодильника"))
        XCTAssertNil(recover(text, exactVerifier: "чухолодильнику позже"))
        XCTAssertNil(recover(text, drift: 0.25))
        XCTAssertNil(recover(text, neighbor: "А дальше отпуск"))
        XCTAssertNil(recover(text, language: "Ukrainian"))
        XCTAssertNil(recover(text, language: "Belarusian"))
        XCTAssertNil(recover("«Мы подключаємо ти ви вчухолодільнику»."))
    }

    func testElisionPreservesNamesAmountsNegationsAndIntelligibleWords() {
        for word in ["Ян", "семь", "дві", "тры", "3", "не", "счёт", "та"] {
            XCTAssertNil(recover("Мы подключаємо " + word + " ви вчухолодільнику."), word)
        }
        XCTAssertNil(recover("Мы подключаємо ти ви вчухолодільнику.", middle: "не штука по"))
        XCTAssertNil(recover("Мы подключаємо ти ви вчухолодільнику.", middle: "та Иван по"))
        XCTAssertNil(recover("Мы подключаємо ти ви вчухолодільнику.", exactVerifier: "Ян тучухлодильнику"))
        XCTAssertNil(recover("Мы подключаємо ти ви вчухолодільнику.", protect: ["ви"]))
    }
}
