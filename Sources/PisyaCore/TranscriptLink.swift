import Foundation

/// A local reference to a transcript fragment. The timestamp supports recovery after reprocessing.
public struct TranscriptLink: Equatable, Sendable {
    public let meetingID: UUID
    public let segmentID: UUID
    public let time: Double

    public init?(meetingID: UUID, segmentID: UUID, time: Double) {
        guard time.isFinite, time >= 0 else { return nil }
        self.meetingID = meetingID; self.segmentID = segmentID; self.time = time
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "pisya"; parts.host = "meeting"; parts.path = "/" + meetingID.uuidString
        parts.queryItems = [URLQueryItem(name: "segment", value: segmentID.uuidString), URLQueryItem(name: "time", value: String(time))]
        return parts.url!
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "pisya", parts.host == "meeting", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path,
              parts.path.first == "/", let meeting = UUID(uuidString: String(parts.path.dropFirst())),
              parts.path == "/" + meeting.uuidString || parts.path == "/" + meeting.uuidString.lowercased() else { return nil }
        guard let items = parts.queryItems, items.count == 2,
              Set(items.map(\.name)) == Set(["segment", "time"]),
              let segmentText = items.first(where: { $0.name == "segment" })?.value,
              let segment = UUID(uuidString: segmentText),
              let timeText = items.first(where: { $0.name == "time" })?.value,
              let time = Double(timeText), time.isFinite, time >= 0 else { return nil }
        self.init(meetingID: meeting, segmentID: segment, time: time)
    }

    public struct Resolution: Sendable {
        public let segment: TranscriptSegment
        public let isApproximate: Bool
    }
    public func resolve(in meeting: Meeting) -> Resolution? {
        guard meeting.id == meetingID, meeting.deletedAt == nil else { return nil }
        let segments = meeting.segments.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        if let exact = segments.first(where: { $0.id == segmentID }) {
            return Resolution(segment: exact, isApproximate: false)
        }
        if let containing = segments.first(where: { $0.start <= time && time < $0.end }) {
            return Resolution(segment: containing, isApproximate: true)
        }
        guard let nearest = segments.min(by: {
            let left = distance($0), right = distance($1)
            if left != right { return left < right }
            let leftStart = abs($0.start - time), rightStart = abs($1.start - time)
            if leftStart != rightStart { return leftStart < rightStart }
            return $0.id.uuidString < $1.id.uuidString
        }) else { return nil }
        return Resolution(segment: nearest, isApproximate: true)
    }
    private func distance(_ segment: TranscriptSegment) -> Double {
        min(abs(segment.start - time), abs(segment.end - time))
    }
}
