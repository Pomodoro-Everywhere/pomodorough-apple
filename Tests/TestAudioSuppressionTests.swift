import Foundation
import Testing
import UserNotifications
@testable import Pomodorough

// R51-AP00: test runs must not play sounds. Suppression lives only in real
// platform adapters; injected fakes keep exercising calls and failures.
@Suite("Test audio suppression (R51-AP00)")
struct TestAudioSuppressionTests {
    @MainActor
    final class FakeSession: CompletionChimeSession, @unchecked Sendable {
        var activateCount = 0
        func activate() throws { activateCount += 1 }
        func deactivate() {}
    }

    @MainActor
    final class FakeSound: CompletionChimeSound, @unchecked Sendable {
        var onFinish: (@MainActor () -> Void)?
        var playCount = 0
        func play() -> Bool {
            playCount += 1
            return true
        }
        func stop() {}
    }

    @Test func normalEnvironmentStaysAudible() {
        #expect(TestAudioSuppression.isEnabled(environment: [:], hasXCTest: false) == false)
        let resetOnly = ["POMODOROUGH_UI_TEST_RESET": "1"]
        #expect(TestAudioSuppression.isEnabled(environment: resetOnly, hasXCTest: false) == false)
        let explicitOff = ["POMODOROUGH_SILENCE_AUDIO": "0"]
        #expect(TestAudioSuppression.isEnabled(environment: explicitOff, hasXCTest: false) == false)
    }

    @Test func testSignalsSuppressIndependentOfReset() {
        #expect(TestAudioSuppression.isEnabled(environment: [:], hasXCTest: true) == true)
        let config = ["XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration"]
        #expect(TestAudioSuppression.isEnabled(environment: config, hasXCTest: false) == true)
        let silenceOnly = ["POMODOROUGH_SILENCE_AUDIO": "1"]
        #expect(TestAudioSuppression.isEnabled(environment: silenceOnly, hasXCTest: false) == true)
        let merged = TestAudioSuppression.silenced([:])
        #expect(merged["POMODOROUGH_SILENCE_AUDIO"] == "1")
        #expect(TestAudioSuppression.isEnabled(environment: merged, hasXCTest: false) == true)
        let withReset = TestAudioSuppression.silenced(["POMODOROUGH_UI_TEST_RESET": "1"])
        #expect(withReset["POMODOROUGH_UI_TEST_RESET"] == "1")
        #expect(TestAudioSuppression.isEnabled(environment: withReset, hasXCTest: false) == true)
        var clearedReset = withReset
        clearedReset.removeValue(forKey: "POMODOROUGH_UI_TEST_RESET")
        #expect(TestAudioSuppression.isEnabled(environment: clearedReset, hasXCTest: false) == true)
    }

    @Test @MainActor func systemBackendsStaySilentUnderTests() async throws {
        #expect(TestAudioSuppression.isEnabled == true)
        let notifications = SystemTimerNotificationBackend()
        #expect(try await notifications.requestAuthorization() == true)
        #expect(await notifications.canSchedule() == true)
        try await notifications.schedule(identifier: "pomodorough.test-silence", phase: .focus, duration: 60)
        notifications.remove(identifier: "pomodorough.test-silence")
        #expect(SystemTimerNotificationBackend.notificationSound() == nil)
        #expect(SystemTimerNotificationBackend.foregroundPresentationOptions == [.banner, .list])
        let alarms = SystemTimerAlarmBackend()
        #expect(alarms.authorizationState == .unsupported)
        #expect(try await alarms.requestAuthorization() == false)
        let alarmID = UUID()
        try await alarms.schedule(id: alarmID, timerID: "timer-test0001", phase: .focus, duration: 60)
        try alarms.pause(id: alarmID)
        #expect(try alarms.resume(id: alarmID) == false)
        try alarms.cancel(id: alarmID)
    }

    @Test @MainActor func injectedSchedulerBackendsStayTestable() async throws {
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        let alarms = RecordingSystemAlarmBackend()
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)
        let timerID = "remote-timer"
        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)
        try await scheduler.cancel(timerID: timerID)
        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: "pomodorough.remote-timer", phase: .focus, duration: 60),
            .remove(identifier: "pomodorough.remote-timer"),
        ])
        #expect(alarms.operations.isEmpty)
    }

    @Test @MainActor func injectedChimeControllerStaysTestable() {
        let session = FakeSession()
        let sound = FakeSound()
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = CompletionChimeController(
            resourceURL: { URL(fileURLWithPath: "/tmp/chime.wav") },
            makeSession: { session },
            makePlayer: { _ in sound },
            report: { failure in
                var current = reports.value
                current.append(failure)
                reports.value = current
            }
        )
        controller.play()
        #expect(session.activateCount == 1)
        #expect(sound.playCount == 1)
        #expect(reports.value.isEmpty)
    }

    @Test @MainActor func productionChimeUsesNoopUnderTests() throws {
        #expect(TestAudioSuppression.isEnabled == true)
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        let reports = LockedTestValue<[CompletionChimeFailure]>([])
        let controller = CompletionChimeController.production(
            resourceURL: { probe },
            report: { failure in
                var current = reports.value
                current.append(failure)
                reports.value = current
            }
        )
        controller.play()
        controller.stop()
        #expect(reports.value.isEmpty)
    }
}
