#if os(iOS)
import Foundation
import Testing
@testable import Pomodorough

struct TimerWidgetSnapshotTests {
    @Test func snapshotRoundTripsAndCompletesAtDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = TimerActivityAttributes.ContentState(
            phase: "focus", taskTitle: "Write", startedAt: start,
            endsAt: start.addingTimeInterval(60), remaining: 60, isPaused: false
        )
        let snapshot = TimerWidgetSnapshot(timer: timer)
        let decoded = try JSONDecoder().decode(TimerWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(!snapshot.isComplete(at: start.addingTimeInterval(59)))
        #expect(snapshot.isComplete(at: start.addingTimeInterval(60)))
        #expect(snapshot.isComplete(at: start.addingTimeInterval(600)))
    }

    @Test func pausedAndIdleSnapshotsDoNotCompleteWithWallClock() {
        let timer = TimerActivityAttributes.ContentState(
            phase: "short_break", taskTitle: nil, startedAt: .distantPast,
            endsAt: .distantPast, remaining: 42, isPaused: true
        )
        #expect(!TimerWidgetSnapshot(timer: timer).isComplete(at: .now))
        #expect(!TimerWidgetSnapshot(timer: nil).isComplete(at: .now))
    }

    // AP122: the widget extension cannot reach Sentry, so decode failures
    // count in the shared app group with no payload for the app to report.
    @Test func decodeFailureCounterCountsAndSaturates() throws {
        let suite = "PomodoroughTests.WidgetCounter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TimerWidgetSnapshot.takeDecodeFailures(from: defaults) == 0)
        TimerWidgetSnapshot.recordDecodeFailure(in: defaults)
        TimerWidgetSnapshot.recordDecodeFailure(in: defaults)
        #expect(TimerWidgetSnapshot.takeDecodeFailures(from: defaults) == 2)
        #expect(TimerWidgetSnapshot.takeDecodeFailures(from: defaults) == 0)
        defaults.set(TimerWidgetSnapshot.decodeFailureCountCeiling, forKey: TimerWidgetSnapshot.decodeFailureCountKey)
        TimerWidgetSnapshot.recordDecodeFailure(in: defaults)
        #expect(defaults.integer(forKey: TimerWidgetSnapshot.decodeFailureCountKey) == TimerWidgetSnapshot.decodeFailureCountCeiling)
    }

    @Test func decodeFailureReportCarriesOnlyTheCount() {
        let recorded = LockedTestValue<[String]>([])
        let counts = LockedTestValue<[Int]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(String(describing: error))
            recorded.value = current
            if let failure = error as? WidgetSnapshotDecodeError {
                var seen = counts.value
                seen.append(failure.count)
                counts.value = seen
            }
        }
        defer { SentryCapture.resetForTesting() }
        TimerLiveActivityCoordinator.reportWidgetDecodeFailures(0)
        #expect(recorded.value.isEmpty)
        TimerLiveActivityCoordinator.reportWidgetDecodeFailures(3)
        TimerLiveActivityCoordinator.reportWidgetDecodeFailures(3)
        #expect(recorded.value.count == 1)
        #expect(counts.value == [3])
    }
}
#endif
