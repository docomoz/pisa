import Foundation

/// Keeps a completed operation alive while protected metadata is temporarily inaccessible.
public enum ProtectedFileRead {
    @MainActor
    public static func waitForAccess<Value>(
        read: () throws -> Value,
        onDenied: () -> Void,
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 3_000_000_000) }
    ) async throws -> Value {
        while true {
            try Task.checkCancellation()
            do {
                return try read()
            } catch {
                guard isPermissionDenied(error) else { throw error }
                try Task.checkCancellation()
                onDenied()
                try await wait()
            }
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        var current = error as NSError
        // Bound traversal in case an NSError chain is malformed or cyclic.
        for _ in 0..<16 {
            if current.domain == NSCocoaErrorDomain &&
                [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(current.code) {
                return true
            }
            if current.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(current.code) {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}
