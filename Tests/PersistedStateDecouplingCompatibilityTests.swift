import CryptoKit
import Foundation
import Testing
@testable import Pomodorough

@Suite("Persisted State Decoupling Compatibility")
struct PersistedStateDecouplingCompatibilityTests {
    @Test
    func canonicalFixtureKeepsExactEncodedBytes() throws {
        let fixture = try Self.fixture()
        let payload = try Self.payload("canonicalState", from: fixture)
        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: payload)
        let encoded = try JSONEncoder.api.encode(decoded)

        #expect(fixture["formatVersion"] as? Int == 1)
        #expect(Self.sha256(encoded) == fixture["canonicalSHA256"] as? String)
        #expect(encoded.count == 839)
    }

    @Test
    func missingAndNullAdditiveValuesKeepSameDefaults() throws {
        let fixture = try Self.fixture()
        let missing = try Self.decode("missingDefaultsState", from: fixture)
        let explicitNull = try Self.decode("explicitNullDefaultsState", from: fixture)

        #expect(missing == explicitNull)
        #expect(missing.knownTasks == missing.tasks)
        #expect(missing.settings == TimerSettings())
        #expect(!missing.hasCorruptPendingOperations)
    }

    @Test
    func nullRequiredValueStillFailsDecoding() throws {
        let fixture = try Self.fixture()
        let data = try Self.payload("requiredNullState", from: fixture)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        }
    }

    @Test
    func lossyQueuesAndLegacySentinelsKeepCompatibility() throws {
        let fixture = try Self.fixture()
        let state = try Self.decode("lossyLegacySentinelState", from: fixture)

        #expect(state.hasCorruptPendingOperations)
        #expect(state.pendingAutoStartOperations.count == 1)
        #expect(state.pendingSelectedTaskOperations.count == 1)
        #expect(state.pendingDurationOperations.count == 1)
        #expect(state.pendingAutoStartOperations[0].occurredAt == Date(timeIntervalSince1970: 0))
        #expect(state.pendingSelectedTaskOperations[0].occurredAt == Date(timeIntervalSince1970: 0))
        #expect(state.pendingDurationOperations[0].occurredAt == Date(timeIntervalSince1970: 0))
    }

    @Test
    func legacyTaskAndSelectionMigrationKeepsOrderingAndUUIDSemantics() throws {
        let first = try #require(FocusTask(title: "First migrated task"))
        let selected = try #require(FocusTask(title: "Selected migrated task"))
        let anchor = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-compatibility"

        try state.migrateLegacyTasks(
            LocalTaskState(tasks: [first, selected], selectedTaskID: selected.id, assignments: [:]),
            at: anchor
        )
        #expect(try state.migrateLegacySelectedTask(at: anchor))

        let taskIDs = try state.pendingTaskOperations.map(Self.operationUUID)
        let selection = try #require(state.pendingSelectedTaskOperations.first)
        #expect(state.pendingTaskOperations.map(\.taskId) == [
            first.id.uuidString.lowercased(), selected.id.uuidString.lowercased()
        ])
        #expect(state.pendingTaskOperations.map(\.hlcCounter) == [0, 1])
        #expect(selection.hlcCounter == 2)
        #expect(try taskIDs.map { try UUIDv7.parts(of: $0).timestampMs } == [1_000_000, 1_000_000])
        #expect(try UUIDv7.parts(of: selection.id).timestampMs == 1_000_000)
        #expect(UUIDv7.isLess(taskIDs[0], than: taskIDs[1]))
        #expect(UUIDv7.isLess(taskIDs[1], than: selection.id))
    }

    @Test
    func deletedLegacySelectionDoesNotSurvivePendingTaskReplay() throws {
        let task = try #require(FocusTask(title: "Deleted selected task"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.selectedTaskID = task.id
        state.pendingTaskOperations = [Self.deleteOperation(for: task)]
        let original = state

        #expect(try !state.migrateLegacySelectedTask(at: Date(timeIntervalSince1970: 1_000)))
        #expect(state == original)
    }

    @Test
    func pendingCommandRebaseKeepsArrayOrderAndUsesSequenceClockOrder() throws {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let later = Self.command(id: "command-later", sequence: 2, wallMs: 1_000_002, at: anchor)
        let earlier = Self.command(id: "command-earlier", sequence: 1, wallMs: 1_000_001, at: anchor)
        var state = PersistedTimerState.fresh()
        state.pendingCommands = [later, earlier]

        try state.rebasePendingOperations(
            afterServerWallMs: 1_000_100,
            serverCounter: 10,
            serverTime: Date(timeIntervalSince1970: 1_000.1)
        )

        #expect(state.pendingCommands.map(\.id) == [later.id, earlier.id])
        #expect(state.pendingCommands.map(\.hlcWallMs) == [1_000_100, 1_000_100])
        #expect(state.pendingCommands.map(\.hlcCounter) == [12, 11])
        #expect((state.hlcWallMs, state.hlcCounter) == (1_000_100, 12))
    }

    private static func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/persisted-state-v1.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private static func decode(
        _ key: String,
        from fixture: [String: Any]
    ) throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: payload(key, from: fixture))
    }

    private static func payload(
        _ key: String,
        from fixture: [String: Any]
    ) throws -> Data {
        let object = try #require(fixture[key])
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func operationUUID(_ operation: TaskOperation) throws -> UUID {
        try #require(UUIDv7.payload(from: operation.id))
    }

    private static func deleteOperation(for task: FocusTask) -> TaskOperation {
        TaskOperation(
            id: "task-operation-delete-selected",
            taskId: task.id.uuidString.lowercased(),
            type: .delete,
            title: nil,
            occurredAt: Date(timeIntervalSince1970: 1_000),
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )
    }

    private static func command(
        id: String,
        sequence: Int64,
        wallMs: Int64,
        at date: Date
    ) -> TimerCommand {
        TimerCommand(
            id: id,
            deviceSequence: sequence,
            timerId: "timer-compatibility",
            taskId: nil,
            type: .start,
            phase: .focus,
            plannedDurationMs: 25 * 60_000,
            occurredAt: date,
            hlcWallMs: wallMs,
            hlcCounter: 0,
            observedElapsedMs: 0
        )
    }
}
