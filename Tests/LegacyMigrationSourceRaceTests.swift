import Foundation
import Testing
@testable import Pomodorough

@Suite("Legacy Migration Source Races")
struct LegacyMigrationSourceRaceTests {
    enum Replacement: CaseIterable, Sendable {
        case distinct, missing, corrupt
    }

    enum Boundary: CaseIterable, Sendable {
        case beforeLoad, duringLoad, afterLoad, afterAuthorization
    }

    struct Scenario: Sendable {
        let mode: ReplicationMode
        let modernSnapshot: Bool
        let replacement: Replacement

        static var all: [Self] {
            ReplicationMode.allCases.flatMap { mode in
                [false, true].flatMap { modern in
                    Replacement.allCases.map { Self(mode: mode, modernSnapshot: modern, replacement: $0) }
                }
            }
        }
    }

    @Test(arguments: Scenario.all, Boundary.allCases) @MainActor
    func replacementCannotDeleteUnmigratedSource(scenario: Scenario, boundary: Boundary) throws {
        let fixture = try SourceRaceFixture(scenario: scenario)
        defer { fixture.cleanup() }
        let store = try fixture.initialRoomStore()
        let persistence = fixture.persistence()
        if boundary == .beforeLoad { fixture.defaults.replaceSource(with: fixture.replacement) }
        if boundary == .duringLoad { fixture.defaults.afterNextSourceRead = { fixture.replaceSource() } }
        let loaded = fixture.load(persistence, store: store)
        #expect(fixture.defaults.sourceReads == 1)
        let decodedSource = boundary == .beforeLoad
            ? (scenario.replacement == .distinct ? fixture.replacement : nil) : fixture.original
        #expect(loaded.legacyTaskSource == decodedSource)
        #expect(loaded.replicationMode == scenario.mode)
        #expect(!loaded.shouldReportInvalidLocalClock)
        if scenario.mode == .iroh { #expect(loaded.state.irohLegacyTaskMigration?.source == decodedSource) }
        if boundary == .afterLoad { fixture.replaceSource() }
        let coordinator = fixture.coordinator(persistence, store: store)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let committed = try fixture.persist(loaded.state, coordinator: coordinator, store: store)
        let authorized = boundary == .afterAuthorization
            || (boundary == .beforeLoad && scenario.replacement == .distinct)
        #expect(committed.effects.contains(.removeLegacyTasks) == authorized)
        if boundary == .afterAuthorization { fixture.replaceSource() }
        for _ in 0..<3 { coordinator.removeLegacyTasks() }
        let cleaned = boundary == .beforeLoad && scenario.replacement == .distinct
        #expect(fixture.source == (cleaned ? nil : fixture.replacement))
        try fixture.expectDurableMigration(loaded.state, source: decodedSource, store: store)
        if let decodedSource, !cleaned {
            try fixture.retryOriginalSource(decodedSource, prepared: loaded.state)
        }
    }

    @Test(arguments: Scenario.all.filter { $0.replacement != .distinct }) @MainActor
    func missingOrCorruptReadDoesNotAdoptLaterValidSource(scenario: Scenario) throws {
        let fixture = try SourceRaceFixture(scenario: scenario)
        defer { fixture.cleanup() }
        let store = try fixture.initialRoomStore()
        fixture.replaceSource()
        fixture.defaults.afterNextSourceRead = { fixture.defaults.replaceSource(with: fixture.original) }
        let persistence = fixture.persistence()
        let loaded = fixture.load(persistence, store: store)
        #expect(fixture.defaults.sourceReads == 1)
        #expect(loaded.legacyTaskSource == nil)
        #expect(!loaded.removesLegacyTasksAfterProjection)
        #expect(loaded.state.pendingTaskOperations.isEmpty)
        #expect(loaded.state.irohLegacyTaskMigration == nil)
        let coordinator = fixture.coordinator(persistence, store: store)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let committed = try fixture.persist(loaded.state, coordinator: coordinator, store: store)
        #expect(!committed.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.source == fixture.original)
        try fixture.retryOriginalSource(fixture.original, prepared: loaded.state)
    }

    @Test(arguments: Replacement.allCases) @MainActor
    func mismatchedTransitionSourceCannotAuthorizeRealRoomCapture(replacement: Replacement) throws {
        let fixture = try SourceRaceFixture(scenario: .init(mode: .iroh, modernSnapshot: true, replacement: replacement))
        defer { fixture.cleanup() }
        let store = try fixture.initialRoomStore()
        let persistence = fixture.persistence()
        var loaded = fixture.load(persistence, store: store)
        #expect(loaded.legacyTaskSource == fixture.original)
        loaded.legacyTaskSource = fixture.replacement
        fixture.replaceSource()
        let coordinator = fixture.coordinator(persistence, store: store)
        _ = coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true)
        let committed = try fixture.persist(loaded.state, coordinator: coordinator, store: store)
        #expect(!committed.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(fixture.source == fixture.replacement)
        #expect(store.activeRoomState?.irohLegacyTaskMigration?.source == fixture.original)
        #expect(store.activeSnapshot?.operationCount == 4)
    }
}

