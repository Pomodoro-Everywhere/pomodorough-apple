import Foundation
import Testing
@testable import Pomodorough

@Suite("Account deletion credential replay")
struct AccountDeletionRetryTests {
    @Test
    func lostResponseRetriesOriginalExpiredCredentialAfterClientRestart() async throws {
        let original = deletionTokens("original", expired: true)
        let fixture = DeletionRetryFixture(tokens: original)
        defer { fixture.close() }
        fixture.scenario.setReplies([
            { _ in throw URLError(.networkConnectionLost) },
            { _ in (204, Data()) },
        ])
        let firstClient = try await fixture.client()
        guard case .unknown = await firstClient.deleteAccount(confirmation: "DELETE") else {
            Issue.record("Lost response must remain unknown")
            return
        }
        let restartedClient = try await fixture.client()
        #expect(await restartedClient.deleteAccount(confirmation: "DELETE") == .committed)
        #expect(fixture.scenario.requests.map(\.path) == ["/api/v1/account", "/api/v1/account"])
        #expect(fixture.scenario.requests.allSatisfy { $0.authorization == "Bearer original.access" })
        #expect(fixture.scenario.requests.allSatisfy { $0.method == "DELETE" })
        #expect(fixture.store.load() == original)
        #expect(fixture.store.saveCount == 0)
        #expect(fixture.store.deleteCount == 0)
    }

