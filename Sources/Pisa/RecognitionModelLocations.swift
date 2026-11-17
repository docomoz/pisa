import Foundation

struct RecognitionModelLocations {
    let primary: URL
    let verifier: URL

    init(preferences: Preferences, models: URL) throws {
        primary = try Self.primary(preferences: preferences, models: models)
        verifier = try Self.verifier(preferences: preferences, models: models)
    }

    static func primary(preferences: Preferences, models: URL) throws -> URL {
        try resolve(preferences.parakeetModelBookmark,
                    fallback: models.appendingPathComponent(SpeechModelFiles.primaryDirectoryName))
    }

    static func verifier(preferences: Preferences, models: URL) throws -> URL {
        try resolve(preferences.modelBookmark,
                    fallback: models.appendingPathComponent(SpeechModelFiles.verifierDirectoryName))
    }

    private static func resolve(_ bookmark: Data?, fallback: URL) throws -> URL {
        guard let bookmark else { return fallback }
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
    }
}
