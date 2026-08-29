import Foundation
import Testing
@testable import Pomodorough

@Suite("AppModel decomposition")
struct AppModelDecompositionTests {
    @Test @MainActor
    func accountLifecycleRejectsStaleAuthenticationAndInvalidatesVerification() throws {
        let lifecycle = AccountLifecycleController(
            api: APIClient(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )

        let first = try #require(lifecycle.beginSignIn(isWorking: false))
        lifecycle.markVerified(first.operation)
        #expect(lifecycle.isVerified(first.operation))

        let second = try #require(lifecycle.beginSignIn(isWorking: false))

        #expect(!lifecycle.owns(first.operation))
        #expect(lifecycle.owns(second.operation))
        #expect(!lifecycle.isVerified(first.operation))
        #expect(!lifecycle.isVerified(second.operation))
        #expect(first.effects == [.invalidateSynchronization, .resetCentralizedLifecycle])
    }

    @Test @MainActor
    func accountLifecyclePlansSignOutAndAccountSwitchCancellationInStableOrder() throws {
        let lifecycle = AccountLifecycleController(
            api: APIClient(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        let strategy = BootstrapResolutionStrategy.replaceRemote

        let signOut = try #require(lifecycle.beginSignOut(
            isWorking: false,
            preservesBootstrapResolution: true,
            pendingStrategy: strategy
        ))
        #expect(signOut.sessionState == .localOnly)
        #expect(signOut.historyResolutionState == .retryable(strategy))
        #expect(signOut.clearsBootstrapPresentation)
        #expect(signOut.isOffline == false)
        #expect(signOut.isWorking == true)
        #expect(signOut.effects == [
            .invalidateSynchronization,
            .resetCentralizedLifecycle,
            .signOutIdentity
        ])

