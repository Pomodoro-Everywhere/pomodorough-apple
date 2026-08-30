import Foundation
import Testing
@testable import Pomodorough

@Suite("Snapshot replacement recovery")
struct SnapshotReplacementRecoveryTests {
    @Test @MainActor
    func preReplacementFailureKeepsPreviousStateAndAllowsNextMutation() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let coordinator = fixture.coordinator()
        try fixture.permissions(0o500, at: fixture.directory)
        defer { try? fixture.permissions(0o700, at: fixture.directory) }

        let result = coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local)

        #expect(!result.committed)
        #expect(result.persistence == .failed)
        #expect(result.state == previous)
        #expect(coordinator.snapshotLoadFailure == nil)
        #expect(try fixture.savedState() == previous)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        try fixture.permissions(0o700, at: fixture.directory)
        #expect(fixture.load(fixture.coordinator()).state == previous)
        #expect(coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local).committed)
        #expect(try fixture.savedState() == proposed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["workspace.json"])
    }

    @Test @MainActor
    func replacementEIODoesNotClaimRollbackOrDurableCommit() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let coordinator = fixture.coordinator(afterReplacement: { throw POSIXError(.EIO) })

        let result = coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local)

        guard case .recoveryRequired(let observed, _) = result.persistence else {
            Issue.record("Post-replacement EIO must report uncertainty, not rollback or success")
            return
        }
        #expect(observed == proposed)
        #expect(result.state == proposed)
        #expect(!result.committed)
        #expect(try fixture.savedState() == proposed)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        let application = coordinator.application(for: result, rebuildsOnRollback: true)
        #expect(application.state == proposed)
        #expect(!application.succeeded)
        #expect(!application.rebuildsProjection)
        #expect(!application.marksIrohConflict)
        #expect(application.conflictMessage != nil)
    }

    @Test @MainActor
    func uncertaintyBlocksFurtherWritesCaptureAndLegacyRemoval() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let coordinator = fixture.coordinator(afterReplacement: { throw POSIXError(.EIO) })
        let failed = coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local)
        let legacy = Data("keep legacy source".utf8)
        fixture.defaults.set(legacy, forKey: PersistedStateLoader.localTaskStorageKey)

        let blocked = coordinator.persistAtomically(previous: previous, proposed: .fresh(), to: .local)
        #expect(!blocked.committed)
        #expect(blocked.state == proposed)
        #expect(blocked.persistence == failed.persistence)
        let capture = coordinator.persistAtomically(
            previous: previous, proposed: .fresh(), replicationMode: .iroh,
            captureIrohState: { _ in Issue.record("Quarantine must prevent capture"); return .unchanged }
        )
        #expect(!capture.committed)
        #expect(capture.state == proposed)
        coordinator.removeLegacyTasks()
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == legacy)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(try fixture.savedState() == proposed)
    }

    @Test @MainActor
    func readbackFailureRetainsProposedStateUntilReadableSynchronizedRetry() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let url = fixture.url
        let coordinator = fixture.coordinator(afterReplacement: {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            throw POSIXError(.EIO)
        })
        defer { try? fixture.permissions(0o600, at: url) }

        let result = coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local)

        #expect(!result.committed)
        #expect(result.state == proposed)
        #expect(coordinator.snapshotLoadFailure != nil)
        let blockedRetry = fixture.load(coordinator)
        #expect(blockedRetry.state == proposed)
        #expect(blockedRetry.snapshotLoadFailure != nil)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(fixture.load(fixture.coordinator()).snapshotLoadFailure != nil)
        try fixture.permissions(0o600, at: url)
        let recovered = fixture.load(coordinator)
        #expect(recovered.snapshotLoadFailure == nil)
        #expect(recovered.state == proposed)
        #expect(try fixture.mirroredState() == proposed)
    }

    @Test @MainActor
    func restartAndRetryRemainQuarantinedWhileSynchronizationFails() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let flag = fixture.directory.appendingPathComponent("sync-fails")
        try Data().write(to: flag)
        let synchronization: @Sendable () throws -> Void = {
            if FileManager.default.fileExists(atPath: flag.path) { throw POSIXError(.EIO) }
        }
        let writer = fixture.coordinator(beforeSynchronization: synchronization)
        #expect(!writer.persistAtomically(previous: previous, proposed: proposed, to: .local).committed)
        #expect(try fixture.savedState() == proposed)
        let restarted = fixture.coordinator(beforeSynchronization: synchronization)

        for coordinator in [writer, restarted] {
            let loaded = fixture.load(coordinator)
            #expect(loaded.state == proposed)
            #expect(loaded.snapshotLoadFailure != nil)
            #expect(coordinator.completionEffect(for: loaded, projectionSucceeded: true) == .none)
            #expect(fixture.load(coordinator).snapshotLoadFailure != nil)
            #expect(!coordinator.persist(.fresh(), to: .local).succeeded)
        }
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        try FileManager.default.removeItem(at: flag)
        let recovered = fixture.load(restarted)
        #expect(recovered.snapshotLoadFailure == nil)
        #expect(recovered.state == proposed)
        #expect(try fixture.mirroredState() == proposed)
        #expect(restarted.persist(proposed, to: .local).succeeded)
    }

    @Test @MainActor
    func restartAdoptsReplacementBeforeAcceptingFurtherOperations() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let writer = fixture.coordinator(afterReplacement: { throw POSIXError(.EIO) })
        #expect(!writer.persistAtomically(previous: previous, proposed: proposed, to: .local).committed)

        let restarted = fixture.coordinator()
        let loaded = fixture.load(restarted)

        #expect(loaded.snapshotLoadFailure == nil)
        #expect(loaded.state == proposed)
        var next = loaded.state
        next.pendingCommands.append(TestFixtures.command(.resume, sequence: 3, elapsed: 1_000))
        next.nextSequence = 4
        let committed = restarted.persistAtomically(previous: loaded.state, proposed: next, to: .local)
        #expect(committed.committed)
        #expect(try fixture.savedState() == next)
        #expect(fixture.load(fixture.coordinator()).state == next)
    }

    @Test(arguments: [false, true]) @MainActor
    func recoveryRejectsIdentityOrContentChangesDuringSynchronization(sameContents: Bool) throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let replacement = sameContents ? previous : fixture.appendingPause(to: previous)
        let bytes = try JSONEncoder.api.encode(replacement)
        let url = fixture.url
        let coordinator = fixture.coordinator(beforeSynchronization: {
            try bytes.write(to: url, options: sameContents ? .atomic : [])
        })

        let loaded = fixture.load(coordinator)

        #expect(loaded.snapshotLoadFailure != nil)
        #expect(!coordinator.persist(previous, to: .local).succeeded)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        let recovered = fixture.load(fixture.coordinator())
        #expect(recovered.snapshotLoadFailure == nil)
        #expect(recovered.state == replacement)
    }

    @Test @MainActor
    func reconciliationAdoptsObservedReplacementInsteadOfAssumingProposedBytes() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        var observed = proposed
        observed.nextSequence = 9
        let bytes = try JSONEncoder.api.encode(observed)
        let url = fixture.url
        let coordinator = fixture.coordinator(afterReplacement: {
            try bytes.write(to: url, options: .atomic)
            throw POSIXError(.EIO)
        })

        let result = coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local)

        #expect(!result.committed)
        #expect(result.state == observed)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        #expect(fixture.load(coordinator).state == observed)
    }

    @Test(arguments: [false, true]) @MainActor
    func corruptOrMissingReadbackCannotUnblockFromOldMirror(missing: Bool) throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let proposed = fixture.appendingPause(to: previous)
        let url = fixture.url
        let coordinator = fixture.coordinator(afterReplacement: {
            if missing { try FileManager.default.removeItem(at: url) }
            else { try Data("corrupt".utf8).write(to: url) }
            throw POSIXError(.EIO)
        })

        let failed = coordinator.persistAtomically(previous: previous, proposed: proposed, to: .local)

        #expect(!failed.committed)
        #expect(failed.state == proposed)
        #expect(fixture.load(coordinator).snapshotLoadFailure != nil)
        #expect(!coordinator.persist(previous, to: .local).succeeded)
        #expect(fixture.defaults.timerStateWrites.isEmpty)
        try JSONEncoder.api.encode(proposed).write(to: url)
        let recovered = fixture.load(coordinator)
        #expect(recovered.snapshotLoadFailure == nil)
        #expect(recovered.state == proposed)
    }

    @Test @MainActor
    func appModelBlocksMutationsAndSignOutUntilDurableRecovery() async throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.seed()
        let flag = fixture.directory.appendingPathComponent("replacement-fails")
        let syncFlag = fixture.directory.appendingPathComponent("sync-fails")
        try Data().write(to: flag)
        let store = AtomicDurableFileStore(fileURL: fixture.url, beforeSynchronization: {
            if FileManager.default.fileExists(atPath: syncFlag.path) { throw POSIXError(.EIO) }
        }, afterReplacement: {
            if FileManager.default.fileExists(atPath: flag.path) { throw POSIXError(.EIO) }
        })
        let identity = RecordingGoogleIdentityProvider()
        let model = fixture.model(store: store, identity: identity)
        model.setDurationMinutes(10, for: .focus)
        let uncertain = try fixture.savedState()
        #expect(uncertain.pendingDurationOperations.count == previous.pendingDurationOperations.count + 1)
        try await fixture.expectQuarantined(model, identity: identity, state: uncertain)
        try FileManager.default.removeItem(at: flag)
        try Data().write(to: syncFlag)
        await model.retrySnapshotLoad()
        try await fixture.expectQuarantined(model, identity: identity, state: uncertain)
        try FileManager.default.removeItem(at: syncFlag)
        await model.retrySnapshotLoad()
        #expect(model.snapshotLoadFailure == nil)
        #expect(!model.isWorkspaceMutationBlocked)
        #expect(model.durationMinutes(for: .focus) == 10)
        #expect(try fixture.savedState() == uncertain)
        #expect(try fixture.mirroredState() == uncertain)
        fixture.defaults.resetTimerStateWrites()
        model.setDurationMinutes(15, for: .focus)
        try fixture.expectDurableFocusChange(from: uncertain, model: model)
    }

    @Test @MainActor
    func uncertainMigrationSaveRetainsSourceUntilConfirmedSave() throws {
        let fixture = try SnapshotReplacementFixture()
        defer { fixture.cleanup() }
        let task = try #require(FocusTask(title: "Legacy recovery"))
        let legacy = LocalTaskState(tasks: [task], selectedTaskID: task.id, assignments: [:])
        let bytes = try JSONEncoder.api.encode(legacy)
        fixture.defaults.set(bytes, forKey: PersistedStateLoader.localTaskStorageKey)
        let persistence = fixture.coordinator(afterReplacement: { throw POSIXError(.EIO) })
        let loaded = fixture.load(persistence)
        let session = fixture.sessionCoordinator(persistence)
        #expect(session.loadCompletionEffects(for: loaded, projectionSucceeded: true) == [.persist])

        let failed = session.persist(loaded.state, to: .local)

        #expect(!failed.action.succeeded)
        #expect(!failed.effects.contains(.removeLegacyTasks))
        session.removeLegacyTasks()
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == bytes)
        let restarted = fixture.coordinator()
        let recovered = fixture.load(restarted)
        #expect(recovered.snapshotLoadFailure == nil)
        let recoveredSession = fixture.sessionCoordinator(restarted)
        _ = recoveredSession.loadCompletionEffects(for: recovered, projectionSucceeded: true)
        #expect(recoveredSession.persist(recovered.state, to: .local).effects == [.removeLegacyTasks])
        recoveredSession.removeLegacyTasks()
        #expect(fixture.defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == nil)
        #expect(try fixture.savedState().pendingTaskOperations == loaded.state.pendingTaskOperations)
    }
}

