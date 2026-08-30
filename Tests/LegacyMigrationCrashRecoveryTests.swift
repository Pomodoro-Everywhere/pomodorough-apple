import Foundation
import Testing
@testable import Pomodorough

@Suite("Legacy Migration Crash Recovery")
struct LegacyMigrationCrashRecoveryTests {
    @Test(arguments: [false, true]) @MainActor
    func repeatedCrashAfterActualIrohCaptureReusesCommittedRecords(modernSnapshot: Bool) throws {
        let fixture = try CrashMigrationFixture(modernSnapshot: modernSnapshot)
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let first = fixture.load(store)
        #expect(first.replicationMode == .iroh)
        #expect(first.state.pendingSelectedTaskOperations.count == 1)
        let receipt = try #require(first.state.irohLegacyTaskMigration)
        let selectedID = try #require(first.state.pendingSelectedTaskOperations.first?.id)
        let captured = try store.captureLocalOperations(from: first.state)
        #expect(captured.selectedTaskID == fixture.legacy.selectedTaskID)
        #expect(captured.pendingTaskOperations.isEmpty)
        #expect(fixture.source == fixture.legacyBytes)
        for _ in 0..<3 {
            let reopened = fixture.roomStore()
            let loaded = fixture.load(reopened)
            #expect(!loaded.shouldReportInvalidLocalClock)
            #expect(loaded.state.pendingTaskOperations.isEmpty)
            #expect(loaded.state.pendingSelectedTaskOperations.isEmpty)
            #expect(loaded.state.irohLegacyTaskMigration == receipt)
            #expect(loaded.state.selectedTaskID == fixture.legacy.selectedTaskID)
            let retry = try reopened.captureLocalOperations(from: loaded.state)
            #expect(retry.irohLegacyTaskMigration == receipt)
            #expect(reopened.activeSnapshot?.operationCount == 4)
            #expect(try fixture.records(in: reopened, receipt: receipt) == receipt.records)
            #expect(receipt.records.contains { $0.id == selectedID.uuidString.lowercased() })
            #expect(fixture.source == fixture.legacyBytes)
        }
        try fixture.finishMigration(in: fixture.roomStore())
        let finalStore = fixture.roomStore()
        let final = fixture.load(finalStore)
        #expect(!final.removesLegacyTasksAfterProjection)
        #expect(final.state.selectedTaskID == fixture.legacy.selectedTaskID)
        #expect(finalStore.activeSnapshot?.operationCount == 4)
    }

    @Test(arguments: [false, true]) @MainActor
    func archivedAssignmentMetadataSurvivesProjectionAndRestart(activeTasks: Bool) throws {
        let fixture = try CrashMigrationFixture(activeTasks: activeTasks, archivedAssignment: true)
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let loaded = fixture.load(store)
        let archived = try #require(fixture.legacy.assignments["legacy-timer"])
        #expect(!loaded.state.pendingTaskOperations.contains { UUID(uuidString: $0.taskId) == archived.id })
        let captured = try store.captureLocalOperations(from: loaded.state)
        fixture.expectArchivedMetadata(in: captured, archived: archived)
        let roomID = try #require(store.activeRoomID)
        let remoteTask = try #require(FocusTask(title: "Remote task"))
        let remote = IrohOperationRecord(
            domain: .task, deviceId: "remote-device",
            payload: .task(TaskOperation(
                id: "remote-task", taskId: remoteTask.id.uuidString.lowercased(), type: .upsert,
                title: remoteTask.title, occurredAt: TestFixtures.anchor,
                hlcWallMs: Int64(TestFixtures.anchor.timeIntervalSince1970 * 1_000), hlcCounter: 20
            ))
        )
        let projected = try store.insertRemoteRecords([remote], roomID: roomID)
        fixture.expectArchivedMetadata(in: projected, archived: archived)
        for _ in 0..<3 {
            let reopened = fixture.roomStore()
            let reloaded = fixture.load(reopened)
            #expect(reloaded.state.pendingTaskOperations.isEmpty)
            let recaptured = try reopened.captureLocalOperations(from: reloaded.state)
            fixture.expectArchivedMetadata(in: recaptured, archived: archived)
            #expect(reopened.activeSnapshot?.operationCount == store.activeSnapshot?.operationCount)
        }
        try fixture.finishMigration(in: fixture.roomStore())
        fixture.expectArchivedMetadata(in: fixture.load(fixture.roomStore()).state, archived: archived)
    }