        let cancellation = try #require(lifecycle.beginAccountSwitchCancellation(
            hasPendingAccountSwitch: true,
            isWorking: false
        ))
        #expect(cancellation.historyResolutionState == nil)
        #expect(!cancellation.clearsBootstrapPresentation)
        #expect(cancellation.isOffline == nil)
        #expect(cancellation.isWorking == nil)
        #expect(cancellation.effects == [
            .invalidateSynchronization,
            .resetCentralizedLifecycle,
            .signOutIdentity
        ])
        #expect(cancellation.operation.generation == signOut.operation.generation + 1)

        let cleared = try #require(lifecycle.beginSignOut(
            isWorking: false,
            preservesBootstrapResolution: false,
            pendingStrategy: nil
        ))
        #expect(cleared.historyResolutionState == .some(.none))
    }

    @Test @MainActor
    func accountLifecycleOwnsAccountSwitchStagingAndConfirmationState() throws {
        let lifecycle = AccountLifecycleController(
            api: APIClient(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        let previousUser = User(
            id: "user-1",
            email: "one@example.com",
            name: "One",
            avatarUrl: ""
        )
        let authenticatedUser = User(
            id: "user-2",
            email: "two@example.com",
            name: "Two",
            avatarUrl: ""
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = previousUser
        state.bootstrapUser = previousUser

        let staging = try #require(lifecycle.stageAccountSwitch(
            to: authenticatedUser,
            state: state
        ))

        #expect(state.cachedUser == previousUser)
        #expect(staging.state.pendingAccountSwitchUser == authenticatedUser)
        #expect(staging.state.bootstrapUser == nil)
        #expect(staging.state.pendingBootstrapResolution == nil)
        #expect(lifecycle.confirmAccountSwitch(
            state: staging.state,
            authenticatedUser: previousUser
        ) == nil)

        let confirmed = try #require(lifecycle.confirmAccountSwitch(
            state: staging.state,
            authenticatedUser: authenticatedUser
        ))
        #expect(confirmed.state.cachedUser == authenticatedUser)
        #expect(confirmed.state.pendingAccountSwitchUser == nil)
    }

    @Test @MainActor
    func accountLifecyclePlansIrohSignOutWithoutDiscardingRoomState() throws {
        let lifecycle = AccountLifecycleController(
            api: APIClient(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        let user = User(id: "user-1", email: "one@example.com", name: "One", avatarUrl: "")
        var state = PersistedTimerState.fresh()
        state.cachedUser = user
        state.bootstrapUser = user
        var returnState = PersistedTimerState.fresh()
        returnState.deviceId = "return-device"
        returnState.cachedUser = user

        let transition = lifecycle.signedOutStorageTransition(
            state: state,
            replicationMode: .iroh,
            preservesBootstrapResolution: false,
            activeReturnState: returnState
        )

        #expect(transition.state.cachedUser == nil)
        #expect(transition.state.bootstrapUser == nil)
        #expect(transition.state.deviceId == state.deviceId)
        #expect(transition.irohReturnState?.cachedUser == nil)
        #expect(transition.irohReturnState?.deviceId == "return-device")
        #expect(!transition.rebuildsProjection)
    }

    @Test @MainActor
    func bootstrapFailurePlanningPreservesExactPresentationAndRetryEffects() {
        let lifecycle = AccountLifecycleController(
            api: APIClient(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )

        let invalid = lifecycle.bootstrapFailure(
            AppError.invalidResponse,
            stage: .preflight
        )
        #expect(invalid.historyResolutionState == .retryable(nil))
        #expect(!invalid.isOffline)
        #expect(invalid.errorMessage == "History setup paused because the server returned an invalid response. Local data remains on this device.")
        #expect(invalid.effects.isEmpty)

        let unavailable = lifecycle.bootstrapFailure(
            AppError.server("Temporarily unavailable"),
            stage: .submission(.keepRemote)
        )
        #expect(unavailable.historyResolutionState == .retryable(.keepRemote))
        #expect(unavailable.isOffline)
        #expect(unavailable.errorMessage == nil)
        #expect(unavailable.effects == [.scheduleRetry])
    }

    @Test @MainActor
    func persistenceCoordinatorWritesExactCodableBytesBeforeReturningStoredState() throws {
        let suiteName = "AppModelDecompositionTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults)
        var state = PersistedTimerState.fresh()
        state.autoStartBreaks = true

        let transition = coordinator.persist(
            state,
            replicationMode: .centralized,
            captureIrohState: { _ in .unchanged }
        )
        let expected = try JSONEncoder.api.encode(state)

        guard case .stored(let stored, let bytes) = transition else {
            Issue.record("Expected centralized state to be stored")
            return
        }
        #expect(stored == state)
        #expect(bytes == expected)
        #expect(defaults.timerStateWrites == [expected])
        #expect(defaults.data(forKey: PersistedStateLoader.storageKey) == expected)
    }

    @Test @MainActor
    func persistenceCoordinatorReturnsDurableIrohRollbackWithoutWritingDefaults() throws {
        let suiteName = "AppModelDecompositionTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults)
        let proposed = PersistedTimerState.fresh()
        var durable = proposed
        durable.nextSequence = 7

        let transition = coordinator.persist(
            proposed,
            replicationMode: .iroh,
            captureIrohState: { _ in
                .captureFailed(durable, message: "immutable conflict", quarantined: true)
            }
        )

        #expect(transition == .captureFailed(
            durable: durable,
            message: "immutable conflict",
            quarantined: true
        ))
        #expect(defaults.timerStateWrites.isEmpty)
    }

    @Test @MainActor
    func persistenceCoordinatorOwnsFailurePublicationDecision() throws {
        let suiteName = "AppModelDecompositionTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults)
        var proposed = PersistedTimerState.fresh()
        proposed.nextSequence = 9
        var durable = proposed
        durable.nextSequence = 4

        let application = coordinator.application(
            for: .captureFailed(
                durable: durable,
                message: "immutable conflict",
                quarantined: true
            ),
            current: proposed,
            rebuildsOnFailure: true
        )

        #expect(application.state == durable)
        #expect(!application.succeeded)
        #expect(application.rebuildsProjection)
        #expect(application.conflictMessage == "immutable conflict")
        #expect(application.marksIrohConflict)
    }

    @Test @MainActor
    func persistenceCoordinatorOwnsAtomicRollbackState() throws {
        let suiteName = "AppModelDecompositionTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults)
        var previous = PersistedTimerState.fresh()
        previous.nextSequence = 3
        var proposed = previous
        proposed.nextSequence = 4

        let transition = coordinator.persistAtomically(
            previous: previous,
            proposed: proposed,
            replicationMode: .iroh,
            captureIrohState: { _ in
                .captureFailed(nil, message: "failed", quarantined: false)
            }
        )

        #expect(!transition.committed)
        #expect(transition.state == previous)
        #expect(transition.persistence == .captureFailed(
            durable: nil,
            message: "failed",
            quarantined: false
        ))
    }

    @Test @MainActor
    func persistenceCoordinatorDoesNotFinalizeFailedMigration() throws {
        let suiteName = "AppModelDecompositionTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults)
        let transition = AppStatePersistenceCoordinator.LoadTransition(
            replicationMode: .centralized,
            state: .fresh(),
            removesLegacyTasksAfterProjection: false,
            shouldPersistAfterProjection: false,
            shouldReportInvalidLocalClock: true
        )

        #expect(coordinator.completionEffect(
            for: transition,
            projectionSucceeded: true
        ) == .reportInvalidLocalClock)
    }

    @Test @MainActor
    func persistenceCoordinatorPreservesLoadCompletionOrdering() throws {
        let suiteName = "AppModelDecompositionTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppStatePersistenceCoordinator(defaults: defaults)
        let transition = AppStatePersistenceCoordinator.LoadTransition(
            replicationMode: .centralized,
            state: .fresh(),
            removesLegacyTasksAfterProjection: true,
            shouldPersistAfterProjection: true,
            shouldReportInvalidLocalClock: true
        )

        #expect(coordinator.completionEffect(
            for: transition,
            projectionSucceeded: true
        ) == .removeLegacyTasksAndPersist)
        #expect(coordinator.completionEffect(
            for: transition,
            projectionSucceeded: false
        ) == .reportInvalidLocalClock)
    }

}