    @Test(arguments: [false, true])
    func onlyDefinitive401AllowsRefreshThenNewCredentialDeletion(expired: Bool) async throws {
        let rotated = deletionTokens("rotated")
        let fixture = DeletionRetryFixture(tokens: deletionTokens("original", expired: expired))
        defer { fixture.close() }
        fixture.scenario.setReplies([
            { _ in (401, Data()) },
            { _ in (200, try JSONEncoder.api.encode(rotated)) },
            { _ in (204, Data()) },
        ])
        let client = try await fixture.client()
        #expect(await client.deleteAccount(confirmation: "DELETE") == .committed)
        #expect(fixture.scenario.requests.map(\.path) == [
            "/api/v1/account", "/api/v1/auth/refresh", "/api/v1/account",
        ])
        #expect(fixture.scenario.requests.map(\.authorization) == [
            "Bearer original.access", nil, "Bearer rotated.access",
        ])
        #expect(fixture.store.load() == rotated)
        #expect(fixture.store.saveCount == 1)
        #expect(fixture.store.deleteCount == 0)
    }

    @Test(arguments: [200, 202, 400, 403, 409, 429, 500, 503])
    func otherStatusesNeverRefreshOrConfirmDeletion(status: Int) async throws {
        let original = deletionTokens("original", expired: true)
        let fixture = DeletionRetryFixture(tokens: original)
        defer { fixture.close() }
        fixture.scenario.setReplies([{ _ in (status, Data()) }])
        let client = try await fixture.client()
        let outcome = await client.deleteAccount(confirmation: "DELETE")
        #expect(outcome != .committed)
        if (400..<500).contains(status) {
            guard case .rejected = outcome else { Issue.record("Expected rejection"); return }
        } else {
            guard case .unknown = outcome else { Issue.record("Expected unknown result"); return }
        }
        #expect(fixture.scenario.requests.count == 1)
        #expect(fixture.store.load() == original)
        #expect(fixture.store.saveCount == 0)
    }

    @Test
    func absentReceiptAndRejectedRefreshNeverBecomeSuccess() async throws {
        let original = deletionTokens("original", expired: true)
        let fixture = DeletionRetryFixture(tokens: original)
        defer { fixture.close() }
        fixture.scenario.setReplies([{ _ in (401, Data()) }, { _ in (401, Data()) }])
        let client = try await fixture.client()
        guard case .unknown = await client.deleteAccount(confirmation: "DELETE") else {
            Issue.record("401 is not deletion confirmation")
            return
        }
        #expect(fixture.scenario.requests.map(\.path) == ["/api/v1/account", "/api/v1/auth/refresh"])
        #expect(fixture.store.load() == original)
        #expect(fixture.store.saveCount == 0)
        #expect(fixture.store.deleteCount == 0)
    }

    @Test
    func lostRefreshedDeletionResponseRetainsNewReceiptCredential() async throws {
        let rotated = deletionTokens("rotated", expired: true)
        let fixture = DeletionRetryFixture(tokens: deletionTokens("original", expired: true))
        defer { fixture.close() }
        fixture.scenario.setReplies([
            { _ in (401, Data()) },
            { _ in (200, try JSONEncoder.api.encode(rotated)) },
            { _ in throw URLError(.networkConnectionLost) },
            { _ in (204, Data()) },
        ])
        let client = try await fixture.client()
        guard case .unknown = await client.deleteAccount(confirmation: "DELETE") else {
            Issue.record("Lost response must remain unknown")
            return
        }
        let restarted = try await fixture.client()
        #expect(await restarted.deleteAccount(confirmation: "DELETE") == .committed)
        #expect(fixture.scenario.requests.suffix(2).allSatisfy { $0.authorization == "Bearer rotated.access" })
        #expect(fixture.scenario.requests.map(\.path).filter { $0 == "/api/v1/auth/refresh" }.count == 1)
        #expect(fixture.store.load() == rotated)
    }

    @Test
    func failedCredentialPersistencePreventsRefreshedDeletion() async throws {
        let original = deletionTokens("original", expired: true)
        let rotated = deletionTokens("rotated")
        let fixture = DeletionRetryFixture(tokens: original, failSave: true)
        defer { fixture.close() }
        fixture.scenario.setReplies([
            { _ in (401, Data()) },
            { _ in (200, try JSONEncoder.api.encode(rotated)) },
        ])
        let client = try await fixture.client()
        guard case .unknown = await client.deleteAccount(confirmation: "DELETE") else {
            Issue.record("Failed persistence must prevent deletion")
            return
        }
        #expect(fixture.scenario.requests.count == 2)
        #expect(fixture.store.load() == original)
    }

    @Test(arguments: [204, 401])
    func accountSwitchInvalidatesOldDeletionResponse(status: Int) async throws {
        let newer = deletionTokens("new-account")
        let fixture = DeletionRetryFixture(tokens: deletionTokens("original", expired: true))
        defer { fixture.close() }
        let client = try await fixture.client()
        fixture.scenario.setReplies([{ _ in
            try fixture.store.save(newer)
            #expect(try await client.restoreTokens())
            return (status, Data())
        }])
        guard case .unknown = await client.deleteAccount(confirmation: "DELETE") else {
            Issue.record("Old response cannot confirm deletion of new session")
            return
        }
        #expect(fixture.scenario.requests.count == 1)
        #expect(fixture.store.load() == newer)
    }

    @Test
    func accountSwitchDuringRefreshNeverOverwritesNewSession() async throws {
        let newer = deletionTokens("new-account")
        let rotated = deletionTokens("rotated")
        let fixture = DeletionRetryFixture(tokens: deletionTokens("original", expired: true))
        defer { fixture.close() }
        let client = try await fixture.client()
        fixture.scenario.setReplies([
            { _ in (401, Data()) },
            { _ in
                try fixture.store.save(newer)
                #expect(try await client.restoreTokens())
                return (200, try JSONEncoder.api.encode(rotated))
            },
        ])
        guard case .unknown = await client.deleteAccount(confirmation: "DELETE") else {
            Issue.record("Old refresh cannot resume deletion in new session")
            return
        }
        #expect(fixture.scenario.requests.count == 2)
        #expect(fixture.store.load() == newer)
        #expect(fixture.store.saveCount == 1)
    }

    @Test
    func concurrentAuthenticatedRequestCannotRotateDeletionCredential() async throws {
        let original = deletionTokens("original", expired: true)
        let fixture = DeletionRetryFixture(tokens: original)
        defer { fixture.close() }
        let client = try await fixture.client()
        fixture.scenario.setReplies([
            { _ in
                do { _ = try await client.me() } catch AppError.unauthorized { }
                return (204, Data())
            },
            { _ in (401, Data()) },
        ])
        #expect(await client.deleteAccount(confirmation: "DELETE") == .committed)
        #expect(fixture.scenario.requests.map(\.path) == ["/api/v1/account", "/api/v1/me"])
        #expect(fixture.scenario.requests.allSatisfy { $0.authorization == "Bearer original.access" })
        #expect(fixture.store.load() == original)
        #expect(fixture.store.saveCount == 0)
    }
}

