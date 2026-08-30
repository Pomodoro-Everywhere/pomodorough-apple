import Foundation

enum AccountSessionState: Equatable, Sendable {
    case restoring
    case localOnly
    case signedIn(User)
}

enum AccountHistoryResolutionState: Equatable, Sendable {
    case none
    case preflighting
    case choosing
    case confirming(BootstrapResolutionStrategy)
    case submitting(BootstrapResolutionStrategy)
    case retryable(BootstrapResolutionStrategy?)
}

@MainActor
final class AccountLifecycleController {
    struct Operation: Equatable, Sendable {
        let generation: Int
    }

    enum Effect: Equatable, Sendable {
        case invalidateSynchronization
        case resetCentralizedLifecycle
        case signOutIdentity
        case scheduleRetry
    }

    struct AuthenticationStartTransition: Equatable, Sendable {
        let operation: Operation
        let effects: [Effect]
    }

    struct ResetTransition: Equatable, Sendable {
        let operation: Operation
        let sessionState: AccountSessionState
        let historyResolutionState: AccountHistoryResolutionState?
        let clearsBootstrapPresentation: Bool
        let isOffline: Bool?
        let isWorking: Bool?
        let effects: [Effect]
    }

    struct SignedOutStorageTransition: Equatable, Sendable {
        let state: PersistedTimerState
        let irohReturnState: PersistedTimerState?
        let rebuildsProjection: Bool
    }

    enum AuthenticationTransition: Equatable, Sendable {
        case stale
        case authenticated(User)
        case failed(String)
    }

    enum RestoreTransition: Equatable, Sendable {
        case stale
        case localOnly(invalidatesSynchronization: Bool)
        case signedIn(User)
        case unauthorized
    }

    enum VerificationTransition: Equatable, Sendable {
        case ignored
        case verified(User)
        case unauthorized
        case retry
    }

    enum BootstrapStage: Equatable, Sendable {
        case preflight
        case submission(BootstrapResolutionStrategy)
    }

    struct BootstrapFailureTransition: Equatable, Sendable {
        let historyResolutionState: AccountHistoryResolutionState
        let isOffline: Bool
        let errorMessage: String?
        let effects: [Effect]
    }

    enum BootstrapRetryAction: Equatable, Sendable {
        case signIn
        case verify(Operation)
        case submit(BootstrapResolveRequest, Operation)
        case preflight(Operation)
    }

    private let api: APIClient
    private let googleIdentityProvider: any GoogleIdentityProviding
    private let revocations: SessionRevocationController
    private let revocationStore: any LogoutRevocationStoring
    private(set) var generation = 0
    private var verification = SessionVerification()
    private var verificationOwner: UUID?

    init(
        api: APIClient,
        googleIdentityProvider: any GoogleIdentityProviding,
        revocations: SessionRevocationController? = nil,
        revocationStore: (any LogoutRevocationStoring)? = nil
    ) {
        let resolvedRevocationStore = revocationStore ?? api.logoutRevocationStore
        self.api = api
        self.googleIdentityProvider = googleIdentityProvider
        self.revocationStore = resolvedRevocationStore
        self.revocations = revocations ?? SessionRevocationController(api: api, store: resolvedRevocationStore)
    }

    var currentOperation: Operation { Operation(generation: generation) }

    func owns(_ operation: Operation) -> Bool {
        operation.generation == generation
    }

    func isVerified(_ operation: Operation) -> Bool {
        owns(operation) && verification.allows(generation: operation.generation)
    }

    func markVerified(_ operation: Operation) {
        guard owns(operation) else { return }
        verification.markVerified(generation: operation.generation)
    }

    func beginSignIn(isWorking: Bool) -> AuthenticationStartTransition? {
        guard !isWorking else { return nil }
        let operation = advanceGeneration()
        return AuthenticationStartTransition(
            operation: operation,
            effects: [.invalidateSynchronization, .resetCentralizedLifecycle]
        )
    }