@Suite("Centralized session ownership architecture")
struct CentralizedSessionOwnershipArchitectureTests {
    @Test
    func appModelDoesNotOwnCentralizedSessionOrPersistencePolicy() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources")
        let appModel = try String(
            contentsOf: sources.appending(path: "AppModel.swift"), encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: sources.appending(path: "CentralizedAccountSessionCoordinator.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "private let accountSynchronization", "private let accountLifecycle",
            "syncOwnership", "bootstrapSnapshot", "case .captureFailed"
        ] {
            #expect(!appModel.contains(forbidden))
        }
        #expect(coordinator.contains("private var syncOwnership"))
        #expect(coordinator.contains("private var bootstrapSnapshot"))
    }

    @Test
    func shippingSourcesContainNoLegacyPendingOperationRebasePolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let queue = try String(
            contentsOf: root.appending(path: "Sources/PersistedQueueReconciliation.swift"),
            encoding: .utf8
        )
        let state = try String(
            contentsOf: root.appending(path: "Sources/PersistedTimerState.swift"), encoding: .utf8
        )
        let compatibility = try String(
            contentsOf: root.appending(
                path: "Tests/Compatibility/LegacyPendingOperationRebase.swift"
            ),
            encoding: .utf8
        )

        #expect(!queue.contains("PendingRebaseContext"))
        #expect(!queue.contains("static func rebase("))
        #expect(!state.contains("rebasePendingOperations"))
        #expect(compatibility.contains("mutating func rebasePendingOperations"))
    }
}

