import XCTest
@testable import PisaCore

final class ProtectedFileReadTests: XCTestCase {
    @MainActor
    func testPermissionWaitRereadsFreshMetadata() async throws {
        var title = "Before lock"
        var denied = true
        var notifications = 0
        let latest = try await ProtectedFileRead.waitForAccess(read: {
            if denied { throw NSError(domain: NSCocoaErrorDomain, code: 257) }
            return title
        }, onDenied: {
            notifications += 1
        }, wait: {
            title = "Renamed while waiting"
            denied = false
        })
        XCTAssertEqual(latest, "Renamed while waiting")
        XCTAssertEqual(notifications, 1)
    }

    @MainActor
    func testOnlyPermissionErrorsRetryIncludingUnderlyingPOSIX() async throws {
        for error in [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            ])
        ] {
            var accessible = false
            let value = try await ProtectedFileRead.waitForAccess(read: {
                if !accessible { throw error }
                return 42
            }, onDenied: {}, wait: { accessible = true })
            XCTAssertEqual(value, 42)
        }
    }

    @MainActor
    func testPermissionWaitRetriesTheEntireReadAndWrite() async throws {
        var title = "Before lock"
        var locked = true
        var notices = 0
        let saved = try await ProtectedFileRead.waitForAccess(read: {
            let currentTitle = title
            if locked { throw CocoaError(.fileWriteNoPermission) }
            return currentTitle
        }, onDenied: {
            notices += 1
        }, wait: {
            title = "Renamed while waiting"
            locked = false
        })
        XCTAssertEqual(saved, "Renamed while waiting")
        XCTAssertEqual(notices, 1)
    }

    @MainActor
    func testDeletionAndOtherFailuresPropagateWithoutWaiting() async {
        for error in [
            NSError(domain: NSCocoaErrorDomain, code: 260),
            NSError(domain: NSCocoaErrorDomain, code: 3840),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            NSError(domain: "unrelated", code: 257)
        ] {
            do {
                let _: Int = try await ProtectedFileRead.waitForAccess(read: { throw error }, onDenied: {
                    XCTFail("Must not report access denial")
                }, wait: { XCTFail("Must not retry") })
                XCTFail("Must propagate read failure")
            } catch let actual as NSError {
                XCTAssertEqual(actual.domain, error.domain)
                XCTAssertEqual(actual.code, error.code)
            }
        }
    }

    @MainActor
    func testCancellationInterruptsDefaultWait() async {
        let denied = expectation(description: "Access denied")
        let task = Task { @MainActor in
            try await ProtectedFileRead.waitForAccess(read: { () throws -> Int in
                throw NSError(domain: NSCocoaErrorDomain, code: 257)
            }, onDenied: { denied.fulfill() })
        }
        await fulfillment(of: [denied], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Must cancel")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testCancellationBeforeRetryDoesNotReadAgain() async {
        var reads = 0
        let task = Task { @MainActor in
            try await ProtectedFileRead.waitForAccess(read: { () throws -> Int in
                reads += 1
                throw NSError(domain: NSCocoaErrorDomain, code: 257)
            }, onDenied: {}, wait: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do {
            _ = try await task.value
            XCTFail("Must cancel")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(reads, 1)
    }
}
