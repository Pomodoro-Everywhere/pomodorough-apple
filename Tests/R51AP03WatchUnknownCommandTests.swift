import Foundation
import Testing
@testable import Pomodorough

@Suite("R51-AP03 unknown Watch vocabulary fixed reason", .serialized)
struct R51AP03WatchUnknownCommandTests {
    @Test
    func unknownErrorIsFixedReasonWithCappedLength() {
        #expect(WatchUnknownCommandError(name: "rewind").localizedDescription == "unknown_command len=6")
        #expect(WatchUnknownCommandError(name: "").localizedDescription == "unknown_command len=0")
        let long = String(repeating: "x", count: 9_000)
        let capped = WatchUnknownCommandError(name: long)
        #expect(capped.localizedDescription == "unknown_command len=8192")
        #expect(!capped.localizedDescription.contains(long))
        #expect(WatchUnknownCommandError(nameLength: 9_000).localizedDescription == "unknown_command len=8192")
        #expect(WatchUnknownCommandError(nameLength: -5).localizedDescription == "unknown_command len=0")
    }

    @Test
    func unknownNameVariantsStayFixedReason() {
        let sentinel = "private-sentinel-R51-AP03"
        let variants = [
            "rewind",
            String(repeating: "s", count: 8_112),
            "ünïcödé\nnewline",
            sentinel,
            String(repeating: "🧪", count: 100),
        ]
        for name in variants {
            let description = WatchUnknownCommandError(name: name).localizedDescription
            #expect(description.hasPrefix("unknown_command len="))
            #expect(!description.contains(name))
        }
        #expect(!WatchUnknownCommandError(name: sentinel).localizedDescription.contains("private-sentinel"))
    }

    @Test @MainActor
    func captureIsFixedReasonBoundedNoRawName() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        let sentinel = "sentinel-R51-AP03-" + String(repeating: "s", count: 8_112)
        var first = WatchTimerCommand.start()
        first.name = sentinel
        for _ in 0..<4 {
            #expect(model.applyWatchCommand(first) == false)
        }
        var second = WatchTimerCommand.start()
        second.name = "another-unknown"
        #expect(model.applyWatchCommand(second) == false)
        #expect(recorded.value.count == 1)
        #expect(recorded.value.first?.hasPrefix("unknown_command len=") == true)
        #expect(!(recorded.value.first?.contains(sentinel) ?? false))
        #expect(!(recorded.value.first?.contains("sentinel-R51") ?? false))
    }

    // Behavior behind the former source-grep tripwire: an unknown command is
    // rejected without touching the workspace, session, or error message.
    // No prod source is read; renames keep this green while behavior holds.
    @Test @MainActor
    func unknownCommandLeavesWorkspaceUntouched() async throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let added = await model.addTask("Keep me R51-AP03")
        try #require(added)
        let tasksBefore = model.tasks.map(\.id)
        let sessionBefore = model.sessionState
        var unknown = WatchTimerCommand.start()
        unknown.name = "totally-bogus-R51-AP03"
        #expect(model.applyWatchCommand(unknown) == false)
        #expect(model.tasks.map(\.id) == tasksBefore)
        #expect(model.sessionState == sessionBefore)
        #expect(model.errorMessage == nil)
    }

    // Mechanism the unknown-command log call site relies on: first emit per
    // key logs, repeats stay silent. Unique key keeps this order-independent.
    @Test
    func watchUnknownLogDedupeEmitsOncePerKey() {
        let key = "watch-command-unknown-probe-\(UUID().uuidString)"
        #expect(WatchSyncLogDedupe.shouldLog(key: key))
        #expect(!WatchSyncLogDedupe.shouldLog(key: key))
    }

    @Test @MainActor
    func knownCommandControlEmitsNoUnknownCapture() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        defer { SentryCapture.resetForTesting() }
        #expect(model.applyWatchCommand(.start()) == true)
        #expect(recorded.value.isEmpty)
        #expect(WatchPauseRefusedError().localizedDescription == "pause")
        #expect(WatchStartRefusedError().localizedDescription == "start")
    }

    @MainActor
    private func makeModel() -> (AppModel, UserDefaults, String) {
        let suite = "PomodoroughTests.R51AP03.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        return (model, defaults, suite)
    }
}
