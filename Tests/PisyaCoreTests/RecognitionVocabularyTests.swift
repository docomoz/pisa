import XCTest
@testable import PisyaCore

final class RecognitionVocabularyTests: XCTestCase {
    func testDictionaryControlsSpellingOfNumericAcronymsAndTheirEndings() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "внутри два ГИСа, в два гисе и через 2гис", vocabulary: "2ГИС, iPhone"), "внутри 2ГИС, в 2ГИС и через 2ГИС")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Проект семь АБВ и 7абвом", vocabulary: "7АБВ"), "Проект 7АБВ и 7АБВ")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "внутри 2GISа, два GIS и 2GISa", vocabulary: "2ГИС"), "внутри 2ГИС, 2ГИС и 2ГИС")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "внутри Двогиса", vocabulary: "2ГИС"), "внутри 2ГИС")
    }

    func testItDoesNotGuessWordsOrChangeWordsOutsideTheDictionary() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "два ГИСа, два проекта ГИС и 12гис", vocabulary: "Геопэй"), "два ГИСа, два проекта ГИС и 12гис")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "два проекта ГИС и 12гис", vocabulary: "2ГИС"), "два проекта ГИС и 12гис")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Марена и Спутнек", vocabulary: "Марина, Спутник"), "Марена и Спутнек")
    }

    func testExactPhrasesUseTheUsersCaseAndWholeWordBoundaries() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "IPHONE, confluence и северный\u{00a0}атлас. Суперiphone.", vocabulary: "iPhone; Confluence\nСеверный Атлас"), "iPhone, Confluence и Северный Атлас. Суперiphone.")
    }
}
