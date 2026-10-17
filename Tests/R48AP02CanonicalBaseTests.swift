import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP02 canonical duration base")
struct R48AP02CanonicalBaseTests {
    @MainActor
    func makeControllers(timerID: String = "timer-R48AP02-test") -> (
        SynchronizedWorkspaceMutationController, TimerSessionController
    ) {
        let session = TimerSessionController { try SharedCore.bundled() }
        let mutations = SynchronizedWorkspaceMutationController(
            timerSessionController: session,
            timerIDProvider: { timerID }
        )
        return (mutations, session)
    }

    func snapshot(
        _ state: PersistedTimerState,
        timer: CanonicalTimer? = nil
    ) -> SynchronizedWorkspaceMutationController.Snapshot {
        SynchronizedWorkspaceMutationController.Snapshot(
            state: state,
            canonicalTimer: timer ?? state.canonicalTimer,
            tasks: state.tasks,
            projectedAutoStartBreaks: state.autoStartBreaks,
            projectedSelectedTaskID: state.selectedTaskID,
            replicationMode: .centralized,
            localDate: Date(timeIntervalSince1970: 1_710_000_001),
            trustedClockUptime: 100,
            isWorkspaceMutationBlocked: false
        )
    }

    @MainActor
    func seedDuration(
        _ state: PersistedTimerState,
        controller: SynchronizedWorkspaceMutationController,
        minutes: Int
    ) throws -> PersistedTimerState {
        let planned = try #require(try controller.plan(
            .setDurationMinutes(minutes, for: .focus),
            from: snapshot(state)
        ))
        return planned.state
    }

    @MainActor
    func claim(
        _ state: PersistedTimerState
    ) throws -> (plan: AccountSynchronization.SyncPlan, retired: PersistedTimerState) {
        let sync = AccountSynchronization(
            api: APIClient(keychain: EmptyTokenStore()),
            sharedCoreProvider: { try SharedCore.bundled() }
        )
        let result = try sync.prepareSyncPlan(state: state)
        #expect(!result.plan.batch.isEmpty)
        return result
    }

    func reopen(_ state: PersistedTimerState) throws -> PersistedTimerState {
        let data = try JSONEncoder.api.encode(state)
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    @MainActor
    func project(
        _ state: PersistedTimerState,
        session: TimerSessionController
    ) throws -> CoreProjectionOutput {
        try session.project(
            state,
            replicationMode: .centralized,
            physicalNow: Date(timeIntervalSince1970: 1_710_000_001)
        )
    }

    @Test @MainActor
    func ackLossShowsCanonicalNotOptimistic() throws {
        let (mutations, session) = makeControllers()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state, controller: mutations, minutes: 30)
        #expect(state.canonicalDurations().focus == DurationValues.defaults.focus)
        #expect(state.settings.focusMinutes == 30)
        let claimed = try claim(state)
        let retired = claimed.retired
        #expect(retired.pendingDurationOperations.count == 1)
        #expect(retired.neverSentDurationOperationIDs.isEmpty)
        #expect(retired.canonicalDurations().focus == DurationValues.defaults.focus)
        let output = try project(retired, session: session)
        #expect(output.durationsMs.focus == DurationValues.defaults.focus)
        #expect(output.durationsMs.focus != 30 * 60_000)
        #expect(output.winningOperationIds.durations.isEmpty)
        #expect(output.durationsMs == retired.canonicalDurations())
    }

    @Test @MainActor
    func retirementPreservesQueuesAndCanonical() throws {
        let (mutations, _) = makeControllers()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state, controller: mutations, minutes: 30)
        let beforeID = try #require(state.pendingDurationOperations.first?.id)
        let claimed = try claim(state)
        let retired = claimed.retired
        #expect(retired.pendingDurationOperations.map(\.id) == [beforeID])
        #expect(retired.canonicalDurationsMs == .defaults)
        #expect(retired.settings.focusMinutes == 30)
        let data = try JSONEncoder.api.encode(retired)
        #expect(String(data: data, encoding: .utf8)?.contains("canonicalDurationsMs") == true)
    }

    @Test @MainActor
    func reopenPreservesCompleteOutputs() throws {
        let (mutations, session) = makeControllers()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state, controller: mutations, minutes: 30)
        let claimed = try claim(state)
        let before = try project(claimed.retired, session: session)
        let reopened = try reopen(claimed.retired)
        #expect(reopened == claimed.retired)
        #expect(reopened.canonicalDurations() == claimed.retired.canonicalDurations())
        let after = try project(reopened, session: session)
        #expect(after == before)
        #expect(after.durationsMs.focus == DurationValues.defaults.focus)
        #expect(after.tasks == before.tasks)
        #expect(after.history == before.history)
        #expect(after.timerOutcomes == before.timerOutcomes)
    }

    @Test @MainActor
    func unrelatedEditKeepsCanonicalDurations() throws {
        let (mutations, session) = makeControllers()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state, controller: mutations, minutes: 30)
        let claimed = try claim(state)
        var retired = claimed.retired
        let task = try #require(FocusTask(title: "Unrelated edit"))
        let edited = try #require(try mutations.plan(
            .task(.upsert, task),
            from: snapshot(retired)
        ))
        retired = edited.state
        let output = try project(retired, session: session)
        #expect(output.durationsMs.focus == DurationValues.defaults.focus)
        #expect(output.tasks.contains(where: { $0.id == task.id }))
        #expect(output.winningOperationIds.durations.isEmpty)
        #expect(output.winningOperationIds.tasks.values.contains(
            retired.pendingTaskOperations.last?.id ?? ""
        ))
    }

    @Test @MainActor
    func newStartUsesCanonicalAfterLostProof() throws {
        let (mutations, _) = makeControllers(timerID: "timer-R48AP02-start")
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state, controller: mutations, minutes: 30)
        let claimed = try claim(state)
        let retired = claimed.retired
        let started = try #require(try mutations.plan(
            .startTimer,
            from: snapshot(retired)
        ))
        let command = try #require(started.state.pendingCommands.last)
        #expect(command.type == .start)
        #expect(command.plannedDurationMs == DurationValues.defaults.focus)
        #expect(command.plannedDurationMs != 30 * 60_000)
        #expect(started.state.canonicalDurations().focus == DurationValues.defaults.focus)
    }

    @Test @MainActor
    func eligibleOptimisticStillProjects() throws {
        let (mutations, session) = makeControllers()
        var state = PersistedTimerState.fresh()
        state = try seedDuration(state, controller: mutations, minutes: 30)
        #expect(!state.isDurationDomainSuppressed())
        let output = try project(state, session: session)
        #expect(output.durationsMs.focus == 30 * 60_000)
        #expect(output.winningOperationIds.durations.values.contains(
            state.pendingDurationOperations.first?.id ?? ""
        ))
    }

    @Test
    func diagnosticsArePrivacySafe() throws {
        var state = PersistedTimerState.fresh()
        state.canonicalDurationsMs = .defaults
        let diagnostics = DurationBaseDiagnostics(
            category: .timerStart,
            reason: "suppressedDurationUsesCanonical",
            pendingDurations: state.pendingDurationOperations.count,
            hasCanonical: state.canonicalDurationsMs != nil,
            usesCanonical: state.isDurationDomainSuppressed(),
            suppressed: state.isDurationDomainSuppressed(),
            provenance: WorkspaceIntentProvenance.current()
        )
        let message = diagnostics.publicMessage()
        #expect(message.contains("timerStart"))
        #expect(message.contains("suppressedDurationUsesCanonical"))
        #expect(message.contains("core="))
        #expect(!message.contains("1500000"))
        #expect(!message.contains("1800000"))
    }
}

