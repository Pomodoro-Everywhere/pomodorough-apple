import Foundation
import Security
import Testing
@testable import Pomodorough

@Suite("Durable logout revocation")
struct LogoutRevocationTests {
    @Test
    func detachmentPersistsObligationBeforeDeletingActiveCredentials() async throws {
        let tokens = tokenPair(access: "account-a")
        let active = OrderedTokenStore(tokens: tokens)
        let obligations = MemoryLogoutRevocationStore(events: active.events)
        let client = APIClient(keychain: active)
        #expect(try await client.restoreTokens())

        let obligation = try await client.detachLogoutObligation(into: obligations)

        #expect(obligation?.tokens.accessToken == "account-a")
        #expect(active.events.values.suffix(2) == ["obligation-save", "token-delete"])
        #expect(active.tokens == nil)
    }

    @Test
    func deleteFailuresNeverReactivateSessionAndEventuallyCleanUp() async throws {
        let tokens = tokenPair(access: "delete-failure")
        let active = OrderedTokenStore(tokens: tokens, deleteFailures: 3)
        let obligations = MemoryLogoutRevocationStore()
        let client = APIClient(keychain: active)
        #expect(try await client.restoreTokens())

        let obligation = try #require(await client.detachLogoutObligation(into: obligations))
        #expect(active.tokens == tokens)
        #expect(try await client.detachLogoutObligation(into: obligations) == nil)

        let restarted = APIClient(keychain: active)
        #expect(try await restarted.restoreTokens(excluding: obligations) == false)
        #expect(active.tokens == tokens)
        #expect(try await restarted.detachLogoutObligation(into: obligations) == nil)

        let revoker = RecordingLogoutRevoker(result: .revoked)
        let controller = SessionRevocationController(
            revoker: revoker,
            credentialCleanup: { token in
                await restarted.deleteDetachedCredential(refreshToken: token)
            },
            store: obligations
        )
        await controller.retryPending()
        let completed = try #require(obligations.load().first)
        #expect(completed.remoteRevocationCompleted)
        #expect(active.tokens == tokens)
        #expect(await revoker.revoked == [obligation])

        await controller.retryPending()
        #expect(try obligations.load().isEmpty)
        #expect(active.tokens == nil)
        #expect(await revoker.revoked == [obligation])
    }

    @Test
    func localSignOutReturnsWhileRemoteRevocationIsStillBlocked() async throws {
        let tokens = tokenPair(access: "non-blocking")
        let store = MemoryLogoutRevocationStore()
        let session = BlockingLogoutSession(tokens: tokens)
        let controller = SessionRevocationController(session: session, store: store)

        try await controller.signOut()

        await session.waitUntilRevocationBlocked()
        #expect(await session.isRevocationBlocked)
        #expect(try store.load().count == 1)
        await session.releaseRevocation()
        for _ in 0..<100 where try !store.load().isEmpty { await Task.yield() }
        #expect(try store.load().isEmpty)
    }

    @Test
    func removingCompletedWorkPreservesNewerAccountObligation() throws {
        let store = MemoryLogoutRevocationStore()
        let first = LogoutRevocationObligation(tokens: tokenPair(access: "account-a"))
        let second = LogoutRevocationObligation(tokens: tokenPair(access: "account-b"))
        try store.append(first)
        try store.append(second)

        try store.remove(id: first.id)

        #expect(try store.load() == [second])
    }

    @Test
    func overlappingCompletionAndNewLogoutPreserveNewAccountObligation() async throws {
        let security = InterleavingKeychainSecurity()
        let removalStore = KeychainLogoutRevocationStore(security: security)
        let appendStore = KeychainLogoutRevocationStore(security: security)
        let first = LogoutRevocationObligation(tokens: tokenPair(access: "account-a"))
        let second = LogoutRevocationObligation(tokens: tokenPair(access: "account-b"))
        try removalStore.append(first)
        let readsBeforeOverlap = security.readCount
        security.pauseNextRead()

        let removal = Task.detached { try removalStore.remove(id: first.id) }
        for _ in 0..<1_000 where !security.isReadPaused { await Task.yield() }
        #expect(security.isReadPaused)
        let append = Task.detached {
            security.markAppendStarted()
            try appendStore.append(second)
        }
        for _ in 0..<1_000 where !security.hasAppendStarted { await Task.yield() }
        try #require(security.hasAppendStarted)
        for _ in 0..<1_000 where security.readCount == readsBeforeOverlap + 1 {
            await Task.yield()
        }
        let serializedAcrossInstances = security.readCount == readsBeforeOverlap + 1
        security.resumeRead()
        try await removal.value
        try await append.value

        #expect(serializedAcrossInstances)
        #expect(try removalStore.load() == [second])
    }

