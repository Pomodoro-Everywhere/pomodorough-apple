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

    static func setTestBackend(_ backend: (@Sendable (Error) -> Void)?) {
        state.lock.withLock { state.backend = backend }
    }

    static func resetForTesting() {
        state.lock.withLock {
            state.backend = nil
            state.seenOnceKeys.removeAll()
        }
    }
}