@Suite("R49-AP02 canonical selected task")
struct R49AP02CanonicalSelectionTests {
    @Test(arguments: [false, true]) @MainActor
    func retiredSelectionReopensCanonicalAndNextStartUsesOfficialProjection(unassigned: Bool) async throws {
        let fixture = try R49AP02SelectionFixture()
        defer { fixture.cleanUp() }
        let before = try fixture.readState()
        let canonical = before.selectedTaskID
        #expect(before.canonicalSelectedTaskID == canonical)
        let model = fixture.model()
        let target = unassigned ? nil : before.tasks[1].id
        model.selectedTaskID = target
        let selected = try fixture.readState()
        #expect(model.selectedTaskID == target)
        #expect(selected.selectedTaskID == target)
        #expect(selected.canonicalSelectedTask?.taskID == canonical)
        #expect(selected.canonicalHeadWallMs == before.canonicalHeadWallMs)
        #expect(selected.canonicalHeadCounter == before.canonicalHeadCounter)
        #expect(selected.pendingSelectedTaskOperations.count == 1)
        _ = try fixture.compareCompleteProjection(selected, canonical: canonical)
        let prepared = try fixture.synchronization.prepareSyncPlan(state: selected)
        try fixture.store.write(JSONEncoder.api.encode(prepared.retired))
        let retired = try fixture.readState()
        #expect(retired == prepared.retired)
        #expect(retired.outgoingSyncClaim == prepared.plan.request)
        #expect(retired.pendingSelectedTaskOperations == selected.pendingSelectedTaskOperations)
        #expect(retired.neverSentSelectedTaskOperationIDs.isEmpty)
        #expect(retired.safeProjectionSelectedTaskOperations().isEmpty)
        #expect(retired.canonicalSelectedTask == selected.canonicalSelectedTask)
        try await fixture.loseResponse(prepared.plan, state: retired)
        let bytes = try fixture.store.read()
        let reopened = fixture.model()
        let official = try fixture.compareCompleteProjection(try fixture.readState(), canonical: canonical)
        #expect(reopened.selectedTaskID?.uuidString.lowercased() == official.selectedTaskId)
        #expect(try fixture.store.read() == bytes)
        let replay = try fixture.synchronization.prepareSyncPlan(state: fixture.readState())
        #expect(replay.plan.isSavedReplay)
        #expect(replay.plan.request == retired.outgoingSyncClaim)
        #expect(replay.retired == retired)
        try await fixture.unrelatedEditsAndNextStart(reopened, retired: retired, canonical: canonical,
                                                   official: official)
        await Task.yield()
    }

