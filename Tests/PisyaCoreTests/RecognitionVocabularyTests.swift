import XCTest
@testable import PisyaCore

final class RecognitionVocabularyTests: XCTestCase {
    func testSharedAbbreviationEndingsAndExplicitCompetingEntries() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "AIем, LLMами, 2GISu и 2GISom", vocabulary: "AI, LLM, 2ГИС"),
                       "AI'ем, LLM'ами, 2ГИС'у и 2ГИС'ом")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "AIM и API", vocabulary: "AI, API"), "AIM и API")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "2GISA", vocabulary: "2GIS, 2GISA"), "2GISA")
    }
    func testDictionaryControlsSpellingOfNumericAcronymsAndTheirEndings() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "внутри два ГИСа, в два гисе и через 2гис", vocabulary: "2ГИС, iPhone"), "внутри 2ГИС'а, в 2ГИС'е и через 2ГИС")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Проект семь АБВ и 7абвом", vocabulary: "7АБВ"), "Проект 7АБВ и 7АБВ'ом")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "внутри 2GISа, два GIS и 2GISa", vocabulary: "2ГИС"), "внутри 2ГИС'а, 2ГИС и 2ГИС'а")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "внутри Двогиса", vocabulary: "2ГИС"), "внутри 2ГИС'а")
    }

    func testItDoesNotGuessWordsOrChangeWordsOutsideTheDictionary() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "два ГИСа, два проекта ГИС и 12гис", vocabulary: "Геопэй"), "два ГИСа, два проекта ГИС и 12гис")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "два проекта ГИС и 12гис", vocabulary: "2ГИС"), "два проекта ГИС и 12гис")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Марена и Спутнек", vocabulary: "Марина, Спутник"), "Марена и Спутнек")
    }

    func testExactPhrasesUseTheUsersCaseAndWholeWordBoundaries() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "IPHONE, confluence и северный\u{00a0}атлас. Суперiphone.", vocabulary: "iPhone; Confluence\nСеверный Атлас"), "iPhone, Confluence и Северный Атлас. Суперiphone.")
    }

    func testExplicitCyrillicCompoundsJoinSplitSpellingAndPreserveCaseEndings() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Кино Поиск, Кино Поиска и в кино поиске.", vocabulary: "Кинопоиск"),
                       "Кинопоиск, Кинопоиска и в Кинопоиске.")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Открой бренд Бук и пользуйся бренд буком.", vocabulary: "брендбук"),
                       "Открой брендбук и пользуйся брендбуком.")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Проверим фото аппаратами.", vocabulary: "фотоаппарат"), "Проверим фотоаппаратами.")
    }

    func testCompoundJoiningRequiresExplicitUnambiguousWholeWords() {
        let text = "Кино Поиска и бренд Бук."
        XCTAssertEqual(RecognitionVocabulary.apply(to: text, vocabulary: ""), text)
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Кино Поиск и Кино Поиска.", vocabulary: "Кинопоиск, Кино Поиск"), "Кино Поиск и Кино Поиска.")
        for text in ["Кино, Поиск.", "Кино Поисковый.", "Суперкино Поиск.", "Кин Поиск."] {
            XCTAssertEqual(RecognitionVocabulary.apply(to: text, vocabulary: "Кинопоиск"), text)
        }
        XCTAssertEqual(RecognitionVocabulary.apply(to: "На род и под ход.", vocabulary: "народ, подход"), "На род и под ход.")
    }

    func testDictionaryRestoresYoAndRegularRussianInflections() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Дегтева, Дегтевой и Дегтеву.", vocabulary: "Дёгтева"), "Дёгтева, Дёгтевой и Дёгтеву.")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "елка и елкой", vocabulary: "ёлка"), "ёлка и ёлкой")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "все и Игнатьовым", vocabulary: "Дёгтева, Игнатов"), "все и Игнатьовым")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Дегтевой и Дёгтевой", vocabulary: "Дегтева, Дёгтева"), "Дегтевой и Дёгтевой")
    }

    func testDictionaryControlsCompoundHyphensWithRegularEndings() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "барбекю-шница и барбекю-шницы", vocabulary: "барбекюшница"), "барбекюшница и барбекюшницы")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Соцдемпрофиль и соцдем профилем", vocabulary: "соцдем-профиль"), "Соцдем-профиль и соцдем-профилем")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "барбекю, шница и соцдемный профиль", vocabulary: "барбекюшница, соцдем-профиль"), "барбекю, шница и соцдемный профиль")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "барбекю-шница", vocabulary: "барбекюшница, барбекю-шница"), "барбекю-шница")
    }

    func testNumericAcronymEndingsUseOneStableApostropheAndRemainIdempotent() {
        let expected = "с 2ГИС'ом, в 2ГИС'е и 2ГИС"
        XCTAssertEqual(RecognitionVocabulary.apply(to: "с 2ГИСом, в 2ГИС’е и 2ГИС", vocabulary: "2ГИС"), expected)
        XCTAssertEqual(RecognitionVocabulary.apply(to: expected, vocabulary: "2ГИС"), expected)
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Двусом и Догесе", vocabulary: "2ГИС"), "Двусом и Догесе")
    }

    func testCommonDictionarySpellingPreservesSentenceInitialCapitalization() {
        let vocabulary = "брендбук, барбекюшница, соцдем-профиль, iPhone, Кинопоиск"
        let source = "Бренд Бук обновили. Барбекю-шницы готовы! «Соцдемпрофиль готов».\nБрендбук открыли. Открой Брендбук и IPHONE, затем кинопоиск."
        let expected = "Брендбук обновили. Барбекюшницы готовы! «Соцдемпрофиль готов».\nБрендбук открыли. Открой брендбук и iPhone, затем Кинопоиск."
        XCTAssertEqual(RecognitionVocabulary.apply(to: source, vocabulary: vocabulary), expected)
        XCTAssertEqual(RecognitionVocabulary.apply(to: expected, vocabulary: vocabulary), expected)
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Соцдемпрофиль готов.", vocabulary: vocabulary), "Соцдем-профиль готов.")
    }

    func testNumericAcronymObliquePrefixesKeepTheirRecognizedEndings() {
        XCTAssertEqual(RecognitionVocabulary.apply(to: "с Двугисом и в двух ГИСе", vocabulary: "2ГИС"), "с 2ГИС'ом и в 2ГИС'е")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "с трёх АБВом и СемиАБВе", vocabulary: "3АБВ, 7АБВ"), "с 3АБВ'ом и 7АБВ'е")
        XCTAssertEqual(RecognitionVocabulary.apply(to: "в восьми АБВе и пяти АБВах", vocabulary: "8АБВ, 5АБВ"), "в 8АБВ'е и 5АБВ'ах")
        let text = "Двугисом, Догисе, Двух Гисоном, Дагестан, Доге, до Гисе, двух проектов ГИС."
        XCTAssertEqual(RecognitionVocabulary.apply(to: text, vocabulary: ""), text)
        XCTAssertEqual(RecognitionVocabulary.apply(to: "Двух Гисоном, до Гисе, двух проектов ГИС", vocabulary: "2ГИС"), "Двух Гисоном, до Гисе, двух проектов ГИС")
    }
}
