import Dispatch
import Foundation
import Synchronization

/// Selects the scheduling priority at each hop without replacing the running task.
final class TranscriptionPerformance: TaskExecutor {
    enum Mode {
        case quiet, normal, turbo

        func pausesForHeat(_ thermal: ProcessInfo.ThermalState) -> Bool {
            thermal == .critical || (thermal == .serious && self != .turbo)
        }

        func pause(after elapsed: TimeInterval, thermal: ProcessInfo.ThermalState) -> Duration {
            guard self == .quiet || pausesForHeat(thermal) else { return .zero }
            return .seconds(min(3, max(0.1, elapsed * (self == .quiet ? 0.6 : 0.2))))
        }
    }

    private let currentMode: Mutex<Mode>

    init(mode: Mode = .normal) {
        currentMode = Mutex(mode)
    }

    var mode: Mode {
        get { currentMode.withLock { $0 } }
        set { currentMode.withLock { $0 = newValue } }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let qos: DispatchQoS.QoSClass = mode == .turbo ? .userInitiated : .utility
        DispatchQueue.global(qos: qos).async {
            job.runSynchronously(on: executor)
        }
    }

    func pace(after started: ContinuousClock.Instant) async throws {
        let finished = ContinuousClock.now
        let elapsed = (finished - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let thermal = ProcessInfo.processInfo.thermalState
        while true {
            let remaining = mode.pause(after: seconds, thermal: thermal) - (ContinuousClock.now - finished)
            guard remaining > .zero else { break }
            try await Task.sleep(for: min(remaining, .milliseconds(200)))
        }
        // Give a changed priority a scheduling boundary even when there is no cooling pause.
        await Task.yield()
    }
}
