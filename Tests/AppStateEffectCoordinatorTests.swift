import Foundation
import Testing
@testable import Pomodorough

@Suite("Workspace snapshot load recovery")
struct WorkspaceSnapshotLoadTests {
    @Test @MainActor
    func missingSnapshotOnFirstLaunchAllowsFreshPersistence() throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()

        #expect(try fixture.store.read() == nil)
        let loaded = fixture.load(coordinator)

        #expect(loaded.snapshotLoadFailure == nil)
        #expect(loaded.state.pendingCommands.isEmpty)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(coordinator.completionEffect(for: loaded, projectionSucceeded: true) == .none)
        #expect(coordinator.persist(loaded.state, to: .local).succeeded)
        #expect(try fixture.store.read() == fixture.defaults.data(forKey: PersistedStateLoader.storageKey))
    }

    @Test @MainActor
    func missingDurableSnapshotStillLoadsExistingDefaultsMirror() throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let original = try fixture.seedSnapshot()
        try FileManager.default.removeItem(at: fixture.url)
        let coordinator = fixture.coordinator()

        let loaded = fixture.load(coordinator)

        #expect(loaded.snapshotLoadFailure == nil)
        #expect(try JSONEncoder.api.encode(loaded.state) == original)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(try fixture.store.read() == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func unreadableSnapshotPreservesQueueAndMirrorUntilSuccessfulRetry(denyDirectory: Bool) throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let original = try fixture.seedSnapshot()
        let deniedURL = denyDirectory ? fixture.directory : fixture.url
        defer { try? fixture.setPermissions(0o700, at: deniedURL) }
        try fixture.setPermissions(0, at: deniedURL)
        #expect(throws: (any Error).self) { try fixture.store.read() }
        let coordinator = fixture.coordinator()

        let loaded = fixture.load(coordinator)
        guard case .unreadable = loaded.snapshotLoadFailure else {
            Issue.record("Expected unreadable snapshot recovery, not fresh startup")
            return
        }
        #expect(coordinator.completionEffect(for: loaded, projectionSucceeded: true) == .none)
        #expect(!loaded.shouldPersistAfterProjection)
        #expect(!loaded.shouldReportInvalidLocalClock)
        #expect(fixture.load(coordinator).snapshotLoadFailure != nil)
        coordinator.removeLegacyTasks()
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == fixture.legacyBytes)
        try fixture.setPermissions(0o700, at: deniedURL)
        #expect(!coordinator.persist(.fresh(), to: .local).succeeded)
        #expect(!coordinator.persist(.fresh(), replicationMode: .iroh, captureIrohState: { _ in
            Issue.record("Recovery must block capture side effects")
            return .unchanged
        }).succeeded)
        #expect(try fixture.store.read() == original)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == original)
        #expect(fixture.defaults.timerStateWrites.isEmpty)

        let recovered = fixture.load(coordinator)
        #expect(recovered.snapshotLoadFailure == nil)
        #expect(try JSONEncoder.api.encode(recovered.state) == original)
        #expect(coordinator.persist(recovered.state, to: .local).succeeded)
    }

    @Test(arguments: [Data(), Data("not a snapshot".utf8)]) @MainActor
    func corruptSnapshotDoesNotFallBackToMirrorOrFreshState(corruptBytes: Data) throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let original = try fixture.seedSnapshot()
        try corruptBytes.write(to: fixture.url)
        let coordinator = fixture.coordinator()

        let loaded = fixture.load(coordinator)

        #expect(loaded.snapshotLoadFailure == .corrupt)
        #expect(coordinator.completionEffect(for: loaded, projectionSucceeded: true) == .none)
        #expect(!coordinator.persist(.fresh(), to: .local).succeeded)
        #expect(try fixture.store.read() == corruptBytes)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == original)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        try FileManager.default.removeItem(at: fixture.url)
        #expect(fixture.load(coordinator).snapshotLoadFailure == .corrupt)
        #expect(!coordinator.persist(.fresh(), to: .local).succeeded)
        try original.write(to: fixture.url)
        let recovered = fixture.load(coordinator)
        #expect(recovered.snapshotLoadFailure == nil)
        #expect(try JSONEncoder.api.encode(recovered.state) == original)
    }

    @Test @MainActor
    func corruptDefaultsWithoutDurableSnapshotAlsoFailClosed() throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let corruptBytes = Data("not a snapshot".utf8)
        fixture.defaults.set(corruptBytes, forKey: PersistedStateLoader.storageKey)
        fixture.defaults.resetTimerStateWrites()
        let coordinator = fixture.coordinator()

        #expect(fixture.load(coordinator).snapshotLoadFailure == .corrupt)
        #expect(!coordinator.persist(.fresh(), to: .local).succeeded)
        #expect(try fixture.store.read() == nil)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == corruptBytes)
    }

    @Test(arguments: [false, true]) @MainActor
    func appModelBlocksSignOutDuringSnapshotQuarantine(corruptSnapshot: Bool) async throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let original = try fixture.seedSnapshot()
        let snapshotBytes = corruptSnapshot ? Data("not a snapshot".utf8) : original
        try snapshotBytes.write(to: fixture.url)
        defer { try? fixture.setPermissions(0o600, at: fixture.url) }
        if !corruptSnapshot { try fixture.setPermissions(0, at: fixture.url) }
        let tokens = StaticTokenStore().tokens
        let tokenStore = RecordingTokenStore(tokens: tokens)
        let identityProvider = RecordingGoogleIdentityProvider()
        let session = TestFixtures.session(for: "snapshot-quarantine-signout-\(UUID().uuidString)")
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: fixture.defaults, durableLocalStore: fixture.store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: fixture.directory),
            alarmScheduler: RecordingAlarmScheduler(), googleIdentityProvider: identityProvider
        )
        try #require(model.snapshotLoadFailure != nil)
        let failure = model.snapshotLoadFailure
        let tokenOperations = tokenStore.operations

        model.signOut()

        #expect(!model.isWorking)
        await Task.yield()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.snapshotLoadFailure == failure)
        #expect(model.sessionState == .restoring)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(tokenStore.tokens == tokens)
        #expect(tokenStore.operations == tokenOperations)
        #expect(try (tokenStore as any LogoutRevocationStoring).load().isEmpty)
        #expect(identityProvider.signOutCount == 0)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == original)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == fixture.legacyBytes)
        try fixture.setPermissions(0o600, at: fixture.url)
        #expect(try fixture.store.read() == snapshotBytes)
    }

    @Test @MainActor
    func appModelBlocksWorkspaceAndRestoreUntilSnapshotRetrySucceeds() async throws {
        let fixture = try SnapshotLoadFixture()
        defer { fixture.cleanup() }
        let original = try fixture.seedSnapshot()
        defer { try? fixture.setPermissions(0o600, at: fixture.url) }
        try fixture.setPermissions(0, at: fixture.url)
        let model = fixture.model()

        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        #expect(model.sessionState == .restoring)
        model.start()
        model.setSceneActive(true)
        await model.restore()
        await model.refreshAfterForeground()
        await model.sync(force: true)
        await model.setReplicationMode(.iroh)
        await model.retrySnapshotLoad()
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.replicationMode == .offline)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == original)

        try fixture.setPermissions(0o600, at: fixture.url)
        await model.retrySnapshotLoad()

        #expect(model.snapshotLoadFailure == nil)
        #expect(!model.isWorkspaceMutationBlocked)
        #expect(model.sessionState == .localOnly)
        #expect(model.pendingCommandCount == 2)
        #expect(try fixture.store.read() == original)
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.storageKey) == original)
    }
}

