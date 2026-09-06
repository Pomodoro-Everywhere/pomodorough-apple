import Foundation
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
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let snapshot = try? JSONDecoder().decode(WatchTimerSnapshot.self, from: data) {
            self.snapshot = snapshot
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
                    Task { @MainActor in
                        if let data = reply[WatchSyncKeys.snapshot] as? Data,
                           let snapshot = try? JSONDecoder().decode(WatchTimerSnapshot.self, from: data) {
                            self?.ingest(snapshot)
                        }
                    }
                },
                errorHandler: nil
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
            session.sendMessage([WatchSyncKeys.command: data], replyHandler: nil, errorHandler: nil)
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
        guard let data = dictionary[WatchSyncKeys.snapshot] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
        else { return }
        Task { @MainActor [weak self] in
            self?.ingest(snapshot)
        }
    }

    private func ingest(_ snapshot: WatchTimerSnapshot) {
        self.snapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "watch-timer-snapshot")
        }
    }
}