@MainActor
private struct SnapshotReplacementFixture {
    let suiteName = "SnapshotReplacementRecoveryTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapshotReplacementRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    var url: URL { directory.appendingPathComponent("workspace.json") }

    init() throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func seed() throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.nextSequence = 2
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.resetTimerStateWrites()
        return state
    }

    func appendingPause(to state: PersistedTimerState) -> PersistedTimerState {
        var proposed = state
        proposed.pendingCommands.append(TestFixtures.command(.pause, sequence: 2, elapsed: 1_000))
        proposed.nextSequence = 3
        return proposed
    }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: Data(contentsOf: url))
    }

    func mirroredState() throws -> PersistedTimerState {
        let bytes = try #require(defaults.data(forKey: PersistedStateLoader.storageKey))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
    }

    func expectQuarantined(
        _ model: AppModel, identity: RecordingGoogleIdentityProvider, state: PersistedTimerState
    ) async throws {
        #expect(model.snapshotLoadFailure != nil)
        #expect(model.isWorkspaceMutationBlocked)
        model.setDurationMinutes(15, for: .focus)
        model.start()
        model.signOut()
        await model.setReplicationMode(.iroh)
        await model.sync(force: true)
        #expect(identity.signOutCount == 0)
        #expect(model.replicationMode == .offline)
        #expect(model.durationMinutes(for: .focus) == 10)
        #expect(try savedState() == state)
        #expect(defaults.timerStateWrites.isEmpty)
    }

    func expectDurableFocusChange(from previous: PersistedTimerState, model: AppModel) throws {
        let saved = try savedState()
        let obsolete = try #require(previous.pendingDurationOperations.first)
        let replacement = try #require(saved.pendingDurationOperations.first)
        let previousID = try #require(previous.lastUuidV7)
        let replacementID = try #require(saved.lastUuidV7)
        #expect(obsolete.phase == .focus)
        #expect(obsolete.durationMs == 600_000)
        #expect(replacement.id == "duration-operation-\(replacementID.uuidString.lowercased())")
        #expect(replacement.id != obsolete.id)
        #expect(UUIDv7.isLess(previousID, than: replacementID))
        #expect(replacement == DurationOperation(
            id: replacement.id, phase: .focus, durationMs: 900_000,
            occurredAt: obsolete.occurredAt, hlcWallMs: obsolete.hlcWallMs,
            hlcCounter: obsolete.hlcCounter + 1
        ))
        var expected = previous
        expected.pendingDurationOperations = [replacement]
        expected.settings.setMinutes(15, for: .focus)
        expected.hlcCounter += 1
        expected.lastUuidV7 = replacementID
        #expect(saved == expected)
        #expect(saved.hasValidPendingWireOperations)
        #expect(model.snapshotLoadFailure == nil)
        #expect(!model.isWorkspaceMutationBlocked)
        #expect(model.durationMinutes(for: .focus) == 15)
        #expect(defaults.timerStateWrites.count == 1)
        #expect(try mirroredState() == expected)
        let reloaded = load(coordinator())
        #expect(reloaded.snapshotLoadFailure == nil)
        #expect(reloaded.state == expected)
        let restarted = self.model(store: AtomicDurableFileStore(fileURL: url), identity: .init())
        #expect(restarted.snapshotLoadFailure == nil)
        #expect(!restarted.isWorkspaceMutationBlocked)
        #expect(restarted.durationMinutes(for: .focus) == 15)
        try expectEquivalentDurationProjection(previous: previous, compacted: saved)
    }

    func expectEquivalentDurationProjection(
        previous: PersistedTimerState, compacted: PersistedTimerState
    ) throws {
        var uncoalesced = compacted
        uncoalesced.pendingDurationOperations = previous.pendingDurationOperations + compacted.pendingDurationOperations
        let controller = TimerSessionController(sharedCoreProvider: { try SharedCore.bundled() })
        let date = TestFixtures.anchor.addingTimeInterval(5)
        let original = try controller.project(uncoalesced, replicationMode: .offline, physicalNow: date)
        let reduced = try controller.project(compacted, replicationMode: .offline, physicalNow: date)
        #expect(original == reduced)
        #expect(reduced.durationsMs.focus == 900_000)
        #expect(reduced.winningOperationIds.durations["focus"] == compacted.pendingDurationOperations.first?.id)
    }

    func permissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func coordinator(
        afterReplacement: @escaping @Sendable () throws -> Void = {},
        beforeSynchronization: @escaping @Sendable () throws -> Void = {}
    ) -> AppStatePersistenceCoordinator {
        AppStatePersistenceCoordinator(defaults: defaults, durableLocalStore: AtomicDurableFileStore(
            fileURL: url, beforeSynchronization: beforeSynchronization, afterReplacement: afterReplacement
        ))
    }

    func load(_ coordinator: AppStatePersistenceCoordinator) -> AppStatePersistenceCoordinator.LoadTransition {
        coordinator.load(
            replicationMode: .offline, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            wallDate: TestFixtures.anchor.addingTimeInterval(5), uptime: 100
        )
    }

    func model(store: AtomicDurableFileStore, identity: RecordingGoogleIdentityProvider) -> AppModel {
        AppModel(
            api: APIClient(keychain: EmptyTokenStore()), defaults: defaults, durableLocalStore: store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(), googleIdentityProvider: identity,
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func sessionCoordinator(_ persistence: AppStatePersistenceCoordinator) -> CentralizedAccountSessionCoordinator {
        let api = APIClient(keychain: EmptyTokenStore())
        return CentralizedAccountSessionCoordinator(
            lifecycle: .init(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
            synchronization: .init(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
            initialPublication: .init(sessionState: .localOnly, historyResolutionState: .none),
            persistence: persistence
        )
    }
}