    @Test
    func keychainObligationsUseSeparateOpaquePayloadAndLegacyTokensStillDecode() throws {
        let tokens = tokenPair(access: "legacy")
        let legacyBytes = try JSONEncoder.api.encode(tokens)
        let legacySecurity = RecordingKeychainSecurity(copyStatus: errSecSuccess, copyData: legacyBytes)
        #expect(try KeychainStore(security: legacySecurity).load()?.accessToken == "legacy")

        let revocationSecurity = RecordingKeychainSecurity(updateStatus: errSecItemNotFound)
        let store = KeychainLogoutRevocationStore(security: revocationSecurity)
        try store.append(LogoutRevocationObligation(tokens: tokens))
        let saved = try #require(revocationSecurity.addQueries.first)
        #expect(saved.account == "logout-revocations-v1")
        #expect(saved.account != legacySecurity.copyQueries.first?.account)
        #expect(saved.valueData != legacyBytes)
    }

    @Test
    func coveredCredentialIsNeverRestoredButNewAccountCredentialStillIs() async throws {
        let retired = tokenPair(access: "account-a")
        let obligations = MemoryLogoutRevocationStore(obligations: [
            LogoutRevocationObligation(tokens: retired),
        ])
        let retiredStore = OrderedTokenStore(tokens: retired)
        let retiredClient = APIClient(keychain: retiredStore)
        #expect(try await retiredClient.restoreTokens(excluding: obligations) == false)
        #expect(retiredStore.tokens == nil)

        let replacement = tokenPair(access: "account-b")
        let replacementStore = OrderedTokenStore(tokens: replacement)
        let replacementClient = APIClient(keychain: replacementStore)
        #expect(try await replacementClient.restoreTokens(excluding: obligations))
        #expect(replacementStore.tokens == replacement)
    }

    @Test
    func detachedCredentialCleanupPreservesNewerAccountCredential() async {
        let retired = tokenPair(access: "account-a")
        let replacement = tokenPair(access: "account-b")
        let active = OrderedTokenStore(tokens: replacement)
        let client = APIClient(keychain: active)

        #expect(await client.deleteDetachedCredential(refreshToken: retired.refreshToken))
        #expect(active.tokens == replacement)
    }

    @Test
    func legacyObligationPayloadDecodesCleanupDefaults() throws {
        let legacy = LegacyLogoutRevocationObligation(
            id: UUID(),
            tokens: tokenPair(access: "legacy-obligation"),
            refreshOutcomeUnknown: true,
            requiresRefresh: true
        )

        let obligation = try JSONDecoder.api.decode(
            LogoutRevocationObligation.self,
            from: JSONEncoder.api.encode(legacy)
        )

        #expect(obligation.activeCredentialRefreshToken == legacy.tokens.refreshToken)
        #expect(obligation.refreshOutcomeUnknown)
        #expect(obligation.requiresRefresh)
        #expect(!obligation.remoteRevocationCompleted)
    }

    @Test
    func expiredObligationIsRetiredWithoutNetworkAndIsNeverRestored() async throws {
        let expired = tokenPair(access: "expired", refreshExpiry: Date(timeIntervalSince1970: 10))
        let store = MemoryLogoutRevocationStore()
        try store.append(LogoutRevocationObligation(tokens: expired))
        let revoker = RecordingLogoutRevoker()
        let controller = SessionRevocationController(
            revoker: revoker,
            store: store,
            now: { Date(timeIntervalSince1970: 20) }
        )

        await controller.retryPending()

        #expect(try store.load().isEmpty)
        #expect(await revoker.revoked.isEmpty)
        #expect(await revoker.restoredCredentialCount == 0)
    }

