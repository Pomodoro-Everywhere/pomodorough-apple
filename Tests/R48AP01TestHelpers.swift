import Foundation
import Testing
@testable import Pomodorough

extension R48AP01DurableAdmissionTests {
    @MainActor
    func makeController(timerID: String = "timer-R48AP01-test") -> SynchronizedWorkspaceMutationController {
        SynchronizedWorkspaceMutationController(
            timerSessionController: TimerSessionController {
                try SharedCore.bundled()
            },
            timerIDProvider: { timerID }
        )
    }

    func snapshot(
        _ state: PersistedTimerState,
        timer: CanonicalTimer? = nil,
        dateOffset: TimeInterval = 0
    ) -> SynchronizedWorkspaceMutationController.Snapshot {
        SynchronizedWorkspaceMutationController.Snapshot(
            state: state,
            canonicalTimer: timer ?? state.canonicalTimer,
            tasks: state.tasks,
            projectedAutoStartBreaks: state.autoStartBreaks,
            projectedSelectedTaskID: state.selectedTaskID,
            replicationMode: .centralized,
            localDate: Date(timeIntervalSince1970: 1_710_000_001 + dateOffset),
            trustedClockUptime: 100 + dateOffset,
            isWorkspaceMutationBlocked: false
        )
    }

    @MainActor
    func seedDuration(
        state: PersistedTimerState,
        controller: SynchronizedWorkspaceMutationController,
        minutes: Int
    ) throws -> PersistedTimerState {
        let planned = try #require(try controller.plan(.setDurationMinutes(minutes, for: .focus), from: snapshot(state)))
        return planned.state
    }

    @MainActor
    func seedUpsert(
        state: PersistedTimerState,
        controller: SynchronizedWorkspaceMutationController,
        task: FocusTask
    ) throws -> PersistedTimerState {
        let planned = try #require(try controller.plan(.task(.upsert, task), from: snapshot(state)))
        return planned.state
    }

    @MainActor
    func claim(state: PersistedTimerState) throws -> (plan: AccountSynchronization.SyncPlan, retired: PersistedTimerState) {
        let sync = AccountSynchronization(api: APIClient(keychain: EmptyTokenStore()), sharedCoreProvider: { try SharedCore.bundled() })
        let result = try sync.prepareSyncPlan(state: state)
        #expect(!result.plan.batch.isEmpty)
        return result
    }

    @MainActor
    func claimSelectedOnly(state: PersistedTimerState) throws -> (plan: AccountSynchronization.SyncPlan, retired: PersistedTimerState) {
        try claim(state: state)
    }

    func reopen(_ state: PersistedTimerState) throws -> PersistedTimerState {
        let data = try JSONEncoder.api.encode(state)
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }
}
