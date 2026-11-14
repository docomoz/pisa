import Foundation

/// A serial, in-memory index. The original text is retained for the final
/// locale-aware comparison; folded byte trigrams only narrow the candidates.
public final class LibrarySearchIndex {
    private struct Entry {
        let text: String
        let grams: Set<UInt32>
    }
    private final class Cancellation {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let queue = DispatchQueue(label: "com.docomoz.pisa.library-search", qos: .userInitiated)
    private var entries: [UUID: Entry] = [:]
    private var postings: [UInt32: Set<UUID>] = [:]
    private var unfiltered: Set<UUID> = []
    private let cancellationLock = NSLock()
    private var currentSearch: Cancellation?

    public init() {}

    public func replace(_ meetings: [Meeting]) {
        queue.async {
            self.entries.removeAll()
            self.postings.removeAll()
            self.unfiltered.removeAll()
            for meeting in meetings { self.update(meeting) }
        }
    }

    public func upsert(_ meeting: Meeting) {
        queue.async { self.update(meeting) }
    }

    public func cancelSearch() {
        cancellationLock.lock()
        currentSearch?.cancel()
        currentSearch = nil
        cancellationLock.unlock()
    }

    public func search(_ query: String, completion: @escaping (Set<UUID>) -> Void) {
        let token = Cancellation()
        cancellationLock.lock()
        currentSearch?.cancel()
        currentSearch = token
        cancellationLock.unlock()
        queue.async {
            guard !token.isCancelled else { return }
            let queryGrams = Self.grams(query)
            let candidates: Set<UUID>
            if queryGrams.isEmpty || !Self.canFilter(query) {
                candidates = Set(self.entries.keys)
            } else {
                // The rarest fragment is sufficient as a filter; the original
                // locale-aware comparison decides whether the query matches.
                let rarest = queryGrams.map { self.postings[$0] ?? [] }.min(by: { $0.count < $1.count }) ?? []
                candidates = rarest.union(self.unfiltered)
            }
            var matches: Set<UUID> = []
            for id in candidates {
                guard !token.isCancelled else { return }
                if self.entries[id]?.text.localizedCaseInsensitiveContains(query) == true { matches.insert(id) }
            }
            self.deliver(matches, token: token, completion: completion)
        }
    }

    private func deliver(_ matches: Set<UUID>, token: Cancellation, completion: @escaping (Set<UUID>) -> Void) {
        DispatchQueue.main.async {
            guard !token.isCancelled else { return }
            completion(matches)
        }
    }

    private func update(_ meeting: Meeting) {
        if let previous = entries[meeting.id] {
            for gram in previous.grams {
                postings[gram]?.remove(meeting.id)
                if postings[gram]?.isEmpty == true { postings[gram] = nil }
            }
        }
        let text = meeting.searchableText
        unfiltered.remove(meeting.id)
        let isFilterable = Self.canFilter(text)
        if !isFilterable { unfiltered.insert(meeting.id) }
        let grams = isFilterable ? Self.grams(text) : []
        entries[meeting.id] = Entry(text: text, grams: grams)
        for gram in grams { postings[gram, default: []].insert(meeting.id) }
    }

    // Context-sensitive Unicode collation can match inside a composed character
    // or ignore format characters. Such strings must always use the full check.
    private static func canFilter(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x20 && v <= 0x7e) || v == 0x09 || v == 0x0a || v == 0x0d ||
                (v >= 0x0410 && v <= 0x044f) || v == 0x0401 || v == 0x0451 ||
                [0x00a0, 0x00ab, 0x00b7, 0x00bb, 0x2013, 0x2014, 0x2018, 0x2019, 0x201c, 0x201d, 0x2026, 0x202f, 0x2116].contains(v)
        }
    }

    private static func grams(_ text: String) -> Set<UInt32> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .precomposedStringWithCanonicalMapping
        let bytes = Array(folded.utf8)
        guard bytes.count >= 3 else { return [] }
        var result: Set<UInt32> = []
        for i in 0..<(bytes.count - 2) {
            result.insert(UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]))
        }
        return result
    }
}
