import Foundation
import Testing
@testable import Pomodorough

/// R54-AP03: sign-out quiescence disarms the timer completion deadline and
/// centralized streams under the sign-out fence. When sign-out fails and the
/// fence is released, the retained workspace must rearm its completion
/// deadline and restart eligible centralized streams. A successful sign-out
/// to a fresh workspace must not rearm the departed workspace's timer (the
/// retained Iroh room timer is R54-AP05 below), and a quarantined snapshot
/// stays fail-closed. Completion sleeps go through an injected
/// gate and alarms through a recording scheduler, so nothing plays sound.
@Suite("R54-AP03 failed sign-out restores timer completion", .serialized, .timeLimit(.minutes(1)))
struct R54AP03SignOutCompletionRecoveryTests {
    @Test @MainActor
    func failedCredentialDetachRearmsRetainedTimerCompletion() async throws {
        try await R54AP03Fixture.run(mode: .offline) { fixture in
            let seeded = try fixture.seedRunningAccount()
            let model = fixture.model(revocationStore: R54AP03FailingDetachStore())
            let armed = try await fixture.restoreArmed(model)
            fixture.clock.elapsed = 20
            model.signOut()
            try await fixture.settleSignOut(model)
            fixture.expectAccountRetained(model)
            #expect(model.errorMessage != nil)
            try await r54ap03Eventually { fixture.sleeper.count > armed }
            #expect(fixture.sleeper.count == armed + 1)
            #expect(fixture.sleeper.durations.last == .seconds(40))
            try await fixture.expectRetainedTimerCompletes(model, seeded: seeded)
        }
    }

    @Test @MainActor
    func failedSignedOutPrecommitRearmsRetainedTimerCompletion() async throws {
        try await R54AP03Fixture.run(mode: .offline) { fixture in
            let seeded = try fixture.seedRunningAccount()
            let model = fixture.model()
            let armed = try await fixture.restoreArmed(model)
            fixture.clock.elapsed = 20
            try fixture.permissions(0o500)
            model.signOut()
            try await fixture.settleSignOut(model)
            try fixture.permissions(0o700)
            fixture.expectAccountRetained(model)
            #expect(model.errorMessage == "Sign-out paused because local data could not be saved.")
            try await r54ap03Eventually { fixture.sleeper.count > armed }
            #expect(fixture.sleeper.count == armed + 1)
            #expect(fixture.sleeper.durations.last == .seconds(40))
            try await fixture.expectRetainedTimerCompletes(model, seeded: seeded)
        }
    }

    // Control: a completed sign-out leaves the departed workspace's timer
    // disarmed; releasing every pending sleep completes nothing.
    @Test @MainActor
    func successfulSignOutKeepsDepartedTimerDisarmed() async throws {
        try await R54AP03Fixture.run(mode: .offline) { fixture in
            _ = try fixture.seedRunningAccount()
            let model = fixture.model()
            let armed = try await fixture.restoreArmed(model)
            fixture.clock.elapsed = 20
            model.signOut()
            try await fixture.settleSignOut(model)
            #expect(model.sessionState == .localOnly)
            #expect(fixture.tokens.tokens == nil)
            #expect(fixture.identity.signOutCount == 1)
            #expect(model.canonicalTimer == nil)
            #expect(fixture.sleeper.count == armed)
            try await fixture.expectNoCompletionAfterDeadline(model)
            let saved = try fixture.savedState()
            #expect(saved.cachedUser == nil)
            #expect(saved.history.isEmpty)
        }
    }

    // Control: detach fails and the account rewrite is uncertain, so the
    // snapshot is quarantined and the retained timer stays disarmed.
    @Test @MainActor
    func quarantinedFailedSignOutKeepsTimerDisarmed() async throws {
        try await R54AP03Fixture.run(mode: .offline) { fixture in
            _ = try fixture.seedRunningAccount()
            let gate = R54AP03SecondWriteGate()
            let store = AtomicDurableFileStore(fileURL: fixture.url, afterReplacement: { try gate.hook() })
            let model = fixture.model(store: store, revocationStore: R54AP03FailingDetachStore())
            let armed = try await fixture.restoreArmed(model)
            fixture.clock.elapsed = 20
            gate.armFailingSecondWrite()
            model.signOut()
            try await fixture.settleSignOut(model)
            #expect(model.snapshotLoadFailure != nil)
            #expect(model.isWorkspaceMutationBlocked)
            #expect(fixture.tokens.tokens != nil)
            #expect(fixture.sleeper.count == armed)
            try await fixture.expectNoCompletionAfterDeadline(model)
        }
    }

