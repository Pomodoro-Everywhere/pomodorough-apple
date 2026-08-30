import Foundation
import OSLog

struct LogoutRevocationObligation: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let tokens: TokenPair
    let activeCredentialRefreshToken: String
    let refreshOutcomeUnknown: Bool
    let requiresRefresh: Bool
    let remoteRevocationCompleted: Bool

    init(
        id: UUID = UUID(),
        tokens: TokenPair,
        activeCredentialRefreshToken: String? = nil,
        refreshOutcomeUnknown: Bool = false,
        requiresRefresh: Bool = false,
        remoteRevocationCompleted: Bool = false
    ) {
        self.id = id
        self.tokens = tokens
        self.activeCredentialRefreshToken = activeCredentialRefreshToken ?? tokens.refreshToken
        self.refreshOutcomeUnknown = refreshOutcomeUnknown
        self.requiresRefresh = requiresRefresh
        self.remoteRevocationCompleted = remoteRevocationCompleted
    }
    private enum CodingKeys: String, CodingKey {
        case id, tokens, activeCredentialRefreshToken
        case refreshOutcomeUnknown, requiresRefresh, remoteRevocationCompleted
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        tokens = try values.decode(TokenPair.self, forKey: .tokens)
        activeCredentialRefreshToken = try values.decodeIfPresent(
            String.self,
            forKey: .activeCredentialRefreshToken
        ) ?? tokens.refreshToken
        refreshOutcomeUnknown = try values.decodeIfPresent(
            Bool.self,
            forKey: .refreshOutcomeUnknown
        ) ?? false
        requiresRefresh = try values.decodeIfPresent(Bool.self, forKey: .requiresRefresh) ?? false
        remoteRevocationCompleted = try values.decodeIfPresent(
            Bool.self,
            forKey: .remoteRevocationCompleted
        ) ?? false
    }
}

enum LogoutRevocationResult: Equatable, Sendable {
    case revoked
    case accessUnauthorized
    case refreshUnauthorized
    case refreshed(TokenPair)
    case retry
}

struct LogoutRevocationStorageDiagnostic: Equatable, Sendable {
    let consecutiveFailures: Int
    let message: String
}

enum LogoutRevocationRetryOutcome: Equatable, Sendable {
    case empty
    case pending(Int)
    case storageReadFailed(LogoutRevocationStorageDiagnostic)
    case cancelled
}

protocol LogoutRevocationStoring: Sendable {
    func load() throws -> [LogoutRevocationObligation]
    func append(_ obligation: LogoutRevocationObligation) throws
    func replace(_ obligation: LogoutRevocationObligation) throws
    func remove(id: UUID) throws
}

protocol LogoutRevoking: Sendable {
    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult
}

