import Foundation
import Testing
@testable import Pomodorough

/// R55-AP10: install the canonical HLC head by the receiver rule.
///
/// The sync response's `serverHlc*` covers the server's physical clock, so a
/// Start queued while a sync was in flight is older than it. The canonical
/// pair covers only operations the server ordered, so the Start stays newer
/// than the head and stays on screen.
@Suite("R55-AP10 canonical head receiver rule")
@MainActor
struct R55AP10CanonicalHeadTests {
    private static let pressedAt = Date(timeIntervalSince1970: 1_784_620_800)

    // Depends on R55-C14: Core's reconcile projectionPending must read the
    // canonical pair too, or validateProjectionEquivalence rejects the
    // response. Core v0.56.0 and older ignore the pair, so the test runs only
    // once the lead bundles a Core release that implements the contract.
    @Test(.enabled(if: BundledCoreRelease.readsCanonicalPair, "Depends on R55-C14 (Core v0.57.0 or later)"))
    func startQueuedDuringSyncStaysProjectedWhenCanonicalHeadIsOlder() throws {
        let fixture = try InFlightStartFixture()
        let canonical = CoreHLC(wallMs: fixture.start.hlcWallMs - 2_000, counter: 0)
        let reconciled = try fixture.reconcile(canonical: canonical)

        #expect(reconciled.canonicalHeadWallMs == canonical.wallMs)
        #expect(reconciled.canonicalHeadCounter == canonical.counter)
        #expect(reconciled.safeProjectionCommands() == [fixture.start])
        let timer = try #require(try fixture.projectedTimer(reconciled))
        #expect(timer.id == fixture.start.timerId)
        #expect(timer.phase == .focus)
        #expect(timer.status == .running)
    }

    /// The client half of the user's case, without Core reconcile: the head
    /// chosen from the response keeps the queued Start on screen.
    @Test func headChosenFromResponseKeepsQueuedStartProjected() throws {
        let fixture = try InFlightStartFixture()
        let canonical = CoreHLC(wallMs: fixture.start.hlcWallMs - 2_000, counter: 3)
        let response = CoreReconcileCanonicalResponse(try fixture.syncResponse(canonical: canonical))
        var installed = fixture.state
        installed.storeCanonicalHead(response.canonicalHead)

        #expect(installed.canonicalHeadWallMs == canonical.wallMs)
        #expect(installed.canonicalHeadCounter == canonical.counter)
        #expect(installed.safeProjectionCommands() == [fixture.start])
        let timer = try #require(try fixture.projectedTimer(installed))
        #expect(timer.id == fixture.start.timerId)
        #expect(timer.status == .running)
    }

    @Test func startStaysHiddenWhenCanonicalHeadCoversAnotherDevicesLaterOperation() throws {
        let fixture = try InFlightStartFixture()
        let canonical = CoreHLC(wallMs: fixture.start.hlcWallMs + 200, counter: 0)
        let reconciled = try fixture.reconcile(canonical: canonical)

        #expect(reconciled.canonicalHeadWallMs == canonical.wallMs)
        #expect(reconciled.canonicalHeadCounter == canonical.counter)
        #expect(reconciled.safeProjectionCommands().isEmpty)
        #expect(try fixture.projectedTimer(reconciled) == nil)
    }

    @Test func olderServerWithoutPairKeepsServerClockAsHead() throws {
        let fixture = try InFlightStartFixture()
        let reconciled = try fixture.reconcile(canonical: nil)

        #expect(reconciled.canonicalHeadWallMs == fixture.serverHlc.wallMs)
        #expect(reconciled.canonicalHeadCounter == fixture.serverHlc.counter)
        #expect(reconciled.safeProjectionCommands().isEmpty)
        #expect(try fixture.projectedTimer(reconciled) == nil)
    }

    /// The whole pair is installed, counter included, through the real sync reconcile.
    @Test func reconciledHeadKeepsTheCanonicalCounter() throws {
        let fixture = try InFlightStartFixture(queuesStart: false)
        let canonical = CoreHLC(wallMs: fixture.serverHlc.wallMs - 1_000, counter: 7)
        let reconciled = try fixture.reconcile(canonical: canonical)

        #expect(reconciled.canonicalHeadWallMs == canonical.wallMs)
        #expect(reconciled.canonicalHeadCounter == canonical.counter)
    }