    @Test @MainActor
    func failedSignOutRestartsCentralizedStreams() async throws {
        try await R54AP03Fixture.run(mode: .centralized) { fixture in
            _ = try fixture.seedRunningAccount()
            let gate = R54AP03GatedFailingDetachStore()
            defer { gate.release() }
            let model = fixture.model(revocationStore: gate)
            await model.restore()
            try #require(model.isSignedIn)
            model.setSceneActive(true)
            await model.refreshAfterForeground()
            try #require(await TestFixtures.waitForRequest(in: fixture.scenario, path: "/api/v1/stream"))
            model.signOut()
            try await r54ap03Eventually { gate.appendCount > 0 }
            // Barrier: held streams end only when cancelled, so every started
            // stream has stopped once sign-out quiescence reached the client.
            try await r54ap03Eventually { fixture.stoppedStreamCount() == fixture.streamRequestCount() }
            let quiesced = fixture.streamRequestCount()
            gate.release()
            try await fixture.settleSignOut(model)
            fixture.expectAccountRetained(model)
            #expect(await TestFixtures.waitForRequest(
                in: fixture.scenario, path: "/api/v1/stream", count: quiesced + 1, timeout: .seconds(2)
            ))
            #expect(fixture.stoppedStreamCount() == quiesced)
        }
    }
}

/// R54-AP05: an Iroh sign-out keeps the active room and its running timer,
/// but sign-out quiescence cancelled the timer's completion deadline. After
/// a successful sign-out the retained room timer must complete at its
/// deadline, and its OS alarm must not be cancelled. Both room identities
/// are covered: a room that carries the account user, and a room entered
/// signed out whose sign-in staged a bootstrap user.
@Suite("R54-AP05 successful Iroh sign-out keeps the room timer armed", .serialized, .timeLimit(.minutes(1)))
struct R54AP05IrohSignOutRoomTimerTests {
    @Test @MainActor
    func successfulSignOutRearmsAccountRoomTimer() async throws {
        try await R54AP03Fixture.run(mode: .iroh) { fixture in
            let account = try fixture.seedAccount()
            let roomStore = fixture.makeRoomStore()
            let roomID = try fixture.seedRunningRoom(in: roomStore, returnState: account)
            let model = fixture.model(roomStore: roomStore, roomService: R54AP05RoomService())
            let armed = try await fixture.restoreArmed(model)
            let user = try #require(account.cachedUser)
            try #require(roomStore.activeRoomState?.cachedUser?.id == user.id)
            let operations = fixture.alarms.operations.count
            try await fixture.signOutKeepingRoom(model, roomStore: roomStore, roomID: roomID)
            try await r54ap03Eventually { fixture.sleeper.count > armed }
            #expect(fixture.sleeper.count == armed + 1)
            #expect(fixture.sleeper.durations.last == .seconds(40))
            let signedOut = fixture.alarms.operations.dropFirst(operations)
            #expect(!signedOut.contains(.cancel(timerID: R54AP03Fixture.timerID)))
            try await fixture.expectRunningTimerCompletes(model)
        }
    }

    @Test @MainActor
    func successfulSignOutRearmsBootstrapRoomTimer() async throws {
        try await R54AP03Fixture.run(mode: .iroh) { fixture in
            _ = try fixture.seedAccount()
            var signedOut = PersistedTimerState.fresh()
            signedOut.autoStartBreaks = true
            let roomStore = fixture.makeRoomStore()
            let roomID = try fixture.seedRunningRoom(in: roomStore, returnState: signedOut)
            let model = fixture.model(roomStore: roomStore, roomService: R54AP05RoomService())
            let armed = try await fixture.signInArmed(model)
            try await fixture.signOutKeepingRoom(model, roomStore: roomStore, roomID: roomID)
            try await r54ap03Eventually { fixture.sleeper.count > armed }
            #expect(fixture.sleeper.count == armed + 1)
            #expect(fixture.sleeper.durations.last == .seconds(40))
            try await fixture.expectRunningTimerCompletes(model)
        }
    }
}

@MainActor
private final class R54AP03Fixture {
    static let timerID = "r54ap03-running-focus"

