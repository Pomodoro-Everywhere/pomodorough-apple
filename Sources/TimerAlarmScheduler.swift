import Foundation

#if os(iOS)
import AlarmKit
import SwiftUI
#endif

#if os(iOS) || os(macOS)
import UserNotifications
#endif

#if os(macOS)
import AppKit
#endif

@MainActor
protocol TimerAlarmScheduling: AnyObject {
    func requestAuthorization() async throws
    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws
    func pause(timerID: String) async throws
    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws
    func cancel(timerID: String) async throws
}

enum TimerAlarmError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Allow notifications or alarms in Settings to receive timer alerts when Pomodorough is not open."
        }
    }
}

enum TimerSystemAlarmAuthorizationState: Equatable {
    case unsupported
    case notDetermined
    case authorized
    case denied
}

@MainActor
protocol TimerNotificationBackend: Sendable {
    var isSupported: Bool { get }
    func requestAuthorization() async throws -> Bool
    func canSchedule() async -> Bool
    func schedule(identifier: String, phase: TimerPhase, duration: TimeInterval) async throws
    func remove(identifier: String)
}

@MainActor
protocol TimerSystemAlarmBackend: Sendable {
    var authorizationState: TimerSystemAlarmAuthorizationState { get }
    func requestAuthorization() async throws -> Bool
    func schedule(id: UUID, timerID: String, phase: TimerPhase, duration: TimeInterval) async throws
    func pause(id: UUID) throws
    func resume(id: UUID) throws -> Bool
    func cancel(id: UUID) throws
}

struct SystemTimerNotificationBackend: TimerNotificationBackend {
    var isSupported: Bool {
#if os(iOS) || os(macOS)
        true
#else
        false
#endif
    }

    func requestAuthorization() async throws -> Bool {
#if os(iOS) || os(macOS)
#if os(macOS)
        _ = MacTimerNotificationCoordinator.shared
#endif
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
#else
        false
#endif
    }

    func canSchedule() async -> Bool {
#if os(iOS) || os(macOS)
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .authorized || status == .provisional { return true }
#if os(iOS)
        return status == .ephemeral
#else
        return false
#endif
#else
        false
#endif
    }

    func schedule(identifier: String, phase: TimerPhase, duration: TimeInterval) async throws {
#if os(iOS) || os(macOS)
        let content = UNMutableNotificationContent()
        content.title = TimerAlarmScheduler.title(for: phase)
        content.body = "Your next Pomodorough interval is ready."
        content.sound = .default
#if os(macOS)
        content.categoryIdentifier = MacTimerNotificationCoordinator.categoryIdentifier
        let coordinator = MacTimerNotificationCoordinator.shared
        coordinator.prepare(identifier: identifier)
#endif
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, duration), repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
#if os(macOS)
            coordinator.arm(identifier: identifier, duration: duration)
#endif
        } catch {
#if os(macOS)
            coordinator.stop(identifier: identifier)
#endif
            throw error
        }
#endif
    }

    func remove(identifier: String) {
#if os(iOS) || os(macOS)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
#if os(macOS)
        MacTimerNotificationCoordinator.shared.stop(identifier: identifier)
#endif
#endif
    }
}

