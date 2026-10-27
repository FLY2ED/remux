import Foundation
import Synchronization

/// A clock that moves only when a test moves it, for code that times itself on a `Clock`. A wait on it
/// checks the time each millisecond, so it ends soon after the test moves the clock past its deadline,
/// and ends at once when cancelled.
final class ManualClock: Clock {
    private let current: Mutex<ContinuousClock.Instant>

    init(now: ContinuousClock.Instant = .now) {
        current = Mutex(now)
    }

    var now: ContinuousClock.Instant {
        current.withLock { $0 }
    }

    var minimumResolution: Duration { .zero }

    func advance(by duration: Duration) {
        current.withLock { $0 += duration }
    }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration? = nil) async throws {
        while now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
