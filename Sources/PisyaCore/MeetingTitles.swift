import Foundation

public struct MeetingTitleRequest: Sendable {
    public enum Kind: Sendable { case summary, title }
    public let kind: Kind
    public let text: String
}

/// Bounded, sequential reduction includes the whole transcript, including its final decisions.
public struct MeetingTitleComposer: Sendable {
    public typealias Generate = @Sendable (MeetingTitleRequest) async throws -> String
    private static let directTitleLimit = 5000
    private let characterLimit: Int
    private let generate: Generate
    public init(characterLimit: Int = 24000, generate: @escaping Generate) {
        self.characterLimit = max(256, characterLimit); self.generate = generate
    }

    public func title(for segments: [TranscriptSegment]) async throws -> String? {
        try Task.checkCancellation()
        var text = segments.sorted { $0.start < $1.start }.compactMap { segment -> String? in
            let clean = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingSpeechText.accepts(clean) ? clean : nil
        }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        if text.count > min(Self.directTitleLimit, characterLimit) {
            // Keep the agenda and follow-up together when the transcript fits in one pass.
            repeat {
                var summaries: [String] = []
                for chunk in chunks(text) {
                    try Task.checkCancellation()
                    let summary = try await generate(.init(kind: .summary, text: chunk))
                    try Task.checkCancellation()
                    let clean = Self.withoutReasoning(summary).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard MeetingSpeechText.accepts(clean) else { throw PisyaError.message("Не удалось кратко пересказать часть встречи") }
                    summaries.append(String(clean.prefix(min(1000, characterLimit / 3))))
                }
                text = summaries.joined(separator: "\n")
            } while text.count > characterLimit
        }
        try Task.checkCancellation()
        let output = try await generate(.init(kind: .title, text: text))
        try Task.checkCancellation()
        return Self.cleanTitle(output)
    }

    private func chunks(_ text: String) -> [String] {
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: characterLimit, limitedBy: remaining.endIndex) ?? remaining.endIndex
            if end != remaining.endIndex,
               let space = remaining[..<end].lastIndex(where: { $0.isWhitespace }),
               remaining.distance(from: remaining.startIndex, to: space) > characterLimit / 2 { end = space }
            result.append(String(remaining[..<end]))
            remaining = remaining[end...].drop(while: { $0.isWhitespace })
        }
        return result
    }

    private static func withoutReasoning(_ output: String) -> String {
        if let end = output.range(of: "</think>", options: .backwards) { return String(output[end.upperBound...]) }
        return output.contains("<think>") ? "" : output
    }

    public static func cleanTitle(_ output: String) -> String? {
        var text = withoutReasoning(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(whereSeparator: { $0.isNewline }).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count == 1 else { return nil }
        for prefix in ["Название встречи:", "Meeting title:", "Название:", "Title:"] where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "#*`\"«»“”‘’. \t"))
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard (3...80).contains(text.count), text.split(separator: " ").count <= 8,
              MeetingSpeechText.accepts(text) else { return nil }
        return text
    }
}
