import Foundation
import Combine
import OSLog
import Synchronization
#if os(iOS)
import WatchConnectivity

/// iOS side of the watch sync. iOS is the source of truth: every workspace
/// mutation pushes a snapshot via application context, commands arriving
/// from the watch are applied as regular mutations. No-op wherever
/// WatchConnectivity is unsupported (macOS compiles this file too).
@MainActor
final class WatchSyncService: NSObject, ObservableObject {
    private weak var model: AppModel?
    private nonisolated let replySnapshot = Mutex<Data?>(nil)
    private nonisolated let incomingSerial = WatchCommandSerialQueue()
    private var sequenceDefaults: UserDefaults = .standard

    private enum SequenceKeys {
        static let seed = "watch-snapshot-seq-seed"
        static let count = "watch-snapshot-seq-count"
    }

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func attach(_ model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.sequenceDefaults = defaults
        _ = push()
        guard let session else { return }
        // Always (re)claim the delegate: a previous AppModel instance may have
        // activated the session and been deallocated, leaving a dangling delegate.
        session.delegate = self
        guard session.activationState == .notActivated else { return }
        session.activate()
        log("attach: activating, paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
    }

    @discardableResult
    func push() -> String {
        guard let model else { return "skip no model" }
        let data: Data
        do {
            data = try JSONEncoder().encode(stampedSnapshot(model.makeWatchSnapshot()))
            replySnapshot.withLock { $0 = data }
        } catch {
            replySnapshot.withLock { $0 = nil }
            Self.snapshotEncodeFailed(error)
            return "skip encode"
        }
        guard let session,
               session.activationState == .activated,
               session.isPaired
        else {
            let report = "skip st=\(session?.activationState.rawValue ?? -1) paired=\(session?.isPaired ?? false) watchApp=\(session?.isWatchAppInstalled ?? false)"
            log("push: \(report)")
            return report
        }
        let report: String
        do {
            try session.updateApplicationContext([WatchSyncKeys.snapshot: data])
            report = "ok \(data.count)B watchApp=\(session.isWatchAppInstalled)"
            log("push: \(report)")
        } catch {
            Self.contextUpdateFailed(error)
            report = "FAIL \(error)"
            log("push: \(report)")
        }
        // Best-effort live report (wire-compat; snapshot remains source of truth).
        if session.isReachable {
            let text = report
            session.sendMessage(
                [WatchSyncKeys.report: text],
                replyHandler: nil,
                errorHandler: { @Sendable error in Self.reportSendFailed(error) }
            )
        }
        return report
    }

    /// Stamps the snapshot with the next phone-owned emission sequence so
    /// the watch can reject delayed refresh replies that predate an already
    /// adopted application-context snapshot.
    private func stampedSnapshot(_ snapshot: WatchTimerSnapshot) -> WatchTimerSnapshot {
        var stamped = snapshot
        stamped.sequence = nextSnapshotSequence()
        return stamped
    }

    /// Monotonic per install, persisted across relaunches, room swaps, and
    /// account changes. The seed is a random per-install epoch (see
    /// makeWatchInstallSeed); the counter orders emissions within the
    /// install, so delivery order never depends on snapshot wall-clock time.
    private func nextSnapshotSequence() -> UInt64 {
        var seed = UInt32(truncatingIfNeeded: sequenceDefaults.integer(forKey: SequenceKeys.seed))
        var count = UInt32(truncatingIfNeeded: sequenceDefaults.integer(forKey: SequenceKeys.count))
        if seed == 0 {
            seed = makeWatchInstallSeed()
            count = 0
        }
        if count == UInt32.max { Self.sequenceSaturated() }
        let next = nextWatchSnapshotSequence(seed: seed, count: count)
        sequenceDefaults.set(Int(truncatingIfNeeded: next.seed), forKey: SequenceKeys.seed)
        sequenceDefaults.set(Int(truncatingIfNeeded: next.count), forKey: SequenceKeys.count)
        return next.sequence
    }
}

extension WatchSyncService: WCSessionDelegate {
    private nonisolated func log(_ message: String) {
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").info("\(message)")
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        log("activation: state=\(activationState.rawValue) paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled) error=\(String(describing: error))")
        guard activationState == .activated else { return }
        Task { @MainActor [weak self] in self?.push() }    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handleIncoming(applicationContext, isDeferred: true)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message[WatchSyncKeys.requestSync] != nil {
            // WC's callback is not Sendable. Reply here using the snapshot
            // encoded on the main actor at attach and every publication.
            if let data = replySnapshot.withLock({ $0 }) {
                replyHandler(Self.snapshotReply(data))
                // The cache may predate a non-mutation transition (room swap,
                // completion, bootstrap, sign-out). Converge after serving.
                Task { @MainActor [weak self] in self?.push() }
            } else {
                Self.snapshotUnavailable()
                replyHandler([WatchSyncKeys.report: "unavailable"])
            }
            return
        }
        handleIncoming(message)
        // Instant ack proves the iOS delegate is alive; the push result
        // follows via sendMessage report (see push()).
        replyHandler([WatchSyncKeys.report: "ack"])
    }

