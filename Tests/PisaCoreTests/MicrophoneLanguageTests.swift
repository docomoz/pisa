import XCTest
@testable import PisaCore

final class MicrophoneLanguageTests: XCTestCase {
    func testAbstentionAndFallbackLanguagesNeverForceSpeech() {
        let supported = ["Russian", "English", "Hindi", "Chinese"]
        XCTAssertFalse(MicrophoneLanguage.shouldRetryRussian(duration: 0.6, language: "English", languageIsExplicit: false, text: "the", supportedLanguages: supported))
        XCTAssertTrue(MicrophoneLanguage.shouldRetryRussian(duration: 0.6, language: "English", languageIsExplicit: true, text: "the", supportedLanguages: supported))
        for language: String? in [nil, "", "None", " none ", "Russian", "Unknown"] {
            XCTAssertFalse(MicrophoneLanguage.shouldRetryRussian(duration: 0.6, language: language, languageIsExplicit: true, text: "Да", supportedLanguages: supported))
        }
        XCTAssertFalse(MicrophoneLanguage.shouldRetryRussian(duration: 0.6, language: "Hindi", languageIsExplicit: true, text: " \n", supportedLanguages: supported))
        XCTAssertFalse(MicrophoneLanguage.shouldRetryRussian(duration: 0.6, language: "Hindi", languageIsExplicit: true, text: "दा", supportedLanguages: []))
    }
    func testOnlyShortExplicitLanguageGetsASecondDecoding() {
        for duration in [0.1, 0.6, 1.5] {
            XCTAssertTrue(MicrophoneLanguage.shouldRetryRussian(duration: duration, language: "Hindi", languageIsExplicit: true, text: "दा", supportedLanguages: ["Hindi"]))
        }
        for duration in [0, -1, 1.501, 5, Double.nan, Double.infinity] {
            XCTAssertFalse(MicrophoneLanguage.shouldRetryRussian(duration: duration, language: "Hindi", languageIsExplicit: true, text: "दा", supportedLanguages: ["Hindi"]))
        }
    }
}