    @Test(arguments: [LogoutRevocationResult.revoked, .refreshUnauthorized])
    func terminalRemoteOutcomeRetiresObligation(result: LogoutRevocationResult) async throws {
        let obligation = LogoutRevocationObligation(tokens: tokenPair(access: "terminal"))
        let store = MemoryLogoutRevocationStore(obligations: [obligation])
        let revoker = RecordingLogoutRevoker(result: result)
        let controller = SessionRevocationController(revoker: revoker, store: store)

        await controller.retryPending()

        #expect(try store.load().isEmpty)
    }

    @Test
    func ordinaryAccessUnauthorizedRefreshesAndPersistsBeforeLogout() async throws {
        let original = LogoutRevocationObligation(tokens: tokenPair(access: "old-access"))
        let replacement = tokenPair(access: "fresh-access")
        let store = MemoryLogoutRevocationStore(obligations: [original])
        let revoker = ScriptedLogoutRevoker(results: [
            .accessUnauthorized,
            .refreshed(replacement),
            .revoked,
        ])

        await SessionRevocationController(revoker: revoker, store: store).retryPending()

        #expect(try store.load().isEmpty)
        let calls = await revoker.obligations
        #expect(calls.count == 3)
        #expect(calls[1].requiresRefresh)
        #expect(calls[1].refreshOutcomeUnknown)
        #expect(calls[2].tokens == replacement)
    }

    @Test
    func expiredAccessPersistsRefreshAmbiguityBeforeTransport() async throws {
        let now = Date(timeIntervalSince1970: 20)
        let original = LogoutRevocationObligation(tokens: tokenPair(
            access: "expired-access",
            accessExpiry: Date(timeIntervalSince1970: 10),
            refreshExpiry: Date(timeIntervalSince1970: 100)
        ))
        let store = MemoryLogoutRevocationStore(obligations: [original])
        let revoker = StoreObservingLogoutRevoker(store: store)
        let controller = SessionRevocationController(
            revoker: revoker,
            store: store,
            now: { now }
        )

        await controller.retryPending()

        let observed = try #require(await revoker.observedAtTransport)
        #expect(observed.id == original.id)
        #expect(observed.requiresRefresh)
        #expect(observed.refreshOutcomeUnknown)
        #expect(try store.load() == [observed])
    }

    @Test
    func refreshedPairSurvivesLaterLogoutFailure() async throws {
        let original = LogoutRevocationObligation(tokens: tokenPair(access: "expired"))
        let replacement = tokenPair(access: "replacement")
        let store = MemoryLogoutRevocationStore(obligations: [original])
        let revoker = ScriptedLogoutRevoker(results: [.refreshed(replacement), .retry])

        await SessionRevocationController(revoker: revoker, store: store).retryPending()

        let pending = try #require(store.load().first)
        #expect(pending.id == original.id)
        #expect(pending.tokens == replacement)
        #expect(!pending.refreshOutcomeUnknown)
    }

    @Test
    func ambiguousRefreshIsNotDroppedAtOldExpiry() async throws {
        let expired = tokenPair(access: "ambiguous", refreshExpiry: Date(timeIntervalSince1970: 10))
        let obligation = LogoutRevocationObligation(
            tokens: expired,
            refreshOutcomeUnknown: true,
            requiresRefresh: true
        )
        let store = MemoryLogoutRevocationStore(obligations: [obligation])
        let revoker = ScriptedLogoutRevoker(results: [.refreshUnauthorized])
        let controller = SessionRevocationController(
            revoker: revoker,
            store: store,
            now: { Date(timeIntervalSince1970: 20) }
        )

        await controller.retryPending()

        #expect(await revoker.obligations == [obligation])
        #expect(try store.load().isEmpty)
    }

