import Foundation
import Combine
import OSLog
#if os(iOS)
import WatchConnectivity

/// iOS side of the watch sync. iOS is the source of truth: every workspace
/// mutation pushes a snapshot via application context, commands arriving
/// from the watch are applied as regular mutations. No-op wherever
/// WatchConnectivity is unsupported (macOS compiles this file too).
@MainActor
final class WatchSyncService: NSObject, ObservableObject {
    private weak var model: AppModel?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func attach(_ model: AppModel) {
        self.model = model
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
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              let model
        else {
            let report = "skip st=\(session?.activationState.rawValue ?? -1) paired=\(session?.isPaired ?? false) watchApp=\(session?.isWatchAppInstalled ?? false)"
            log("push: \(report)")
            return report
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(model.makeWatchSnapshot())
        } catch {
            Self.snapshotEncodeFailed(error)
            let report = "skip encode st=\(session.activationState.rawValue) paired=\(session.isPaired) watchApp=\(session.isWatchAppInstalled)"
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
                errorHandler: { error in Self.reportSendFailed(error) }
            )
        }
        return report
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
        handleIncoming(applicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleIncoming(message)
        // Instant ack proves the iOS delegate is alive; the push result
        // follows via sendMessage report (see push()).
        replyHandler([WatchSyncKeys.report: "ack"])
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {}

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.push() }
    }
#endif

    private nonisolated func handleIncoming(_ dictionary: [String: Any]) {
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
        Task { @MainActor [weak self] in
            self?.model?.applyWatchCommand(command)
        }
    }
}
#else
@MainActor
final class WatchSyncService: NSObject, ObservableObject {
    func attach(_ model: AppModel) {}

    @discardableResult
    func push() -> String { "Watch sync unavailable" }
}
#endif

// Test seams: real failure-handler bodies shared by iOS and macOS builds
// so the unit-test bundle drives the same key + capture logic on macOS.
// Delivery stays best-effort: no retry, no user surface change; failures are
// log + SentryCapture.captureOnce (Error-only, no snapshot payload), deduped.
extension WatchSyncService {
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
}