    let suiteName = "R54AP03.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54AP03-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "signout-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "signout-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let identity = RecordingGoogleIdentityProvider()
    let alarms = RecordingAlarmScheduler()
    let clock = R54AP03Clock()
    let sleeper = R54AP03SleepGate()
    let secrets = MemoryIrohRoomSecretStore()
    let scenario = "apple-api-coverage-model-local-signout-\(UUID().uuidString)"
    let logout: LogoutDrainingSession
    var url: URL { directory.appendingPathComponent("workspace.json") }
    var roomsURL: URL { directory.appendingPathComponent("iroh-rooms.json") }

    private init(mode: ReplicationMode) throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(mode.rawValue, forKey: "replication-mode-v1")
        logout = LogoutDrainingSession(
            scenario: scenario, obligations: tokens, session: R54AP03HeldStreamProtocol.session(for: scenario)
        )
    }

    // Runs one test body with a fixture it owns and tears the fixture down on
    // every exit path. Releasing the completion sleeps and restoring the
    // directory first lets a parked sign-out finish; LogoutDrainingSession
    // then drains its logout revocation before it invalidates the session.
    static func run(mode: ReplicationMode, _ body: @MainActor (R54AP03Fixture) async throws -> Void) async throws {
        let fixture = try R54AP03Fixture(mode: mode)
        defer { fixture.removeStorage() }
        try await fixture.logout.run(releasingHolds: {
            fixture.sleeper.releaseAll()
            try? fixture.permissions(0o700)
        }) {
            try await body(fixture)
        }
    }

    private func removeStorage() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // Signed-in account workspace with an owned focus timer running since
    // the clock anchor, and automatic breaks on so completion is visible.
    func seedRunningAccount() throws -> PersistedTimerState {
        var state = TestFixtures.syncContractState(includesPendingOperations: false)
        state.autoStartBreaks = true
        state.canonicalTimer = runningTimer(startedBy: state.deviceId)
        state.localTimerOwners[Self.timerID] = state.deviceId
        try write(state)
        return state
    }

    // Signed-in account workspace with automatic breaks on and no timer.
    func seedAccount() throws -> PersistedTimerState {
        var state = TestFixtures.syncContractState(includesPendingOperations: false)
        state.autoStartBreaks = true
        try write(state)
        return state
    }

    // Shares the fixture clock, so room projections and the completion
    // deadline read the same time.
    func makeRoomStore() -> IrohRoomStore {
        let clock = clock
        return IrohRoomStore(fileURL: roomsURL, secretStore: secrets, now: { clock.now })
    }

    // Active Iroh room entered from `returnState`, whose genesis runs a focus
    // timer since the clock anchor with automatic breaks on.
    func seedRunningRoom(in roomStore: IrohRoomStore, returnState: PersistedTimerState) throws -> String {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try roomStore.createRoom(
            roomID: roomID, roomSecret: secret, name: nil, returnState: returnState,
            genesis: IrohGenesis(
                canonicalTimer: runningTimer(startedBy: returnState.deviceId), history: [], tasks: [],
                durationsMs: .defaults, autoStartBreaks: true, hlcWallMs: 0, hlcCounter: 0
            ),
            now: clock.anchor
        )
        return roomID
    }

    private func runningTimer(startedBy deviceID: String) -> CanonicalTimer {
        CanonicalTimer(
            id: Self.timerID, taskId: nil, phase: .focus, status: .running,
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0, anchorAt: clock.anchor,
            startedByDeviceId: deviceID,
            lastIntent: TimerIntent(
                type: .start, commandId: "r54ap03-start", occurredAt: clock.anchor, deviceId: deviceID
            )
        )
    }

    private func write(_ state: PersistedTimerState) throws {
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.resetTimerStateWrites()
    }

    func model(
        store: AtomicDurableFileStore? = nil,
        revocationStore: (any LogoutRevocationStoring)? = nil,
        roomStore: IrohRoomStore? = nil,
        roomService: (any RoomReplicationServing)? = nil
    ) -> AppModel {
        let clock = clock
        let sleeper = sleeper
        var roomServiceFactory: (@MainActor @Sendable (RoomReplicationController.ServiceHandlers) -> any RoomReplicationServing)?
        if let roomService { roomServiceFactory = { _ in roomService } }
        return logout.track(AppModel(
            api: APIClient(session: logout.session, keychain: tokens, logoutRevocationStore: revocationStore),
            defaults: defaults, durableLocalStore: store ?? AtomicDurableFileStore(fileURL: url),
            roomStore: roomStore ?? TestFixtures.emptyIrohRoomStore(in: directory),
            roomServiceFactory: roomServiceFactory,
            alarmScheduler: alarms,
            completionScheduler: TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) }),
            googleIdentityProvider: identity,
            now: { clock.now }, uptime: { clock.elapsed }
        ))
    }

    // Restores the account and returns the completion sleep count once the
    // running timer's deadline is armed and restore has settled.
    func restoreArmed(_ model: AppModel) async throws -> Int {
        await model.restore()
        return try await armedSleepCount(model)
    }

    // Signs in to the signed-out room workspace and returns the completion
    // sleep count once the room timer's deadline is armed.
    func signInArmed(_ model: AppModel) async throws -> Int {
        model.signIn()
        try await r54ap03Eventually { !model.isWorking }
        return try await armedSleepCount(model)
    }

    private func armedSleepCount(_ model: AppModel) async throws -> Int {
        try #require(model.isSignedIn)
        try #require(model.canonicalTimer?.status == .running)
        try await r54ap03Eventually { sleeper.count >= 1 }
        await model.waitForAlarmOperations()
        await r54ap03MainQueueBarrier()
        return sleeper.count
    }

    // Waits for sign-out to give the workspace back. The fence release and
    // any completion rearm run in the job that clears isWorking, so after
    // the barrier the rearmed completion task has parked its sleep.
    func settleSignOut(_ model: AppModel) async throws {
        try await r54ap03Eventually { !model.isWorking }
        await r54ap03MainQueueBarrier()
    }

    func expectAccountRetained(_ model: AppModel) {
        #expect(!model.isWorking)
        #expect(model.isSignedIn)
        #expect(tokens.tokens != nil)
        #expect(identity.signOutCount == 0)
        #expect(model.snapshotLoadFailure == nil)
        #expect(!model.isWorkspaceMutationBlocked)
    }

    // Signs out successfully, then checks that the Iroh room and its running
    // timer stayed while the account identity left.
    func signOutKeepingRoom(_ model: AppModel, roomStore: IrohRoomStore, roomID: String) async throws {
        clock.elapsed = 20
        model.signOut()
        try await settleSignOut(model)
        await model.waitForAlarmOperations()
        #expect(model.sessionState == .localOnly)
        #expect(model.errorMessage == nil)
        #expect(tokens.tokens == nil)
        #expect(identity.signOutCount == 1)
        #expect(model.replicationMode == .iroh)
        #expect(roomStore.activeRoomID == roomID)
        #expect(roomStore.activeRoomState?.cachedUser == nil)
        #expect(roomStore.activeRoomState?.bootstrapUser == nil)
    }

    func expectRetainedTimerCompletes(_ model: AppModel, seeded: PersistedTimerState) async throws {
        try await expectRunningTimerCompletes(model)
        let saved = try savedState()
        #expect(saved.cachedUser?.id == seeded.cachedUser?.id)
        #expect(saved.pendingCommands.contains { $0.timerId == Self.timerID && $0.type == .finish })
    }

    // Passes the deadline and releases every pending sleep, then waits until
    // each released completion task has run its post-sleep job before
    // checking that none of them completed the departed timer.
    func expectNoCompletionAfterDeadline(_ model: AppModel) async throws {
        let completed = model.completedFocusCount
        clock.elapsed = 61
        let resumed = sleeper.resumedCount
        let released = sleeper.releaseAll()
        try #require(released > 0)
        try await r54ap03Eventually { sleeper.resumedCount == resumed + released }
        #expect(model.completedFocusCount == completed)
        let saved = try savedState()
        #expect(saved.pendingCommands.allSatisfy { $0.timerId != Self.timerID })
    }

    // Passes the deadline and releases every pending sleep. Only a rearmed
    // deadline survives cancellation, so completion proves the rearm.
    func expectRunningTimerCompletes(_ model: AppModel) async throws {
        #expect(model.canonicalTimer?.id == Self.timerID)
        #expect(model.canonicalTimer?.status == .running)
        let completed = model.completedFocusCount
        clock.elapsed = 61
        sleeper.releaseAll()
        try await r54ap03Eventually { model.completedFocusCount == completed + 1 }
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.canonicalTimer?.status == .running)
    }

    func streamRequestCount() -> Int {
        TestFixtures.recordedRequests(for: scenario).count { $0.path == "/api/v1/stream" }
    }

    func stoppedStreamCount() -> Int {
        TestFixtures.lifecycleEvents(for: scenario).count { $0 == R54AP03HeldStreamProtocol.stoppedEvent }
    }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: Data(contentsOf: url))
    }

    func permissions(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
    }
}

