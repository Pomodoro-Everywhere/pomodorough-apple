import Foundation
import Testing
@testable import Pomodorough

// R52-AP04: AlarmKit cleanup failure must preserve a successfully
// scheduled notification fallback instead of removing it and throwing.
@Suite("R52-AP04 Alarm Cleanup", .serialized)
struct R52AP04AlarmCleanupTests {
    @MainActor
    final class StatefulNotificationBackend: TimerNotificationBackend {
        var isSupported = true
        var canScheduleResult = true
        var schedulingError: Error?
        private(set) var pending: Set<String> = []
        private(set) var removes: [String] = []

        func requestAuthorization() async throws -> Bool { true }

        func canSchedule() async -> Bool { canScheduleResult }

        func schedule(identifier: String, phase: TimerPhase, duration: TimeInterval) async throws {
            if let schedulingError { throw schedulingError }
            pending.insert(identifier)
        }

        func remove(identifier: String) {
            removes.append(identifier)
            pending.remove(identifier)
        }
    }

    @MainActor
    final class StatefulAlarmBackend: TimerSystemAlarmBackend {
        var authorizationState: TimerSystemAlarmAuthorizationState = .authorized
        var scheduleError: Error?
        var cancelError: Error?
        private(set) var scheduled: Set<UUID> = []
        private(set) var cancels: [UUID] = []

        func requestAuthorization() async throws -> Bool { true }

        func schedule(id: UUID, timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
            if let scheduleError { throw scheduleError }
            scheduled.insert(id)
        }

        func pause(id: UUID) throws {
            guard scheduled.contains(id) else { return }
        }

        func resume(id: UUID) throws -> Bool { scheduled.contains(id) }

        func cancel(id: UUID) throws {
            guard scheduled.contains(id) else { return }
            cancels.append(id)
            if let cancelError { throw cancelError }
            scheduled.remove(id)
        }

        func preseed(id: UUID) {
            scheduled.insert(id)
        }
    }

    private static let uuid = UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613")!

    private static func timerID() -> String {
        "timer-\(uuid.uuidString.lowercased())"
    }

    @Test @MainActor
    func scheduleKeepsFallbackWhenCleanupCancelFails() async throws {
        let timerID = Self.timerID()
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = StatefulNotificationBackend()
        let alarms = StatefulAlarmBackend()
        alarms.preseed(id: Self.uuid)
        alarms.scheduleError = AppError.invalidResponse
        alarms.cancelError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)

        #expect(notifications.pending == [notificationID])
        #expect(notifications.removes.isEmpty)
        #expect(alarms.scheduled.contains(Self.uuid))
    }

    @Test @MainActor
    func resumeKeepsFallbackWhenCleanupCancelFails() async throws {
        let timerID = Self.timerID()
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = StatefulNotificationBackend()
        let alarms = StatefulAlarmBackend()
        alarms.preseed(id: Self.uuid)
        alarms.scheduleError = AppError.invalidResponse
        alarms.cancelError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        try await scheduler.resume(timerID: timerID, phase: .focus, duration: 30)

        #expect(notifications.pending == [notificationID])
        #expect(notifications.removes.isEmpty)
        #expect(alarms.scheduled.contains(Self.uuid))
    }

    @Test @MainActor
    func scheduleCleanupSuccessLeavesSingleFallback() async throws {
        let timerID = Self.timerID()
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = StatefulNotificationBackend()
        let alarms = StatefulAlarmBackend()
        alarms.preseed(id: Self.uuid)
        alarms.scheduleError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)

        #expect(notifications.pending == [notificationID])
        #expect(alarms.cancels == [Self.uuid])
        #expect(alarms.scheduled.isEmpty)
    }

    @Test @MainActor
    func scheduleNotificationFailureStillThrows() async throws {
        let notifications = StatefulNotificationBackend()
        notifications.schedulingError = AppError.invalidResponse
        let alarms = StatefulAlarmBackend()
        alarms.scheduleError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        await #expect(throws: AppError.self) {
            try await scheduler.schedule(timerID: Self.timerID(), phase: .focus, duration: 60)
        }
        #expect(notifications.pending.isEmpty)
    }

    @Test @MainActor
    func laterCancelRetriesStaleAlarm() async throws {
        let timerID = Self.timerID()
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = StatefulNotificationBackend()
        let alarms = StatefulAlarmBackend()
        alarms.preseed(id: Self.uuid)
        alarms.scheduleError = AppError.invalidResponse
        alarms.cancelError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)
        #expect(notifications.pending == [notificationID])

        alarms.cancelError = nil
        try await scheduler.cancel(timerID: timerID)
        #expect(alarms.scheduled.isEmpty)
        #expect(notifications.pending.isEmpty)
    }

    @Test @MainActor
    func cleanupFailuresCaptureOnce() async throws {
        SentryCapture.resetForTesting()
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let notifications = StatefulNotificationBackend()
        let alarms = StatefulAlarmBackend()
        alarms.scheduleError = AppError.invalidResponse
        alarms.cancelError = AppError.invalidResponse
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        alarms.preseed(id: Self.uuid)
        try await scheduler.schedule(timerID: Self.timerID(), phase: .focus, duration: 60)
        alarms.preseed(id: Self.uuid)
        try await scheduler.schedule(timerID: Self.timerID(), phase: .focus, duration: 60)

        #expect(recorded.value.count == 2)
    }
}