    /// The server clock runs ahead of both the local clock and the physical time
    /// the response carries, and the pair is older than all of them. Only a merge
    /// that reads `serverHlc*` can move the local clock up to the server wall.
    @Test func clockMergeReadsServerClockNotCanonicalPair() throws {
        let fixture = try InFlightStartFixture(queuesStart: false, serverLeadMs: 3_000)
        let canonical = CoreHLC(wallMs: fixture.start.hlcWallMs - 2_000, counter: 0)
        #expect(fixture.state.hlcWallMs < fixture.serverHlc.wallMs)
        let reconciled = try fixture.reconcile(canonical: canonical)

        #expect(reconciled.hlcWallMs == fixture.serverHlc.wallMs)
        #expect(reconciled.hlcCounter >= fixture.serverHlc.counter)
        #expect(reconciled.canonicalHeadWallMs == canonical.wallMs)
    }

    @Test func emptyWorkspaceInstallsZeroHeadAndStateStaysValid() throws {
        let fixture = try InFlightStartFixture(queuesStart: false)
        let reconciled = try fixture.reconcile(canonical: CoreHLC(wallMs: 0, counter: 0))

        #expect(reconciled.canonicalHeadWallMs == 0)
        #expect(reconciled.canonicalHeadCounter == 0)
        #expect(reconciled.hasValidPendingWireOperations)
        let restored = try JSONDecoder.api.decode(
            PersistedTimerState.self, from: JSONEncoder.api.encode(reconciled)
        )
        #expect(restored.canonicalHeadWallMs == 0)
        #expect(restored.hasValidPendingWireOperations)
    }

    @Test func coreRequestCarriesPairOnlyWhenServerSentIt() throws {
        let fixture = try InFlightStartFixture(queuesStart: false)
        let canonical = CoreHLC(wallMs: 1_784_620_799_000, counter: 3)
        let withPair = CoreReconcileCanonicalResponse(try fixture.syncResponse(canonical: canonical))
        let withoutPair = CoreReconcileCanonicalResponse(try fixture.syncResponse(canonical: nil))

        #expect(withPair.canonicalHead == canonical)
        #expect(withoutPair.canonicalHead == fixture.serverHlc)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(withPair)) as? [String: Any]
        )
        #expect(encoded["canonicalHlcWallMs"] as? Int64 == canonical.wallMs)
        #expect(encoded["canonicalHlcCounter"] as? Int64 == canonical.counter)
        #expect(encoded["serverHlcWallMs"] as? Int64 == fixture.serverHlc.wallMs)
        let legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(withoutPair)) as? [String: Any]
        )
        #expect(legacy["canonicalHlcWallMs"] == nil)
        #expect(legacy["canonicalHlcCounter"] == nil)
    }
}

@Suite("R55-AP10 canonical head fail-closed decoding")
struct R55AP10CanonicalHeadDecodingTests {
    static let serverWall: Int64 = 1_784_620_800_500
    static let serverCounter: Int64 = 4

