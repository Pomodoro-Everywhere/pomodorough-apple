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