@MainActor
private struct SnapshotLoadFixture {
    let suiteName = "SnapshotLoadTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapshotLoadTests-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let legacyBytes = Data("retained legacy task bytes".utf8)
    var url: URL { directory.appendingPathComponent("workspace.json") }
    var store: AtomicDurableFileStore { AtomicDurableFileStore(fileURL: url) }

    init() throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func seedSnapshot() throws -> Data {
        var state = PersistedTimerState.fresh()
        state.pendingCommands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0),
            TestFixtures.command(.pause, sequence: 2, elapsed: 1_000)
        ]
        state.nextSequence = 3
        let bytes = try JSONEncoder.api.encode(state)
        try bytes.write(to: url)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.set(legacyBytes, forKey: PersistedStateLoader.localTaskStorageKey)
        defaults.resetTimerStateWrites()
        return bytes
    }

    func coordinator() -> AppStatePersistenceCoordinator {
        AppStatePersistenceCoordinator(defaults: defaults, durableLocalStore: store)
    }

    func load(_ coordinator: AppStatePersistenceCoordinator) -> AppStatePersistenceCoordinator.LoadTransition {
        coordinator.load(
            replicationMode: .offline, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            wallDate: TestFixtures.anchor.addingTimeInterval(5), uptime: 100
        )
    }

    func model() -> AppModel {
        AppModel(
            api: APIClient(keychain: EmptyTokenStore()),
            defaults: defaults, durableLocalStore: store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

@Suite("App state publication and alarm effects")
struct AppStateEffectCoordinatorTests {
    @Test @MainActor
    func publisherPreservesTaskIdentityAndCompletionCancellationPlan() throws {
        let task = try #require(FocusTask(title: "Projection task"))
        var state = PersistedTimerState.fresh()
        state.knownTasks = [task]
        let output = CoreProjectionOutput(
            canonicalTimer: nil,
            history: [],
            tasks: [task],
            durationsMs: state.settings.durationsMs,
            autoStartBreaks: true,
            selectedTaskId: task.id.uuidString.lowercased(),
            timerOutcomes: [:],
            winningOperationIds: .init(
                tasks: [:],
                durations: [:],
                autoStart: nil,
                selectedTask: nil
            )
        )

        let publication = AppStatePublisher().publication(
            output: output,
            state: state,
            completionAlertTimerID: "timer-completed",
            completionQueuedFor: "timer-completed"
        )

        #expect(publication.tasks == [task])
        #expect(publication.state.knownTasks == [task])
        #expect(publication.selectedTaskID == task.id)
        #expect(publication.autoStartBreaks)
        #expect(publication.completionAlertTimerID == "timer-completed")
        #expect(publication.completionQueuedFor == nil)
        #expect(publication.effects.isEmpty)

        let activeTimer = CanonicalTimer(
            id: "active-timer",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: Date(timeIntervalSince1970: 1_000),
            lastIntent: nil
        )
        let completion = AppStatePublisher().completionPresentation(
            alertTimerID: "timer-completed",
            currentTimer: activeTimer
        )
        #expect(completion.alertTimerID == nil)
        #expect(completion.effects == [
            .cancelAlarm(timerID: "timer-completed", reportsError: false)
        ])
    }

    @Test @MainActor
    func alarmCoordinatorPreservesEffectOrderAndFinishRouting() throws {
        let timerController = TimerSessionController(
            sharedCoreProvider: { try SharedCore.bundled() }
        )
        let coordinator = AlarmEffectCoordinator(timerSessionController: timerController)
        let effects = coordinator.effects(
            for: .init(actions: [
                .cancel(timerID: "timer-focus"),
                .schedule(timerID: "timer-break", phase: .shortBreak, duration: 300)
            ]),
            cancelReportsError: false
        )
        #expect(effects == [
            .cancel(timerID: "timer-focus", reportsError: false),
            .schedule(timerID: "timer-break", phase: .shortBreak, duration: 300)
        ])

        let fixture = try makeFinishFixture(timerController: timerController)
        let completionDate = fixture.date.addingTimeInterval(60)
        let plan = try coordinator.finishPlan(.init(
            timer: fixture.timer,
            completionDate: completionDate,
            occurredAt: completionDate,
            localDate: completionDate,
            state: fixture.state,
            replicationMode: .centralized,
            physicalNow: completionDate,
            autoStartsBreak: false
        ))
        guard case .finish(let transition) = plan else {
            Issue.record("Expected finish-only plan")
            return
        }
        #expect(transition.command.type == .finish)
        #expect(transition.command.timerId == fixture.timer.id)
    }

    @Test
    func durableDeletionJournalReopensExactRecordAndFailsClosedOnCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughDeletionJournal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let record = AccountDeletionJournal.Record(
            phase: .prepared,
            roomIDs: ["room-b", "room-a"]
        )

        try AccountDeletionJournal(fileURL: url).save(record)

        #expect(try AccountDeletionJournal(fileURL: url).load() == .record(
            .init(phase: .prepared, roomIDs: ["room-a", "room-b"])
        ))
        try Data("damaged".utf8).write(to: url, options: .atomic)
        #expect(try AccountDeletionJournal(fileURL: url).load() == .corrupt)
    }

    @Test
    func durableWorkspaceStoreReopensExactBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughDurableWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let data = Data("durable-workspace".utf8)

        try AtomicDurableFileStore(fileURL: url).write(data)

        #expect(try AtomicDurableFileStore(fileURL: url).read() == data)
    }

    @MainActor
    private func makeFinishFixture(
        timerController: TimerSessionController
    ) throws -> (state: PersistedTimerState, timer: CanonicalTimer, date: Date) {
        var state = PersistedTimerState.fresh()
        state.settings.autoStartBreaks = false
        let date = Date(timeIntervalSince1970: 1_000)
        let start = try timerController.makeCommand(
            .init(
                type: .start,
                timerID: "timer-finish-plan",
                taskID: nil,
                phase: .focus,
                duration: 60,
                elapsed: 0,
                occurredAt: date,
                localDate: date
            ),
            state: state
        )
        state = start.state
        let timer = try #require(try timerController.project(
            state,
            now: date,
            replicationMode: .centralized,
            physicalNow: date
        ).canonicalTimer)
        return (state, timer, date)
    }
}