    @Test(arguments: [false, true]) @MainActor
    func genuineAcknowledgementInstallsSelectionAndCoveringHead(unassigned: Bool) async throws {
        let fixture = try R49AP02SelectionFixture()
        defer { fixture.cleanUp() }
        let before = try fixture.readState()
        let model = fixture.model()
        let target = unassigned ? nil : before.tasks[1].id
        model.selectedTaskID = target
        let selected = try fixture.readState()
        let prepared = try fixture.synchronization.prepareSyncPlan(state: selected)
        try fixture.store.write(JSONEncoder.api.encode(prepared.retired))
        let retired = try fixture.readState()
        let sampled = try await fixture.acknowledge(prepared.plan, state: retired, selected: target)
        let wire = try #require(R49AP02SelectionProtocol.bodies.value[fixture.scenario]?.last)
        #expect(try fixture.decodeWire(wire) == retired.outgoingSyncClaim)
        let transition = try fixture.synchronization.reconcileSync(sampled, plan: prepared.plan, state: retired)
        try fixture.store.write(JSONEncoder.api.encode(transition.state))
        let installed = try fixture.readState()
        #expect(installed == transition.state)
        #expect(installed.selectedTaskID == target)
        #expect(installed.canonicalSelectedTask != nil)
        #expect(installed.canonicalSelectedTask?.taskID == target)
        #expect(installed.pendingSelectedTaskOperations.isEmpty)
        #expect(installed.outgoingSyncClaim == nil)
        #expect(installed.canonicalHeadWallMs == sampled.value.serverHlcWallMs)
        #expect(installed.canonicalHeadCounter == sampled.value.serverHlcCounter)
        let official = try fixture.compareCompleteProjection(installed, canonical: target)
        let reopened = fixture.model()
        #expect(reopened.selectedTaskID?.uuidString.lowercased() == official.selectedTaskId)
        reopened.start()
        let started = try fixture.readState()
        #expect(started.pendingCommands.last?.taskId == official.selectedTaskId)
        _ = try fixture.compareCompleteProjection(started, canonical: target)
        await Task.yield()
    }

