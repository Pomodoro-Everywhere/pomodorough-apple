import Foundation
import Sentry

// Central Sentry entry point for user-visible failure boundaries.
// No PII: callers pass only the caught Error, never tokens, titles,
// URLs, or snapshot payloads. Session replay masking and no-setUser
// policy live in SentrySetup and are preserved here by not touching scope.
enum SentryCapture {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var backend: (@Sendable (Error) -> Void)?
        var seenOnceKeys = Set<String>()
        var recurringCounts = [String: Int]()
    }

    private static let state = State()

    static func capture(_ error: Error) {
        let backend: (@Sendable (Error) -> Void)? = state.lock.withLock { state.backend }
        guard let backend else {
            SentrySDK.capture(error: error)
            return
        }
        backend(error)
    }

    static func captureOnce(key: String, error: Error) {
        let shouldCapture = state.lock.withLock {
            guard !state.seenOnceKeys.contains(key) else { return false }
            state.seenOnceKeys.insert(key)
            return true
        }
        guard shouldCapture else { return }
        capture(error)
    }

    /// Capped counting for recurring errors (AP123): captureOnce collapses
    /// distinct recurrences to the first per launch, losing the recurrence
    /// signal on hot loops (revision-stream reconnects, unavailable-widget
    /// snapshots). captureRecurring keeps the first `limit` occurrences per
    /// key per launch, then stays silent. The counter saturates at the limit
    /// so a never-quiet loop cannot grow state.
    static func captureRecurring(key: String, limit: Int = 5, error: Error) {
        precondition(limit > 0, "captureRecurring limit must be positive")
        let shouldCapture = state.lock.withLock {
            let count = state.recurringCounts[key, default: 0]
            guard count < limit else { return false }
            state.recurringCounts[key] = count + 1
            return true
        }
        guard shouldCapture else { return }
        capture(error)
    }

    static func setTestBackend(_ backend: (@Sendable (Error) -> Void)?) {
        state.lock.withLock { state.backend = backend }
    }

    static func resetForTesting() {
        state.lock.withLock {
            state.backend = nil
            state.seenOnceKeys.removeAll()
            state.recurringCounts.removeAll()
        }
    }
}
