import XCTest
@testable import PisyaCore

final class TranscriptDisplayTests: XCTestCase {
    func testDisplayCapitalizesFirstLetterWithoutChangingTheRest() {
        let examples = [
            ("онлайн транспорт то никакая", "Онлайн транспорт то никакая"),
            ("  «сразу же» iPhone", "  «Сразу же» iPhone"),
            ("123 test", "123 Test"),
            ("Уже готово", "Уже готово"),
            ("...", "..."),
            ("", "")
        ]
        for (original, expected) in examples {
            let segment = TranscriptSegment(start: 0, end: 1, speaker: "Я", text: original)
            XCTAssertEqual(segment.displayText, expected)
            XCTAssertEqual(segment.text, original)
        }
    }
}
