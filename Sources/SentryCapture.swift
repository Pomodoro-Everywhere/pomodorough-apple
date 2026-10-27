import Foundation
import Sentry

// Central Sentry entry point for user-visible failure boundaries.
// Errors may contain private payloads. DiagnosticPrivacy bounds identity before
// capture; final SDK hooks also cover automatic events and discard scope data.
enum SentryCapture {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var backend: (@Sendable (Error) -> Void)?
        var seenOnceKeys = Set<String>()
        var recurringCounts = [String: Int]()
    }

    private static let state = State()

    // WCErrorDomain 7006 "Watch app is not installed" and 7007 "Not reachable"
    // (WCErrorCodeNotReachable): benign counterpart-state noise. 7006 fires
    // when the paired phone has no watch app (14 prod occurrences);
    // 7007 fires when the counterpart is not reachable at send time —
    // out of range, locked, or backgrounded (POMODOROUGH-38, 8 events,
    // 1 user). Neither is actionable: delivery stays best-effort log-only.
    static let watchAppNotInstalledDomain = "WCErrorDomain"
    static let watchAppNotInstalledCode = 7006
    static let counterpartNotReachableCode = 7007

    static func shouldDrop(domain: String, code: Int) -> Bool {
        guard domain == watchAppNotInstalledDomain else { return false }
        return code == watchAppNotInstalledCode || code == counterpartNotReachableCode
    }

    static func shouldDrop(_ error: Error) -> Bool {
        let reported = error as NSError
        return shouldDrop(domain: reported.domain, code: reported.code)
    }

    static func shouldSuppressForEnvironment(isSimulator: Bool, isTestProcess: Bool) -> Bool {
        isSimulator || isTestProcess
    }

    static var isSimulatorBuild: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }

    static var isTestProcess: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
#if canImport(ObjectiveC)
        return NSClassFromString("XCTestCase") != nil
#else
        return false
#endif
    }

    static func capture(_ error: Error, file: StaticString = #fileID) {
        guard !shouldDrop(error) else { return }
        let diagnostic = DiagnosticPrivacy.diagnostic(error, file: file)
        let backend: (@Sendable (Error) -> Void)? = state.lock.withLock { state.backend }
        guard let backend else {
            guard !shouldSuppressForEnvironment(isSimulator: isSimulatorBuild, isTestProcess: isTestProcess) else { return }
            SentrySDK.capture(error: diagnostic)
            return
        }
        backend(diagnostic)
    }

    static func captureOnce(key: String, error: Error, file: StaticString = #fileID) {
        guard !shouldDrop(error) else { return }
        let shouldCapture = state.lock.withLock {
            guard !state.seenOnceKeys.contains(key) else { return false }
            state.seenOnceKeys.insert(key)
            return true
        }
        guard shouldCapture else { return }
        capture(error, file: file)
    }

    /// Capped counting for recurring errors (AP123): captureOnce collapses
    /// distinct recurrences to the first per launch, losing the recurrence
    /// signal on hot loops (revision-stream reconnects, unavailable-widget
    /// snapshots). captureRecurring keeps the first `limit` occurrences per
    /// key per launch, then stays silent. The counter saturates at the limit
    /// so a never-quiet loop cannot grow state.
    static func captureRecurring(key: String, limit: Int = 5, error: Error, file: StaticString = #fileID) {
        precondition(limit > 0, "captureRecurring limit must be positive")
        guard !shouldDrop(error) else { return }
        let shouldCapture = state.lock.withLock {
            let count = state.recurringCounts[key, default: 0]
            guard count < limit else { return false }
            state.recurringCounts[key] = count + 1
            return true
        }
        guard shouldCapture else { return }
        capture(error, file: file)
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
