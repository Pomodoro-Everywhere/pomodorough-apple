import Foundation
import Testing
@testable import Pomodorough

@Suite("Legacy task migration durability")
struct LegacyMigrationDurabilityTests {
    @Test @MainActor
    func failedDestinationWriteRetainsLegacyUntilSuccessfulRetry() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let loaded = fixture.load(persistence)
        let coordinator = fixture.coordinator(persistence)
        #expect(coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true) == [.persist])
        try fixture.blockDestination()

        let failed = coordinator.persist(loaded.state, to: .local)
        #expect(!failed.action.succeeded)
        #expect(!failed.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == nil)

        try fixture.unblockDestination()
        let retried = coordinator.persist(failed.action.state, to: .local)
        #expect(retried.action.succeeded)
        #expect(retried.effects == [.removeLegacyTasks])
        #expect(try fixture.savedState() == loaded.state)
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == nil)
        #expect(!coordinator.persist(retried.action.state, to: .local).effects.contains(.removeLegacyTasks))
        #expect(try fixture.savedState().pendingTaskOperations == loaded.state.pendingTaskOperations)
    }

    @Test @MainActor
    func restartAfterFailedWriteRecoversSoleLegacyCopy() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let loaded = fixture.load(persistence)
        let coordinator = fixture.coordinator(persistence)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        try fixture.blockDestination()
        #expect(!coordinator.persist(loaded.state, to: .local).action.succeeded)
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)

        try fixture.unblockDestination()
        let restartedPersistence = fixture.persistence()
        let restarted = fixture.load(restartedPersistence)
        let restartedCoordinator = fixture.coordinator(restartedPersistence)
        #expect(restarted.state.tasks == fixture.legacy.tasks)
        #expect(restarted.state.pendingTaskOperations.count == fixture.legacy.tasks.count)
        #expect(restarted.state.pendingSelectedTaskOperations.count == 1)
        _ = restartedCoordinator.loadCompletionEffects(for: restarted, projectionSucceeded: true)
        let committed = restartedCoordinator.persist(restarted.state, to: .local)
        #expect(committed.action.succeeded)
        #expect(committed.effects == [.removeLegacyTasks])
        restartedCoordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == nil)
        #expect(try fixture.savedState().pendingTaskOperations == restarted.state.pendingTaskOperations)
    }

    @Test @MainActor
    func uncommittedApplicationStateRetainsLegacyAcrossRetryAndRestart() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let failingStore = AtomicDurableFileStore(fileURL: fixture.url) {
            throw POSIXError(.EIO)
        }
        let persistence = AppStatePersistenceCoordinator(defaults: fixture.defaults, durableLocalStore: failingStore)
        let loaded = fixture.load(persistence)
        let coordinator = fixture.coordinator(persistence)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)

        let failed = coordinator.persistAtomically(
            previous: .fresh(), proposed: loaded.state, to: .local, rebuildsOnRollback: true
        )
        #expect(!failed.action.succeeded)
        #expect(failed.action.state == loaded.state)
        #expect(try fixture.savedState() == loaded.state)
        #expect(!failed.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)

        let retried = coordinator.persist(failed.action.state, to: .local)
        #expect(!retried.action.succeeded)
        #expect(!retried.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)

        let restartedPersistence = fixture.persistence()
        let restarted = fixture.load(restartedPersistence)
        let restartedCoordinator = fixture.coordinator(restartedPersistence)
        #expect(restarted.state.pendingTaskOperations == loaded.state.pendingTaskOperations)
        #expect(restarted.state.pendingSelectedTaskOperations == loaded.state.pendingSelectedTaskOperations)
        #expect(restartedCoordinator.loadCompletionEffects(for: restarted, projectionSucceeded: true) == [.persist])
        let committed = restartedCoordinator.persist(restarted.state, to: .local)
        #expect(committed.action.succeeded)
        #expect(committed.effects == [.removeLegacyTasks])
        restartedCoordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == nil)
        #expect(try fixture.savedState().pendingTaskOperations == loaded.state.pendingTaskOperations)
    }

    @Test @MainActor
    func restartBetweenCommitAndCleanupDoesNotDuplicateWork() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let loaded = fixture.load(persistence)
        let coordinator = fixture.coordinator(persistence)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        #expect(coordinator.persist(loaded.state, to: .local).action.succeeded)
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)

        let restartedPersistence = fixture.persistence()
        let restarted = fixture.load(restartedPersistence)
        let restartedCoordinator = fixture.coordinator(restartedPersistence)
        #expect(restarted.state.pendingTaskOperations == loaded.state.pendingTaskOperations)
        #expect(restarted.state.pendingSelectedTaskOperations == loaded.state.pendingSelectedTaskOperations)
        _ = restartedCoordinator.loadCompletionEffects(for: restarted, projectionSucceeded: true)
        #expect(restartedCoordinator.persist(restarted.state, to: .local).effects == [.removeLegacyTasks])
        restartedCoordinator.removeLegacyTasks()

        let finalLoad = fixture.load(fixture.persistence())
        #expect(finalLoad.state.pendingTaskOperations == loaded.state.pendingTaskOperations)
        #expect(finalLoad.state.pendingSelectedTaskOperations == loaded.state.pendingSelectedTaskOperations)
        #expect(restartedCoordinator.loadCompletionEffects(for: finalLoad, projectionSucceeded: true).isEmpty)
        #expect(fixture.legacyBytesOnDisk == nil)
    }

    @Test @MainActor
    func appModelFailedStartupWriteRetriesThroughAtomicMutation() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        fixture.defaults.ignoredSetKeys.insert(PersistedStateLoader.storageKey)
        let model = AppModel(
            api: APIClient(keychain: EmptyTokenStore()), defaults: fixture.defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(in: fixture.directory),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { TestFixtures.anchor }, uptime: { 100 }
        )
        #expect(model.tasks == fixture.legacy.tasks)
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == nil)

        fixture.defaults.ignoredSetKeys.remove(PersistedStateLoader.storageKey)
        model.setDurationMinutes(10, for: .focus)

        let bytes = try #require(fixture.defaults.data(forKey: PersistedStateLoader.storageKey))
        let saved = try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
        #expect(saved.pendingTaskOperations.count == fixture.legacy.tasks.count)
        #expect(saved.pendingSelectedTaskOperations.count == 1)
        #expect(fixture.legacyBytesOnDisk == nil)
    }

    @Test(arguments: MigrationMismatch.allCases) @MainActor
    func unrelatedSuccessfulSaveCannotConsumeMigration(mismatch: MigrationMismatch) throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let loaded = fixture.load(persistence)
        let coordinator = fixture.coordinator(persistence)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let unrelated = mismatch.applying(to: loaded.state)

        let saved = coordinator.persist(unrelated, to: .local)

        #expect(saved.action.succeeded)
        #expect(!saved.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
        #expect(coordinator.persist(loaded.state, to: .local).effects == [.removeLegacyTasks])
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == nil)
    }

    @Test @MainActor
    func failedProjectionCannotAuthorizeLegacyCleanup() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let loaded = fixture.load(persistence)
        let coordinator = fixture.coordinator(persistence)

        #expect(coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: false).isEmpty)
        #expect(coordinator.persist(loaded.state, to: .local).effects.isEmpty)
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
    }

    @Test @MainActor
    func roomMigrationRequiresSuccessfulRoomCaptureNotLocalSave() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let roomStore = fixture.roomStore()
        try fixture.createRoom(in: roomStore)
        let loaded = fixture.loadRoom(persistence, roomStore: roomStore)
        let coordinator = fixture.coordinator(persistence, roomStore: roomStore)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let failed = coordinator.persist(
            loaded.state, to: .iroh(.captureFailed(nil, message: "failed capture", quarantined: true))
        )
        #expect(!failed.action.succeeded)
        #expect(!failed.effects.contains(.removeLegacyTasks))
        #expect(coordinator.persist(loaded.state, to: .local).effects.isEmpty)
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
        #expect(coordinator.persist(loaded.state, to: .iroh(.captured(loaded.state))).effects.isEmpty)
        let captured = try roomStore.captureLocalOperations(from: loaded.state)
        #expect(captured.pendingTaskOperations.isEmpty)
        #expect(captured.pendingSelectedTaskOperations.isEmpty)
        #expect(coordinator.persist(loaded.state, to: .iroh(.captured(captured))).effects == [.removeLegacyTasks])
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == nil)
        let restartedStore = fixture.roomStore()
        let restarted = fixture.loadRoom(fixture.persistence(), roomStore: restartedStore)
        #expect(restarted.state.pendingTaskOperations.isEmpty)
        #expect(restarted.state.pendingSelectedTaskOperations.isEmpty)
        #expect(restarted.state.tasks == captured.tasks)
        #expect(!restarted.removesLegacyTasksAfterProjection)
        #expect(restartedStore.activeSnapshot?.operationCount == fixture.legacy.tasks.count + 2)
        _ = try restartedStore.captureLocalOperations(from: restarted.state)
        #expect(restartedStore.activeSnapshot?.operationCount == roomStore.activeSnapshot?.operationCount)
    }

    @Test @MainActor
    func migrationCannotConsumeCaptureInDifferentRoom() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let roomStore = fixture.roomStore()
        try fixture.createRoom(in: roomStore)
        let loaded = fixture.loadRoom(persistence, roomStore: roomStore)
        let coordinator = fixture.coordinator(persistence, roomStore: roomStore)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        try fixture.createRoom(in: roomStore, secret: Data(32...63))
        #expect(throws: (any Error).self) { try roomStore.captureLocalOperations(from: loaded.state) }
        let captured = try #require(roomStore.activeRoomState)
        let saved = coordinator.persist(loaded.state, to: .iroh(.captured(captured)))
        #expect(saved.action.succeeded)
        #expect(!saved.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
    }

    @Test @MainActor
    func delayedCleanupCannotConsumeLegacyAfterRoomSwitch() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let roomStore = fixture.roomStore()
        try fixture.createRoom(in: roomStore)
        let loaded = fixture.loadRoom(persistence, roomStore: roomStore)
        let coordinator = fixture.coordinator(persistence, roomStore: roomStore)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let captured = try roomStore.captureLocalOperations(from: loaded.state)
        #expect(coordinator.persist(loaded.state, to: .iroh(.captured(captured))).effects == [.removeLegacyTasks])
        try fixture.createRoom(in: roomStore, secret: Data(32...63))
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == fixture.legacyBytes)
    }

    @Test @MainActor
    func committedRoomSelectionAndTaskRecordsAllowIdempotentRetry() throws {
        let fixture = try LegacyMigrationFixture()
        defer { fixture.cleanup() }
        let persistence = fixture.persistence()
        let roomStore = fixture.roomStore()
        try fixture.createRoom(in: roomStore)
        let migration = fixture.loadRoom(persistence, roomStore: roomStore)
        let coordinator = fixture.coordinator(persistence, roomStore: roomStore)
        _ = coordinator.loadCompletionEffects(for: migration, projectionSucceeded: true)
        let captured = try roomStore.captureLocalOperations(from: migration.state)
        #expect(captured.selectedTaskID == fixture.legacy.selectedTaskID)
        #expect(captured.pendingSelectedTaskOperations.isEmpty)
        #expect(coordinator.persist(migration.state, to: .iroh(.captured(captured))).effects == [.removeLegacyTasks])
        let retried = try roomStore.captureLocalOperations(from: migration.state)
        #expect(coordinator.persist(migration.state, to: .iroh(.captured(retried))).effects == [.removeLegacyTasks])
        #expect(roomStore.activeSnapshot?.operationCount == fixture.legacy.tasks.count + 2)
        coordinator.removeLegacyTasks()
        #expect(fixture.legacyBytesOnDisk == nil)
        let restarted = fixture.loadRoom(fixture.persistence(), roomStore: fixture.roomStore())
        #expect(restarted.state.pendingTaskOperations.isEmpty)
        #expect(restarted.state.pendingSelectedTaskOperations.isEmpty)
        #expect(restarted.state.selectedTaskID == captured.selectedTaskID)
    }
}