    @Test
    func transientFailureSurvivesRestartAndLaterSucceeds() async throws {
        let obligation = LogoutRevocationObligation(tokens: tokenPair(access: "offline"))
        let store = MemoryLogoutRevocationStore(obligations: [obligation])
        let offline = RecordingLogoutRevoker(result: .retry)
        await SessionRevocationController(revoker: offline, store: store).retryPending()
        #expect(try store.load() == [obligation])

        let online = RecordingLogoutRevoker(result: .revoked)
        await SessionRevocationController(revoker: online, store: store).retryPending()
        #expect(try store.load().isEmpty)
        #expect(await online.revoked == [obligation])
    }

    @Test
    func storageReadFailureIsDistinctFromEmptyQueue() async {
        let store = ControllableReadLogoutRevocationStore(obligations: [])
        let controller = SessionRevocationController(
            revoker: RecordingLogoutRevoker(),
            store: store
        )

        let failed = await controller.retryPending()
        guard case .storageReadFailed(let diagnostic) = failed else {
            Issue.record("Storage read failure was reported as an empty queue")
            return
        }
        #expect(diagnostic.consecutiveFailures == 1)

        store.allowReads()
        #expect(await controller.retryPending() == .empty)
    }

    @Test
    func repeatedStorageReadFailuresBackOffThenRecoverAndDrain() async {
        let obligation = LogoutRevocationObligation(tokens: tokenPair(access: "read-retry"))
        let store = ControllableReadLogoutRevocationStore(obligations: [obligation])
        let revoker = RecordingLogoutRevoker(result: .revoked)
        let controller = SessionRevocationController(
            revoker: revoker,
            store: store,
            storageReadRetryDelays: [.milliseconds(1), .milliseconds(2)],
            storageDiagnosticThreshold: 2
        )

        await controller.resumePending()
        #expect(await waitUntil { store.loadAttempts >= 3 })
        let diagnostic = await controller.storageDiagnostic
        #expect(diagnostic?.consecutiveFailures ?? 0 >= 2)
        #expect(store.obligations == [obligation])

        store.allowReads()
        #expect(await waitUntil { await store.isEmptyAnd(controllerIdle: controller) })
        #expect(await revoker.revoked == [obligation])
        #expect(await controller.storageDiagnostic == nil)
    }

    @Test
    func cancelledStorageReadRetryPreservesWorkForRestart() async {
        let obligation = LogoutRevocationObligation(tokens: tokenPair(access: "restart"))
        let store = ControllableReadLogoutRevocationStore(obligations: [obligation])
        let first = SessionRevocationController(
            revoker: RecordingLogoutRevoker(),
            store: store,
            storageReadRetryDelays: [.milliseconds(5)]
        )
        await first.resumePending()
        #expect(await waitUntil { store.loadAttempts >= 1 })

        await first.cancelRetry()
        #expect(await waitUntil { !(await first.isRetryRunning) })
        let attemptsAfterCancellation = store.loadAttempts
        try? await Task.sleep(for: .milliseconds(10))
        #expect(store.loadAttempts == attemptsAfterCancellation)
        #expect(store.obligations == [obligation])

        store.allowReads()
        let revoker = RecordingLogoutRevoker(result: .revoked)
        let restarted = SessionRevocationController(revoker: revoker, store: store)
        await restarted.resumePending()
        #expect(await waitUntil { await store.isEmptyAnd(controllerIdle: restarted) })
        #expect(await revoker.revoked == [obligation])
    }

    @Test
    func accountSwitchObligationJoinsActiveStorageReadRetry() async throws {
        let first = LogoutRevocationObligation(tokens: tokenPair(access: "account-a"))
        let store = ControllableReadLogoutRevocationStore(obligations: [first])
        let session = RecordingLogoutSession(tokens: tokenPair(access: "account-b"))
        let controller = SessionRevocationController(
            session: session,
            store: store,
            storageReadRetryDelays: [.milliseconds(1)]
        )
        await controller.resumePending()
        #expect(await waitUntil { store.loadAttempts >= 2 })

        try await controller.signOut()
        #expect(store.obligations.map(\.tokens.accessToken) == ["account-a", "account-b"])
        store.allowReads()

        #expect(await waitUntil { await store.isEmptyAnd(controllerIdle: controller) })
        let revoked = await session.revoked.map(\.tokens.accessToken)
        #expect(Set(revoked) == Set(["account-a", "account-b"]))
    }