@MainActor
private final class R54AP03Clock {
    let anchor = Date(timeIntervalSince1970: 1_780_000_000)
    var elapsed: TimeInterval = 0
    var now: Date { anchor.addingTimeInterval(elapsed) }
}

// Completion sleeps park here until released. A cancelled completion task
// still parks, then its post-sleep cancellation check drops it.
@MainActor
private final class R54AP03SleepGate {
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private(set) var durations: [Duration] = []
    private(set) var resumedCount = 0
    var count: Int { durations.count }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            durations.append(duration)
            continuations.append(continuation)
        }
        // The scheduler's cancellation check and completion run in this
        // same main-actor job, so a counted resume has finished both.
        resumedCount += 1
    }

    // Returns how many parked sleeps were resumed.
    @discardableResult
    func releaseAll() -> Int {
        let parked = continuations
        continuations.removeAll()
        for continuation in parked { continuation.resume() }
        return parked.count
    }
}

@MainActor
private func r54ap03Eventually(_ predicate: () -> Bool) async throws {
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate(), ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(predicate())
}

// The main actor runs jobs from the serial main queue in FIFO order, so a
// block enqueued here runs after every main-actor job already enqueued,
// including the first job of any completion task scheduled before it.
@MainActor
private func r54ap03MainQueueBarrier() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

