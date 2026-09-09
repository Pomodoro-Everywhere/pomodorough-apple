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
                replyHandler: { @Sendable [weak self] reply in
                    // WC invokes callbacks off-main. Sendable prevents inherited
                    // MainActor isolation; only the decoded snapshot crosses actors.
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
                errorHandler: { @Sendable error in
                    // Silent delivery preserved: no retry, no user surface.
                    // Log-only (no Sentry on watchOS), deduped to avoid spam.
                    Self.logOnce(key: "watch-request-send", error: error)
                }
            )
        } else {
            do {
                try session.updateApplicationContext(payload)
            } catch {
                // Log-only (no Sentry on watchOS by design); next
                // appear/activation/reachability retries the pull.
                Self.logOnce(key: "watch-request-queue", error: error)
            }
        }
    }

    func send(_ command: WatchTimerCommand) {
        let session = WCSession.default
        guard WCSession.isSupported(),
              session.activationState == .activated
        else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(command)
        } catch {
            // Log-only (no Sentry on watchOS by design); command is dropped,
            // the phone remains the source of truth.
            Self.logOnce(key: "watch-command-encode", error: error)
            return
        }
        if session.isReachable {
            session.sendMessage(
                [WatchSyncKeys.command: data],
                replyHandler: nil,
                errorHandler: { @Sendable error in
                    // Reachable send failed (e.g. link dropped mid-send):
                    // fall back to the ordered user-info queue so the
                    // command is still delivered exactly once in order.
                    Self.logOnce(key: "watch-command-send", error: error)
                    Task { @MainActor in
                        _ = WCSession.default.transferUserInfo([WatchSyncKeys.command: data])
                    }
                }
            )
        } else {
            // Queued offline, one transfer per command: the system holds
            // them ordered until the phone is reachable again. Application
            // context is NOT used here — it keeps only the last dictionary,
            // so queued commands would overwrite each other (and a sync
            // pull would overwrite a queued Pause). Context stays reserved
            // for replaceable state; the phone re-pushes on reachability.
            _ = session.transferUserInfo([WatchSyncKeys.command: data])
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
        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: "watch-timer-snapshot")
        } catch {
            // Log-only (no Sentry on watchOS by design); in-memory snapshot
            // is already set, only the disk cache for offline launch is lost.
            Self.logOnce(key: "watch-cache-encode", error: error)
        }
    }
}

// Watch-side delivery note: commands travel live via sendMessage and queued
// via transferUserInfo (ordered, one transfer per command — application
// context keeps only the last dictionary and must stay reserved for
// replaceable state such as snapshot pulls). No Sentry on watchOS by design —
// the Pomodorough-watchOS target does not link the Sentry package
// (see project.yml: Sentry is a dependency of iOS/macOS targets only), so the
// sendMessage errorHandler above stays a thin logOnce wrapper around the
// shared WatchSyncLogDedupe (covered in the macOS/iOS unit-test bundle).
// Queued commands need no retry UI: the phone is the source of truth and
// re-pushes its snapshot on reachability change. The iOS-side
// WatchSyncService captures its own encode/send failures via SentryCapture
// and handles didReceiveUserInfo for queued commands.
// WCSession itself cannot be driven without a watchOS test host, which this
// project does not have (Pomodorough-watchOS has no test bundle).