    @Test @MainActor
    func mismatchedSourceCannotReuseReceiptOrAuthorizeDelayedCleanup() throws {
        let fixture = try CrashMigrationFixture()
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let persistence = fixture.persistence()
        let loaded = fixture.load(store, persistence: persistence)
        let coordinator = fixture.coordinator(persistence, store: store)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let captured = try store.captureLocalOperations(from: loaded.state)
        #expect(coordinator.persist(loaded.state, to: .iroh(.captured(captured))).effects == [.removeLegacyTasks])
        var changed = fixture.legacy
        changed.selectedTaskID = changed.tasks.last?.id
        let replacement = try JSONEncoder.api.encode(changed)
        fixture.defaults.set(replacement, forKey: PersistedStateLoader.localTaskStorageKey)
        coordinator.removeLegacyTasks()
        #expect(fixture.source == replacement)
        let restarted = fixture.load(fixture.roomStore())
        #expect(restarted.shouldReportInvalidLocalClock)
        #expect(!restarted.removesLegacyTasksAfterProjection)
        #expect(restarted.state == captured)
        #expect(restarted.state.pendingTaskOperations.isEmpty)
        #expect(restarted.state.pendingSelectedTaskOperations.isEmpty)
        #expect(throws: (any Error).self) { try store.committedLegacyTaskMigration(source: replacement) }
        fixture.defaults.set(fixture.legacyBytes, forKey: PersistedStateLoader.localTaskStorageKey)
        try fixture.finishMigration(in: fixture.roomStore())
    }

    @Test @MainActor
    func wrongRoomRejectsPreparedReceiptBeforeCapture() throws {
        let fixture = try CrashMigrationFixture()
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let loaded = fixture.load(store)
        let originalRoomID = try #require(store.activeRoomID)
        try fixture.createRoom(in: store, secret: Data(32...63))
        let untouched = store.activeRoomState
        #expect(throws: (any Error).self) { try store.captureLocalOperations(from: loaded.state) }
        #expect(store.activeRoomState == untouched)
        #expect(store.activeSnapshot?.operationCount == 1)
        #expect(fixture.source == fixture.legacyBytes)
        _ = try store.activateExistingRoom(roomID: originalRoomID, returnState: .fresh())
        _ = try store.captureLocalOperations(from: loaded.state)
        try fixture.finishMigration(in: fixture.roomStore())
    }

    @Test(arguments: CaptureMismatch.allCases) @MainActor
    func partialOrMismatchedCaptureCannotCommitEvidence(mismatch: CaptureMismatch) throws {
        let fixture = try CrashMigrationFixture()
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let loaded = fixture.load(store)
        let before = store.activeRoomState
        let invalid = try mismatch.applying(to: loaded.state)
        #expect(throws: (any Error).self) { try store.captureLocalOperations(from: invalid) }
        #expect(store.activeRoomState == before)
        #expect(store.activeSnapshot?.operationCount == 1)
        #expect(fixture.source == fixture.legacyBytes)
        _ = try store.captureLocalOperations(from: loaded.state)
        try fixture.finishMigration(in: fixture.roomStore())
    }

