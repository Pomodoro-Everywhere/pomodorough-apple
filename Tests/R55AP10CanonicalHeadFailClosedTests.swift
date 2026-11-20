import Foundation
import Testing
@testable import Pomodorough

/// One sync response tail written as raw JSON text: the server clock wall and
/// the canonical pair members, so float and exponent spellings reach the app.
struct CanonicalSyncTail: Sendable, CustomTestStringConvertible {
    let name: String
    let serverWall: String
    let pair: String

    var testDescription: String { name }

    static let serverWallMs: Int64 = 1_784_620_800_000
    static let installedHead = CoreHLC(wallMs: serverWallMs - 1_000, counter: 3)

    static let integerPair = CanonicalSyncTail(
        name: "integer pair", serverWall: "\(serverWallMs)",
        pair: #""canonicalHlcWallMs":\#(installedHead.wallMs),"canonicalHlcCounter":3"#
    )
    /// Today's fail-closed baseline: a malformed server clock and no pair.
    static let quotedServerClock = CanonicalSyncTail(
        name: "quoted serverHlcWallMs", serverWall: #""\#(serverWallMs)""#, pair: ""
    )
    static let rejected: [CanonicalSyncTail] = [
        tail("float wall 5.0", wall: "5.0", counter: "0"),
        tail("float wall 1.0", wall: "1.0", counter: "0"),
        tail("float counter 0.0", wall: "5", counter: "0.0"),
        tail("exponent counter 1e0", wall: "5", counter: "1e0"),
        tail("exponent wall 1E3", wall: "1E3", counter: "0"),
        tail("negative zero wall", wall: "-0", counter: "0"),
        tail("null in both fields", wall: "null", counter: "null"),
        tail("quoted counter", wall: "5", counter: #""0""#)
    ]

    private static func tail(_ name: String, wall: String, counter: String) -> CanonicalSyncTail {
        CanonicalSyncTail(
            name: name, serverWall: "\(serverWallMs)",
            pair: #""canonicalHlcWallMs":\#(wall),"canonicalHlcCounter":\#(counter)"#
        )
    }
}

/// R55-AP10 rework: a pair spelled as anything but a plain integer literal is
/// rejected with the whole response, exactly like a malformed `serverHlc*`
/// today. Nothing from the response is written: the queue, the stored head and
/// the revision stay as they were, and the user sees the same outcome.
@Suite("R55-AP10 canonical head fail-closed sync")
@MainActor
struct R55AP10CanonicalHeadFailClosedTests {
    @Test func integerPairIsInstalledAndAcknowledgesTheQueue() async throws {
        let outcome = try await R55AP10SyncFixture.run(.integerPair)
        #expect(outcome.state.canonicalHeadWallMs == CanonicalSyncTail.installedHead.wallMs)
        #expect(outcome.state.canonicalHeadCounter == CanonicalSyncTail.installedHead.counter)
        #expect(outcome.state.pendingCommands.isEmpty)
        #expect(outcome.state.pendingTaskOperations.isEmpty)
        #expect(outcome.state.revision == 1)
        #expect(!outcome.isOffline)
    }

    @Test func rejectedSpellingsFailLikeAMalformedServerClock() async throws {
        let baseline = try await R55AP10SyncFixture.run(.quotedServerClock)
        baseline.expectNothingWritten()
        #expect(baseline.errorMessage != nil || baseline.isOffline)
        for tail in CanonicalSyncTail.rejected {
            let outcome = try await R55AP10SyncFixture.run(tail)
            outcome.expectNothingWritten(tail.name)
            #expect(outcome.errorMessage == baseline.errorMessage, "\(tail.name)")
            #expect(outcome.isOffline == baseline.isOffline, "\(tail.name)")
        }
    }
}

struct R55AP10SyncOutcome {
    let seed: PersistedTimerState
    let state: PersistedTimerState
    let errorMessage: String?
    let isOffline: Bool

