import Foundation
import Testing
@testable import Pomodorough

@Suite("Immutable retarget")
struct ImmutableRetargetTests {
    @Test func retargetNilEncodesExplicitNullDistinctFromOmission() throws {
        let date = Date(timeIntervalSince1970: 1_774_166_400)
        let retargetNil = TimerCommand(
            id: "command-retarget-nil", deviceSequence: 2, timerId: "timer-a", taskId: nil,
            type: .retarget, phase: .focus, plannedDurationMs: 60_000, occurredAt: date,
            hlcWallMs: 1_774_166_400_000, hlcCounter: 1, observedElapsedMs: 0
        )
        let pauseNil = TimerCommand(
            id: "command-pause-nil", deviceSequence: 2, timerId: "timer-a", taskId: nil,
            type: .pause, phase: .focus, plannedDurationMs: 60_000, occurredAt: date,
            hlcWallMs: 1_774_166_400_000, hlcCounter: 1, observedElapsedMs: 0
        )
        let retargetJSON = try JSONEncoder.api.encode(retargetNil)
        let pauseJSON = try JSONEncoder.api.encode(pauseNil)
        let retargetObject = try #require(JSONSerialization.jsonObject(with: retargetJSON) as? [String: Any])
        let pauseObject = try #require(JSONSerialization.jsonObject(with: pauseJSON) as? [String: Any])
        #expect(retargetObject.keys.contains("taskId"))
        #expect(retargetObject["taskId"] is NSNull)
        #expect(!pauseObject.keys.contains("taskId"))
        let coreRetarget = CoreTimerCommand(retargetNil, deviceId: "device-a")
        let coreJSON = try JSONEncoder.sharedCoreLike.encode(coreRetarget)
        let coreObject = try #require(JSONSerialization.jsonObject(with: coreJSON) as? [String: Any])
        #expect(coreObject["taskId"] is NSNull)
    }

