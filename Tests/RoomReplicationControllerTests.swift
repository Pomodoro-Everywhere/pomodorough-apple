import Foundation
import Testing
@testable import Pomodorough

@Suite("Room replication controller")
struct RoomReplicationControllerTests {
    @Test @MainActor
    func createRoomReturnsTypedTransitionAndKeepsSecretBytes() async throws {
        let fixture = makeFixture(mode: .offline)
        let secret = Data(0..<32)
        fixture.randomBytes.value = secret
        var local = PersistedTimerState.fresh()
        local.deviceId = "device-controller"
        fixture.workspace.value = workspace(from: local)

        let transition = await fixture.controller.createRoom(
            name: "  Focus room  ",
            environment: environment(for: local)
        )

        guard case .roomCreated(let state, let invite, let status) = transition else {
            Issue.record("Expected roomCreated, got \(transition)")
            return
        }
        #expect(invite == "encoded-invite")
        #expect(status == .listening(endpointMark: "ticket"))
        #expect(state.deviceId == local.deviceId)
        #expect(fixture.store.activeRoomSecret == secret)
        #expect(fixture.store.activeSnapshot?.roomName == "Focus room")
        let contexts = await fixture.service.startedContexts
        #expect(contexts.count == 1)
        #expect(contexts.first?.roomSecret == secret)
        #expect(contexts.first?.roomID == fixture.store.activeRoomID)
    }

    @Test @MainActor
    func createRoomReadsWorkspaceAfterEndpointStartup() async {
        let fixture = makeFixture(mode: .offline)
        var initial = PersistedTimerState.fresh()
        initial.deviceId = "before-start"
        var latest = initial
        latest.deviceId = "after-start"
        latest.settings.durationsMs.focus = 42 * 60_000
        fixture.workspace.value = workspace(from: initial)
        let workspace = fixture.workspace
        let refreshed = self.workspace(from: latest)
        await fixture.service.setStartHook { workspace.value = refreshed }

        let transition = await fixture.controller.createRoom(
            name: "Reentrant room",
            environment: environment(for: initial)
        )

        guard case .roomCreated(let state, _, _) = transition else {
            Issue.record("Expected roomCreated, got \(transition)")
            return
        }
        #expect(state.deviceId == "after-start")
        #expect(state.settings.durationsMs.focus == 42 * 60_000)
    }

    @Test @MainActor
    func modeRoundTripPreservesWorkspaceAndReturnState() async throws {
        let local = PersistedTimerState.fresh()
        let fixture = makeFixture(mode: .iroh)
        let roomState = try makeActiveRoom(in: fixture.store, returnState: local)
        let original = fixture.store.activeSnapshot
        fixture.workspace.value = workspace(from: roomState)

        let offline = await fixture.controller.changeMode(
            to: .offline,
            environment: environment(for: roomState)
        )
        guard case .modeChanged(.offline, let returned) = offline else {
            Issue.record("Expected offline mode transition, got \(offline)")
            return
        }
        #expect(returned == local)
        #expect(fixture.store.activeRoomID == nil)
        fixture.workspace.value = workspace(from: returned)

        let resumed = await fixture.controller.changeMode(
            to: .iroh,
            environment: environment(for: returned)
        )
        guard case .modeChanged(.iroh, let restored) = resumed else {
            Issue.record("Expected Iroh mode transition, got \(resumed)")
            return
        }
        #expect(restored == roomState)
        #expect(fixture.store.activeSnapshot == original)
    }

    @Test @MainActor
    func overlongRoomNameKeepsExactErrorAndDoesNotStartEndpoint() async {
        let fixture = makeFixture(mode: .offline)
        let local = PersistedTimerState.fresh()
        let name = String(repeating: "x", count: 65)

        let transition = await fixture.controller.createRoom(
            name: name,
            environment: environment(for: local)
        )

        #expect(transition == .failed("Room name must be 64 characters or fewer."))
        #expect(await fixture.service.startedContexts.isEmpty)
        #expect(fixture.store.activeRoomID == nil)
    }