    /// Each case is the raw JSON text of the pair members; an absent key is left
    /// out. Raw text keeps spellings such as `5.0` that `JSONSerialization` loses.
    static var malformedPairs: [(String, String)] { [
        ("wall only", #""canonicalHlcWallMs":\#(serverWall)"#),
        ("counter only", #""canonicalHlcCounter":0"#),
        ("wall above server", pair("\(serverWall + 1)", "0")),
        ("counter above server", pair("\(serverWall)", "\(serverCounter + 1)")),
        ("negative wall", pair("-1", "0")),
        ("negative counter", pair("1", "-1")),
        ("fractional wall", pair("1.5", "0")),
        ("string counter", pair("1", #""0""#)),
        ("null wall", pair("null", "0")),
        ("null counter", pair("1", "null")),
        ("null in both fields", pair("null", "null")),
        ("unsafe wall", pair("\(WireBounds.maxSafeInteger + 1)", "0")),
        ("unsafe counter", pair("1", "\(WireBounds.maxSafeInteger + 1)")),
        ("float wall 5.0", pair("5.0", "0")),
        ("exponent counter 1e0", pair("5", "1e0")),
        ("negative zero wall", pair("-0", "0")),
        ("float counter 1.0", pair("5", "1.0")),
        ("float wall 0.0", pair("0.0", "0")),
        ("exponent wall 1E3", pair("1E3", "0"))
    ] }

    static let malformedPairCount = 19

    @Test(arguments: 0..<malformedPairCount)
    func syncResponseRejectsMalformedPair(index: Int) throws {
        let body = try Self.body(raw: Self.malformedPairs[index].1)
        #expect(throws: DecodingError.self, "\(Self.malformedPairs[index].0)") {
            try JSONDecoder.apiResponse(SyncResponse.self, from: body)
        }
    }

    @Test(arguments: 0..<malformedPairCount)
    func bootstrapResponseRejectsMalformedPair(index: Int) throws {
        let body = try Self.body(raw: Self.malformedPairs[index].1)
        #expect(throws: DecodingError.self, "\(Self.malformedPairs[index].0)") {
            try JSONDecoder.apiResponse(BootstrapResponse.self, from: body)
        }
    }

    @Test func pairEqualToServerClockIsAccepted() throws {
        let pair: [String: Any] = ["canonicalHlcWallMs": Self.serverWall, "canonicalHlcCounter": Self.serverCounter]
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body(pair))
        let bootstrap = try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body(pair))
        let expected = CoreHLC(wallMs: Self.serverWall, counter: Self.serverCounter)
        #expect(sync.canonicalHlc == expected)
        #expect(bootstrap.canonicalHlc == expected)
    }