    // Watch commands are sent without a reply handler (fire-and-forget):
    // without this overload the reachable-watch path has no receiver and
    // Start/Pause/Resume/Done are dropped. Route same as the reply path.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handleIncoming(message)
    }

    // Offline watch commands arrive queued via transferUserInfo (ordered,
    // one dictionary per command). Same handling as live messages.
    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        handleIncoming(userInfo, isDeferred: true)
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The session deactivates on paired-Watch switch and stays down
        // until reactivated: snapshot pushes then fail the .activated guard.
        // Reactivate; activationDidComplete pushes the fresh snapshot.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.push() }
    }
#endif

    private nonisolated func handleIncoming(_ dictionary: [String: Any], isDeferred: Bool = false) {
        if dictionary[WatchSyncKeys.requestSync] != nil {
            Task { @MainActor [weak self] in self?.push() }
            return
        }
        guard let data = dictionary[WatchSyncKeys.command] as? Data else { return }
        let command: WatchTimerCommand
        do {
            command = try JSONDecoder().decode(WatchTimerCommand.self, from: data)
        } catch {
            Self.commandDecodeFailed(error)
            return
        }
        // FIFO: chain onto the serial tail so concurrent delegate callbacks
        // apply in arrival order even when one work suspends.
        incomingSerial.enqueue { @MainActor [weak self] in
            self?.applyIncoming(command, isDeferred: isDeferred)
        }
    }

    @MainActor
    private func applyIncoming(_ command: WatchTimerCommand, isDeferred: Bool) {
        // Stale timer-targeted commands are rejected without mutation;
        // push the current snapshot so the watch converges at once
        // instead of waiting for the next local mutation.
        if model?.applyWatchCommand(command, isDeferred: isDeferred) == false {
            push()
        }
    }
}
#else
@MainActor
final class WatchSyncService: NSObject, ObservableObject {
    func attach(_ model: AppModel, defaults: UserDefaults = .standard) {}

    @discardableResult
    func push() -> String { "Watch sync unavailable" }
}
#endif

// Test seams: real failure-handler bodies shared by iOS and macOS builds
// so the unit-test bundle drives the same key + capture logic on macOS.
// Delivery stays best-effort: no retry, no user surface change; failures are
// log + SentryCapture.captureOnce (Error-only, no snapshot payload), deduped.
extension WatchSyncService {
    nonisolated static func snapshotReply(_ data: Data) -> [String: Data] {
        [WatchSyncKeys.snapshot: data]
    }

    nonisolated static func snapshotEncodeFailed(_ error: Error) {
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").error("snapshot encode failed: \(error.localizedDescription, privacy: .public)")
        SentryCapture.captureOnce(key: "watch-snapshot-encode", error: error)
    }

    nonisolated static func contextUpdateFailed(_ error: Error) {
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").error("context update failed: \(error.localizedDescription, privacy: .public)")
        SentryCapture.captureOnce(key: "watch-context-update", error: error)
    }

    nonisolated static func reportSendFailed(_ error: Error) {
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").error("report send failed: \(error.localizedDescription, privacy: .public)")
        SentryCapture.captureOnce(key: "watch-report-send", error: error)
    }

    nonisolated static func commandDecodeFailed(_ error: Error) {
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").error("command decode failed: \(error.localizedDescription, privacy: .public)")
        SentryCapture.captureOnce(key: "watch-command-decode", error: error)
    }

    nonisolated static func sequenceSaturated() {
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").error("snapshot sequence saturated")
        SentryCapture.captureOnce(key: "watch-snapshot-sequence", error: WatchSnapshotUnavailableError())
    }

    nonisolated static func snapshotUnavailable() {
        let error = WatchSnapshotUnavailableError()
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync").error("snapshot unavailable: \(error.localizedDescription, privacy: .public)")
        SentryCapture.captureOnce(key: "watch-snapshot-unavailable", error: error)
    }
}