// Holds each revision stream open until the client cancels it, so stream
// starts and cancellations are discrete recorded events with no reconnect
// churn. Other routes fall through to StubURLProtocol.
private final class R54AP03HeldStreamProtocol: URLProtocol, @unchecked Sendable {
    static let stoppedEvent = "r54ap03 stream stopped"
    private static let scenarioHeader = "X-Pomodorough-Test-Scenario"

    // The standard stub session with this protocol ahead of the stub.
    static func session(for scenario: String) -> URLSession {
        let stub = TestFixtures.session(for: scenario)
        let configuration = stub.configuration
        stub.invalidateAndCancel()
        let held: [AnyClass] = [R54AP03HeldStreamProtocol.self]
        configuration.protocolClasses = held + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/v1/stream" && request.value(forHTTPHeaderField: scenarioHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario = request.value(forHTTPHeaderField: Self.scenarioHeader),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              ) else { return }
        _ = StubRequestRecorder.shared.record(request, body: nil, scenario: scenario)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {
        guard let scenario = request.value(forHTTPHeaderField: Self.scenarioHeader) else { return }
        StubRequestRecorder.shared.recordLifecycle(Self.stoppedEvent, scenario: scenario)
    }
}

// Iroh service stand-in with no peers: every call succeeds at once.
private actor R54AP05RoomService: RoomReplicationServing {
    func start(_ context: IrohServiceContext) async throws -> String { "endpoint-ticket" }
    func stop() async {}
    func currentEndpointTicket() async throws -> String { "endpoint-ticket" }
    func syncNow() async {}
    func markConflict(roomID: String?) async {}
    func join(invite: IrohRoomInvite) async throws {}
}

private struct R54AP03FailingDetachStore: LogoutRevocationStoring, Sendable {
    struct DetachFailure: Error {}
    func load() throws -> [LogoutRevocationObligation] { [] }
    func append(_ obligation: LogoutRevocationObligation) throws { throw DetachFailure() }
    func replace(_ obligation: LogoutRevocationObligation) throws {}
    func remove(id: UUID) throws {}
}

// Parks the credential detach until released, then fails it, so the test
// can observe the quiesced streams before sign-out gives the workspace back.
private final class R54AP03GatedFailingDetachStore: LogoutRevocationStoring, @unchecked Sendable {
    struct DetachFailure: Error {}
    private let lock = NSLock()
    private var appends = 0
    private var released = false
    var appendCount: Int { lock.withLock { appends } }
    func load() throws -> [LogoutRevocationObligation] { [] }
    func append(_ obligation: LogoutRevocationObligation) throws {
        lock.withLock { appends += 1 }
        while !lock.withLock({ released }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw DetachFailure()
    }
    func replace(_ obligation: LogoutRevocationObligation) throws {}
    func remove(id: UUID) throws {}
    func release() { lock.withLock { released = true } }
}

// Lets the signed-out precommit write land, then fails the account rewrite
// after replacement so the outcome is uncertain and quarantines.
private final class R54AP03SecondWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var failFromWrite: Int?

    func armFailingSecondWrite() { lock.withLock { failFromWrite = writes + 2 } }

    func hook() throws {
        let (count, gate) = lock.withLock {
            writes += 1
            return (writes, failFromWrite)
        }
        if let gate, count >= gate { throw POSIXError(.EIO) }
    }
}