@Suite("Centralized session transitions")
struct CentralizedAccountSessionCoordinatorTests {
    @Test @MainActor
    func syncLeaseCoalescesAndPublishesFollowUpDecision() throws {
        let user = Self.user(id: "user-1")
        let coordinator = Self.makeCoordinator(sessionState: .signedIn(user))
        coordinator.markCurrentSessionVerified()
        var state = PersistedTimerState.fresh()
        state.cachedUser = user
        let workspace = CentralizedAccountSessionCoordinator.Workspace(
            state: state,
            replicationMode: .centralized,
            modeGeneration: 7,
            isMutationBlocked: false
        )

        let first = coordinator.beginSync(
            workspace: workspace,
            force: true,
            showsActivity: true
        )
        guard case .started(let lease) = first.action else {
            Issue.record("Expected coordinator-owned sync lease")
            return
        }
        #expect(first.publication.isSyncing)
        #expect(first.effects == [.cancelRetry])
        #expect(coordinator.beginSync(
            workspace: workspace,
            force: true,
            showsActivity: true
        ).action == .coalesced)

        let finished = coordinator.finishSync(
            lease,
            workspace: workspace,
            hintedFollowUp: true,
            allowsFollowUp: true
        )
        #expect(finished.action == .synchronize)
        #expect(!finished.publication.isSyncing)
    }

    @Test @MainActor
    func authenticatedRoutingStagesAccountSwitchWithoutMutatingInput() throws {
        let previous = Self.user(id: "user-1")
        let authenticated = Self.user(id: "user-2")
        let coordinator = Self.makeCoordinator(sessionState: .signedIn(authenticated))
        coordinator.markCurrentSessionVerified()
        var state = PersistedTimerState.fresh()
        state.cachedUser = previous
        state.bootstrapUser = previous

        let transition = coordinator.routeAuthenticatedSession(
            authenticated,
            operation: coordinator.currentOperation,
            state: state,
            replicationMode: .centralized
        )

        guard case .stageAccountSwitch(let staged) = transition.action else {
            Issue.record("Expected account-switch route")
            return
        }
        #expect(state.cachedUser == previous)
        #expect(staged.cachedUser == previous)
        #expect(staged.pendingAccountSwitchUser == authenticated)
        #expect(staged.bootstrapUser == nil)
        #expect(transition.effects == [.cancelCentralizedStreams, .persist])
        #expect(transition.publication.historyResolutionState == .none)
    }

    @MainActor
    private static func makeCoordinator(
        sessionState: AccountSessionState
    ) -> CentralizedAccountSessionCoordinator {
        CentralizedAccountSessionCoordinator(
            lifecycle: AccountLifecycleController(
                api: APIClient(),
                googleIdentityProvider: RecordingGoogleIdentityProvider()
            ),
            synchronization: AccountSynchronization(
                api: APIClient(),
                sharedCoreProvider: { try SharedCore.bundled() }
            ),
            initialPublication: .init(sessionState: sessionState)
        )
    }

    private static func user(id: String) -> User {
        User(id: id, email: "\(id)@example.com", name: id, avatarUrl: "")
    }
}

@Suite("Shared-core projection boundary")
struct SharedCoreProjectionBoundaryTests {
    private let invalidProjection = SharedCoreError.invalidResponse(
        "projection.apply.v2 output failed structural or winner validation"
    )

    @Test
    func acceptsInternallyConsistentWinnerThatDiffersFromLegacyTupleOracle() throws {
        let futureChoice = durationOperation(
            id: "future-policy-choice",
            minutes: 10,
            wallMilliseconds: 1_000,
            deviceID: "device-a"
        )
        let legacyTupleChoice = durationOperation(
            id: "legacy-tuple-choice",
            minutes: 20,
            wallMilliseconds: 2_000,
            deviceID: "device-z"
        )
        let input = projectionInput(durationOperations: [futureChoice, legacyTupleChoice])
        var durations = DurationValues.defaults
        durations.setDurationMs(futureChoice.durationMs, for: .focus)
        let output = projectionOutput(
            durations: durations,
            durationWinners: [TimerPhase.focus.rawValue: futureChoice.id]
        )

        #expect(try output.validated(for: input) == output)
    }