    @Test @MainActor
    func conflictedRoomNeverRequeuesCommittedMigration() throws {
        let fixture = try CrashMigrationFixture()
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let loaded = fixture.load(store)
        _ = try store.captureLocalOperations(from: loaded.state)
        let operation = try #require(loaded.state.pendingTaskOperations.first)
        let conflict = IrohOperationRecord(domain: .task, deviceId: "other-device", payload: .task(operation))
        let roomID = try #require(store.activeRoomID)
        #expect(throws: (any Error).self) { try store.insertRemoteRecords([conflict], roomID: roomID) }
        let reopened = fixture.roomStore()
        let restarted = fixture.load(reopened)
        #expect(reopened.activeSnapshot?.conflict != nil)
        #expect(restarted.shouldReportInvalidLocalClock)
        #expect(!restarted.removesLegacyTasksAfterProjection)
        #expect(restarted.state.pendingTaskOperations.isEmpty)
        #expect(restarted.state.pendingSelectedTaskOperations.isEmpty)
        #expect(fixture.source == fixture.legacyBytes)
        #expect(throws: (any Error).self) { try reopened.captureLocalOperations(from: restarted.state) }
    }

    @Test @MainActor
    func repeatedFailedRoomWritesNeverPublishReceiptAndRetryRecovers() throws {
        let fixture = try CrashMigrationFixture(archivedAssignment: true)
        defer { fixture.cleanup() }
        let store = fixture.roomStore()
        try fixture.createRoom(in: store)
        let loaded = fixture.load(store)
        let before = store.activeRoomState
        let originalBytes = try Data(contentsOf: fixture.roomURL)
        let backup = fixture.directory.appendingPathComponent("room-backup.json")
        try FileManager.default.moveItem(at: fixture.roomURL, to: backup)
        try FileManager.default.createDirectory(at: fixture.roomURL, withIntermediateDirectories: false)
        for _ in 0..<3 {
            #expect(throws: (any Error).self) { try store.captureLocalOperations(from: loaded.state) }
            #expect(store.activeRoomState == before)
            #expect(store.activeRoomState?.irohLegacyTaskMigration == nil)
            #expect(fixture.source == fixture.legacyBytes)
            #expect(try Data(contentsOf: backup) == originalBytes)
        }
        try FileManager.default.removeItem(at: fixture.roomURL)
        try FileManager.default.moveItem(at: backup, to: fixture.roomURL)
        let reopened = fixture.roomStore()
        #expect(reopened.activeRoomState == before)
        let captured = try reopened.captureLocalOperations(from: loaded.state)
        #expect(captured.irohLegacyTaskMigration == loaded.state.irohLegacyTaskMigration)
        #expect(fixture.load(fixture.roomStore()).state.pendingTaskOperations.isEmpty)
        try fixture.finishMigration(in: fixture.roomStore())
    }
}

extension LegacyMigrationCrashRecoveryTests {
    enum CaptureMismatch: CaseIterable, Sendable {
        case missingTasks, missingSelection, outerDevice, taskPayload

        func applying(to state: PersistedTimerState) throws -> PersistedTimerState {
            var changed = state
            switch self {
            case .missingTasks: changed.pendingTaskOperations = []
            case .missingSelection: changed.pendingSelectedTaskOperations = []
            case .outerDevice: changed.deviceId = "other-device"
            case .taskPayload:
                let original = try #require(state.pendingTaskOperations.first)
                changed.pendingTaskOperations[0] = TaskOperation(
                    id: original.id, taskId: original.taskId, type: original.type, title: original.title,
                    occurredAt: original.occurredAt, hlcWallMs: original.hlcWallMs,
                    hlcCounter: original.hlcCounter + 1
                )
            }
            return changed
        }
    }
}