#if os(macOS)
@MainActor
private final class MacTimerNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacTimerNotificationCoordinator()
    static let categoryIdentifier = "pomodorough.timer.complete"

    private static let dismissActionIdentifier = "pomodorough.timer.dismiss"
    private let center = UNUserNotificationCenter.current()
    private var alarmTasks: [String: Task<Void, Never>] = [:]
    private var activeSoundIdentifier: String?
    private var sound: NSSound?

    override private init() {
        super.init()
        center.delegate = self
        let dismissAction = UNNotificationAction(
            identifier: Self.dismissActionIdentifier,
            title: TimerAlarmScheduler.stopSoundTitle
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [dismissAction],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
    }

    func prepare(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        stop(identifier: identifier)
    }

    func arm(identifier: String, duration: TimeInterval) {
        alarmTasks[identifier]?.cancel()
        alarmTasks[identifier] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(1, duration)))
            } catch {
                return
            }
            guard let self, self.alarmTasks.removeValue(forKey: identifier) != nil else { return }
            self.playSound(identifier: identifier)
        }
    }

    func stop(identifier: String) {
        alarmTasks.removeValue(forKey: identifier)?.cancel()
        if activeSoundIdentifier == identifier { stopSound() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await dismiss(identifier: response.notification.request.identifier)
    }

    private func dismiss(identifier: String) {
        stop(identifier: identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func playSound(identifier: String) {
        stopSound()
        let sound = NSSound(
            contentsOfFile: "/System/Library/Sounds/Glass.aiff",
            byReference: true
        ) ?? NSSound(named: NSSound.Name("Glass"))
        guard let sound else {
            NSSound.beep()
            return
        }
        sound.loops = true
        activeSoundIdentifier = identifier
        self.sound = sound
        sound.play()
    }

    private func stopSound() {
        sound?.stop()
        sound = nil
        activeSoundIdentifier = nil
    }
}
#endif

struct SystemTimerAlarmBackend: TimerSystemAlarmBackend {
    var authorizationState: TimerSystemAlarmAuthorizationState {
#if os(iOS)
        if #available(iOS 26.0, *) {
            return switch AlarmManager.shared.authorizationState {
            case .notDetermined: .notDetermined
            case .authorized: .authorized
            case .denied: .denied
            @unknown default: .denied
            }
        }
#endif
        return .unsupported
    }

    func requestAuthorization() async throws -> Bool {
#if os(iOS)
        if #available(iOS 26.0, *) {
            return try await AlarmManager.shared.requestAuthorization() == .authorized
        }
#endif
        return false
    }

    func schedule(id: UUID, timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
#if os(iOS)
        if #available(iOS 26.0, *) {
            let attributes = AlarmAttributes(
                presentation: AlarmPresentation(alert: Self.alert(for: phase)),
                metadata: TimerAlarmMetadata(timerID: timerID, phase: phase.rawValue),
                tintColor: Color(red: 1, green: 96.0 / 255.0, blue: 79.0 / 255.0)
            )
            let configuration = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>.timer(
                duration: max(1, duration),
                attributes: attributes
            )
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        }
#endif
    }

    func pause(id: UUID) throws {
#if os(iOS)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            guard try manager.alarms.contains(where: { $0.id == id }) else { return }
            try manager.pause(id: id)
        }
#endif
    }

    func resume(id: UUID) throws -> Bool {
#if os(iOS)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            guard try manager.alarms.contains(where: { $0.id == id }) else { return false }
            try manager.resume(id: id)
            return true
        }
#endif
        return false
    }

    func cancel(id: UUID) throws {
#if os(iOS)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            guard try manager.alarms.contains(where: { $0.id == id }) else { return }
            try manager.cancel(id: id)
        }
#endif
    }
}

@MainActor
private final class TimerAlarmOperationCoordinator {
    static let shared = TimerAlarmOperationCoordinator()

    private var tails: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]

    func perform(
        timerID: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let previous = tails[timerID]
        let token = UUID()
        let task = Task<Void, Error> { @MainActor in
            await previous?.value
            try await operation()
        }
        let tail = Task<Void, Never> { @MainActor in
            _ = await task.result
        }
        tails[timerID] = tail
        tokens[timerID] = token
        defer {
            if tokens[timerID] == token {
                tokens.removeValue(forKey: timerID)
                tails.removeValue(forKey: timerID)
            }
        }
        try await task.value
    }
}

@MainActor
final class TimerAlarmScheduler: TimerAlarmScheduling {
    private let notifications: any TimerNotificationBackend
    private let alarms: any TimerSystemAlarmBackend

    init(
        notifications: any TimerNotificationBackend = SystemTimerNotificationBackend(),
        alarms: any TimerSystemAlarmBackend = SystemTimerAlarmBackend()
    ) {
        self.notifications = notifications
        self.alarms = alarms
    }