    /// A bootstrap resolution installs its head through the same Core request.
    @Test func bootstrapPairBecomesCanonicalHead() throws {
        let pair: [String: Any] = ["canonicalHlcWallMs": Self.serverWall - 1_000, "canonicalHlcCounter": 2]
        let withPair = try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body(pair))
        let withoutPair = try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body([:]))

        #expect(CoreReconcileCanonicalResponse(withPair).canonicalHead
                == CoreHLC(wallMs: Self.serverWall - 1_000, counter: 2))
        #expect(CoreReconcileCanonicalResponse(withoutPair).canonicalHead
                == CoreHLC(wallMs: Self.serverWall, counter: Self.serverCounter))
    }

    @Test func malformedPairTableCountMatchesArguments() {
        #expect(Self.malformedPairs.count == Self.malformedPairCount)
    }

    @Test func absentPairDecodesAsOlderServer() throws {
        let sync = try JSONDecoder.apiResponse(SyncResponse.self, from: Self.body([:]))
        let bootstrap = try JSONDecoder.apiResponse(BootstrapResponse.self, from: Self.body([:]))
        #expect(sync.canonicalHlc == nil)
        #expect(bootstrap.canonicalHlc == nil)
        #expect(CoreReconcileCanonicalResponse(sync).canonicalHead
                == CoreHLC(wallMs: Self.serverWall, counter: Self.serverCounter))
    }

    static func pair(_ wall: String, _ counter: String) -> String {
        #""canonicalHlcWallMs":\#(wall),"canonicalHlcCounter":\#(counter)"#
    }

    /// The plain response with `raw` member text spliced in before the closing brace.
    static func body(raw: String) throws -> Data {
        let plain = String(decoding: try body([:]), as: UTF8.self)
        return Data((plain.dropLast() + "," + raw + "}").utf8)
    }

    static func body(_ pair: [String: Any]) throws -> Data {
        var response: [String: Any] = [
            "acknowledgements": [], "taskAcknowledgements": [], "durationAcknowledgements": [],
            "autoStartAcknowledgements": [], "selectedTaskAcknowledgements": [],
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false, "selectedTaskId": NSNull(), "revision": 1,
            "canonicalTimer": NSNull(), "history": [], "tasks": [],
            "serverTime": "2026-07-21T08:00:00.500Z",
            "serverHlcWallMs": serverWall, "serverHlcCounter": serverCounter
        ]
        response.merge(pair) { _, new in new }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

/// A never-sent Start queued after the in-flight request left; its response
/// carries a server clock 500 ms newer than the Start.
@MainActor
private struct InFlightStartFixture {
    let state: PersistedTimerState
    let start: TimerCommand
    let serverHlc: CoreHLC
    let controller: TimerSessionController

    init(queuesStart: Bool = true, serverLeadMs: Int64 = 500) throws {
        let pressedAt = R55AP10CanonicalHeadTests.pressedAtDate
        let controller = TimerSessionController(sharedCoreProvider: { try SharedCore.bundled() })
        self.controller = controller
        var fresh = PersistedTimerState.fresh()
        fresh.cachedUser = TestFixtures.user
        let transition = try controller.makeCommand(.init(
            type: .start, timerID: "timer-\(UUID().uuidString.lowercased())", taskID: nil,
            phase: .focus, duration: 1_500, elapsed: 0, occurredAt: pressedAt, localDate: pressedAt
        ), state: fresh)
        start = transition.command
        if queuesStart {
            state = transition.state
        } else {
            var clockOnly = transition.state
            clockOnly.pendingCommands = []
            clockOnly.pruneNeverSentProofToPending()
            clockOnly.localTimerOwners = [:]
            clockOnly.localCommandDates = [:]
            state = clockOnly
        }
        serverHlc = CoreHLC(wallMs: start.hlcWallMs + serverLeadMs, counter: 0)
    }

    func syncResponse(canonical: CoreHLC?) throws -> SyncResponse {
        var pair: [String: Any] = [:]
        if let canonical {
            pair = ["canonicalHlcWallMs": canonical.wallMs, "canonicalHlcCounter": canonical.counter]
        }
        var response: [String: Any] = [
            "acknowledgements": [], "taskAcknowledgements": [], "durationAcknowledgements": [],
            "autoStartAcknowledgements": [], "selectedTaskAcknowledgements": [],
            "durationsMs": try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state.canonicalDurations())),
            "autoStartBreaks": state.autoStartBreaks, "selectedTaskId": NSNull(),
            "revision": state.revision + 1, "canonicalTimer": NSNull(), "history": [], "tasks": [],
            "serverTime": APIDateCodec.string(from: R55AP10CanonicalHeadTests.pressedAtDate.addingTimeInterval(0.5)) ?? "",
            "serverHlcWallMs": serverHlc.wallMs, "serverHlcCounter": serverHlc.counter
        ]
        response.merge(pair) { _, new in new }
        return try JSONDecoder.apiResponse(SyncResponse.self, from: JSONSerialization.data(withJSONObject: response))
    }

    func reconcile(canonical: CoreHLC?) throws -> PersistedTimerState {
        let synchronization = AccountSynchronization(
            api: APIClient(session: .shared, keychain: EmptyTokenStore()),
            sharedCoreProvider: { try SharedCore.bundled() }
        )
        let empty = AccountSynchronization.SyncBatch(
            commands: [], taskOperations: [], durationOperations: [],
            autoStartOperations: [], selectedTaskOperations: []
        )
        // The in-flight request left before the Start was queued, so it carried nothing.
        let plan = AccountSynchronization.SyncPlan(
            batch: empty,
            request: SyncRequest(
                deviceId: state.deviceId, lastRevision: state.revision, commands: [],
                taskOperations: [], durationOperations: [], autoStartOperations: []
            ),
            legacyDependencyReviewRequired: false
        )
        let sampled = TimedHTTPResponse(
            value: try syncResponse(canonical: canonical),
            requestWall: R55AP10CanonicalHeadTests.pressedAtDate,
            requestUptime: 1_000,
            responseUptime: 1_000.5
        )
        return try synchronization.reconcileSync(sampled, plan: plan, state: state).state
    }

    func projectedTimer(_ reconciled: PersistedTimerState) throws -> CanonicalTimer? {
        let now = R55AP10CanonicalHeadTests.pressedAtDate.addingTimeInterval(1)
        return try controller.project(
            reconciled, now: now, replicationMode: .centralized, physicalNow: now
        ).canonicalTimer
    }
}