    @Test func omittedRetargetDecodingFails() throws {
        var omitted: [String: Any] = [
            "id": "command-omitted", "deviceSequence": 2, "timerId": "timer-a",
            "type": "retarget", "phase": "focus", "plannedDurationMs": 60_000,
            "occurredAt": "2026-03-06T12:00:00Z", "hlcWallMs": 1_774_166_400_000,
            "hlcCounter": 1, "observedElapsedMs": 0
        ]
        let appData = try JSONSerialization.data(withJSONObject: omitted)
        #expect(throws: (any Error).self) {
            try JSONDecoder.api.decode(TimerCommand.self, from: appData)
        }
        omitted["deviceId"] = "device-a"
        let coreData = try JSONSerialization.data(withJSONObject: omitted)
        #expect(throws: (any Error).self) {
            try JSONDecoder.api.decode(CoreTimerCommand.self, from: coreData)
        }
        let recordJSON: [String: Any] = [
            "domain": "timer", "deviceId": "device-a",
            "operation": omitted
        ]
        let recordData = try JSONSerialization.data(withJSONObject: recordJSON)
        #expect(throws: (any Error).self) {
            try JSONDecoder.api.decode(IrohOperationRecord.self, from: recordData)
        }
    }

    @Test func retargetPreservesLifecycleAndElapsed() throws {
        let core = try SharedCore.bundled()
        let startJSON: [String: Any] = [
            "id": "command-start-immutable", "deviceId": "device-a", "deviceSequence": 1,
            "timerId": "timer-immutable", "taskId": "11111111-1111-1111-1111-111111111111",
            "type": "start", "phase": "focus", "plannedDurationMs": 60_000,
            "occurredAt": "2026-09-13T12:00:01Z", "hlcWallMs": 1_789_300_800_000, "hlcCounter": 0,
            "observedElapsedMs": 0
        ]
        let base = try core.dispatch(
            "timer.reduce.v1",
            inputJSON: JSONSerialization.data(withJSONObject: ["commands": [startJSON], "now": "2026-09-13T12:00:02Z"]),
            as: ImmutableTimerReduction.self
        )
        var retargetJSON = startJSON
        retargetJSON["id"] = "command-retarget-immutable"
        retargetJSON["deviceSequence"] = 2
        retargetJSON["taskId"] = "22222222-2222-2222-2222-222222222222"
        retargetJSON["type"] = "retarget"
        retargetJSON["hlcCounter"] = 1
        let result = try core.dispatch(
            "timer.reduce.v1",
            inputJSON: JSONSerialization.data(withJSONObject: ["commands": [startJSON, retargetJSON], "now": "2026-09-13T12:00:02Z"]),
            as: ImmutableTimerReduction.self
        )
        #expect(result.canonicalTimer?.taskId == "22222222-2222-2222-2222-222222222222")
        #expect(result.canonicalTimer?.anchorAt == base.canonicalTimer?.anchorAt)
        #expect(result.canonicalTimer?.status == base.canonicalTimer?.status)
    }

    @Test @MainActor func pausedTimerAcceptsImmutableRetarget() throws {
        let suiteName = "ImmutableRetargetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldTask = try #require(FocusTask(title: "Paused old"))
        let newTask = try #require(FocusTask(title: "Paused new"))
        var state = PersistedTimerState.fresh()
        state.tasks = [oldTask, newTask]
        state.knownTasks = state.tasks
        state.selectedTaskID = oldTask.id
        state.canonicalTimer = TestFixtures.timer(
            status: .paused, elapsed: 15_000, timerID: "timer-paused-retarget",
            taskID: oldTask.id.uuidString.lowercased()
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.selectedTaskID = newTask.id
        let persisted = try persistedState(defaults)
        #expect(persisted.pendingCommands.contains { $0.type == .retarget && $0.taskId == newTask.id.uuidString.lowercased() })
        #expect(!persisted.pendingCommands.contains { $0.type == .start && $0.taskId == newTask.id.uuidString.lowercased() })
        #expect(model.task(forTimerID: "timer-paused-retarget")?.id == newTask.id)
    }

    @Test @MainActor func acknowledgedTimerRetargetKeepsStartImmutable() throws {
        let suiteName = "ImmutableRetargetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldTask = try #require(FocusTask(title: "Acked old"))
        let newTask = try #require(FocusTask(title: "Acked new"))
        var state = PersistedTimerState.fresh()
        state.tasks = [oldTask, newTask]
        state.knownTasks = state.tasks
        state.selectedTaskID = oldTask.id
        // Live anchor keeps the running timer active at projection time. The shared
        // TestFixtures.timer anchor (1970) is already expired, so Core auto-completes
        // it before retarget and correctly ignores the retarget as not active.
        state.canonicalTimer = CanonicalTimer(
            id: "timer-acked-retarget",
            taskId: oldTask.id.uuidString.lowercased(),
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 5_000,
            anchorAt: Date(),
            lastIntent: nil
        )
        state.pendingCommands = []
        state.neverSentCommandIDs = []
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.selectedTaskID = newTask.id
        let persisted = try persistedState(defaults)
        #expect(persisted.pendingCommands.filter { $0.type == .start }.isEmpty)
        let retarget = try #require(persisted.pendingCommands.first { $0.type == .retarget })
        #expect(retarget.timerId == "timer-acked-retarget")
        #expect(retarget.taskId == newTask.id.uuidString.lowercased())
    }

    @Test func restartPreservesProofPendingAndHead() throws {
        var state = PersistedTimerState.fresh()
        let command = TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "timer-restart")
        state.pendingCommands = [command]
        state.neverSentCommandIDs = [command.id]
        state.storeCanonicalHead(wallMs: 1_774_166_400_000, counter: 7)
        let encoded = try JSONEncoder.api.encode(state)
        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: encoded)
        #expect(decoded.pendingCommands == [command])
        #expect(decoded.neverSentCommandIDs == [command.id])
        #expect(decoded.canonicalHeadWallMs == 1_774_166_400_000)
        #expect(decoded.canonicalHeadCounter == 7)
        #expect(decoded.neverSentProof().commands == [command.id])
    }

    @Test @MainActor func retryRetainsExactPayload() throws {
        var state = PersistedTimerState.fresh()
        let command = TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "timer-retry")
        state.pendingCommands = [command]
        state.neverSentCommandIDs = [command.id]
        let sync = AccountSynchronization(api: APIClient(session: .shared, keychain: EmptyTokenStore()), sharedCoreProvider: { try SharedCore.bundled() })
        let first = sync.prepareSyncPlan(state: state)
        #expect(first.plan.batch.commands == [command])
        #expect(!first.retired.neverSentCommandIDs.contains(command.id))
        #expect(first.retired.pendingCommands == [command])
        let second = sync.prepareSyncPlan(state: first.retired)
        #expect(second.plan.batch.commands == [command])
        #expect(second.plan.request.commands == first.plan.request.commands)
    }

    @Test func safeProjectionExcludesPossiblyDeliveredWork() throws {
        var state = PersistedTimerState.fresh()
        let old = TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "timer-safe-old")
        let fresh = TestFixtures.command(.pause, sequence: 2, elapsed: 1_000, timerID: "timer-safe-old")
        state.pendingCommands = [old, fresh]
        state.neverSentCommandIDs = [fresh.id]
        state.storeCanonicalHead(wallMs: old.hlcWallMs + 1_000, counter: 0)
        #expect(state.safeProjectionCommands().isEmpty)
        #expect(state.pendingCommands.count == 2)
        var proven = state
        proven.neverSentCommandIDs = [old.id, fresh.id]
        proven.storeCanonicalHead(wallMs: old.hlcWallMs - 1_000, counter: 0)
        #expect(proven.safeProjectionCommands().count == 2)
    }

    @Test func irohRetargetRecordRoundTripsExactly() throws {
        let date = Date(timeIntervalSince1970: 1_774_166_400)
        let command = TimerCommand(
            id: "command-iroh-retarget", deviceSequence: 2, timerId: "timer-iroh",
            taskId: nil, type: .retarget, phase: .focus, plannedDurationMs: 60_000,
            occurredAt: date, hlcWallMs: 1_774_166_400_000, hlcCounter: 1, observedElapsedMs: 5_000
        )
        let record = IrohOperationRecord(domain: .timer, deviceId: "device-iroh", payload: .timer(command))
        #expect(record.isValid)
        let digest = try record.digest()
        let bytes = try record.canonicalBytes()
        let decoded = try JSONDecoder.api.decode(IrohOperationRecord.self, from: bytes)
        #expect(decoded == record)
        #expect(try decoded.digest() == digest)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(command)) as? [String: Any]
        #expect((json?["taskId"] as? NSNull) != nil)
    }

    @Test func historyConvergesToRetargetedTask() throws {
        let oldTask = try #require(FocusTask(title: "History old"))
        let newTask = try #require(FocusTask(title: "History new"))
        let completedAt = Date(timeIntervalSince1970: 1_774_166_400)
        let item = TestFixtures.history(
            id: "timer-history-retarget", durationMs: 60_000, date: completedAt,
            taskID: newTask.id.uuidString.lowercased()
        )
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: nil, history: [item], tasks: [oldTask, newTask],
            state: PersistedTimerState.fresh()
        )
        let publisher = AppStatePublisher()
        #expect(publisher.task(forTimerID: "timer-history-retarget", snapshot: snapshot)?.id == newTask.id)
        let summaries = publisher.taskSummaries(for: completedAt, calendar: .current, snapshot: snapshot)
        #expect(summaries.first { $0.task.id == newTask.id }?.finishedPomodoros == 1)
        #expect(summaries.first { $0.task.id == oldTask.id }?.finishedPomodoros == 0)
    }

    @Test func retargetFinishHistoryConvergesToRetargetedTask() throws {
        let oldTask = try #require(FocusTask(title: "Core old finish"))
        let newTask = try #require(FocusTask(title: "Core new finish"))
        let core = try SharedCore.bundled()
        let timerID = "timer-core-retarget-finish"
        let start: [String: Any] = [
            "id": "command-core-start", "deviceId": "device-a", "deviceSequence": 1,
            "timerId": timerID, "taskId": oldTask.id.uuidString.lowercased(),
            "type": "start", "phase": "focus", "plannedDurationMs": 60_000,
            "occurredAt": "2026-09-13T12:00:01Z", "hlcWallMs": 1_789_300_800_000, "hlcCounter": 0,
            "observedElapsedMs": 0
        ]
        var retarget = start
        retarget["id"] = "command-core-retarget"
        retarget["deviceSequence"] = 2
        retarget["taskId"] = newTask.id.uuidString.lowercased()
        retarget["type"] = "retarget"
        retarget["hlcCounter"] = 1
        var finish = start
        finish["id"] = "command-core-finish"
        finish["deviceSequence"] = 3
        finish.removeValue(forKey: "taskId")
        finish["type"] = "finish"
        finish["hlcCounter"] = 2
        finish["observedElapsedMs"] = 60_000
        let result = try core.dispatch(
            "timer.reduce.v1",
            inputJSON: JSONSerialization.data(withJSONObject: [
                "commands": [start, retarget, finish], "now": "2026-09-13T12:00:02Z"
            ]),
            as: ImmutableRetargetFinishReduction.self
        )
        let item = try #require(result.history.first)
        #expect(item.taskId == newTask.id.uuidString.lowercased())
        #expect(item.timerId == timerID)
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: nil, history: result.history,
            tasks: [oldTask, newTask], state: PersistedTimerState.fresh()
        )
        #expect(AppStatePublisher().task(forTimerID: timerID, snapshot: snapshot)?.id == newTask.id)
    }

    private func persistedState(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }
}

private struct ImmutableTimerReduction: Decodable {
    struct Timer: Decodable {
        let taskId: String?
        let anchorAt: String?
        let status: String?
    }
    let canonicalTimer: Timer?
}

private struct ImmutableRetargetFinishReduction: Decodable {
    let history: [HistoryItem]
}

private extension JSONEncoder {
    static var sharedCoreLike: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