    @Test
    func terminalQueueDrainStopsWorkerWithoutAnotherNetworkAttempt() async {
        let obligation = LogoutRevocationObligation(tokens: tokenPair(access: "drain"))
        let store = ControllableReadLogoutRevocationStore(
            obligations: [obligation],
            readsFail: false
        )
        let revoker = RecordingLogoutRevoker(result: .revoked)
        let controller = SessionRevocationController(revoker: revoker, store: store)

        await controller.resumePending()
        #expect(await waitUntil { await store.isEmptyAnd(controllerIdle: controller) })
        #expect(await revoker.revoked == [obligation])

        await controller.resumePending()
        #expect(await waitUntil { !(await controller.isRetryRunning) })
        #expect(await revoker.revoked == [obligation])
    }

    private func tokenPair(
        access: String,
        accessExpiry: Date = .distantFuture,
        refreshExpiry: Date = .distantFuture
    ) -> TokenPair {
        TokenPair(
            accessToken: access,
            accessTokenExpiresAt: accessExpiry,
            refreshToken: "refresh-\(access)",
            refreshTokenExpiresAt: refreshExpiry
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class OrderedTokenStore: TokenStoring, @unchecked Sendable {
    let events = EventLog()
    private let lock = NSLock()
    private var storage: TokenPair?
    private var deleteFailuresRemaining: Int
    init(tokens: TokenPair?, deleteFailures: Int = 0) {
        storage = tokens
        deleteFailuresRemaining = deleteFailures
    }
    var tokens: TokenPair? { lock.withLock { storage } }
    func load() throws -> TokenPair? { events.append("token-load"); return tokens }
    func save(_ tokens: TokenPair) throws { lock.withLock { storage = tokens } }
    func delete() throws {
        events.append("token-delete")
        try lock.withLock {
            guard deleteFailuresRemaining == 0 else {
                deleteFailuresRemaining -= 1
                throw OrderedTokenStoreError.deleteFailed
            }
            storage = nil
        }
    }
}

private enum OrderedTokenStoreError: Error { case deleteFailed }

private struct LegacyLogoutRevocationObligation: Codable {
    let id: UUID
    let tokens: TokenPair
    let refreshOutcomeUnknown: Bool
    let requiresRefresh: Bool
}

private final class MemoryLogoutRevocationStore: LogoutRevocationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogoutRevocationObligation]
    private let events: EventLog?
    init(obligations: [LogoutRevocationObligation] = [], events: EventLog? = nil) {
        storage = obligations
        self.events = events
    }
    func load() throws -> [LogoutRevocationObligation] { lock.withLock { storage } }
    func append(_ obligation: LogoutRevocationObligation) throws {
        events?.append("obligation-save")
        lock.withLock { storage.append(obligation) }
    }
    func replace(_ obligation: LogoutRevocationObligation) throws {
        lock.withLock {
            guard let index = storage.firstIndex(where: { $0.id == obligation.id }) else { return }
            storage[index] = obligation
        }
    }
    func remove(id: UUID) throws { lock.withLock { storage.removeAll { $0.id == id } } }
}

private enum RevocationStoreReadError: LocalizedError, Sendable {
    case unreadable

    var errorDescription: String? { "Pending logout credential storage is unreadable" }
}

private final class ControllableReadLogoutRevocationStore: LogoutRevocationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogoutRevocationObligation]
    private var readsFail: Bool
    private var reads = 0

    init(obligations: [LogoutRevocationObligation], readsFail: Bool = true) {
        storage = obligations
        self.readsFail = readsFail
    }

    var loadAttempts: Int { lock.withLock { reads } }
    var obligations: [LogoutRevocationObligation] { lock.withLock { storage } }

    func allowReads() { lock.withLock { readsFail = false } }

    func load() throws -> [LogoutRevocationObligation] {
        try lock.withLock {
            reads += 1
            if readsFail { throw RevocationStoreReadError.unreadable }
            return storage
        }
    }

    func append(_ obligation: LogoutRevocationObligation) throws {
        lock.withLock { storage.append(obligation) }
    }

    func replace(_ obligation: LogoutRevocationObligation) throws {
        lock.withLock {
            guard let index = storage.firstIndex(where: { $0.id == obligation.id }) else { return }
            storage[index] = obligation
        }
    }

    func remove(id: UUID) throws {
        lock.withLock { storage.removeAll { $0.id == id } }
    }

    func isEmptyAnd(controllerIdle controller: SessionRevocationController) async -> Bool {
        let controllerIsIdle = !(await controller.isRetryRunning)
        return obligations.isEmpty && controllerIsIdle
    }
}