private func deletionTokens(_ prefix: String, expired: Bool = false) -> TokenPair {
    let expiry = expired ? Date(timeIntervalSince1970: 1) : Date(timeIntervalSince1970: 4_000_000_000)
    return TokenPair(
        accessToken: "\(prefix).access", accessTokenExpiresAt: expiry,
        refreshToken: "\(prefix).refresh", refreshTokenExpiresAt: expiry
    )
}

private final class DeletionRetryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenPair?
    private var saves = 0
    private var deletes = 0
    private let failSave: Bool

    init(tokens: TokenPair, failSave: Bool) {
        self.tokens = tokens
        self.failSave = failSave
    }

    var saveCount: Int { lock.withLock { saves } }
    var deleteCount: Int { lock.withLock { deletes } }
    func load() -> TokenPair? { lock.withLock { tokens } }

    func save(_ tokens: TokenPair) throws {
        try lock.withLock {
            if failSave { throw CocoaError(.fileWriteNoPermission) }
            saves += 1
            self.tokens = tokens
        }
    }

    func delete() { lock.withLock { deletes += 1; tokens = nil } }
}

private final class DeletionRetryScenario: @unchecked Sendable {
    typealias Reply = @Sendable (URLRequest) async throws -> (Int, Data)
    struct Request: Sendable {
        let path: String
        let method: String?
        let authorization: String?
    }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }
    func setReplies(_ replies: [Reply]) { lock.withLock { self.replies = replies } }

    func respond(to request: URLRequest) async throws -> (Int, Data) {
        let reply: Reply? = lock.withLock {
            recorded.append(Request(
                path: request.url?.path ?? "", method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization")
            ))
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else {
            Issue.record("Unexpected request: \(request.url?.path ?? "")")
            throw URLError(.badServerResponse)
        }
        return try await reply(request)
    }
}

private final class DeletionRetryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: DeletionRetryScenario] = [:]

    static func register(_ scenario: DeletionRetryScenario?, host: String) {
        lock.withLock { scenarios[host] = scenario }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scenario = Self.lock.withLock { Self.scenarios[request.url?.host ?? ""] }
        Task {
            do {
                guard let scenario, let url = request.url else { throw URLError(.badURL) }
                let (status, body) = try await scenario.respond(to: request)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() { }
}

private final class DeletionRetryFixture: @unchecked Sendable {
    let store: DeletionRetryTokenStore
    let scenario = DeletionRetryScenario()
    private let host = UUID().uuidString.lowercased() + ".invalid"
    private let session: URLSession

    init(tokens: TokenPair, failSave: Bool = false) {
        store = DeletionRetryTokenStore(tokens: tokens, failSave: failSave)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionRetryURLProtocol.self]
        session = URLSession(configuration: configuration)
        DeletionRetryURLProtocol.register(scenario, host: host)
    }

    func client() async throws -> APIClient {
        let client = APIClient(baseURL: URL(string: "https://\(host)")!, session: session, keychain: store)
        #expect(try await client.restoreTokens())
        return client
    }

    func close() {
        session.invalidateAndCancel()
        DeletionRetryURLProtocol.register(nil, host: host)
    }
}
