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
    /// Temporary debug: nil = no reply yet, true/false = iOS acked or failed.
    @Published private(set) var iosAck: Bool?
    /// Temporary debug: last report string received from iOS.
    @Published private(set) var iosReport: String?
    /// Temporary debug: keys of the last application context received.
    @Published private(set) var lastContextKeys: [String] = []

    /// Temporary debug line for the empty state.
    var diag: String {
        let s = WCSession.default
        let ack: String
        switch iosAck {
        case nil: ack = "?"
        case true?: ack = "y"
        case false?: ack = "n"
        }
        return "act=\(s.activationState.rawValue) comp=\(s.isCompanionAppInstalled) reach=\(isReachable) ctx=\(lastContextKeys) ack=\(ack)"
    }

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
                        self?.iosAck = true
                        if let text = reply[WatchSyncKeys.report] as? String, text != "ack" {
                            self?.iosReport = text
                        }
                        if let data = reply[WatchSyncKeys.snapshot] as? Data,
                           let snapshot = try? JSONDecoder().decode(WatchTimerSnapshot.self, from: data) {
                            self?.ingest(snapshot)
                        }
                    }
                },
                errorHandler: { [weak self] _ in
                    Task { @MainActor in self?.iosAck = false }
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
        if let text = message[WatchSyncKeys.report] as? String {
            Task { @MainActor [weak self] in self?.iosReport = text }
        }
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
        let keys = Array(dictionary.keys)
        guard let data = dictionary[WatchSyncKeys.snapshot] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
        else {
            Task { @MainActor [weak self] in self?.lastContextKeys = keys }
            return
        }
        Task { @MainActor [weak self] in
            self?.lastContextKeys = keys
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