@MainActor
private struct CrashMigrationFixture {
    let suiteName = "LegacyMigrationCrashRecoveryTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LegacyMigrationCrashRecoveryTests-\(UUID().uuidString)")
    let defaults: RecordingUserDefaults
    let secrets = MemoryIrohRoomSecretStore()
    let legacy: LocalTaskState
    let legacyBytes: Data
    var roomURL: URL { directory.appendingPathComponent("rooms.json") }
    var source: Data? { defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) }

    init(modernSnapshot: Bool = false, activeTasks: Bool = true, archivedAssignment: Bool = false) throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        let first = try #require(FocusTask(title: "First legacy task"))
        let second = try #require(FocusTask(title: "Second legacy task"))
        let archived = try #require(FocusTask(title: "Archived assignment only"))
        legacy = LocalTaskState(
            tasks: activeTasks ? [first, second] : [], selectedTaskID: activeTasks ? first.id : nil,
            assignments: archivedAssignment ? ["legacy-timer": archived] : [:]
        )
        legacyBytes = try JSONEncoder.api.encode(legacy)
        defaults.set(legacyBytes, forKey: PersistedStateLoader.localTaskStorageKey)
        if modernSnapshot {
            defaults.set(try JSONEncoder.api.encode(PersistedTimerState.fresh()), forKey: PersistedStateLoader.storageKey)
        }
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func roomStore() -> IrohRoomStore {
        IrohRoomStore(fileURL: roomURL, secretStore: secrets, now: { TestFixtures.anchor })
    }

    func createRoom(in store: IrohRoomStore, secret: Data = Data(0...31)) throws {
        let history = legacy.assignments.keys.map { timerID in
            HistoryItem(
                id: "history-" + timerID, timerId: timerID, commandId: "finish-" + timerID,
                taskId: nil, phase: .focus, status: "completed", plannedDurationMs: 60_000,
                completedAt: TestFixtures.anchor, endedAt: TestFixtures.anchor
            )
        }
        _ = try store.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret, name: nil, returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: history, tasks: [], durationsMs: .defaults,
                autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0
            ), now: TestFixtures.anchor
        )
    }

    func persistence() -> AppStatePersistenceCoordinator {
        AppStatePersistenceCoordinator(
            defaults: defaults,
            durableLocalStore: AtomicDurableFileStore(fileURL: directory.appendingPathComponent("workspace.json"))
        )
    }

    func load(
        _ store: IrohRoomStore,
        persistence: AppStatePersistenceCoordinator? = nil
    ) -> AppStatePersistenceCoordinator.LoadTransition {
        (persistence ?? self.persistence()).load(
            replicationMode: .iroh, roomStore: store, wallDate: TestFixtures.anchor, uptime: 100
        )
    }

    func coordinator(
        _ persistence: AppStatePersistenceCoordinator,
        store: IrohRoomStore
    ) -> CentralizedAccountSessionCoordinator {
        let api = APIClient(keychain: EmptyTokenStore())
        return CentralizedAccountSessionCoordinator(
            lifecycle: .init(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
            synchronization: .init(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
            initialPublication: .init(sessionState: .localOnly), persistence: persistence, roomStore: store
        )
    }

    func records(in store: IrohRoomStore, receipt: IrohLegacyTaskMigration) throws -> [IrohOperationRecord] {
        try store.operations(
            roomID: receipt.roomID,
            references: receipt.records.map { IrohInventoryReference(domain: $0.domain, id: $0.id) }
        )
    }

    func expectArchivedMetadata(in state: PersistedTimerState, archived: FocusTask) {
        #expect(state.knownTasks.contains(archived))
        #expect(!state.tasks.contains(archived))
        #expect(state.legacyTaskAssignments["legacy-timer"] == archived.id)
        #expect(state.history.first { $0.timerId == "legacy-timer" }?.taskId == archived.id.uuidString.lowercased())
    }

    func finishMigration(in store: IrohRoomStore) throws {
        let persistence = persistence()
        let loaded = load(store, persistence: persistence)
        let coordinator = coordinator(persistence, store: store)
        #expect(coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true) == [.persist])
        let captured = try store.captureLocalOperations(from: loaded.state)
        #expect(coordinator.persist(loaded.state, to: .iroh(.captured(captured))).effects == [.removeLegacyTasks])
        #expect(source == legacyBytes)
        coordinator.removeLegacyTasks()
        #expect(source == nil)
    }
}