    @Test @MainActor
    func revisionStreamOrdersHintsAndReconnectsAfterOneSecond() async {
        let fixture = makeFixture(mode: .centralized, revision: 10)
        fixture.controller.setSceneActive(true, environment: environment())
        fixture.controller.startRevisionStream()

        await waitUntil {
            fixture.operations.value.contains(.synchronize(force: true, showsActivity: true))
                && fixture.sleeps.value == [.seconds(1)]
        }

        #expect(fixture.operations.value.filter {
            $0 == .synchronize(force: true, showsActivity: true)
        }.count == 1)
        #expect(fixture.revisionRequests.value == 1)
        #expect(fixture.sleeps.value == [.seconds(1)])
    }

    @Test @MainActor
    func newerRevisionCoalescesWhileSyncing() async {
        let fixture = makeFixture(mode: .centralized, revision: 10, isSyncing: true)

        await fixture.controller.receiveRevisionHint(12)
        await fixture.controller.receiveRevisionHint(11)
        #expect(fixture.operations.value.isEmpty)

        fixture.centralizedState.value.localRevision = 11
        fixture.centralizedState.value.isSyncing = false
        #expect(fixture.controller.consumeRevisionFollowUp())
        #expect(!fixture.controller.consumeRevisionFollowUp())
    }

    @Test @MainActor
    func immutableConflictReturnsQuarantineAndStopsPeerSynchronization() async throws {
        let fixture = makeFixture(mode: .iroh)
        let local = PersistedTimerState.fresh()
        var roomState = try makeActiveRoom(in: fixture.store, returnState: local)
        roomState.pendingDurationOperations = [durationOperation(minutes: 30)]
        roomState.settings.durationsMs.focus = 30 * 60_000
        let first = fixture.controller.captureLocalState(roomState)
        guard case .captured(let durable) = first else {
            Issue.record("Expected captured state, got \(first)")
            return
        }

        var conflicting = durable
        conflicting.pendingDurationOperations = [durationOperation(minutes: 35)]
        conflicting.settings.durationsMs.focus = 35 * 60_000
        let transition = fixture.controller.captureLocalState(conflicting)

        guard case .captureFailed(let restored, let message, let quarantined) = transition else {
            Issue.record("Expected captureFailed, got \(transition)")
            return
        }
        #expect(restored == durable)
        #expect(message == "Room contains two different operations with the same immutable ID.")
        #expect(quarantined)
        #expect(fixture.store.activeSnapshot?.conflict != nil)
        await waitUntil { await fixture.service.markedConflictRoomIDs.count == 1 }
        #expect(await fixture.service.markedConflictRoomIDs == [fixture.store.activeRoomID])
    }

    @Test @MainActor
    func centralizedOwnershipIsInvalidatedByModeTransition() async {
        let fixture = makeFixture(mode: .centralized)
        let owner = fixture.controller.ownership(sessionGeneration: 7)

        _ = await fixture.controller.changeMode(
            to: .offline,
            environment: environment()
        )

        #expect(!fixture.controller.owns(owner, sessionGeneration: 7))
        #expect(fixture.controller.modeGeneration == owner.modeGeneration + 1)
    }

    @Test @MainActor
    func accountDeletionQuiescenceWaitsForQueuedIrohStartupBeforeStoppingService() async throws {
        let fixture = makeFixture(mode: .iroh)
        fixture.controller.setSceneActive(true, environment: environment())
        await Task.yield()
        let roomState = try makeActiveRoom(in: fixture.store, returnState: .fresh())
        fixture.workspace.value = workspace(from: roomState)
        await fixture.service.setStartSuspended(true)
        let startCountBefore = await fixture.service.startedContexts.count
        let completionCountBefore = await fixture.service.startCompletionCount
        fixture.controller.scheduleIrohStartup(environment: environment(for: roomState))
        await waitUntil { await fixture.service.startedContexts.count == startCountBefore + 1 }
        let stopCountBeforeQuiescence = await fixture.service.stopCount

        let quiescence = Task { await fixture.controller.quiesceForAccountDeletion() }
        await Task.yield()

        #expect(await fixture.service.stopCount == stopCountBeforeQuiescence)
        await fixture.service.releaseStart()
        await quiescence.value

        #expect(await fixture.service.startCompletionCount == completionCountBefore + 1)
        #expect(await fixture.service.stopCount == stopCountBeforeQuiescence + 1)
        #expect(Array(await fixture.service.lifecycleEvents.suffix(3)) == [
            .startEntered, .startCompleted, .stop
        ])
    }

    @Test @MainActor
    func accountDeletionWaitsForExactRevisionTaskTerminationBeforeDeleteStarts() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await api.restoreTokens())
        let lifecycle = LockedTestValue<[String]>([])
        let probe = RevisionStreamCancellationProbe(lifecycle: lifecycle)
        let fixture = makeFixture(
            mode: .centralized,
            revisionEvents: { try await probe.events() }
        )
        fixture.controller.setSceneActive(true, environment: environment())
        fixture.controller.startRevisionStream()
        await waitUntil { fixture.revisionRequests.value == 1 }

        let deletion = Task {
            await fixture.controller.quiesceForAccountDeletion()
            let outcome = await api.deleteAccount(confirmation: "DELETE")
            lifecycle.value.append("DELETE completed")
            return outcome
        }
        await waitUntil { lifecycle.value.contains("revision cancellation requested") }

        #expect(lifecycle.value == ["revision cancellation requested"])
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/account"
        })
        probe.releaseTermination()
        #expect(await deletion.value == .committed)
        #expect(TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/account"
        }.count == 1)
        #expect(lifecycle.value == [
            "revision cancellation requested",
            "revision terminated",
            "DELETE completed",
        ])
    }

    @Test @MainActor
    func accountDeletionRollbackRestartsIrohEndpoint() async throws {
        let fixture = makeFixture(mode: .iroh)
        let roomState = try makeActiveRoom(in: fixture.store, returnState: .fresh())
        fixture.workspace.value = workspace(from: roomState)
        fixture.controller.setSceneActive(true, environment: environment(for: roomState))
        await waitUntil { await fixture.service.startedContexts.count == 1 }
        await fixture.controller.quiesceForAccountDeletion()
        let startCountBeforeRollback = await fixture.service.startedContexts.count
        let syncCountBeforeRollback = await fixture.service.syncCount

        _ = await fixture.controller.rollbackAccountDeletion(
            environment: environment(for: roomState)
        )

        #expect(await fixture.service.startedContexts.count == startCountBeforeRollback + 1)
        #expect(await fixture.service.syncCount == syncCountBeforeRollback + 1)
    }

    @Test @MainActor
    func invalidJoinFailsClosedThenResumesCentralizedSynchronization() async {
        let fixture = makeFixture(mode: .centralized)

        let transition = await fixture.controller.joinRoom(
            inviteText: "not-an-iroh-invite",
            environment: environment()
        )

        guard case .failed = transition else {
            Issue.record("Expected invalid invite failure, got \(transition)")
            return
        }
        #expect(fixture.store.activeRoomID == nil)
        #expect(await fixture.service.stopCount == 1)
        #expect(fixture.events.value.contains(.centralizedQuiesced))
        await waitUntil {
            fixture.operations.value.contains(.synchronize(force: true, showsActivity: true))
        }
    }

    @Test @MainActor
    func foregroundRefreshUsesModeSpecificSynchronizationContract() async throws {
        let centralized = makeFixture(mode: .centralized)
        let centralAction = await centralized.controller.refreshAfterForeground(
            environment: environment()
        )
        #expect(centralAction == .synchronize)

        let offline = makeFixture(mode: .offline)
        #expect(await offline.controller.refreshAfterForeground(
            environment: environment()
        ) == .none)

        let iroh = makeFixture(mode: .iroh)
        let roomState = try makeActiveRoom(in: iroh.store, returnState: .fresh())
        iroh.workspace.value = workspace(from: roomState)
        iroh.controller.setSceneActive(true, environment: environment(for: roomState))
        let irohAction = await iroh.controller.refreshAfterForeground(
            environment: environment(for: roomState)
        )
        #expect(irohAction == .none)
        #expect(await iroh.service.startedContexts.count >= 1)
        #expect(await iroh.service.syncCount == 1)
    }

    @Test @MainActor
    func selectingIrohWithoutRoomFailsAndResumesCentralizedSync() async {
        let fixture = makeFixture(mode: .centralized)

        let transition = await fixture.controller.changeMode(
            to: .iroh,
            environment: environment()
        )

        #expect(transition == .failed("Create or join an Iroh room before selecting Iroh mode."))
        #expect(fixture.events.value.contains(.centralizedQuiesced))
        await waitUntil {
            fixture.operations.value.contains(.synchronize(force: true, showsActivity: true))
        }
    }

    @Test @MainActor
    func createRoomStartupFailureLeavesNoRoomAndResumesCentralizedSync() async {
        let fixture = makeFixture(mode: .centralized)
        await fixture.service.setStartError(.endpointUnavailable)

        let transition = await fixture.controller.createRoom(
            name: "Unavailable room",
            environment: environment()
        )

        #expect(transition == .failed(TestRoomServiceError.endpointUnavailable.localizedDescription))
        #expect(fixture.store.activeRoomID == nil)
        #expect(await fixture.service.stopCount == 1)
        await waitUntil {
            fixture.operations.value.contains(.synchronize(force: true, showsActivity: true))
        }
    }

    @Test @MainActor
    func unauthorizedRevisionStreamInvalidatesOnlyOwningSession() async {
        let fixture = makeFixture(mode: .centralized, revisionStreamUnauthorized: true)
        fixture.controller.setSceneActive(true, environment: environment())
        fixture.controller.startRevisionStream()

        await waitUntil {
            fixture.operations.value.contains(.unauthorized(sessionGeneration: 7))
        }

        #expect(fixture.operations.value == [.unauthorized(sessionGeneration: 7)])
        #expect(fixture.sleeps.value.isEmpty)
    }

    @Test @MainActor
    func retryCoalescesAndUsesLatestHistoryResolutionState() async {
        let fixture = makeFixture(
            mode: .centralized,
            cancelsSleep: false,
            isHistoryResolutionBlocking: true
        )

        fixture.controller.scheduleRetry()
        fixture.controller.scheduleRetry()

        await waitUntil {
            fixture.operations.value.contains(.retry(sessionGeneration: 7, resolvesHistory: true))
        }
        #expect(fixture.sleeps.value == [.seconds(5)])
        #expect(fixture.operations.value == [.retry(sessionGeneration: 7, resolvesHistory: true)])
    }

    @Test @MainActor
    func activeRoomInviteRefreshUsesCurrentEndpointAndPreservesSecret() async throws {
        let fixture = makeFixture(mode: .iroh)
        let roomState = try makeActiveRoom(in: fixture.store, returnState: .fresh())
        let secret = try #require(fixture.store.activeRoomSecret)
        fixture.workspace.value = workspace(from: roomState)
        fixture.controller.setSceneActive(true, environment: environment(for: roomState))

        let transition = await fixture.controller.refreshInvite(
            environment: environment(for: roomState)
        )

        #expect(transition == .inviteRefreshed("encoded-invite"))
        #expect(fixture.store.activeRoomSecret == secret)
        #expect(await fixture.service.ticketRequestCount == 1)
    }

    @Test @MainActor
    func currentIrohModeIsIdempotentAndRestartsEndpoint() async throws {
        let fixture = makeFixture(mode: .iroh)
        let roomState = try makeActiveRoom(in: fixture.store, returnState: .fresh())
        fixture.workspace.value = workspace(from: roomState)
        fixture.controller.setSceneActive(true, environment: environment(for: roomState))

        let transition = await fixture.controller.changeMode(
            to: .iroh,
            environment: environment(for: roomState)
        )

        #expect(transition == .unchanged)
        await waitUntil { await fixture.service.startedContexts.count >= 1 }
        #expect(await fixture.service.startedContexts.last?.roomID == fixture.store.activeRoomID)
    }

    @Test @MainActor
    func inviteRefreshWithoutRoomIsNoOpAndTicketFailureIsReported() async throws {
        let fixture = makeFixture(mode: .iroh)
        #expect(await fixture.controller.refreshInvite(environment: environment()) == .unchanged)

        let roomState = try makeActiveRoom(in: fixture.store, returnState: .fresh())
        fixture.workspace.value = workspace(from: roomState)
        fixture.controller.setSceneActive(true, environment: environment(for: roomState))
        await fixture.service.setTicketError(.endpointUnavailable)

        let failed = await fixture.controller.refreshInvite(environment: environment(for: roomState))
        #expect(failed == .failed(TestRoomServiceError.endpointUnavailable.localizedDescription))
    }

    @Test @MainActor
    func leavingRoomReturnsLocalStateThenBecomesIdempotent() async throws {
        let local = PersistedTimerState.fresh()
        let fixture = makeFixture(mode: .iroh)
        let roomState = try makeActiveRoom(in: fixture.store, returnState: local)
        fixture.workspace.value = workspace(from: roomState)

        let left = await fixture.controller.leaveRoom(environment: environment(for: roomState))
        #expect(left == .roomLeft(local))
        #expect(fixture.store.activeRoomID == nil)
        #expect(await fixture.service.stopCount == 1)
        #expect(await fixture.controller.leaveRoom(environment: environment()) == .unchanged)
    }

    @Test @MainActor
    func completedRoomProjectionAdvancesDefaultPhaseAndPersistsDerivedSelection() throws {
        let fixture = makeFixture(mode: .iroh)
        var completed = PersistedTimerState.fresh()
        completed.canonicalTimer = TestFixtures.timer(status: .completed, elapsed: 60_000)
        completed.history = [TestFixtures.history(
            id: completed.canonicalTimer!.id,
            durationMs: 60_000,
            date: TestFixtures.anchor
        )]
        completed.settings.selectedPhase = .focus
        let projectedRoom = try makeActiveRoom(in: fixture.store, returnState: completed)
        let roomID = try #require(fixture.store.activeRoomID)

        let transition = fixture.controller.projectionTransition(for: .init(
            roomID: roomID,
            state: projectedRoom
        ))

        guard case .projectionApplied(let state, let error) = transition else {
            Issue.record("Expected projectionApplied, got \(transition)")
            return
        }
        #expect(error == nil)
        #expect(state.settings.selectedPhase == .shortBreak)
        #expect(fixture.store.activeRoomState?.settings.selectedPhase == .shortBreak)
        #expect(fixture.controller.projectionTransition(for: .init(
            roomID: "other-room",
            state: projectedRoom
        )) == .unchanged)
    }

    @Test func secureRandomBytesReturnsRequestedIndependentPayloads() {
        let first = RoomReplicationController.secureRandomBytes(count: 32)
        let second = RoomReplicationController.secureRandomBytes(count: 32)

        #expect(first.count == 32)
        #expect(second.count == 32)
        #expect(first != second)
    }

    @MainActor
    private func makeFixture(
        mode: ReplicationMode,
        revision: Int64 = 0,
        isSyncing: Bool = false,
        revisionStreamUnauthorized: Bool = false,
        cancelsSleep: Bool = true,
        isHistoryResolutionBlocking: Bool = false,
        revisionEvents: (@Sendable () async throws -> AsyncThrowingStream<Int64, Error>)? = nil
    ) -> ControllerFixture {
        let store = IrohRoomStore(
            fileURL: temporaryURL(),
            secretStore: MemoryIrohRoomSecretStore()
        )
        let service = RoomReplicationServiceSpy()
        let state = LockedTestValue(RoomReplicationCentralizedState(
            sessionGeneration: 7,
            isSignedIn: true,
            isWorkspaceMutationBlocked: false,
            isSessionVerified: true,
            localRevision: revision,
            isSyncing: isSyncing,
            isTimerActive: false,
            isHistoryResolutionBlocking: isHistoryResolutionBlocking
        ))
        let events = LockedTestValue<[RoomReplicationEvent]>([])
        let operations = LockedTestValue<[RoomReplicationOperation]>([])
        let randomBytes = LockedTestValue(Data(repeating: 3, count: 32))
        let sleeps = LockedTestValue<[Duration]>([])
        let revisionRequests = LockedTestValue(0)
        let workspace = LockedTestValue(self.workspace(from: .fresh()))
        let dependencies = RoomReplicationController.Dependencies(
            roomStore: store,
            retryDelay: .seconds(5),
            centralizedState: { state.value },
            workspaceSnapshot: { workspace.value },
            revisionEvents: {
                revisionRequests.value += 1
                if let revisionEvents { return try await revisionEvents() }
                return AsyncThrowingStream { continuation in
                    if revisionStreamUnauthorized {
                        continuation.finish(throwing: AppError.unauthorized)
                        return
                    }
                    continuation.yield(12)
                    continuation.finish()
                }
            },
            sleep: { duration in
                sleeps.value.append(duration)
                if cancelsSleep { throw CancellationError() }
            },
            secureRandomBytes: { _ in randomBytes.value },
            encodeInvite: { _, _, _, _ in "encoded-invite" },
            makeService: { _ in service }
        )
        let controller = RoomReplicationController(
            mode: mode,
            dependencies: dependencies,
            eventHandler: { event in events.value.append(event) },
            operationHandler: { operation in operations.value.append(operation) }
        )
        return ControllerFixture(
            controller: controller,
            store: store,
            service: service,
            centralizedState: state,
            workspace: workspace,
            events: events,
            operations: operations,
            randomBytes: randomBytes,
            sleeps: sleeps,
            revisionRequests: revisionRequests
        )
    }

    private func makeActiveRoom(
        in store: IrohRoomStore,
        returnState: PersistedTimerState
    ) throws -> PersistedTimerState {
        let secret = Data(repeating: 9, count: 32)
        return try store.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret),
            roomSecret: secret,
            name: "Existing",
            returnState: returnState,
            genesis: genesis(from: returnState)
        )
    }

    private func genesis(from state: PersistedTimerState) -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: state.canonicalTimer,
            history: state.history,
            tasks: state.tasks,
            durationsMs: state.settings.durationsMs,
            autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: state.selectedTaskID?.uuidString.lowercased(),
            hlcWallMs: state.hlcWallMs,
            hlcCounter: state.hlcCounter
        )
    }

    private func workspace(from state: PersistedTimerState) -> RoomReplicationWorkspaceSnapshot {
        RoomReplicationWorkspaceSnapshot(state: state, genesis: genesis(from: state))
    }

    private func environment(for state: PersistedTimerState = .fresh()) -> RoomReplicationEnvironment {
        RoomReplicationEnvironment(deviceID: state.deviceId, displayName: nil, platform: "macos")
    }

    private func durationOperation(minutes: Int64) -> DurationOperation {
        TestFixtures.durationOperation(
            id: "duration-controller-conflict",
            phase: .focus,
            durationMs: minutes * 60_000,
            wallMs: 1_000
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomReplicationController-\(UUID().uuidString)")
            .appendingPathComponent("rooms.json")
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
    }
}