extension R55AP10CanonicalHeadTests {
    static var pressedAtDate: Date { pressedAt }
}

/// Reads the bundled Core release tag (for example `v0.56.0`).
enum BundledCoreRelease {
    struct Version: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    static let firstReadingCanonicalPair = Version(major: 0, minor: 57, patch: 0)

    static var tag: String {
        String(WorkspaceIntentProvenance.current().split(separator: "/").first ?? "")
    }

    static var readsCanonicalPair: Bool { readsCanonicalPair(tag: tag) }

    /// A pre-release of 0.57.0 (`v0.57.0-rc1`) counts as 0.57.0: release
    /// candidates are cut from the branch that already carries R55-C14.
    static func readsCanonicalPair(tag: String) -> Bool {
        guard let version = version(of: tag) else { return false }
        return version >= firstReadingCanonicalPair
    }

    /// Parses `v<major>.<minor>.<patch>` with an optional `-pre-release` or
    /// `+build` suffix; anything else is `nil`.
    static func version(of tag: String) -> Version? {
        let core = tag.drop { $0 == "v" }.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            !part.isEmpty && part.allSatisfy({ ("0"..."9").contains($0) }) ? Int(part) : nil
        }
        guard parts.count == 3, numbers.count == 3 else { return nil }
        return Version(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }
}

/// Lows of the first verdict: the widened stored-head range still has bounds,
/// and the Core gate reads a parsed version.
@Suite("R55-AP10 stored head bounds and Core gate")
struct R55AP10StoredHeadAndGateTests {
    struct StoredHead: Sendable, CustomTestStringConvertible {
        let name: String
        let wall: Int64?
        let counter: Int64?
        var testDescription: String { name }
    }

    nonisolated static let invalidStoredHeads: [StoredHead] = [
        .init(name: "negative wall", wall: -1, counter: 0),
        .init(name: "negative counter", wall: 0, counter: -1),
        .init(name: "2^53 wall", wall: WireBounds.maxSafeInteger + 1, counter: 0),
        .init(name: "2^53 counter", wall: 0, counter: WireBounds.maxSafeInteger + 1),
        .init(name: "wall without counter", wall: 5, counter: nil),
        .init(name: "counter without wall", wall: nil, counter: 5)
    ]

    @Test(arguments: invalidStoredHeads)
    func invalidStoredHeadIsStillRejected(_ head: StoredHead) {
        var state = PersistedTimerState.fresh()
        state.canonicalHeadWallMs = head.wall
        state.canonicalHeadCounter = head.counter
        #expect(!state.hasValidPendingWireOperations)
        #expect(!state.hasValidPendingWireOperationsForResample)
    }

    @Test func storedHeadBoundsAreInclusive() {
        for head in [(Int64(0), Int64(0)), (WireBounds.maxSafeInteger, WireBounds.maxSafeInteger)] {
            var state = PersistedTimerState.fresh()
            state.canonicalHeadWallMs = head.0
            state.canonicalHeadCounter = head.1
            #expect(state.hasValidPendingWireOperations, "\(head)")
        }
    }

    @Test(arguments: [
        ("v0.56.0", false), ("v0.56.9-rc1", false), ("v0.57.0", true), ("v0.57.0-rc1", true),
        ("v0.57.0+build.5", true), ("v0.57.1", true), ("v0.100.0", true), ("v1.0.0", true),
        ("0.57.0", true), ("v0.57", false), ("v0.57.0.1", false), ("v0..57", false), ("", false)
    ])
    func coreGateComparesParsedVersion(tag: String, reads: Bool) {
        #expect(BundledCoreRelease.readsCanonicalPair(tag: tag) == reads)
    }

    /// An unreadable bundled tag would silently skip the user's-case test, so it fails here.
    @Test func bundledCoreTagParses() {
        #expect(BundledCoreRelease.version(of: BundledCoreRelease.tag) != nil, "\(BundledCoreRelease.tag)")
    }
}