    func authenticate(
        _ operation: Operation,
        deviceID: String,
        platform: String
    ) async -> AuthenticationTransition {
        do {
            let challenge = try await api.challenge()
            let idToken = try await googleIdentityProvider.identityToken(nonce: challenge.nonce)
            let response = try await api.exchange(NativeExchangeRequest(
                idToken: idToken,
                challenge: challenge.challenge,
                deviceId: deviceID,
                platform: platform
            ))
            guard owns(operation) else { return .stale }
            markVerified(operation)
            return .authenticated(response.user)
        } catch {
            guard owns(operation) else { return .stale }
            return .failed(error.localizedDescription)
        }
    }

    func restore(cachedUser: User?) async -> RestoreTransition {
        await revocations.resumePending()
        let operation = currentOperation
        do {
            guard try await api.restoreTokens(excluding: revocationStore) else {
                return owns(operation)
                    ? .localOnly(invalidatesSynchronization: false)
                    : .stale
            }
            guard owns(operation) else { return .stale }
            guard let cachedUser else {
                _ = advanceGeneration()
                try? await api.clearTokens()
                return .localOnly(invalidatesSynchronization: true)
            }
            return .signedIn(cachedUser)
        } catch AppError.unauthorized {
            return owns(operation) ? .unauthorized : .stale
        } catch {
            return owns(operation)
                ? .localOnly(invalidatesSynchronization: false)
                : .stale
        }
    }

    func verifyRestoredSession(
        _ operation: Operation,
        isSignedIn: Bool,
        hasAccountState: Bool
    ) async -> VerificationTransition {
        guard owns(operation),
              isSignedIn,
              !isVerified(operation),
              hasAccountState,
              verificationOwner == nil else { return .ignored }
        let owner = UUID()
        verificationOwner = owner
        defer {
            if verificationOwner == owner { verificationOwner = nil }
        }
        do {
            let response = try await api.me()
            guard owns(operation), verificationOwner == owner else { return .ignored }
            markVerified(operation)
            return .verified(response.user)
        } catch AppError.unauthorized {
            return owns(operation) ? .unauthorized : .ignored
        } catch {
            return owns(operation) && verificationOwner == owner ? .retry : .ignored
        }
    }

    func beginAccountSwitchCancellation(
        hasPendingAccountSwitch: Bool,
        isWorking: Bool
    ) -> ResetTransition? {
        guard hasPendingAccountSwitch, !isWorking else { return nil }
        return resetTransition(
            historyResolutionState: nil,
            clearsBootstrapPresentation: false,
            isOffline: nil,
            isWorking: nil
        )
    }

    func beginSignOut(
        isWorking: Bool,
        preservesBootstrapResolution: Bool,
        pendingStrategy: BootstrapResolutionStrategy?
    ) -> ResetTransition? {
        guard !isWorking else { return nil }
        return resetTransition(
            historyResolutionState: preservesBootstrapResolution
                ? .retryable(pendingStrategy)
                : AccountHistoryResolutionState.none,
            clearsBootstrapPresentation: true,
            isOffline: false,
            isWorking: true
        )
    }

    func completeDeletion() -> ResetTransition {
        resetTransition(
            historyResolutionState: AccountHistoryResolutionState.none,
            clearsBootstrapPresentation: true,
            isOffline: false,
            isWorking: nil
        )
    }

    func signedOutStorageTransition(
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        preservesBootstrapResolution: Bool,
        activeReturnState: PersistedTimerState?
    ) -> SignedOutStorageTransition {
        if replicationMode == .iroh {
            var signedOut = state
            signedOut.cachedUser = nil
            signedOut.bootstrapUser = nil
            signedOut.pendingBootstrapResolution = nil
            var returnState = activeReturnState ?? .fresh()
            if returnState.cachedUser != nil {
                let deviceID = returnState.deviceId
                returnState = .fresh()
                returnState.deviceId = deviceID
            } else {
                returnState.cachedUser = nil
                returnState.pendingAccountSwitchUser = nil
                returnState.bootstrapUser = nil
                returnState.pendingBootstrapResolution = nil
            }
            return SignedOutStorageTransition(
                state: signedOut,
                irohReturnState: returnState,
                rebuildsProjection: false
            )
        }
        return SignedOutStorageTransition(
            state: preservesBootstrapResolution ? state : .fresh(),
            irohReturnState: nil,
            rebuildsProjection: !preservesBootstrapResolution
        )
    }