private final class SourceRaceDefaults: UserDefaults {
    let directory: URL
    var afterNextSourceRead: (() -> Void)?
    private(set) var sourceReads = 0

    init(directory: URL) {
        self.directory = directory
        super.init(suiteName: "LegacyMigrationSourceRaceTests.\(UUID().uuidString)")!
    }

    override func data(forKey key: String) -> Data? {
        let bytes = read(key)
        if key == PersistedStateLoader.localTaskStorageKey {
            sourceReads += 1
            let scheduled = afterNextSourceRead
            afterNextSourceRead = nil
            scheduled?()
        }
        return bytes
    }

    override func set(_ value: Any?, forKey key: String) {
        guard let bytes = value as? Data else { removeObject(forKey: key); return }
        try! bytes.write(to: directory.appendingPathComponent(key), options: .atomic)
    }

    override func removeObject(forKey key: String) {
        let path = directory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: path.path) { try! FileManager.default.removeItem(at: path) }
    }

    func read(_ key: String) -> Data? {
        let path = directory.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: path.path) ? try! Data(contentsOf: path) : nil
    }

    func replaceSource(with bytes: Data?) {
        set(bytes, forKey: PersistedStateLoader.localTaskStorageKey)
    }
}

@MainActor
private struct SourceRaceFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LegacyMigrationSourceRaceTests-\(UUID().uuidString)", isDirectory: true)
    let defaults: SourceRaceDefaults
    let scenario: LegacyMigrationSourceRaceTests.Scenario
    let original: Data
    let replacement: Data?
    let initialState: PersistedTimerState
    let secrets = MemoryIrohRoomSecretStore()
    var source: Data? { defaults.read(PersistedStateLoader.localTaskStorageKey) }
    var workspaceURL: URL { directory.appendingPathComponent("workspace.json") }

    init(scenario: LegacyMigrationSourceRaceTests.Scenario) throws {
        self.scenario = scenario
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = SourceRaceDefaults(directory: directory)
        let first = try #require(FocusTask(title: "Original selected task"))
        let second = try #require(FocusTask(title: "Original second task"))
        original = try JSONEncoder.api.encode(LocalTaskState(tasks: [first, second], selectedTaskID: first.id, assignments: [:]))
        switch scenario.replacement {
        case .distinct:
            let task = try #require(FocusTask(title: "Unmigrated replacement task"))
            replacement = try JSONEncoder.api.encode(LocalTaskState(tasks: [task], selectedTaskID: task.id, assignments: [:]))
        case .missing: replacement = nil
        case .corrupt: replacement = Data("not-json".utf8)
        }
        var state = PersistedTimerState.fresh()
        if scenario.modernSnapshot {
            state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
            state.nextSequence = 2
            state.pendingDurationOperations = [TestFixtures.durationOperation(
                id: "duration-source-race", phase: .focus, durationMs: 120_000, wallMs: 0
            )]
            #expect(state.hasValidPendingWireOperations)
            defaults.set(try JSONEncoder.api.encode(state), forKey: PersistedStateLoader.storageKey)
        }
        initialState = state
        defaults.replaceSource(with: original)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func replaceSource() { defaults.replaceSource(with: replacement) }

    func roomStore() -> IrohRoomStore {
        IrohRoomStore(fileURL: directory.appendingPathComponent("rooms.json"), secretStore: secrets, now: { TestFixtures.anchor })
    }

    func initialRoomStore() throws -> IrohRoomStore {
        let store = roomStore()
        if scenario.mode == .iroh {
            let secret = Data(0...31)
            _ = try store.createRoom(
                roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret, name: nil, returnState: .fresh(),
                genesis: IrohGenesis(canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
                    autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0), now: TestFixtures.anchor
            )
        }
        return store
    }

    func persistence() -> AppStatePersistenceCoordinator {
        AppStatePersistenceCoordinator(defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: workspaceURL))
    }

    func load(
        _ persistence: AppStatePersistenceCoordinator, store: IrohRoomStore
    ) -> AppStatePersistenceCoordinator.LoadTransition {
        persistence.load(replicationMode: scenario.mode, roomStore: store, wallDate: TestFixtures.anchor, uptime: 100)
    }

    func coordinator(
        _ persistence: AppStatePersistenceCoordinator, store: IrohRoomStore
    ) -> CentralizedAccountSessionCoordinator {
        let api = APIClient(keychain: EmptyTokenStore())
        return CentralizedAccountSessionCoordinator(
            lifecycle: .init(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
            synchronization: .init(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
            initialPublication: .init(sessionState: .localOnly), persistence: persistence, roomStore: store
        )
    }

    func persist(
        _ state: PersistedTimerState, coordinator: CentralizedAccountSessionCoordinator, store: IrohRoomStore
    ) throws -> CentralizedAccountSessionCoordinator.Transition<CentralizedAccountSessionCoordinator.PersistenceAction> {
        let destination: AppStatePersistenceCoordinator.Destination
        if scenario.mode == .iroh {
            destination = .iroh(.captured(try store.captureLocalOperations(from: state)))
        } else {
            destination = .local
        }
        let committed = coordinator.persist(state, to: destination)
        #expect(committed.action.succeeded)
        return committed
    }

    func expectDurableMigration(_ prepared: PersistedTimerState, source: Data?, store: IrohRoomStore) throws {
        let legacy = try source.map { try JSONDecoder.api.decode(LocalTaskState.self, from: $0) }
        let saved: PersistedTimerState
        if scenario.mode == .iroh {
            saved = try #require(roomStore().activeRoomState)
            #expect(saved.irohLegacyTaskMigration?.source == source)
            #expect(saved.pendingTaskOperations.isEmpty)
            #expect(saved.pendingSelectedTaskOperations.isEmpty)
            #expect(store.activeSnapshot?.operationCount == 1 + (legacy.map { $0.tasks.count + 1 } ?? 0))
        } else {
            saved = try JSONDecoder.api.decode(PersistedTimerState.self, from: Data(contentsOf: workspaceURL))
            #expect(saved.pendingTaskOperations == prepared.pendingTaskOperations)
            #expect(saved.pendingSelectedTaskOperations == prepared.pendingSelectedTaskOperations)
            #expect(saved.pendingCommands == initialState.pendingCommands)
            #expect(saved.pendingDurationOperations == initialState.pendingDurationOperations)
        }
        #expect(Set(saved.tasks) == Set(legacy?.tasks ?? []))
        #expect(saved.selectedTaskID == legacy?.selectedTaskID)
    }

    func retryOriginalSource(_ source: Data, prepared: PersistedTimerState) throws {
        defaults.replaceSource(with: source)
        let store = roomStore()
        let persistence = persistence()
        let loaded = load(persistence, store: store)
        #expect(loaded.legacyTaskSource == source)
        #expect(!loaded.shouldReportInvalidLocalClock)
        if scenario.mode == .iroh, prepared.irohLegacyTaskMigration != nil {
            #expect(loaded.state.pendingTaskOperations.isEmpty)
            #expect(loaded.state.pendingSelectedTaskOperations.isEmpty)
            #expect(loaded.state.irohLegacyTaskMigration == prepared.irohLegacyTaskMigration)
        } else {
            #expect(prepared.pendingTaskOperations.allSatisfy(loaded.state.pendingTaskOperations.contains))
            #expect(prepared.pendingSelectedTaskOperations.allSatisfy(loaded.state.pendingSelectedTaskOperations.contains))
        }
        let coordinator = coordinator(persistence, store: store)
        #expect(coordinator.loadCompletionEffects(for: loaded, projectionSucceeded: true) == [.persist])
        let committed = try persist(loaded.state, coordinator: coordinator, store: store)
        #expect(committed.effects.contains(.removeLegacyTasks))
        coordinator.removeLegacyTasks()
        #expect(self.source == nil)
    }
}
