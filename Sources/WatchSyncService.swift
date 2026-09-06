import Foundation
import OSLog
import WatchConnectivity

/// iOS side of the watch sync. iOS is the source of truth: every workspace
/// mutation pushes a snapshot via application context, commands arriving
/// from the watch are applied as regular mutations. No-op wherever
/// WatchConnectivity is unsupported (macOS compiles this file too).
@MainActor
final class WatchSyncService: NSObject {
    private weak var model: AppModel?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func attach(_ model: AppModel) {
        self.model = model
        guard let session, session.activationState == .notActivated else { return }
        session.delegate = self
        session.activate()
        log("attach: activating, paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
    }

    func push() {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              let model,
              let data = try? JSONEncoder().encode(model.makeWatchSnapshot())
        else {
            log("push: skipped state=\(session?.activationState.rawValue ?? -1) paired=\(session?.isPaired ?? false) watchAppInstalled=\(session?.isWatchAppInstalled ?? false)")
            return
        }
        do {
            try session.updateApplicationContext([WatchSyncKeys.snapshot: data])
            log("push: ok paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
        } catch {
            log("push: FAILED \(error)")
        }
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
        Task { @MainActor [weak self] in self?.push() }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handleIncoming(applicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleIncoming(message)
        replyHandler([:])
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {}

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.push() }
    }
#endif

    private nonisolated func handleIncoming(_ dictionary: [String: Any]) {
        guard let data = dictionary[WatchSyncKeys.command] as? Data,
              let command = try? JSONDecoder().decode(WatchTimerCommand.self, from: data)
        else { return }
        Task { @MainActor [weak self] in
            self?.model?.applyWatchCommand(command)
        }
    }
}