actor SessionRevocationController {
    private static let logger = Logger(
        subsystem: "me.egigoka.pomodorough",
        category: "logout-revocation"
    )
    private static let defaultStorageReadRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30),
    ]

    private let revoker: any LogoutRevoking
    private let detacher: (any LogoutSessionDetaching)?
    private let credentialCleanup: (@Sendable (String) async -> Bool)?
    private let store: any LogoutRevocationStoring
    private let now: @Sendable () -> Date
    private let retryDelay: Duration
    private let storageReadRetryDelays: [Duration]
    private let storageDiagnosticThreshold: Int
    private var retryTask: Task<Void, Never>?
    private var retryTaskID: UUID?
    private var consecutiveStorageReadFailures = 0
    private(set) var storageDiagnostic: LogoutRevocationStorageDiagnostic?

    var isRetryRunning: Bool { retryTask != nil }

    init(
        api: APIClient,
        store: any LogoutRevocationStoring = KeychainLogoutRevocationStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelay: Duration = .seconds(5),
        storageReadRetryDelays: [Duration] = defaultStorageReadRetryDelays,
        storageDiagnosticThreshold: Int = 3
    ) {
        precondition(!storageReadRetryDelays.isEmpty)
        precondition(storageDiagnosticThreshold > 0)
        revoker = api
        detacher = api
        credentialCleanup = { refreshToken in
            await api.deleteDetachedCredential(refreshToken: refreshToken)
        }
        self.store = store
        self.now = now
        self.retryDelay = retryDelay
        self.storageReadRetryDelays = storageReadRetryDelays
        self.storageDiagnosticThreshold = storageDiagnosticThreshold
    }

    init(
        session: any LogoutRevoking & LogoutSessionDetaching,
        store: any LogoutRevocationStoring,
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelay: Duration = .seconds(5),
        storageReadRetryDelays: [Duration] = defaultStorageReadRetryDelays,
        storageDiagnosticThreshold: Int = 3
    ) {
        precondition(!storageReadRetryDelays.isEmpty)
        precondition(storageDiagnosticThreshold > 0)
        revoker = session
        detacher = session
        credentialCleanup = nil
        self.store = store
        self.now = now
        self.retryDelay = retryDelay
        self.storageReadRetryDelays = storageReadRetryDelays
        self.storageDiagnosticThreshold = storageDiagnosticThreshold
    }

    init(
        revoker: any LogoutRevoking,
        credentialCleanup: (@Sendable (String) async -> Bool)? = nil,
        store: any LogoutRevocationStoring,
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelay: Duration = .seconds(5),
        storageReadRetryDelays: [Duration] = defaultStorageReadRetryDelays,
        storageDiagnosticThreshold: Int = 3
    ) {
        precondition(!storageReadRetryDelays.isEmpty)
        precondition(storageDiagnosticThreshold > 0)
        self.revoker = revoker
        detacher = nil
        self.credentialCleanup = credentialCleanup
        self.store = store
        self.now = now
        self.retryDelay = retryDelay
        self.storageReadRetryDelays = storageReadRetryDelays
        self.storageDiagnosticThreshold = storageDiagnosticThreshold
    }

    func signOut() async throws {
        if let detacher {
            _ = try await detacher.detachLogoutObligation(into: store)
        }
        startRetryIfNeeded()
    }

    func resumePending() {
        startRetryIfNeeded()
    }

    @discardableResult
    func retryPending() async -> LogoutRevocationRetryOutcome {
        let initial = loadPending()
        guard case .loaded(let obligations) = initial else {
            return outcome(for: initial)
        }
        guard !obligations.isEmpty else { return .empty }
        for obligation in obligations {
            guard !Task.isCancelled else { return .cancelled }
            await retry(obligation)
        }
        return outcome(for: loadPending())
    }

    func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryTaskID = nil
    }

    private func retry(_ initial: LogoutRevocationObligation) async {
        let credentialRemoved = await removeActiveCredential(for: initial)
        if initial.remoteRevocationCompleted {
            if credentialRemoved { try? store.remove(id: initial.id) }
            return
        }
        if safelyExpired(initial) {
            completeRemoteRevocation(initial, credentialRemoved: credentialRemoved)
            return
        }
        if requiresDetachedRefresh(initial) {
            await refreshAfterUnauthorized(initial, credentialRemoved: credentialRemoved)
        } else {
            let result = await revoker.revoke(initial)
            await apply(result, to: initial, freshlyRefreshed: false, credentialRemoved: credentialRemoved)
        }
    }

    private func removeActiveCredential(for obligation: LogoutRevocationObligation) async -> Bool {
        guard let credentialCleanup else { return true }
        return await credentialCleanup(obligation.activeCredentialRefreshToken)
    }

    private func requiresDetachedRefresh(_ obligation: LogoutRevocationObligation) -> Bool {
        obligation.requiresRefresh || obligation.tokens.accessTokenExpiresAt.timeIntervalSince(now()) <= 30
    }

    private func apply(
        _ result: LogoutRevocationResult,
        to obligation: LogoutRevocationObligation,
        freshlyRefreshed: Bool,
        credentialRemoved: Bool
    ) async {
        switch result {
        case .revoked, .refreshUnauthorized:
            completeRemoteRevocation(obligation, credentialRemoved: credentialRemoved)
        case .accessUnauthorized where freshlyRefreshed:
            completeRemoteRevocation(obligation, credentialRemoved: credentialRemoved)
        case .accessUnauthorized:
            await refreshAfterUnauthorized(obligation, credentialRemoved: credentialRemoved)
        case .refreshed(let tokens):
            await persistAndSubmit(tokens, replacing: obligation, credentialRemoved: credentialRemoved)
        case .retry:
            return
        }
    }

    private func refreshAfterUnauthorized(
        _ obligation: LogoutRevocationObligation,
        credentialRemoved: Bool
    ) async {
        let uncertain = LogoutRevocationObligation(
            id: obligation.id,
            tokens: obligation.tokens,
            activeCredentialRefreshToken: obligation.activeCredentialRefreshToken,
            refreshOutcomeUnknown: true,
            requiresRefresh: true
        )
        guard (try? store.replace(uncertain)) != nil else { return }
        let result = await revoker.revoke(uncertain)
        await apply(result, to: uncertain, freshlyRefreshed: false, credentialRemoved: credentialRemoved)
    }

    private func persistAndSubmit(
        _ tokens: TokenPair,
        replacing obligation: LogoutRevocationObligation,
        credentialRemoved: Bool
    ) async {
        let replacement = LogoutRevocationObligation(
            id: obligation.id,
            tokens: tokens,
            activeCredentialRefreshToken: obligation.activeCredentialRefreshToken
        )
        guard (try? store.replace(replacement)) != nil else { return }
        let result = await revoker.revoke(replacement)
        await apply(result, to: replacement, freshlyRefreshed: true, credentialRemoved: credentialRemoved)
    }

    private func completeRemoteRevocation(
        _ obligation: LogoutRevocationObligation,
        credentialRemoved: Bool
    ) {
        let completed = LogoutRevocationObligation(
            id: obligation.id,
            tokens: obligation.tokens,
            activeCredentialRefreshToken: obligation.activeCredentialRefreshToken,
            refreshOutcomeUnknown: obligation.refreshOutcomeUnknown,
            requiresRefresh: obligation.requiresRefresh,
            remoteRevocationCompleted: true
        )
        guard (try? store.replace(completed)) != nil else { return }
        if credentialRemoved { try? store.remove(id: completed.id) }
    }

    private func safelyExpired(_ obligation: LogoutRevocationObligation) -> Bool {
        !obligation.refreshOutcomeUnknown && obligation.tokens.refreshTokenExpiresAt <= now()
    }

    private func startRetryIfNeeded() {
        guard retryTask == nil else { return }
        let taskID = UUID()
        retryTaskID = taskID
        retryTask = Task { [weak self] in await self?.retryLoop(taskID: taskID) }
    }

    private func retryLoop(taskID: UUID) async {
        defer { finishRetry(taskID: taskID) }
        while !Task.isCancelled {
            let outcome = await retryPending()
            guard let delay = delay(after: outcome) else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func loadPending() -> PendingLoadResult {
        do {
            let obligations = try store.load()
            recordStorageReadSuccess()
            return .loaded(obligations)
        } catch {
            return .failed(recordStorageReadFailure(error))
        }
    }

    private func recordStorageReadSuccess() {
        if storageDiagnostic != nil {
            Self.logger.notice("Pending logout credential storage became readable again")
        }
        consecutiveStorageReadFailures = 0
        storageDiagnostic = nil
    }

    private func recordStorageReadFailure(_ error: Error) -> LogoutRevocationStorageDiagnostic {
        consecutiveStorageReadFailures += 1
        let diagnostic = LogoutRevocationStorageDiagnostic(
            consecutiveFailures: consecutiveStorageReadFailures,
            message: error.localizedDescription
        )
        if consecutiveStorageReadFailures >= storageDiagnosticThreshold {
            storageDiagnostic = diagnostic
        }
        if consecutiveStorageReadFailures == storageDiagnosticThreshold {
            Self.logger.error(
                "Pending logout credentials remain unreadable: \(diagnostic.message, privacy: .public)"
            )
        }
        return diagnostic
    }

    private func outcome(for result: PendingLoadResult) -> LogoutRevocationRetryOutcome {
        switch result {
        case .loaded(let obligations):
            return obligations.isEmpty ? .empty : .pending(obligations.count)
        case .failed(let diagnostic):
            return .storageReadFailed(diagnostic)
        }
    }

    private func delay(after outcome: LogoutRevocationRetryOutcome) -> Duration? {
        switch outcome {
        case .empty, .cancelled:
            return nil
        case .pending:
            return retryDelay
        case .storageReadFailed(let diagnostic):
            let index = min(diagnostic.consecutiveFailures - 1, storageReadRetryDelays.count - 1)
            return storageReadRetryDelays[index]
        }
    }

    private func finishRetry(taskID: UUID) {
        guard retryTaskID == taskID else { return }
        retryTask = nil
        retryTaskID = nil
    }

    private enum PendingLoadResult {
        case loaded([LogoutRevocationObligation])
        case failed(LogoutRevocationStorageDiagnostic)
    }
}

protocol LogoutSessionDetaching: Sendable {
    func detachLogoutObligation(into store: any LogoutRevocationStoring) async throws -> LogoutRevocationObligation?
}