extension LegacyMigrationDurabilityTests {
    enum MigrationMismatch: CaseIterable, Sendable {
        case cachedAccount, bootstrapAccount, pendingAccountSwitch, device, missingTaskOperations

        func applying(to migrated: PersistedTimerState) -> PersistedTimerState {
            var unrelated = migrated
            let user = User(id: "other-account", email: "other@example.com", name: "Other", avatarUrl: "")
            switch self {
            case .cachedAccount: unrelated.cachedUser = user
            case .bootstrapAccount: unrelated.bootstrapUser = user
            case .pendingAccountSwitch: unrelated.pendingAccountSwitchUser = user
            case .device: unrelated.deviceId = "other-device"
            case .missingTaskOperations: unrelated.pendingTaskOperations = []
            }
            return unrelated
        }
    }
}

@MainActor
private struct LegacyMigrationFixture {
    let suiteName = "LegacyMigrationDurabilityTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LegacyMigrationDurabilityTests-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let legacy: LocalTaskState
    let legacyBytes: Data
    let roomSecrets = MemoryIrohRoomSecretStore()
    var url: URL { directory.appendingPathComponent("workspace.json") }
    var store: AtomicDurableFileStore { AtomicDurableFileStore(fileURL: url) }
    var legacyBytesOnDisk: Data? { defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) }

    init() throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        let first = try #require(FocusTask(title: "First legacy task"))
        let second = try #require(FocusTask(title: "Second legacy task"))
        legacy = LocalTaskState(tasks: [first, second], selectedTaskID: first.id, assignments: [:])
        legacyBytes = try JSONEncoder.api.encode(legacy)
        defaults.set(legacyBytes, forKey: PersistedStateLoader.localTaskStorageKey)
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func blockDestination() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func unblockDestination() throws {
        try FileManager.default.removeItem(at: url)
    }

    func persistence() -> AppStatePersistenceCoordinator {
        AppStatePersistenceCoordinator(defaults: defaults, durableLocalStore: store)
    }

    func load(_ persistence: AppStatePersistenceCoordinator) -> AppStatePersistenceCoordinator.LoadTransition {
        persistence.load(
            replicationMode: .offline, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            wallDate: TestFixtures.anchor, uptime: 100
        )
    }

    func coordinator(
        _ persistence: AppStatePersistenceCoordinator,
        roomStore: IrohRoomStore? = nil
    ) -> CentralizedAccountSessionCoordinator {
        let api = APIClient(keychain: EmptyTokenStore())
        return CentralizedAccountSessionCoordinator(
            lifecycle: .init(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
            synchronization: .init(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
            initialPublication: .init(sessionState: .localOnly), persistence: persistence, roomStore: roomStore
        )
    }

    func roomStore() -> IrohRoomStore {
        IrohRoomStore(
            fileURL: directory.appendingPathComponent("rooms.json"), secretStore: roomSecrets,
            now: { TestFixtures.anchor }
        )
    }

    func createRoom(in roomStore: IrohRoomStore, secret: Data = Data(0...31)) throws {
        _ = try roomStore.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret, name: nil,
            returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
                autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0
            ), now: TestFixtures.anchor
        )
    }

    func loadRoom(
        _ persistence: AppStatePersistenceCoordinator,
        roomStore: IrohRoomStore
    ) -> AppStatePersistenceCoordinator.LoadTransition {
        persistence.load(replicationMode: .iroh, roomStore: roomStore, wallDate: TestFixtures.anchor, uptime: 100)
    }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: #require(try store.read()))
    }
}