private actor BlockingLogoutSession: LogoutRevoking, LogoutSessionDetaching {
    private let tokens: TokenPair
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isRevocationBlocked = false

    init(tokens: TokenPair) { self.tokens = tokens }

    func detachLogoutObligation(
        into store: any LogoutRevocationStoring
    ) async throws -> LogoutRevocationObligation? {
        let obligation = LogoutRevocationObligation(tokens: tokens)
        try store.append(obligation)
        return obligation
    }

    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        isRevocationBlocked = true
        await withCheckedContinuation { continuation = $0 }
        isRevocationBlocked = false
        return .revoked
    }

    func releaseRevocation() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilRevocationBlocked() async {
        while !isRevocationBlocked { await Task.yield() }
    }
}

private actor RecordingLogoutSession: LogoutRevoking, LogoutSessionDetaching {
    private let tokens: TokenPair
    private(set) var revoked: [LogoutRevocationObligation] = []

    init(tokens: TokenPair) { self.tokens = tokens }

    func detachLogoutObligation(
        into store: any LogoutRevocationStoring
    ) async throws -> LogoutRevocationObligation? {
        let obligation = LogoutRevocationObligation(tokens: tokens)
        try store.append(obligation)
        return obligation
    }

    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        revoked.append(obligation)
        return .revoked
    }
}

private actor ScriptedLogoutRevoker: LogoutRevoking {
    private var results: [LogoutRevocationResult]
    private(set) var obligations: [LogoutRevocationObligation] = []

    init(results: [LogoutRevocationResult]) { self.results = results }

    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        obligations.append(obligation)
        return results.isEmpty ? .retry : results.removeFirst()
    }
}

private actor StoreObservingLogoutRevoker: LogoutRevoking {
    private let store: MemoryLogoutRevocationStore
    private(set) var observedAtTransport: LogoutRevocationObligation?

    init(store: MemoryLogoutRevocationStore) { self.store = store }

    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        observedAtTransport = try? store.load().first
        return .retry
    }
}

private final class InterleavingKeychainSecurity: KeychainSecurityOperating, @unchecked Sendable {
    private let lock = NSLock()
    private let readResume = DispatchSemaphore(value: 0)
    private var data: Data?
    private var shouldPauseRead = false
    private var readIsPaused = false
    private var copies = 0
    private var appendStarted = false

    func pauseNextRead() { lock.withLock { shouldPauseRead = true } }
    var isReadPaused: Bool { lock.withLock { readIsPaused } }
    var readCount: Int { lock.withLock { copies } }
    var hasAppendStarted: Bool { lock.withLock { appendStarted } }
    func markAppendStarted() { lock.withLock { appendStarted = true } }
    func resumeRead() { readResume.signal() }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        let snapshot: Data?
        let pause: Bool
        (snapshot, pause) = lock.withLock {
            copies += 1
            let pause = shouldPauseRead
            shouldPauseRead = false
            return (data, pause)
        }
        if pause {
            lock.withLock { readIsPaused = true }
            readResume.wait()
            lock.withLock { readIsPaused = false }
        }
        return snapshot.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard data != nil else { return errSecItemNotFound }
            data = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            guard data == nil else { return errSecDuplicateItem }
            data = query[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { data = nil }
        return errSecSuccess
    }

    func errorMessage(for status: OSStatus) -> String? { nil }
}

private actor RecordingLogoutRevoker: LogoutRevoking {
    private let result: LogoutRevocationResult
    private(set) var revoked: [LogoutRevocationObligation] = []
    private(set) var restoredCredentialCount = 0
    init(result: LogoutRevocationResult = .retry) { self.result = result }
    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        revoked.append(obligation)
        return result
    }
}
