import Foundation

struct AccountSwitchTransition: Equatable, Sendable {
    let state: PersistedTimerState
}

extension AccountLifecycleController {
    func stageAccountSwitch(
        to authenticatedUser: User,
        state: PersistedTimerState
    ) -> AccountSwitchTransition? {
        guard let previousUser = state.cachedUser,
              previousUser.id != authenticatedUser.id else { return nil }
        var updated = state
        updated.pendingAccountSwitchUser = authenticatedUser
        updated.bootstrapUser = nil
        updated.pendingBootstrapResolution = nil
        return AccountSwitchTransition(state: updated)
    }

    func confirmAccountSwitch(
        state: PersistedTimerState,
        authenticatedUser: User?
    ) -> AccountSwitchTransition? {
        guard let pendingUser = state.pendingAccountSwitchUser,
              authenticatedUser?.id == pendingUser.id else { return nil }
        var updated = state
        updated.prepare(for: pendingUser)
        return AccountSwitchTransition(state: updated)
    }
}