    func requestAuthorization() async throws {
        guard notifications.isSupported || alarms.authorizationState != .unsupported else { return }
        let notificationsAllowed = (try? await notifications.requestAuthorization()) ?? false
        let alarmsAllowed: Bool
        switch alarms.authorizationState {
        case .notDetermined:
            alarmsAllowed = (try? await alarms.requestAuthorization()) ?? false
        case .authorized:
            alarmsAllowed = true
        case .unsupported, .denied:
            alarmsAllowed = false
        }
        guard notificationsAllowed || alarmsAllowed else {
            throw TimerAlarmError.authorizationDenied
        }
    }

    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        try await TimerAlarmOperationCoordinator.shared.perform(timerID: timerID) { [notifications, alarms] in
            guard notifications.isSupported || alarms.authorizationState != .unsupported else { return }
            if alarms.authorizationState == .authorized,
               let alarmID = Self.alarmID(for: timerID) {
                try await alarms.schedule(id: alarmID, timerID: timerID, phase: phase, duration: duration)
                notifications.remove(identifier: Self.notificationID(for: timerID))
                return
            }
            guard await notifications.canSchedule() else { throw TimerAlarmError.authorizationDenied }
            let notificationID = Self.notificationID(for: timerID)
            try await notifications.schedule(identifier: notificationID, phase: phase, duration: duration)
            if let alarmID = Self.alarmID(for: timerID) {
                do {
                    try alarms.cancel(id: alarmID)
                } catch {
                    notifications.remove(identifier: notificationID)
                    throw error
                }
            }
        }
    }

    func pause(timerID: String) async throws {
        try await TimerAlarmOperationCoordinator.shared.perform(timerID: timerID) { [notifications, alarms] in
            guard notifications.isSupported || alarms.authorizationState != .unsupported else { return }
            notifications.remove(identifier: Self.notificationID(for: timerID))
            if let alarmID = Self.alarmID(for: timerID) {
                try alarms.pause(id: alarmID)
            }
        }
    }

    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        try await TimerAlarmOperationCoordinator.shared.perform(timerID: timerID) { [notifications, alarms] in
            guard notifications.isSupported || alarms.authorizationState != .unsupported else { return }
            if alarms.authorizationState == .authorized,
               let alarmID = Self.alarmID(for: timerID) {
                if try alarms.resume(id: alarmID) {
                    notifications.remove(identifier: Self.notificationID(for: timerID))
                    return
                }
                try await alarms.schedule(id: alarmID, timerID: timerID, phase: phase, duration: duration)
                notifications.remove(identifier: Self.notificationID(for: timerID))
                return
            }
            guard await notifications.canSchedule() else { throw TimerAlarmError.authorizationDenied }
            let notificationID = Self.notificationID(for: timerID)
            try await notifications.schedule(identifier: notificationID, phase: phase, duration: duration)
            if let alarmID = Self.alarmID(for: timerID) {
                do {
                    try alarms.cancel(id: alarmID)
                } catch {
                    notifications.remove(identifier: notificationID)
                    throw error
                }
            }
        }
    }

    func cancel(timerID: String) async throws {
        try await TimerAlarmOperationCoordinator.shared.perform(timerID: timerID) { [notifications, alarms] in
            guard notifications.isSupported || alarms.authorizationState != .unsupported else { return }
            notifications.remove(identifier: Self.notificationID(for: timerID))
            if let alarmID = Self.alarmID(for: timerID) {
                try alarms.cancel(id: alarmID)
            }
        }
    }

    nonisolated static func alarmID(for timerID: String) -> UUID? {
        guard timerID.hasPrefix("timer-") else { return nil }
        return UUID(uuidString: String(timerID.dropFirst("timer-".count)))
    }

    nonisolated static func notificationID(for timerID: String) -> String {
        "pomodorough.\(timerID)"
    }

    nonisolated static func title(for phase: TimerPhase) -> String {
        switch phase {
        case .focus: "Focus complete"
        case .shortBreak: "Short break complete"
        case .longBreak: "Long break complete"
        }
    }

    nonisolated static var stopSoundTitle: String { "Stop sound" }
}

#if os(iOS)
@available(iOS 26.0, *)
private struct TimerAlarmMetadata: AlarmMetadata {
    let timerID: String
    let phase: String
}

@available(iOS 26.0, *)
private extension SystemTimerAlarmBackend {
    static func alert(for phase: TimerPhase) -> AlarmPresentation.Alert {
        let title: LocalizedStringResource = switch phase {
        case .focus: "Focus complete"
        case .shortBreak: "Short break complete"
        case .longBreak: "Long break complete"
        }
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: title)
        }
        return legacyAlert(title: title)
    }

    @available(iOS, introduced: 26.0, obsoleted: 26.1)
    static func legacyAlert(title: LocalizedStringResource) -> AlarmPresentation.Alert {
        AlarmPresentation.Alert(
            title: title,
            stopButton: AlarmButton(text: "Stop sound", textColor: .white, systemImageName: "stop.circle.fill")
        )
    }
}

#endif
