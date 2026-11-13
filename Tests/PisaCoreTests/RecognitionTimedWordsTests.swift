import XCTest
@testable import PisaCore

final class RecognitionTimedWordsTests: XCTestCase {
    func testSentencePieceAndPunctuationMatchOriginalWords() {
        let words = RecognitionTimedWords.map(text: "Привет, мир!", tokens: ["▁При", "вет", ",", "▁мир", "!"],
            timestamps: [0.1, 0.3, 0.5, 0.7, 1.1], duration: 1.3)
        XCTAssertEqual(words.map(\.text), ["Привет", "мир"])
        XCTAssertEqual(words[0].start, 0.1, accuracy: 0.0001)
        XCTAssertEqual(words[0].end, 0.5, accuracy: 0.0001)
        XCTAssertEqual(words[1].start, 0.7, accuracy: 0.0001)
        XCTAssertEqual(words[1].end, 1.1, accuracy: 0.0001)
    }

    func testOneTokenWithTwoWordsUsesConservativeSharedTiming() {
        let words = RecognitionTimedWords.map(text: "да нет", tokens: ["▁да▁нет"], timestamps: [0.2], duration: 1)
        XCTAssertEqual(words.map(\.text), ["да", "нет"])
        XCTAssertTrue(words.allSatisfy { $0.start == 0.2 && $0.end == 1 })
    }

    func testMismatchMissingAndInvalidTimingFailClosed() {
        XCTAssertTrue(RecognitionTimedWords.map(text: "другая речь", tokens: ["▁да"], timestamps: [0], duration: 1).isEmpty)
        XCTAssertTrue(RecognitionTimedWords.map(text: "да", tokens: ["▁да"], timestamps: [], duration: 1).isEmpty)
        XCTAssertTrue(RecognitionTimedWords.map(text: "да", tokens: ["▁да"], timestamps: [.nan], duration: 1).isEmpty)
        XCTAssertTrue(RecognitionTimedWords.map(text: "да нет", tokens: ["▁да", "▁нет"], timestamps: [0.8, 0.2], duration: 1).isEmpty)
    }

    func testOutOfRangeTimestampsAreClamped() {
        let words = RecognitionTimedWords.map(text: "да нет", tokens: ["▁да", "▁нет"], timestamps: [-1, 2], duration: 1)
        XCTAssertEqual(words.map(\.start), [0, 1])
        XCTAssertEqual(words.map(\.end), [1, 1])
    }
}