    @Test(arguments: [false, true]) @MainActor
    func liveModelPublishesSafeSelectionAfterPossibleDelivery(unassigned: Bool) async throws {
        let fixture = try R49AP02SelectionFixture()
        defer { fixture.cleanUp() }
        let before = try fixture.readState()
        let model = fixture.model()
        model.selectedTaskID = unassigned ? nil : before.tasks[1].id
        var selected = try fixture.readState()
        selected.cachedUser = TestFixtures.user
        try fixture.store.write(JSONEncoder.api.encode(selected))
        let live = fixture.model()
        await live.restore()
        let retired = try fixture.readState()
        #expect(live.isOffline)
        #expect(retired.outgoingSyncClaim != nil)
        #expect(retired.neverSentSelectedTaskOperationIDs.isEmpty)
        let official = try fixture.compareCompleteProjection(retired, canonical: before.selectedTaskID)
        #expect(live.selectedTaskID?.uuidString.lowercased() == official.selectedTaskId)
        let body = try #require(R49AP02SelectionProtocol.bodies.value[fixture.scenario]?.last)
        #expect(try fixture.decodeWire(body) == retired.outgoingSyncClaim)
        let reopened = fixture.model()
        #expect(reopened.selectedTaskID == live.selectedTaskID)
    }

    @Test(arguments: [1, 2]) @MainActor
    func exactPreSendRollbackRestoresEligibleSelectionPublication(failingCoreCall: Int) async throws {
        let fixture = try R49AP02SelectionFixture()
        defer { fixture.cleanUp() }
        let before = try fixture.readState()
        let model = fixture.model()
        let target = before.tasks[1].id
        model.selectedTaskID = target
        var selected = try fixture.readState()
        selected.cachedUser = TestFixtures.user
        try fixture.store.write(JSONEncoder.api.encode(selected))
        let store = fixture.store
        let rejected = LockedTestValue(false)
        let callsAfterRetirement = LockedTestValue(0)
        let live = fixture.model(sharedCoreProvider: {
            SharedCore(moduleURL: try SharedCore.bundledModuleURL(), freeResultValidator: { _ in
                guard !rejected.value, let bytes = try store.read(),
                      try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes).outgoingSyncClaim != nil else { return }
                callsAfterRetirement.value += 1
                guard callsAfterRetirement.value == failingCoreCall else { return }
                rejected.value = true
                throw SharedCoreError.resourceMissing
            })
        })
        await live.restore()
        #expect(rejected.value)
        #expect(R49AP02SelectionProtocol.bodies.value[fixture.scenario] == nil)
        #expect(try fixture.readState() == selected)
        let official = try fixture.compareCompleteProjection(try fixture.readState(), canonical: before.selectedTaskID)
        #expect(live.selectedTaskID?.uuidString.lowercased() == official.selectedTaskId)
        #expect(live.selectedTaskID == target)
    }

    @Test @MainActor
    func coveringHeadSuppressionAndCanonicalFallbackUseCapturedBase() throws {
        let fixture = try R49AP02SelectionFixture()
        defer { fixture.cleanUp() }
        let before = try fixture.readState()
        let model = fixture.model()
        model.selectedTaskID = before.tasks[1].id
        var state = try fixture.readState()
        let operation = try #require(state.pendingSelectedTaskOperations.first)
        state.storeCanonicalHead(wallMs: operation.hlcWallMs, counter: operation.hlcCounter)
        try fixture.store.write(JSONEncoder.api.encode(state))
        let persisted = try fixture.readState()
        #expect(!persisted.neverSentSelectedTaskOperationIDs.isEmpty)
        let official = try fixture.compareCompleteProjection(persisted, canonical: before.selectedTaskID)
        #expect(official.selectedTaskId == before.selectedTaskID?.uuidString.lowercased())
        #expect(AppStatePublisher().fallbackPublication(from: persisted).selectedTaskID == before.selectedTaskID)
        let (controller, _) = R48AP02CanonicalBaseTests().makeControllers()
        let admission = WorkspaceIntentAdmission { try SharedCore.bundled() }
        let snapshot = R48AP02CanonicalBaseTests().snapshot(persisted)
        let request = admission.intentWorkspace(state: persisted, snapshot: snapshot)
        #expect(request.base.selectedTaskId == official.selectedTaskId)
        let started = try #require(try controller.plan(.startTimer, from: .init(
            state: persisted, canonicalTimer: nil, tasks: official.tasks,
            projectedAutoStartBreaks: official.autoStartBreaks,
            projectedSelectedTaskID: official.selectedTaskId.flatMap(UUID.init(uuidString:)),
            replicationMode: .centralized, localDate: R49AP02SelectionFixture.date,
            trustedClockUptime: 100, isWorkspaceMutationBlocked: false
        )))
        #expect(started.state.pendingCommands.last?.taskId == official.selectedTaskId)
    }

    @Test
    func legacyMigrationSeparatesUnknownCanonicalAndExplicitUnassigned() throws {
        let task = try #require(FocusTask(title: "Legacy private B"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.selectedTaskID = task.id
        let legacy = try JSONEncoder.api.encode(state)
        let clean = try JSONDecoder.api.decode(PersistedTimerState.self, from: legacy)
        #expect(clean.canonicalSelectedTaskID == task.id)
        #expect(try JSONEncoder.api.encode(clean) == legacy)
        state.pendingSelectedTaskOperations = [SelectedTaskOperation(
            id: UUID(), deviceId: state.deviceId, taskId: nil,
            occurredAt: R49AP02SelectionFixture.date, hlcWallMs: 1_784_620_800_000, hlcCounter: 0
        )]
        let contaminated = try JSONDecoder.api.decode(PersistedTimerState.self, from: JSONEncoder.api.encode(state))
        #expect(contaminated.selectedTaskID == task.id)
        #expect(contaminated.canonicalSelectedTaskID == nil)
        #expect(contaminated.pendingSelectedTaskOperations == state.pendingSelectedTaskOperations)
        var retired = contaminated
        retired.captureCanonicalSelectedTaskIfNeeded()
        retired.pendingSelectedTaskOperations = []
        let reopened = try JSONDecoder.api.decode(PersistedTimerState.self, from: JSONEncoder.api.encode(retired))
        #expect(reopened.canonicalSelectedTask != nil)
        #expect(reopened.canonicalSelectedTaskID == nil)
        #expect(reopened.selectedTaskID == task.id)
        var corrupt = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        corrupt["pendingSelectedTaskOperations"] = [["id": "corrupt-private-selection"]]
        let lossy = try JSONDecoder.api.decode(PersistedTimerState.self, from: JSONSerialization.data(withJSONObject: corrupt))
        #expect(lossy.hasCorruptPendingOperations)
        #expect(lossy.canonicalSelectedTaskID == nil)
    }

    @Test
    func suppressionDiagnosticContainsCountsAndProvenanceOnly() throws {
        var state = PersistedTimerState.fresh()
        state.deviceId = "private-device"
        state.selectedTaskID = UUID()
        state.canonicalSelectedTask = CanonicalSelectedTask(taskID: UUID())
        let diagnostic = SuppressedSelectionDiagnostics(state: state)
        #expect(diagnostic.publicMessage.contains("pending=0 proof=0 dependencies=0"))
        #expect(diagnostic.publicMessage.contains("core="))
        #expect(diagnostic.publicMessage.utf8.count < 350)
        #expect(!diagnostic.publicMessage.contains("private"))
        #expect(!diagnostic.publicMessage.contains(state.selectedTaskID!.uuidString))
        #expect(!diagnostic.publicMessage.contains(state.canonicalSelectedTask!.taskID!.uuidString))
    }
}

