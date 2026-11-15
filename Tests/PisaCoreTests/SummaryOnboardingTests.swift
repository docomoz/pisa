import XCTest
@testable import PisaCore

final class SummaryOnboardingTests: XCTestCase {
    func testConfigurationPreservesSpacesUnicodeQuotesAndControlCharacters() throws {
        for path in ["/Applications/Pisa.app/Contents/Helpers/pisa-mcp", "/Папка с пробелами/\"Pisa\"\\test\n\t\u{7F}.app/Contents/Helpers/pisa-mcp"] {
            let configuration = MCPClientConfiguration.toml(commandPath: path)
            let prefix = "[mcp_servers.pisa]\ncommand = "
            XCTAssertTrue(configuration.hasPrefix(prefix))
            let literal = String(configuration.dropFirst(prefix.count))
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(literal.utf8)), path)
            XCTAssertEqual(configuration.components(separatedBy: "\n").count, 2)
        }
    }

    func testExistingPreferencesShowOnboardingWithoutResettingOtherSettings() throws {
        var preferences = Preferences()
        preferences.mcpEnabled = false
        preferences.vocabulary = "Свой словарь"
        let data = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["summaryOnboardingAcknowledged"])
        let restored = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertTrue(restored.showsSummaryOnboarding)
        XCTAssertFalse(restored.mcpEnabled)
        XCTAssertEqual(restored.vocabulary, preferences.vocabulary)
    }

    func testAcknowledgementSurvivesReopeningLibraryAndOtherPreferenceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var preferences = try library.preferences()
        XCTAssertTrue(preferences.showsSummaryOnboarding)
        preferences.summaryOnboardingAcknowledged = true
        try library.savePreferences(preferences)
        let reopened = try MeetingLibrary(root: root)
        preferences = try reopened.preferences()
        XCTAssertFalse(preferences.showsSummaryOnboarding)
        preferences.mcpEnabled = false
        try reopened.savePreferences(preferences)
        XCTAssertFalse(try library.preferences().showsSummaryOnboarding)
    }
}