    func expectNothingWritten(_ name: String = "baseline") {
        #expect(state.pendingCommands == seed.pendingCommands, "\(name)")
        #expect(state.pendingTaskOperations == seed.pendingTaskOperations, "\(name)")
        #expect(state.pendingDurationOperations == seed.pendingDurationOperations, "\(name)")
        #expect(state.pendingAutoStartOperations == seed.pendingAutoStartOperations, "\(name)")
        #expect(state.pendingSelectedTaskOperations == seed.pendingSelectedTaskOperations, "\(name)")
        #expect(state.canonicalHeadWallMs == seed.canonicalHeadWallMs, "\(name)")
        #expect(state.canonicalHeadCounter == seed.canonicalHeadCounter, "\(name)")
        #expect(state.revision == seed.revision, "\(name)")
        #expect(state.hlcWallMs == seed.hlcWallMs, "\(name)")
    }
}

/// Restores an `AppModel` over a seeded queue; its first sync gets one canned
/// response built from `tail`, acknowledging every queued operation.
@MainActor
enum R55AP10SyncFixture {
    static func run(_ tail: CanonicalSyncTail) async throws -> R55AP10SyncOutcome {
        let scenario = UUID().uuidString
        let suite = "R55AP10.\(scenario)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(scenario)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let session = R55AP10SyncProtocol.session(scenario: scenario, tail: tail)
        defer {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            R55AP10SyncProtocol.remove(scenario)
        }
        let store = AtomicDurableFileStore(fileURL: directory.appendingPathComponent("workspace.json"))
        var seed = R48AP05BatchPlanTests().mixedState(count: 1)
        seed.cachedUser = TestFixtures.user
        try store.write(JSONEncoder.api.encode(seed))
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()), defaults: defaults,
            durableLocalStore: store, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
            now: { Date(timeIntervalSince1970: 1_710_100_000) }, uptime: { 100 }
        )
        await model.restore()
        try #require(R55AP10SyncProtocol.syncCount(scenario) == 1)
        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: #require(try store.read()))
        return R55AP10SyncOutcome(
            seed: seed, state: state, errorMessage: model.errorMessage, isOffline: model.isOffline
        )
    }
}

private final class R55AP10SyncProtocol: URLProtocol, @unchecked Sendable {
    private static let header = "X-R55-AP10-Sync"
    private static let tails = LockedTestValue<[String: CanonicalSyncTail]>([:])
    private static let syncs = LockedTestValue<[String: Int]>([:])
    private static let lock = NSLock()

    static func session(scenario: String, tail: CanonicalSyncTail) -> URLSession {
        lock.withLock { tails.value[scenario] = tail }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R55AP10SyncProtocol.self]
        configuration.httpAdditionalHeaders = [header: scenario]
        return URLSession(configuration: configuration)
    }

    static func syncCount(_ scenario: String) -> Int { lock.withLock { syncs.value[scenario] ?? 0 } }

    static func remove(_ scenario: String) {
        lock.withLock {
            tails.value[scenario] = nil
            syncs.value[scenario] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: header) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if request.url?.path == "/api/v1/me" {
            respond(R48AP04StubProtocol.meBody)
            return
        }
        let scenario = request.value(forHTTPHeaderField: Self.header) ?? ""
        guard request.url?.path == "/api/v1/sync", let wire = Self.requestBody(request),
              let tail = Self.lock.withLock({ Self.tails.value[scenario] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.syncs.value[scenario, default: 0] += 1 }
        do { respond(try Self.response(acknowledging: wire, tail: tail)) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func respond(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
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

    /// Serializes the plain fields, then splices the raw clock and pair text
    /// before the closing brace so their spelling reaches the client unchanged.
    private static func response(acknowledging wire: Data, tail: CanonicalSyncTail) throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        var response: [String: Any] = [
            "revision": 1, "canonicalTimer": NSNull(), "history": [], "tasks": [],
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false, "selectedTaskId": NSNull(),
            "serverTime": "2026-07-21T08:00:00.000Z"
        ]
        let keys = ["acknowledgements", "taskAcknowledgements", "durationAcknowledgements",
                    "autoStartAcknowledgements", "selectedTaskAcknowledgements"]
        for (domain, key) in zip(SyncBatchDomain.allCases, keys) {
            response[key] = (request[domain.rawValue] as? [[String: Any]] ?? []).map {
                [domain == .commands ? "commandId" : "operationId": $0["id"]!,
                 "outcome": "applied", "reason": ""]
            }
        }
        let plain = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        var raw = #""serverHlcWallMs":\#(tail.serverWall),"serverHlcCounter":4"#
        if !tail.pair.isEmpty { raw += "," + tail.pair }
        return Data((plain.dropLast() + "," + raw + "}").utf8)
    }
}