private final class RevisionStreamCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let lifecycle: LockedTestValue<[String]>
    private var terminationContinuation: CheckedContinuation<Void, Never>?
    private var terminationReleased = false

    init(lifecycle: LockedTestValue<[String]>) {
        self.lifecycle = lifecycle
    }

    func events() async throws -> AsyncThrowingStream<Int64, Error> {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumesImmediately = lock.withLock {
                    if terminationReleased { return true }
                    terminationContinuation = continuation
                    return false
                }
                if resumesImmediately { continuation.resume() }
            }
            lifecycle.value.append("revision terminated")
            throw CancellationError()
        } onCancel: {
            self.lifecycle.value.append("revision cancellation requested")
        }
    }

    func releaseTermination() {
        let continuation = lock.withLock {
            terminationReleased = true
            defer { terminationContinuation = nil }
            return terminationContinuation
        }
        continuation?.resume()
    }
}

@MainActor
private struct ControllerFixture {
    let controller: RoomReplicationController
    let store: IrohRoomStore
    let service: RoomReplicationServiceSpy
    let centralizedState: LockedTestValue<RoomReplicationCentralizedState>
    let workspace: LockedTestValue<RoomReplicationWorkspaceSnapshot>
    let events: LockedTestValue<[RoomReplicationEvent]>
    let operations: LockedTestValue<[RoomReplicationOperation]>
    let randomBytes: LockedTestValue<Data>
    let sleeps: LockedTestValue<[Duration]>
    let revisionRequests: LockedTestValue<Int>
}

