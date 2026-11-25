import XCTest
@testable import PisaCore

final class RecognitionNumberMagnitudeTests: XCTestCase {
    private let original = "По расчётам общий тираж составит 1 100 000 000 000 000 экземпляров к осени."
    private let acoustic = "По расчётам общий тираж составит 1 100 000 экземпляров к осени."

    func testBothIndependentReadingsCanConfirmDroppedGroupsOfZeros() {
        XCTAssertTrue(RecognitionNumberMagnitude.needsVerification(original))
        XCTAssertTrue(RecognitionNumberMagnitude.hasShorterReading(original: original, acoustic: acoustic))
        for reading in ["миллион сто", "один миллион сто тысяч", "1 100 000"] {
            let reread = acoustic.replacingOccurrences(of: "1 100 000", with: reading)
            XCTAssertEqual(RecognitionNumberMagnitude.revisedText(original: original, acoustic: acoustic,
                reread: reread), acoustic, reading)
        }
    }

    func testDifferentAmountAndUnrelatedWordsStayInThePrimaryText() {
        let primary = "Отпечатали 24 обложки. По смете общий тираж составит 2 500 000 000 000 экземпляров к лету!"
        let independent = "Записали 42 обложки. По смете общий тираж составит 2 500 000 экземпляров к лету."
        let verifier = "Записали 42 обложки. По смете общий тираж составит два миллиона пятьсот тысяч экземпляров к лету."
        let expected = primary.replacingOccurrences(of: "2 500 000 000 000", with: "2 500 000")
        XCTAssertEqual(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: independent,
            reread: verifier), expected)
    }

    func testVerifierCanConfirmTheGrammaticalGenderOfOneAndTwo() {
        for (unit, digits, spoken, different) in [
            ("Заявок", "2", "две", "одна"),
            ("Заявок", "21", "двадцать одна", "двадцать одна тысяча"),
            ("Обращений", "21", "двадцать одно", "двадцать два"),
            ("Заявок", "122", "сто двадцать две", "сто двенадцать")
        ] {
            func sentence(_ amount: String) -> String { "\(unit) поступило \(amount), включая повторные." }
            let primary = sentence(digits + " 000")
            let acoustic = sentence(digits)
            XCTAssertEqual(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: acoustic,
                reread: sentence(spoken)), acoustic, spoken)
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: acoustic,
                reread: sentence(different)), different)
        }
        XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: "2 000", acoustic: "2", reread: "Две."))
    }

    func testCorrectLargeAmountsSurviveOneDisagreeingModel() {
        XCTAssertFalse(RecognitionNumberMagnitude.hasShorterReading(original: original, acoustic: original))
        for (first, second) in [(original, original), (acoustic, original), (original, acoustic),
                                (acoustic, ""), ("", acoustic)] {
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: original, acoustic: first, reread: second))
        }
        let disagrees = acoustic.replacingOccurrences(of: "1 100 000", with: "миллион двести тысяч")
        XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: original, acoustic: acoustic, reread: disagrees))
    }

    func testOrdinaryDisagreementsCannotChangeTheDigits() {
        XCTAssertFalse(RecognitionNumberMagnitude.needsVerification("Следующий тираж обсудим завтра."))
        XCTAssertFalse(RecognitionNumberMagnitude.needsVerification("Подтвердили 24 заявки в этом месяце."))
        for (before, after) in [("24", "42"), ("1 100 000", "1 200 000"),
                                ("1 100 000 000 001", "1 100 000"),
                                ("1 100 000 000 000", "1 000 000")] {
            let primary = "В отчёте общий тираж составил \(before) экземпляров за год."
            let reading = "В отчёте общий тираж составил \(after) экземпляров за год."
            XCTAssertFalse(RecognitionNumberMagnitude.hasShorterReading(original: primary, acoustic: reading))
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: reading, reread: reading))
        }
    }

    func testEvidenceMustIdentifyTheSameOccurrence() {
        let unrelated = "Для ремонта завтра потребуется 1 100 000 отдельных деталей."
        let repeated = original + " " + original
        for (primary, first, second) in [(original, acoustic, unrelated), (original, unrelated, acoustic),
                                         (repeated, acoustic, acoustic)] {
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: first, reread: second))
        }
    }

    func testNumericIdentifiersAndFractionsCannotBePartiallyRewritten() {
        for token in ["RU1 100 000 000 000", "01 100 000 000 000", "1 100 000 000 000-A",
                      "1 100 000 000 000,25", "1 100 000 000 000.25"] {
            let primary = "В таблице нашли значение \(token) для этой строки."
            let shorter = "В таблице нашли значение 1 100 000 для этой строки."
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: shorter, reread: shorter), token)
        }
    }

    func testStandaloneIntegerNeedsThreeCompleteReadings() {
        let primary = "1 100 000 000 000!"
        XCTAssertTrue(RecognitionNumberMagnitude.isStandaloneCandidate(primary))
        XCTAssertTrue(RecognitionNumberMagnitude.needsVerification(primary))
        for reading in ["миллион сто.", "1 100 000"] {
            XCTAssertEqual(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: "1 100 000.",
                reread: reading), "1 100 000!")
        }
        XCTAssertEqual(RecognitionNumberMagnitude.revisedText(original: "1000000000", acoustic: "1000000",
            reread: "Миллион."), "1000000")
        for (first, second) in [("почти 1 100 000", "миллион сто"), ("1 100 000", "больше миллиона"),
                                ("1 100 000 штук", "1 100 000"), ("1 100 000", "≈1 100 000")] {
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: first, reread: second))
        }
        XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: "3000", acoustic: "3", reread: "Три!"))
    }

    func testDecimalCurrencyPercentAndComparisonMarksRemainBoundToTheirNumber() {
        let sentence = "По шкале доля @ к концу."
        let unmarked = sentence.replacingOccurrences(of: "@", with: "125")
        for form in [".125000", ",125000", "$125000", "125000 ₽", "125000%", "125000‰", "≈125000",
                     "<125000", "≥ 125000", "125000 ×"] {
            let primary = sentence.replacingOccurrences(of: "@", with: form)
            XCTAssertFalse(RecognitionNumberMagnitude.hasShorterReading(original: primary, acoustic: unmarked), form)
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: unmarked, reread: unmarked), form)
        }
        let plain = sentence.replacingOccurrences(of: "@", with: "125000")
        let scaled = sentence.replacingOccurrences(of: "@", with: "125%")
        XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: plain, acoustic: unmarked, reread: scaled))
        for (before, after) in [("1 000 000%", "1 000‰"), ("$1 000 000", "€1 000")] {
            let primary = sentence.replacingOccurrences(of: "@", with: before)
            let shorter = sentence.replacingOccurrences(of: "@", with: after)
            XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: primary, acoustic: shorter, reread: shorter))
        }
    }

    func testStandaloneSymbolsQualifiersAndCodesAreProtected() {
        for source in ["1,100,000", "1.100000", ".1100000", "1100000.00", "+1100000", "−1100000",
                       "001100000", "#1100000", "`1100000`", "«1100000»", "(1100000)", "$1100000",
                       "1100000%", "№ 1100000", "1100000 штук", "около 1100000", "ID 1100000"] {
            XCTAssertFalse(RecognitionNumberMagnitude.isStandaloneCandidate(source), source)
            XCTAssertFalse(RecognitionNumberMagnitude.hasShorterReading(original: source, acoustic: "1100"), source)
        }
        let code = "Reference number 1100000 is valid."
        let shorter = code.replacingOccurrences(of: "1100000", with: "1100")
        XCTAssertNil(RecognitionNumberMagnitude.revisedText(original: code, acoustic: shorter, reread: shorter))
    }
}