private struct R49AP02OfficialProjection: Decodable, Sendable {
    let workspace: CoreProjectionOutput
    let projectionPending: R49AP02OfficialPending
}

private struct R49AP02OfficialPending: Codable, Sendable {
    let commands: [CoreTimerCommand]
    let taskOperations: [CoreTaskOperation]
    let durationOperations: [CoreDurationOperation]
    let autoStartOperations: [CoreAutoStartOperation]
    let selectedTaskOperations: [CoreSelectedTaskOperation]
}

@MainActor
private struct R49AP02SelectionFixture {
    let scenario = UUID().uuidString
    let suite = "R49AP02.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let session: URLSession
    let api: APIClient
    let synchronization: AccountSynchronization
    nonisolated static let date = Date(timeIntervalSince1970: 1_784_620_800)
    var store: AtomicDurableFileStore { .init(fileURL: directory.appendingPathComponent("workspace.json")) }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R49AP02SelectionProtocol.self]
        configuration.httpAdditionalHeaders = ["X-R49AP02": scenario]
        session = URLSession(configuration: configuration)
        api = APIClient(session: session, keychain: StaticTokenStore(),
                        logoutRevocationStore: TestLogoutRevocationStore(),
                        wallNow: { Self.date }, uptime: { 100 })
        synchronization = AccountSynchronization(api: api, sharedCoreProvider: { try SharedCore.bundled() })
        var state = PersistedTimerState.fresh()
        state.tasks = [try #require(FocusTask(title: "Private canonical A")),
                       try #require(FocusTask(title: "Private optimistic B"))]
        state.knownTasks = state.tasks
        state.selectedTaskID = state.tasks[0].id
        state.storeCanonicalHead(wallMs: Int64(Self.date.timeIntervalSince1970 * 1_000) - 1_000, counter: 0)
        try store.write(JSONEncoder.api.encode(state))
    }

    func model(sharedCoreProvider: @escaping @MainActor () throws -> SharedCore = { try SharedCore.bundled() }) -> AppModel {
        AppModel(api: api, defaults: defaults, durableLocalStore: store,
                 roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
                 alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
                 now: { Self.date }, uptime: { 100 }, sharedCoreProvider: sharedCoreProvider)
    }

    func readState() throws -> PersistedTimerState {
        let bytes = try #require(try store.read())
        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes) == state)
        return state
    }

    func unrelatedEditsAndNextStart(_ reopened: AppModel, retired: PersistedTimerState,
                                   canonical: UUID?, official: CoreProjectionOutput) async throws {
        reopened.setDurationMinutes(35, for: .focus)
        #expect(await reopened.addTask("Unrelated private edit"))
        let edited = try readState()
        #expect(edited.outgoingSyncClaim == retired.outgoingSyncClaim)
        #expect(edited.neverSentSelectedTaskOperationIDs == retired.neverSentSelectedTaskOperationIDs)
        #expect(edited.canonicalSelectedTask == retired.canonicalSelectedTask)
        _ = try compareCompleteProjection(edited, canonical: canonical)
        let next = model()
        next.start()
        let started = try readState()
        let command = try #require(started.pendingCommands.last)
        #expect(command.type == .start)
        #expect(command.taskId == official.selectedTaskId)
        #expect(next.selectedTaskID?.uuidString.lowercased() == official.selectedTaskId)
        let startedOfficial = try compareCompleteProjection(started, canonical: canonical)
        #expect(next.rebuildOptimisticState())
        #expect(next.canonicalTimer == startedOfficial.canonicalTimer)
        #expect(next.selectedTaskID?.uuidString.lowercased() == startedOfficial.selectedTaskId)
    }

    func compareCompleteProjection(_ state: PersistedTimerState, canonical: UUID?) throws -> CoreProjectionOutput {
        #expect(state.canonicalSelectedTaskID == canonical)
        let base = WorkspaceIntentBase(canonicalTimer: try state.physicalCanonicalTimer(state.canonicalTimer),
                                       history: state.history, tasks: state.tasks,
                                       durationsMs: state.canonicalDurations(), autoStartBreaks: state.autoStartBreaks,
                                       selectedTaskId: canonical?.uuidString.lowercased())
        let local = CoreReconcileLocalQueues(state: state)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(local)) as? [String: Any])
        object = ["base": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(base)), "local": object,
                  "canonicalHead": state.canonicalHeadWallMs.map { ["wallMs": $0, "counter": state.canonicalHeadCounter!] } as Any? ?? NSNull(),
                  "neverSent": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state.neverSentProof())),
                  "timerDependencies": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state.pendingTimerDependencies)),
                  "now": APIDateCodec.string(from: Self.date)]
        let request = try JSONSerialization.data(withJSONObject: object)
        let official = try SharedCore.bundled().dispatch("workspace.project.v1", inputJSON: request,
                                                       as: R49AP02OfficialProjection.self)
        // Native display uses projection.apply.v2. Use the official workspace's
        // complete safe queues, not a test-side copy of delivery policy.
        let projection: [String: Any] = ["base": object["base"]!, "now": object["now"]!,
                                        "pending": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(official.projectionPending))]
        let officialDisplay = try SharedCore.bundled().dispatch(
            "projection.apply.v2", inputJSON: JSONSerialization.data(withJSONObject: projection), as: CoreProjectionOutput.self
        )
        let production = try TimerSessionController { try SharedCore.bundled() }.project(
            state, now: Self.date, replicationMode: .centralized, physicalNow: Self.date
        )
        #expect(production == officialDisplay)
        if state.pendingCommands.isEmpty {
            #expect(production == official.workspace)
        }
        #expect(officialDisplay.selectedTaskId == official.workspace.selectedTaskId)
        #expect(try JSONEncoder.api.encode(official.projectionPending) == JSONEncoder.api.encode(state.safeProjectionPending()))
        return officialDisplay
    }

    func loseResponse(_ plan: AccountSynchronization.SyncPlan, state: PersistedTimerState) async throws {
        #expect(try await api.restoreTokens())
        do {
            _ = try await synchronization.sendSync(plan, state: state)
            Issue.record("Expected lost response")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
        let body = try #require(R49AP02SelectionProtocol.bodies.value[scenario]?.last)
        #expect(try decodeWire(body) == state.outgoingSyncClaim)
        #expect(try readState() == state)
    }

    func decodeWire(_ bytes: Data) throws -> SyncRequest {
        var raw = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let deviceId = try #require(raw["deviceId"] as? String)
        // API omits each operation's deviceId; the request envelope owns it.
        for domain in ["autoStartOperations", "selectedTaskOperations"] {
            let operations = try #require(raw[domain] as? [[String: Any]])
            raw[domain] = operations.map { operation in
                #expect(operation["deviceId"] == nil)
                var decoded = operation
                decoded["deviceId"] = deviceId
                return decoded
            }
        }
        return try JSONDecoder.api.decode(SyncRequest.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func acknowledge(_ plan: AccountSynchronization.SyncPlan, state: PersistedTimerState,
                     selected: UUID?) async throws -> TimedHTTPResponse<SyncResponse> {
        #expect(try await api.restoreTokens())
        let acknowledgements = plan.request.selectedTaskOperations.map {
            ["operationId": $0.id.uuidString.lowercased(), "outcome": "applied", "reason": ""]
        }
        let response: [String: Any] = [
            "revision": state.revision + 1, "canonicalTimer": NSNull(), "history": [],
            "tasks": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state.tasks)),
            "durationsMs": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state.canonicalDurations())),
            "autoStartBreaks": state.autoStartBreaks, "selectedTaskId": selected?.uuidString.lowercased() as Any? ?? NSNull(),
            "acknowledgements": [], "taskAcknowledgements": [], "durationAcknowledgements": [],
            "autoStartAcknowledgements": [], "selectedTaskAcknowledgements": acknowledgements,
            "serverTime": APIDateCodec.string(from: Self.date),
            "serverHlcWallMs": state.hlcWallMs + 1, "serverHlcCounter": 0
        ]
        R49AP02SelectionProtocol.setResponse(try JSONSerialization.data(withJSONObject: response), scenario: scenario)
        return try await synchronization.sendSync(plan, state: state)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class R49AP02SelectionProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = LockedTestValue<[String: [Data]]>([:])
    static let responses = LockedTestValue<[String: Data]>([:])
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-R49AP02") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func setResponse(_ body: Data, scenario: String) {
        lock.withLock {
            var responses = Self.responses.value
            responses[scenario] = body
            Self.responses.value = responses
        }
    }

    override func startLoading() {
        if request.url?.path == "/api/v1/me" {
            respond(R48AP04StubProtocol.meBody)
            return
        }
        let scenario = request.value(forHTTPHeaderField: "X-R49AP02")!
        let body = Self.body(request)
        Self.lock.withLock {
            var recorded = Self.bodies.value
            recorded[scenario, default: []].append(body)
            Self.bodies.value = recorded
        }
        guard let responseBody = Self.responses.value[scenario] else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        respond(responseBody)
    }

    private func respond(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return body }
            body.append(buffer, count: count)
        }
    }
}
