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
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
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
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[WatchSyncKeys.snapshot] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
        else { return }
        Task { @MainActor [weak self] in
            self?.snapshot = snapshot
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "watch-timer-snapshot")
            }
        }
    }
}
