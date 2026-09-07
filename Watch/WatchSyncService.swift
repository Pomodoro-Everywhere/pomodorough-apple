import Foundation
import OSLog
import WatchConnectivity

/// watchOS side of the sync. The iPhone is the source of truth: this service
/// publishes the latest snapshot and forwards user intents as commands.
/// The last snapshot is cached so the watch still shows state when the phone
/// is temporarily unreachable.
@MainActor
final class WatchSyncService: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchTimerSnapshot?
    @Published private(set) var isReachable = false

    private let storeKey = "watch-timer-snapshot"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: storeKey) {
            do {
                self.snapshot = try JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
            } catch {
                // Corrupt cache: drop silently, log once for dev. No Sentry
                // on watchOS (no Sentry dependency); delivery stays silent.
                Self.logOnce(key: "watch-cache-decode", error: error)
            }
        }
        // TEMP-CRASH-REPRO (simulator only, never device): seed a running
        // snapshot to exercise syncedView without WC.
        #if targetEnvironment(simulator)
        if self.snapshot == nil {
            let now = Date()
            self.snapshot = WatchTimerSnapshot(
                phase: "focus", status: "running",
                plannedDurationMs: 25 * 60 * 1_000, elapsedAtAnchorMs: 0, anchorAt: now,
                selectedPhase: "focus",
                focusDurationMs: 25 * 60 * 1_000,
                shortBreakDurationMs: 5 * 60 * 1_000,
                longBreakDurationMs: 15 * 60 * 1_000,
                updatedAt: now
            )
        }
        #endif
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Pull: ask the phone for a fresh snapshot. Called on appear/activation/reachability.
    func requestSync() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        let payload = [WatchSyncKeys.requestSync: true]
        if session.isReachable {
            session.sendMessage(
                payload,
                replyHandler: { [weak self] reply in
                    // Decode on the WC callback thread (same proven-safe pattern as
                    // storeSnapshot): only Sendable values may cross into the Task.
                    // Capturing the raw non-Sendable reply dict crashed here (SIGTRAP
                    // in the actor-isolation check on the WC background queue).
                    guard let data = reply[WatchSyncKeys.snapshot] as? Data else { return }
                    let snapshot: WatchTimerSnapshot
                    do {
                        snapshot = try JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
                    } catch {
                        Self.logOnce(key: "watch-reply-decode", error: error)
                        return
                    }
                    Task { @MainActor in
                        self?.ingest(snapshot)
                    }
                },
                errorHandler: { error in
                    // Silent delivery preserved: no retry, no user surface.
                    // Log-only (no Sentry on watchOS), deduped to avoid spam.
                    Self.logOnce(key: "watch-request-send", error: error)
                }
            )
        } else {
            try? session.updateApplicationContext(payload)
        }
    }

    func send(_ command: WatchTimerCommand) {
        let session = WCSession.default
        guard WCSession.isSupported(),
              session.activationState == .activated,
              let data = try? JSONEncoder().encode(command)
        else { return }
        if session.isReachable {
            session.sendMessage(
                [WatchSyncKeys.command: data],
                replyHandler: nil,
                errorHandler: { error in
                    // Silent delivery preserved: command stays queued via
                    // application context on next reachability change.
                    Self.logOnce(key: "watch-command-send", error: error)
                }
            )
        } else {
            // Queued: delivered as soon as the phone is reachable again.
            try? session.updateApplicationContext([WatchSyncKeys.command: data])
        }
    }
}

extension WatchSyncService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
            self?.requestSync()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
            self?.requestSync()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        if message[WatchSyncKeys.snapshot] != nil {
            storeSnapshot(from: message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        storeSnapshot(from: applicationContext)
    }

    private nonisolated func storeSnapshot(from dictionary: [String: Any]) {
        guard let data = dictionary[WatchSyncKeys.snapshot] as? Data else { return }
        let snapshot: WatchTimerSnapshot
        do {
            snapshot = try JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
        } catch {
            WatchSyncService.logOnce(key: "watch-snapshot-decode", error: error)
            return
        }
        Task { @MainActor [weak self] in
            self?.ingest(snapshot)
        }
    }

    private nonisolated static func logOnce(key: String, error: Error) {
        guard WatchSyncLogDedupe.shouldLog(key: key) else { return }
        Logger(subsystem: "me.egigoka.pomodorough", category: "WatchSync")
            .error("\(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    private func ingest(_ snapshot: WatchTimerSnapshot) {
        self.snapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "watch-timer-snapshot")
        }
    }
}

// Watch-side silent-delivery note: no Sentry on watchOS, so the
// sendMessage errorHandlers above are thin logOnce wrappers around the
// shared WatchSyncLogDedupe (covered in the macOS/iOS unit-test bundle).
// WCSession itself cannot be driven without a watchOS test host, which this
// project does not have (Pomodorough-watchOS has no test bundle).
