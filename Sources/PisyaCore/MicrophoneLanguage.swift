import Foundation

/// Short replies have little language evidence. Never infer an explicit language
/// from a decoder's fallback value for a malformed or missing prefix.
public enum MicrophoneLanguage {
    public static func shouldRetryRussian(duration: Double, language: String?, languageIsExplicit: Bool, text: String,
                                          supportedLanguages: [String]) -> Bool {
        guard languageIsExplicit, duration.isFinite, duration > 0, duration <= 1.5,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !["none", "russian", ""].contains(language) else { return false }
        return supportedLanguages.contains { $0.lowercased() == language }
    }
}