    @Test
    func rejectsWinnerReferenceOutsideMatchingOperationGroup() {
        let focus = durationOperation(
            id: "focus-choice",
            phase: .focus,
            minutes: 10,
            wallMilliseconds: 1_000
        )
        let shortBreak = durationOperation(
            id: "short-break-choice",
            phase: .shortBreak,
            minutes: 5,
            wallMilliseconds: 2_000
        )
        let input = projectionInput(durationOperations: [focus, shortBreak])
        var durations = DurationValues.defaults
        durations.setDurationMs(focus.durationMs, for: .focus)
        let output = projectionOutput(
            durations: durations,
            durationWinners: [
                TimerPhase.focus.rawValue: shortBreak.id,
                TimerPhase.shortBreak.rawValue: shortBreak.id
            ]
        )

        #expect(throws: invalidProjection) {
            try output.validated(for: input)
        }
    }

    @Test
    func rejectsProjectedValueInconsistentWithReferencedWinner() {
        let selected = durationOperation(
            id: "selected-choice",
            minutes: 10,
            wallMilliseconds: 1_000
        )
        let input = projectionInput(durationOperations: [selected])
        let output = projectionOutput(
            durations: .defaults,
            durationWinners: [TimerPhase.focus.rawValue: selected.id]
        )

        #expect(throws: invalidProjection) {
            try output.validated(for: input)
        }
    }

    @Test
    func rejectsDuplicatePendingIdentifiersHiddenByOutcomeSetComparison() {
        let command = timerCommand(id: "duplicate-command")
        let input = projectionInput(commands: [command, command])
        let output = projectionOutput(
            timerOutcomes: [
                command.id: CoreProjectionTimerOutcome(outcome: .applied, reason: "")
            ]
        )

        #expect(throws: invalidProjection) {
            try output.validated(for: input)
        }
    }

    private func projectionInput(
        commands: [CoreTimerCommand] = [],
        durationOperations: [CoreDurationOperation] = []
    ) -> CoreProjectionInput {
        CoreProjectionInput(
            base: CoreProjectionBase(
                canonicalTimer: nil,
                history: [],
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: false,
                selectedTaskId: nil
            ),
            pending: CoreProjectionPending(
                commands: commands,
                taskOperations: [],
                durationOperations: durationOperations,
                autoStartOperations: [],
                selectedTaskOperations: []
            ),
            now: Date(timeIntervalSince1970: 3)
        )
    }

    private func projectionOutput(
        durations: DurationValues = .defaults,
        timerOutcomes: [String: CoreProjectionTimerOutcome] = [:],
        durationWinners: [String: String] = [:]
    ) -> CoreProjectionOutput {
        CoreProjectionOutput(
            canonicalTimer: nil,
            history: [],
            tasks: [],
            durationsMs: durations,
            autoStartBreaks: false,
            selectedTaskId: nil,
            timerOutcomes: timerOutcomes,
            winningOperationIds: CoreProjectionWinningOperationIDs(
                tasks: [:],
                durations: durationWinners,
                autoStart: nil,
                selectedTask: nil
            )
        )
    }

    private func durationOperation(
        id: String,
        phase: TimerPhase = .focus,
        minutes: Int,
        wallMilliseconds: Int64,
        deviceID: String = "device-a"
    ) -> CoreDurationOperation {
        CoreDurationOperation(
            DurationOperation(
                id: id,
                phase: phase,
                durationMs: Int64(minutes) * DurationValues.wireUnitMs,
                occurredAt: Date(timeIntervalSince1970: Double(wallMilliseconds) / 1_000),
                hlcWallMs: wallMilliseconds,
                hlcCounter: 0
            ),
            deviceId: deviceID
        )
    }

    private func timerCommand(id: String) -> CoreTimerCommand {
        CoreTimerCommand(
            TimerCommand(
                id: id,
                deviceSequence: 1,
                timerId: "timer-1",
                taskId: nil,
                type: .clear,
                phase: .focus,
                plannedDurationMs: DurationValues.defaults.focus,
                occurredAt: Date(timeIntervalSince1970: 1),
                hlcWallMs: 1_000,
                hlcCounter: 0,
                observedElapsedMs: 0
            ),
            deviceId: "device-a"
        )
    }
}

