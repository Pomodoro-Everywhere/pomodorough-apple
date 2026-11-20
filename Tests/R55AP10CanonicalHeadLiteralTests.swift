import Foundation
import Testing
@testable import Pomodorough

/// One canonical pair written as raw JSON text; `nil` leaves the key out.
struct CanonicalPairLiteral: Sendable, CustomTestStringConvertible {
    let name: String
    let wall: String?
    let counter: String?

    var testDescription: String { name }
}

/// R55-AP10 rework: the receiver rule must match the R55-C14 Core verifier. A
/// present key counts as present, `null` fails closed, and each value must be a
/// JSON integer literal in 0...2^53-1. The raw text matters here, so bodies are
/// written by hand instead of through `JSONSerialization`.
@Suite("R55-AP10 canonical head literal rule")
struct R55AP10CanonicalHeadLiteralTests {
    static let maxSafe = "9007199254740991"
    static let firstUnsafe = "9007199254740992"

    nonisolated static let rejectedLiterals: [CanonicalPairLiteral] = [
        .init(name: "null wall", wall: "null", counter: "0"),
        .init(name: "null counter", wall: "1", counter: "null"),
        .init(name: "null in both fields", wall: "null", counter: "null"),
        .init(name: "quoted wall", wall: #""5""#, counter: "0"),
        .init(name: "quoted counter", wall: "5", counter: #""0""#),
        .init(name: "float wall 5.0", wall: "5.0", counter: "0"),
        .init(name: "float wall 1.0", wall: "1.0", counter: "0"),
        .init(name: "float counter 0.0", wall: "5", counter: "0.0"),
        .init(name: "exponent counter 1e0", wall: "5", counter: "1e0"),
        .init(name: "exponent wall 1E2", wall: "1E2", counter: "0"),
        .init(name: "exponent counter 1E3", wall: "5", counter: "1E3"),
        .init(name: "negative zero wall", wall: "-0", counter: "0"),
        .init(name: "negative zero counter", wall: "5", counter: "-0"),
        .init(name: "leading zero wall", wall: "05", counter: "0"),
        .init(name: "boolean counter", wall: "5", counter: "true"),
        .init(name: "object wall", wall: "{}", counter: "0"),
        .init(name: "array counter", wall: "5", counter: "[0]"),
        .init(name: "2^53 wall", wall: firstUnsafe, counter: "0"),
        .init(name: "2^53 counter", wall: "5", counter: firstUnsafe),
        .init(name: "wall only", wall: "5", counter: nil),
        .init(name: "null counter only", wall: nil, counter: "null")
    ]

    @Test(arguments: rejectedLiterals)
    func syncResponseRejectsLiteral(_ pair: CanonicalPairLiteral) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(pair))
        }
    }

    @Test(arguments: rejectedLiterals)
    func bootstrapResponseRejectsLiteral(_ pair: CanonicalPairLiteral) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body(pair))
        }
    }

    @Test func largestSafePairIsAcceptedInBothFields() throws {
        let pair = CanonicalPairLiteral(name: "2^53-1", wall: Self.maxSafe, counter: Self.maxSafe)
        let max = CoreHLC(wallMs: WireBounds.maxSafeInteger, counter: WireBounds.maxSafeInteger)
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(pair))
        let bootstrap = try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body(pair))
        #expect(sync.canonicalHlc == max)
        #expect(bootstrap.canonicalHlc == max)
        #expect(CoreReconcileCanonicalResponse(sync).canonicalHead == max)
    }

    /// The decoder also rejects 2^53 and leading zeros, so the literal rule is checked alone here.
    @Test func literalRuleAloneStopsAtLargestSafeInteger() throws {
        let largest = CanonicalPairLiteral(name: "2^53-1", wall: Self.maxSafe, counter: Self.maxSafe)
        try CanonicalHeadLiteralRule.validate(Self.body(largest))
        for pair in [
            CanonicalPairLiteral(name: "2^53 wall", wall: Self.firstUnsafe, counter: "0"),
            CanonicalPairLiteral(name: "2^53 counter", wall: "0", counter: Self.firstUnsafe),
            // JSONDecoder refuses a leading zero too; the rule keeps the JSON grammar on its own.
            CanonicalPairLiteral(name: "leading zero counter", wall: "0", counter: "07")
        ] {
            #expect(throws: DecodingError.self, "\(pair.name)") {
                try CanonicalHeadLiteralRule.validate(Self.body(pair))
            }
        }
    }

    /// Decoding without the literal rule still fails closed: the receiver rule keeps
    /// its own range and presence checks. Each wall is below the server clock, so
    /// the server bound cannot be what rejects these pairs.
    nonisolated static let rejectedByReceiverRule: [CanonicalPairLiteral] = [
        .init(name: "2^53 counter", wall: "5", counter: firstUnsafe),
        .init(name: "negative counter", wall: "5", counter: "-1"),
        .init(name: "negative wall", wall: "-1", counter: "0"),
        .init(name: "null wall", wall: "null", counter: "0"),
        .init(name: "null counter", wall: "5", counter: "null")
    ]

    @Test(arguments: rejectedByReceiverRule)
    func receiverRuleAloneRejectsPair(_ pair: CanonicalPairLiteral) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(SyncResponse.self, from: Self.body(pair))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(BootstrapResponse.self, from: Self.body(pair))
        }
    }

    @Test func zeroPairWithSurroundingWhitespaceIsAccepted() throws {
        let pair = CanonicalPairLiteral(name: "zero", wall: " 0 ", counter: "\n0\t")
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(pair))
        #expect(sync.canonicalHlc == CoreHLC(wallMs: 0, counter: 0))
    }

    /// Only a response with neither key falls back to `serverHlc*`.
    @Test func responseWithNeitherKeyFallsBackToServerClock() throws {
        let pair = CanonicalPairLiteral(name: "absent", wall: nil, counter: nil)
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(pair))
        let bootstrap = try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body(pair))
        let server = CoreHLC(wallMs: WireBounds.maxSafeInteger, counter: WireBounds.maxSafeInteger)
        #expect(sync.canonicalHlc == nil)
        #expect(bootstrap.canonicalHlc == nil)
        #expect(CoreReconcileCanonicalResponse(sync).canonicalHead == server)
    }

    /// Swift reads the first duplicate and serde_json the last, so a repeated
    /// field fails closed even when both spellings are valid.
    @Test func repeatedCanonicalFieldIsRejected() {
        let pair = CanonicalPairLiteral(name: "valid", wall: "5", counter: "0")
        let body = Self.body(pair, extra: #","canonicalHlcWallMs":6"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.apiResponse(SyncResponse.self, from: body)
        }
    }

    /// JSONDecoder resolves a Unicode escape in a member name, so `canonicalHlc\u0057allMs`
    /// (0057 is `W`) names the same field.
    @Test func escapedFieldNameIsCheckedLikeThePlainName() {
        let pair = CanonicalPairLiteral(name: "counter only", wall: nil, counter: "0")
        // The six-character JSON escape: a backslash, `u`, then `0057`.
        let escapedName = "canonicalHlc" + #"\u"# + "0057" + "allMs"
        let body = Self.body(pair, extra: #","\#(escapedName)":5.0"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.apiResponse(SyncResponse.self, from: body)
        }
        let valid = Self.body(pair, extra: #","\#(escapedName)":5"#)
        let sync = try? JSONDecoder.apiResponse(SyncResponse.self, from: valid)
        #expect(sync?.canonicalHlc == CoreHLC(wallMs: 5, counter: 0))
    }

    /// Nested members and string contents that look like the pair are not the pair.
    @Test func nestedAndQuotedLookalikesAreIgnored() throws {
        let pair = CanonicalPairLiteral(name: "valid", wall: "5", counter: "1")
        let extra = #","extension":{"canonicalHlcWallMs":5.0,"list":[{"canonicalHlcCounter":"x"}]}"#
            + #","note":"\"canonicalHlcWallMs\":-0, }""#
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(pair, extra: extra))
        #expect(sync.canonicalHlc == CoreHLC(wallMs: 5, counter: 1))
    }

    /// A brace or bracket inside a string nested in an object or array is text,
    /// not structure: it neither ends the nested value early nor swallows the
    /// top-level pair that follows it.
    @Test func bracesInsideNestedStringsKeepThePairVisible() throws {
        let valid = CanonicalPairLiteral(name: "valid", wall: "5", counter: "1")
        let closing = #","extension":{"note":"\"canonicalHlcWallMs\":5.0 }","list":["]"]}"#
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(valid, extra: closing))
        #expect(sync.canonicalHlc == CoreHLC(wallMs: 5, counter: 1))

        let absent = CanonicalPairLiteral(name: "absent", wall: nil, counter: nil)
        let hidden = #","opening":{"note":"{"},"canonicalHlcWallMs":5.0,"canonicalHlcCounter":0"#
            + #","closing":{"note":"}"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(absent, extra: hidden))
        }
    }

    @Test func truncatedBodyIsRejected() {
        let pair = CanonicalPairLiteral(name: "valid", wall: "5", counter: "1")
        let body = Self.body(pair).dropLast()
        #expect(throws: DecodingError.self) {
            try JSONDecoder.apiResponse(SyncResponse.self, from: Data(body))
        }
    }

    /// A full response whose server clock sits at 2^53-1, so only the literal and
    /// safe-integer checks can reject a pair, never the server bound.
    static func body(_ pair: CanonicalPairLiteral, extra: String = "") -> Data {
        var fields = [
            #""acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[]"#,
            #""autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[]"#,
            #""durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000}"#,
            #""autoStartBreaks":false,"selectedTaskId":null,"revision":1,"canonicalTimer":null"#,
            #""history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.500Z""#,
            #""serverHlcWallMs":\#(maxSafe),"serverHlcCounter":\#(maxSafe)"#
        ]
        if let wall = pair.wall { fields.append(#""canonicalHlcWallMs":\#(wall)"#) }
        if let counter = pair.counter { fields.append(#""canonicalHlcCounter":\#(counter)"#) }
        return Data(("{" + fields.joined(separator: ",") + extra + "}").utf8)
    }
}

/// The literal rule must run on the bodies the API client really decodes.
@Suite("R55-AP10 canonical head literal rule through APIClient")
struct R55AP10CanonicalHeadClientTests {
    /// The six integral spellings `JSONDecoder` would read as integers.
    nonisolated static let integralSpellings: [CanonicalPairLiteral] = [
        .init(name: "5.0", wall: "5.0", counter: "0"),
        .init(name: "1e0", wall: "5", counter: "1e0"),
        .init(name: "-0", wall: "-0", counter: "0"),
        .init(name: "1.0", wall: "5", counter: "1.0"),
        .init(name: "0.0", wall: "0.0", counter: "0"),
        .init(name: "1E3", wall: "1E3", counter: "0")
    ]

    @Test(arguments: CanonicalHeadEndpoint.allCases, integralSpellings)
    func endpointRejectsIntegralSpelling(_ endpoint: CanonicalHeadEndpoint, _ pair: CanonicalPairLiteral) async throws {
        let client = CannedResponseURLProtocol.client(body: R55AP10CanonicalHeadLiteralTests.body(pair))
        try #require(await client.restoreTokens())
        await #expect(throws: AppError.invalidResponse) {
            _ = try await endpoint.canonicalHlc(from: client)
        }
    }

    @Test(arguments: CanonicalHeadEndpoint.allCases)
    func endpointInstallsIntegerPair(_ endpoint: CanonicalHeadEndpoint) async throws {
        let pair = CanonicalPairLiteral(name: "valid", wall: "1000", counter: "2")
        let client = CannedResponseURLProtocol.client(body: R55AP10CanonicalHeadLiteralTests.body(pair))
        try #require(await client.restoreTokens())
        #expect(try await endpoint.canonicalHlc(from: client) == CoreHLC(wallMs: 1_000, counter: 2))
    }

    @Test func bootstrapRejectsNullPair() async throws {
        let pair = CanonicalPairLiteral(name: "null", wall: "null", counter: "null")
        let client = CannedResponseURLProtocol.client(body: R55AP10CanonicalHeadLiteralTests.body(pair))
        try #require(await client.restoreTokens())
        await #expect(throws: AppError.invalidResponse) {
            _ = try await client.bootstrap(Self.emptyRequest)
        }
    }

    static var emptyRequest: SyncRequest {
        SyncRequest(
            deviceId: "r55-ap10-device", lastRevision: 0, commands: [],
            taskOperations: [], durationOperations: [], autoStartOperations: []
        )
    }
}

/// The three API calls whose response carries the canonical pair.
enum CanonicalHeadEndpoint: String, CaseIterable, Sendable {
    case sync, bootstrap, resolveBootstrap

    func canonicalHlc(from client: APIClient) async throws -> CoreHLC? {
        let request = R55AP10CanonicalHeadClientTests.emptyRequest
        switch self {
        case .sync:
            return try await client.sync(request).value.canonicalHlc
        case .bootstrap:
            return try await client.bootstrap(request).value.canonicalHlc
        case .resolveBootstrap:
            let resolve = BootstrapResolveRequest(
                requestId: "r55-ap10-resolve", deviceId: request.deviceId, expectedRevision: 0,
                strategy: .keepRemote, commands: [], taskOperations: [], durationOperations: [],
                autoStartOperations: []
            )
            return try await client.resolveBootstrap(resolve).value.canonicalHlc
        }
    }
}

/// Serves one fixed body to every request of its session. The base URL uses the
/// reserved `.invalid` domain, so nothing can leave the machine.
final class CannedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let header = "X-R55-AP10-Canned-Body"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func client(body: Data) -> APIClient {
        let id = UUID().uuidString
        lock.withLock { bodies[id] = body }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedResponseURLProtocol.self]
        configuration.httpAdditionalHeaders = [header: id]
        return APIClient(
            baseURL: URL(string: "https://r55-ap10.invalid")!,
            session: URLSession(configuration: configuration),
            keychain: StaticTokenStore()
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: header) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        let body = Self.lock.withLock { Self.bodies[id] } ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
