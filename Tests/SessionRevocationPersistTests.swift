import Foundation
import Testing
@testable import Pomodorough

// AP52: replace/remove persist failures surface through storageDiagnostic
// plus a deduped capture instead of vanishing silently.
@Suite("Revocation persist failures")
struct SessionRevocationPersistTests {
    @Test
    func replaceFailureRetainsObligationAndSurfacesDiagnostic() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let store = FailingWriteRevocationStore(failReplace: true)
        try store.append(Self.obligation())
        let controller = SessionRevocationController(revoker: RevokedRevoker(), store: store)
        await controller.retryPending()
        let diagnostic = await controller.storageDiagnostic
        #expect(diagnostic?.consecutiveFailures == 1)
        #expect(try store.load().count == 1)
        #expect(recorded.value.count == 1)
    }

    @Test
    func removeFailureRetainsCompletedObligationAndCaptures() async throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let store = FailingWriteRevocationStore(failRemove: true)
        try store.append(Self.obligation())
        let controller = SessionRevocationController(revoker: RevokedRevoker(), store: store)
        await controller.retryPending()
        let stored = try #require(try store.load().first)
        #expect(stored.remoteRevocationCompleted)
        #expect(await controller.storageDiagnostic != nil)
        #expect(recorded.value.count == 1)
    }

    // AP84: read failures capture once at threshold, mirroring AP52.
    @Test
    func readFailuresCaptureOnceAtThreshold() async {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let store = FailingReadRevocationStore()
        let controller = SessionRevocationController(
            revoker: RevokedRevoker(), store: store
        )
        await controller.retryPending()
        #expect(await controller.storageDiagnostic == nil)
        #expect(recorded.value.isEmpty)
        await controller.retryPending()
        await controller.retryPending()
        let diagnostic = await controller.storageDiagnostic
        #expect(diagnostic?.consecutiveFailures == 3)
        #expect(recorded.value.count == 1)
        await controller.retryPending()
        #expect(recorded.value.count == 1)
    }

    private static func obligation() -> LogoutRevocationObligation {
        LogoutRevocationObligation(tokens: TokenPair(
            accessToken: "persist-access", accessTokenExpiresAt: .distantFuture,
            refreshToken: "persist-refresh", refreshTokenExpiresAt: .distantFuture
        ))
    }
}

private actor RevokedRevoker: LogoutRevoking {
    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult { .revoked }
}

private final class FailingWriteRevocationStore: LogoutRevocationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var obligations: [LogoutRevocationObligation] = []
    private let failReplace: Bool
    private let failRemove: Bool

    init(failReplace: Bool = false, failRemove: Bool = false) {
        self.failReplace = failReplace
        self.failRemove = failRemove
    }

    func load() throws -> [LogoutRevocationObligation] { lock.withLock { obligations } }

    func append(_ obligation: LogoutRevocationObligation) throws {
        lock.withLock { obligations.append(obligation) }
    }

    func replace(_ obligation: LogoutRevocationObligation) throws {
        if failReplace { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock {
            guard let index = obligations.firstIndex(where: { $0.id == obligation.id }) else { return }
            obligations[index] = obligation
        }
    }

    func remove(id: UUID) throws {
        if failRemove { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { obligations.removeAll { $0.id == id } }
    }
}

private final class FailingReadRevocationStore: LogoutRevocationStoring, @unchecked Sendable {
    func load() throws -> [LogoutRevocationObligation] {
        throw CocoaError(.fileReadNoPermission)
    }

    func append(_ obligation: LogoutRevocationObligation) throws {}
    func replace(_ obligation: LogoutRevocationObligation) throws {}
    func remove(id: UUID) throws {}
}
