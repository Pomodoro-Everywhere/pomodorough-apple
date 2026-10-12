import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP05 durable transport")
struct R48AP05TransportTests {
    @Test @MainActor
    func lostResponseReopenReplaysExactWireAndClearsClaimOnlyAfterCommit() async throws {
        let fixture = try R48AP05TransportFixture()
        defer { fixture.cleanUp() }
        var seed = R48AP05BatchPlanTests().mixedState(count: 3)
        seed.pendingSelectedTaskOperations.removeLast()
        seed.pruneNeverSentProofToPending()
        seed.cachedUser = TestFixtures.user
        try fixture.store.write(JSONEncoder.api.encode(seed))
        let first = fixture.model()
        await first.restore()
        #expect(first.isOffline)
        let saved = try fixture.readState()
        let claim = try #require(saved.outgoingSyncClaim)
        #expect(saved.syncBatchCursor != seed.syncBatchCursor)
        #expect(saved.neverSentCommandIDs.isEmpty)
        #expect(saved.neverSentTaskOperationIDs.isEmpty)
        #expect(saved.neverSentDurationOperationIDs.isEmpty)
        #expect(saved.neverSentAutoStartOperationIDs.isEmpty)
        #expect(saved.neverSentSelectedTaskOperationIDs.isEmpty)
        let reopened = fixture.model()
        await reopened.restore()
        #expect(!reopened.isOffline)
        let bodies = R48AP05TransportProtocol.bodies.value[fixture.scenario] ?? []
        try #require(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
        let wire = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(wire["lastRevision"] as? Int64 == claim.lastRevision)
        for domain in SyncBatchDomain.allCases {
            #expect((wire[domain.rawValue] as? [[String: Any]])?.count == (domain == .selectedTaskOperations ? 2 : 3))
        }
        let installed = try fixture.readState()
        #expect(installed.outgoingSyncClaim == nil)
        #expect(installed.syncBatchCursor == saved.syncBatchCursor)
        #expect(installed.pendingCommands.isEmpty)
        #expect(installed.pendingTaskOperations.isEmpty)
        #expect(installed.pendingDurationOperations.isEmpty)
        #expect(installed.pendingAutoStartOperations.isEmpty)
        #expect(installed.pendingSelectedTaskOperations.isEmpty)
    }

    @Test @MainActor
    func oversizedRecoveryPersistsBeforeReplanningAndKeepsSentProof() async throws {
        let fixture = try R48AP05TransportFixture()
        defer { fixture.cleanUp() }
        var seed = R48AP05BatchPlanTests().mixedState(count: 0)
        seed.cachedUser = TestFixtures.user
        seed.pendingTaskOperations = R48AP05BatchPlanTests().makeTasks(
            count: 257, baseWallMs: 1_710_000_100_000
        )
        seed.outgoingSyncClaim = R48AP05BatchPlanTests().requestForAll(seed)
        try fixture.store.write(JSONEncoder.api.encode(seed))
        let model = fixture.model()
        await model.restore()
        #expect(await model.sync(force: true) == false)
        #expect(model.hasOversizedSavedSyncClaim)
        #expect(R48AP05TransportProtocol.bodies.value[fixture.scenario] == nil)
        #expect(!model.recoverOversizedSavedSyncClaim(confirmed: false))
        #expect(try fixture.readState().outgoingSyncClaim == seed.outgoingSyncClaim)
        #expect(model.recoverOversizedSavedSyncClaim(confirmed: true))
        let reopened = try fixture.readState()
        #expect(reopened.outgoingSyncClaim == nil)
        #expect(reopened.pendingTaskOperations == seed.pendingTaskOperations)
        #expect(reopened.neverSentTaskOperationIDs.isEmpty)
        #expect(reopened.syncBatchCursor == seed.syncBatchCursor)
        let prepared = try R48AP05BatchPlanTests().makeSync().prepareSyncPlan(state: reopened)
        #expect(prepared.plan.batch.taskOperations.count == 256)
        #expect(prepared.retired.neverSentTaskOperationIDs.isEmpty)
    }

    @Test @MainActor
    func recoveryWriteFailurePreservesExactSavedClaim() async throws {
        let fixture = try R48AP05TransportFixture()
        defer { fixture.cleanUp() }
        var seed = R48AP05BatchPlanTests().mixedState(count: 0)
        seed.pendingTaskOperations = R48AP05BatchPlanTests().makeTasks(
            count: 257, baseWallMs: 1_710_000_100_000
        )
        seed.outgoingSyncClaim = R48AP05BatchPlanTests().requestForAll(seed)
        try fixture.store.write(JSONEncoder.api.encode(seed))
        let model = fixture.model()
        let before = try fixture.store.read()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
        #expect(!model.recoverOversizedSavedSyncClaim(confirmed: true))
        #expect(try fixture.store.read() == before)
        #expect(try fixture.readState().outgoingSyncClaim == seed.outgoingSyncClaim)
    }
}

@MainActor
private struct R48AP05TransportFixture {
    let scenario = UUID().uuidString
    let suite = "R48AP05.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let session: URLSession
    var store: AtomicDurableFileStore { AtomicDurableFileStore(fileURL: directory.appendingPathComponent("workspace.json")) }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R48AP05TransportProtocol.self]
        configuration.httpAdditionalHeaders = ["X-R48AP05": scenario]
        session = URLSession(configuration: configuration)
    }

    func model() -> AppModel {
        AppModel(api: APIClient(session: session, keychain: StaticTokenStore()), defaults: defaults,
                 durableLocalStore: store, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
                 alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
                 now: { Date(timeIntervalSince1970: 1_710_100_000) }, uptime: { 100 })
    }

    func readState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: #require(try store.read()))
    }

    func cleanUp() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class R48AP05TransportProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = LockedTestValue<[String: [Data]]>([:])
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-R48AP05") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        if request.url?.path == "/api/v1/me" {
            respond(R48AP04StubProtocol.meBody)
            return
        }
        guard request.url?.path == "/api/v1/sync", let body = Self.body(request),
              let scenario = request.value(forHTTPHeaderField: "X-R48AP05") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let count = Self.lock.withLock {
            var recorded = Self.bodies.value
            recorded[scenario, default: []].append(body)
            Self.bodies.value = recorded
            return recorded[scenario]?.count ?? 0
        }
        if count == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        do { respond(try Self.response(body)) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func respond(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

    private static func response(_ body: Data) throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var response: [String: Any] = [
            "revision": 1, "canonicalTimer": NSNull(), "history": [], "tasks": [],
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false, "selectedTaskId": NSNull(),
            "serverTime": "2026-07-21T08:00:00.000Z", "serverHlcWallMs": 1_784_620_800_000,
            "serverHlcCounter": 4
        ]
        let keys = ["acknowledgements", "taskAcknowledgements", "durationAcknowledgements",
                    "autoStartAcknowledgements", "selectedTaskAcknowledgements"]
        for (domain, key) in zip(SyncBatchDomain.allCases, keys) {
            response[key] = (request[domain.rawValue] as? [[String: Any]] ?? []).map {
                [domain == .commands ? "commandId" : "operationId": $0["id"]!,
                 "outcome": "applied", "reason": ""]
            }
        }
        return try JSONSerialization.data(withJSONObject: response)
    }
}
