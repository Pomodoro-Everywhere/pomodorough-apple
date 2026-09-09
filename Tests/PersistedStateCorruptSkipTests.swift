import Foundation
import Testing
@testable import Pomodorough

// AP51: a single unknown/corrupt op must skip lossily, flag the state,
// and report once — never wipe the whole persisted state silently.
@Suite("Persisted corrupt-operation skip")
struct PersistedStateCorruptSkipTests {
    @Test
    func unknownCommandTypeSkipsElementAndFlagsCorruption() throws {
        let data = try stateData(appending: [(
            key: "pendingCommands",
            element: commandDict(type: "snooze_future")
        )])
        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        #expect(decoded.deviceId == "device-corrupt-skip")
        #expect(decoded.pendingCommands.count == 1)
        #expect(decoded.pendingCommands[0].id == "command-test1")
        #expect(decoded.hasCorruptPendingOperations)
    }

    @Test
    func corruptElementsAcrossQueuesSkipWithoutWipingState() throws {
        let data = try stateData(appending: [
            (key: "pendingCommands", element: commandDict(type: "snooze_future")),
            (key: "pendingTaskOperations", element: taskOperationDict(type: "explode")),
            (key: "pendingDurationOperations", element: durationOperationDict(phase: "nap")),
            (key: "history", element: historyDict(plannedDurationMs: "sixty-seconds")),
        ])
        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        #expect(decoded.deviceId == "device-corrupt-skip")
        #expect(decoded.pendingCommands.count == 1)
        #expect(decoded.pendingTaskOperations.count == 1)
        #expect(decoded.pendingDurationOperations.count == 1)
        #expect(decoded.history.count == 1)
        #expect(decoded.history[0].id == "history-valid")
        #expect(decoded.hasCorruptPendingOperations)
    }

    @Test
    func loaderPreservesStateAndReportsCorruptSkipOnce() throws {
        let recorded = LockedTestValue<[String]>([])
        let suiteName = "PersistedStateCorruptSkipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corrupt = try stateData(appending: [(
            key: "pendingCommands",
            element: commandDict(type: "snooze_future")
        )])
        defaults.set(corrupt, forKey: PersistedStateLoader.storageKey)
        let loader = PersistedStateLoader(defaults: defaults)
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let first = loader.load()
        let second = loader.load()
        #expect(first.localState.deviceId == "device-corrupt-skip")
        #expect(first.localState.pendingCommands.count == 1)
        #expect(first.localState.hasCorruptPendingOperations)
        #expect(second.decodedState?.deviceId == "device-corrupt-skip")
        #expect(recorded.value.count == 1)
        defaults.set(try JSONEncoder.api.encode(PersistedTimerState.fresh()), forKey: PersistedStateLoader.storageKey)
        _ = loader.load()
        #expect(recorded.value.count == 1)
    }

    private func validBaseState() throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-corrupt-skip"
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        let task = try #require(FocusTask(title: "Corrupt Skip Task"))
        state.pendingTaskOperations = [TaskOperation(
            id: "task-op-valid",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )]
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-op-valid", phase: .focus, durationMs: 1_500_000, wallMs: 1_000_000
        )]
        state.history = [TestFixtures.history(
            id: "history-valid", durationMs: 1_500_000, date: TestFixtures.anchor
        )]
        return state
    }

    private func stateData(
        appending elements: [(key: String, element: [String: Any])]
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(validBaseState())) as? [String: Any]
        )
        for (key, element) in elements {
            var array = try #require(object[key] as? [[String: Any]])
            array.append(element)
            object[key] = array
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func elementDict<Value: Encodable>(
        _ value: Value,
        mutate: (inout [String: Any]) -> Void
    ) throws -> [String: Any] {
        var dict = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(value)) as? [String: Any]
        )
        mutate(&dict)
        return dict
    }

    private func commandDict(type: String) throws -> [String: Any] {
        try elementDict(TestFixtures.command(.start, sequence: 9, elapsed: 0)) { $0["type"] = type }
    }

    private func taskOperationDict(type: String) throws -> [String: Any] {
        let task = try #require(FocusTask(title: "Corrupt Future Task"))
        return try elementDict(TaskOperation(
            id: "task-op-future",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )) { $0["type"] = type }
    }

    private func durationOperationDict(phase: String) throws -> [String: Any] {
        try elementDict(TestFixtures.durationOperation(
            id: "duration-op-future", phase: .focus, durationMs: 1_500_000, wallMs: 1_000_000
        )) { $0["phase"] = phase }
    }

    private func historyDict(plannedDurationMs: Any) throws -> [String: Any] {
        try elementDict(TestFixtures.history(
            id: "history-future", durationMs: 1_500_000, date: TestFixtures.anchor
        )) { $0["plannedDurationMs"] = plannedDurationMs }
    }
}
