import Darwin
import XCTest
@testable import PisyaCore

final class TranscriptionPerformanceTests: XCTestCase {
    @MainActor
    func testSwitchingTurboChangesSchedulingForTheSameTranscription() async throws {
        let performance = TranscriptionPerformance()
        let worker = Worker()
        let priorities = try await Task(executorPreference: performance, priority: .utility) { @MainActor in
            try await worker.prioritiesAfterSwitching(performance)
        }.value
        XCTAssertEqual(priorities, [QOS_CLASS_UTILITY, QOS_CLASS_USER_INITIATED, QOS_CLASS_UTILITY])
    }

    func testTurboContinuesAtSeriousHeatButPacesAtCriticalHeat() {
        XCTAssertEqual(TranscriptionPerformance.Mode.normal.pause(after: 5, thermal: .serious), .seconds(1))
        XCTAssertEqual(TranscriptionPerformance.Mode.turbo.pause(after: 5, thermal: .serious), .zero)
        XCTAssertEqual(TranscriptionPerformance.Mode.turbo.pause(after: 5, thermal: .critical), .seconds(1))
    }

    private actor Worker {
        func prioritiesAfterSwitching(_ performance: TranscriptionPerformance) async throws -> [qos_class_t] {
            let initial = qos_class_self()
            performance.mode = .turbo
            try await performance.pace(after: .now)
            let accelerated = qos_class_self()
            performance.mode = .normal
            try await performance.pace(after: .now)
            return [initial, accelerated, qos_class_self()]
        }
    }
}