    func invalidateUnauthorized(
        _ operation: Operation,
        preservesBootstrapResolution: Bool,
        pendingStrategy: BootstrapResolutionStrategy?
    ) -> ResetTransition? {
        guard owns(operation) else { return nil }
        return resetTransition(
            historyResolutionState: preservesBootstrapResolution
                ? .retryable(pendingStrategy)
                : AccountHistoryResolutionState.none,
            clearsBootstrapPresentation: true,
            isOffline: false,
            isWorking: false,
            signsOutIdentity: false
        )
    }

    func logout() async -> String? {
        do {
            try await revocations.signOut()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func clearTokens() async {
        try? await api.clearTokens()
    }

    func deleteAccount(confirmation: String) async -> String? {
        do {
            try await api.deleteAccount(confirmation: confirmation)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOutIdentity() {
        googleIdentityProvider.signOut()
    }

    func handleGoogleSignInURL(_ url: URL) -> Bool {
        googleIdentityProvider.handle(url)
    }

    func bootstrapFailure(
        _ error: Error,
        stage: BootstrapStage
    ) -> BootstrapFailureTransition {
        let strategy: BootstrapResolutionStrategy?
        let invalidResponseMessage: String
        switch stage {
        case .preflight:
            strategy = nil
            invalidResponseMessage = String(localized: "History setup paused because the server returned an invalid response. Local data remains on this device.")
        case .submission(let submittedStrategy):
            strategy = submittedStrategy
            invalidResponseMessage = String(localized: "History setup paused because the server returned an invalid response. Your saved choice and local data were preserved.")
        }
        switch error {
        case AppError.invalidResponse, is SharedCoreError:
            return BootstrapFailureTransition(
                historyResolutionState: .retryable(strategy),
                isOffline: false,
                errorMessage: invalidResponseMessage,
                effects: []
            )
        case AppError.historyReplacementUnavailable:
            return BootstrapFailureTransition(
                historyResolutionState: .retryable(strategy),
                isOffline: false,
                errorMessage: AppError.historyReplacementUnavailable.localizedDescription,
                effects: []
            )
        default:
            return BootstrapFailureTransition(
                historyResolutionState: .retryable(strategy),
                isOffline: true,
                errorMessage: nil,
                effects: [.scheduleRetry]
            )
        }
    }

    func bootstrapRetryAction(
        isSignedIn: Bool,
        pendingRequest: BootstrapResolveRequest?
    ) -> BootstrapRetryAction {
        guard isSignedIn else { return .signIn }
        let operation = currentOperation
        guard isVerified(operation) else { return .verify(operation) }
        if let pendingRequest { return .submit(pendingRequest, operation) }
        return .preflight(operation)
    }

    private func advanceGeneration() -> Operation {
        generation += 1
        verification.invalidate()
        verificationOwner = nil
        return currentOperation
    }

    private func resetTransition(
        historyResolutionState: AccountHistoryResolutionState?,
        clearsBootstrapPresentation: Bool,
        isOffline: Bool?,
        isWorking: Bool?,
        signsOutIdentity: Bool = true
    ) -> ResetTransition {
        let operation = advanceGeneration()
        var effects: [Effect] = [
            .invalidateSynchronization,
            .resetCentralizedLifecycle
        ]
        if signsOutIdentity { effects.append(.signOutIdentity) }
        return ResetTransition(
            operation: operation,
            sessionState: .localOnly,
            historyResolutionState: historyResolutionState,
            clearsBootstrapPresentation: clearsBootstrapPresentation,
            isOffline: isOffline,
            isWorking: isWorking,
            effects: effects
        )
    }
}