@Suite("Synchronized workspace mutation planner")
struct SynchronizedWorkspaceMutationPlannerTests {
    @Test @MainActor
    func durationIntentClampsCompactsProjectsAndReturnsOrderedEffects() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        let obsolete = DurationOperation(
            id: "duration-operation-018f24e8-7400-7000-8000-000000000001",
            phase: .focus,
            durationMs: 20 * DurationValues.wireUnitMs,
            occurredAt: Date(timeIntervalSince1970: 1_710_000_000),
            hlcWallMs: 1_710_000_000_000,
            hlcCounter: 0
        )
        state.pendingDurationOperations = [obsolete]
        state.lastUuidV7 = UUID(uuidString: "018f24e8-7400-7000-8000-000000000001")
        state.hlcWallMs = obsolete.hlcWallMs
        let snapshot = makeSnapshot(state: state)

        let planned = try controller.plan(
            .setDurationMinutes(999, for: .focus),
            from: snapshot
        )
        let transition = try #require(planned)

        #expect(snapshot.state == state)
        #expect(transition.state.settings.focusMinutes == 180)
        #expect(transition.state.pendingDurationOperations.count == 1)
        #expect(transition.state.pendingDurationOperations[0].id != obsolete.id)
        #expect(transition.projection?.durationsMs.focus == 180 * DurationValues.wireUnitMs)
        #expect(transition.requirements.durationOperationIDs == [
            transition.state.pendingDurationOperations[0].id
        ])
        #expect(transition.effects.count == 2)
        guard case .persistAtomically(let previous, true) = transition.effects[0] else {
            Issue.record("First effect must atomically persist against immutable input")
            return
        }
        #expect(previous == state)
        #expect(transition.effects[1] == .launchSync)
    }

    @Test @MainActor
    func startIntentDerivesCommandAndReturnsTransactionSyncAndAlarmOrder() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        state.hasExplicitPhaseSelection = true
        let snapshot = makeSnapshot(state: state)

        let planned = try controller.plan(.startTimer, from: snapshot)
        let transition = try #require(planned)

        let command = try #require(transition.state.pendingCommands.last)
        #expect(command.type == .start)
        #expect(command.timerId == "timer-planner-test")
        #expect(command.phase == .focus)
        #expect(command.plannedDurationMs == DurationValues.defaults.focus)
        #expect(transition.projection?.canonicalTimer?.id == command.timerId)
        #expect(transition.requirements.timerCommandIDs == [command.id])
        #expect(transition.effects.count == 5)
        guard case .persistAtomically(let previous, true) = transition.effects[0] else {
            Issue.record("Start must atomically persist projected command first")
            return
        }
        #expect(previous == state)
        #expect(transition.effects[1] == .launchSync)
        #expect(transition.effects[2] == .setExplicitPhaseSelection(false))
        #expect(transition.effects[3] == .persist)
        #expect(transition.effects[4] == .alarm(
            TimerSessionController.AlarmPlan(actions: [.schedule(
                timerID: command.timerId,
                phase: command.phase,
                duration: TimeInterval(command.plannedDurationMs) / 1_000
            )]),
            cancelReportsError: true
        ))
    }

    @MainActor
    private func makeController() -> SynchronizedWorkspaceMutationController {
        SynchronizedWorkspaceMutationController(
            timerSessionController: TimerSessionController {
                try SharedCore.bundled()
            },
            timerIDProvider: { "timer-planner-test" }
        )
    }

    private func makeSnapshot(
        state: PersistedTimerState
    ) -> SynchronizedWorkspaceMutationController.Snapshot {
        SynchronizedWorkspaceMutationController.Snapshot(
            state: state,
            canonicalTimer: state.canonicalTimer,
            tasks: state.tasks,
            projectedAutoStartBreaks: state.autoStartBreaks,
            projectedSelectedTaskID: state.selectedTaskID,
            replicationMode: .centralized,
            localDate: Date(timeIntervalSince1970: 1_710_000_001),
            trustedClockUptime: 100,
            isWorkspaceMutationBlocked: false
        )
    }
}