private actor RoomReplicationServiceSpy: RoomReplicationServing {
    enum LifecycleEvent: Equatable, Sendable {
        case startEntered
        case startCompleted
        case stop
    }

    private(set) var startedContexts: [IrohServiceContext] = []
    private(set) var startCompletionCount = 0
    private(set) var lifecycleEvents: [LifecycleEvent] = []
    private(set) var markedConflictRoomIDs: [String?] = []
    private(set) var stopCount = 0
    private(set) var syncCount = 0
    private(set) var ticketRequestCount = 0
    private var startHook: (@Sendable () -> Void)?
    private var suspendsStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startError: TestRoomServiceError?
    private var ticketError: TestRoomServiceError?

    func setStartHook(_ hook: @escaping @Sendable () -> Void) {
        startHook = hook
    }

    func setStartSuspended(_ suspended: Bool) { suspendsStart = suspended }

    func releaseStart() {
        suspendsStart = false
        startContinuation?.resume()
        startContinuation = nil
    }

    func setStartError(_ error: TestRoomServiceError?) { startError = error }
    func setTicketError(_ error: TestRoomServiceError?) { ticketError = error }

    func start(_ context: IrohServiceContext) async throws -> String {
        startedContexts.append(context)
        lifecycleEvents.append(.startEntered)
        startHook?()
        if suspendsStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if let startError { throw startError }
        startCompletionCount += 1
        lifecycleEvents.append(.startCompleted)
        return "endpoint-ticket"
    }

    func stop() async {
        stopCount += 1
        lifecycleEvents.append(.stop)
    }

    func currentEndpointTicket() async throws -> String {
        ticketRequestCount += 1
        if let ticketError { throw ticketError }
        return "endpoint-ticket"
    }

    func syncNow() async { syncCount += 1 }
    func join(invite: IrohRoomInvite) async throws {}

    func markConflict(roomID: String?) async {
        markedConflictRoomIDs.append(roomID)
    }
}

private enum TestRoomServiceError: Error {
    case endpointUnavailable
}
