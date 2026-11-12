import Foundation
import IrohLib
import Testing
@testable import Pomodorough

/// R54-AP01: mode and room transitions replace the workspace this device
/// owns, so they must not run while sign-out owns it. New transitions are
/// refused at entry through the sign-out refusal path. Transitions already
/// suspended in the room service when sign-out starts roll back instead of
/// durably creating, joining, leaving, or switching. Every test gates the
/// credential detach after the signed-out precommit and reads the persisted
/// workspace bytes, room file, and mode key while sign-out still owns them.
/// A revoked transition is not an error: the Sentry backend receives only
/// DiagnosticPrivacy descriptions, so the tests require that nothing but the
/// `sign-out stage=` breadcrumb is captured.
@Suite("R54-AP01 sign-out fences workspace ownership changes", .serialized, .timeLimit(.minutes(1)))
struct R54AP01SignOutOwnershipFenceTests {
    @Test @MainActor
    func signOutRefusesModeAndRoomEntry() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let recorded = fixture.recordSentry()
            defer { SentryCapture.resetForTesting() }
            let invite = try fixture.invite()
            let precommit = try await fixture.beginGatedSignOut(model)
            await model.setReplicationMode(.centralized)
            #expect(await model.createIrohRoom(name: "Race room") == false)
            #expect(await model.joinIrohRoom(inviteText: invite) == false)
            try fixture.expectOfflineWorkspaceKept(model, precommit: precommit)
            #expect(fixture.service.startCount == 0)
            #expect(fixture.service.joinCount == 0)
            #expect(model.errorMessage == R54AP01Fixture.refusal)
            #expect(recorded.value.contains(where: { $0.contains("sign-out stage=mutation outcome=refused") }))
            try await fixture.finishSignOut(model)
            #expect(try fixture.savedState().tasks.isEmpty)
            #expect(model.replicationMode == .offline)
        }
    }

    @Test @MainActor
    func signOutRevokesCreateSuspendedInServiceStart() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let recorded = fixture.recordSentry()
            defer { SentryCapture.resetForTesting() }
            fixture.service.hold(.start)
            let create = Task { await model.createIrohRoom(name: "Race room") }
            try await fixture.waitForService(.start)
            let precommit = try await fixture.beginGatedSignOut(model)
            fixture.service.release(.start)
            let created = await create.value
            #expect(created == false)
            try fixture.expectOfflineWorkspaceKept(model, precommit: precommit)
            #expect(fixture.service.stopCount >= 1)
            #expect(model.errorMessage == R54AP01Fixture.refusal)
            #expect(recorded.value.contains(where: { $0.contains("sign-out stage=mutation outcome=refused") }))
            #expect(recorded.value.filter { !$0.contains("sign-out stage=") }.isEmpty)
            try await fixture.finishSignOut(model)
            #expect(try fixture.persistedRooms() == .empty)
        }
    }

    @Test @MainActor
    func signOutRevokesJoinSuspendedInServiceStart() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let recorded = fixture.recordSentry()
            defer { SentryCapture.resetForTesting() }
            let invite = try fixture.invite()
            fixture.service.hold(.start)
            let join = Task { await model.joinIrohRoom(inviteText: invite) }
            try await fixture.waitForService(.start)
            let precommit = try await fixture.beginGatedSignOut(model)
            fixture.service.release(.start)
            let joined = await join.value
            #expect(joined == false)
            // The lease check after service.start keeps the transport join from
            // running for a revoked owner, so no peer records reach the room.
            #expect(fixture.service.joinCount == 0)
            #expect(fixture.deliveries.value == 0)
            #expect(fixture.service.stopCount >= 1)
            try fixture.expectOfflineWorkspaceKept(model, precommit: precommit)
            #expect(model.errorMessage == R54AP01Fixture.refusal)
            #expect(recorded.value.contains(where: { $0.contains("sign-out stage=mutation outcome=refused") }))
            #expect(recorded.value.filter { !$0.contains("sign-out stage=") }.isEmpty)
            try await fixture.finishSignOut(model)
            #expect(try fixture.persistedRooms() == .empty)
        }
    }

    // Control: the spy delivers a valid genesis during join, so the same join
    // activates the room when no sign-out runs. The revocation tests' durable
    // assertions therefore observe the lease, not a join that cannot succeed.
    @Test @MainActor
    func joinOutsideSignOutActivatesDeliveredRoom() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let invite = try fixture.invite()
            let roomID = try IrohProtocolV1.roomID(for: R54AP01Fixture.inviteSecret)
            #expect(await model.joinIrohRoom(inviteText: invite))
            #expect(fixture.service.joinCount == 1)
            #expect(fixture.deliveries.value == 1)
            #expect(model.errorMessage == nil)
            #expect(model.isSignedIn)
            try fixture.expectRoomKept(model, roomID: roomID)
            let room = try #require(try fixture.persistedRooms().rooms.first)
            #expect(room.genesis?.isValid == true)
            // R54-AP06: activation stamps the account identity the prepared room
            // left out.
            #expect(room.roomState.cachedUser != nil)
            #expect(room.roomState.cachedUser == room.returnState.cachedUser)
        }
    }

    // R54-AP06: a join parked in service.start has already written its
    // prepared room. While sign-out owns the workspace, neither that room
    // file nor a store relaunched from it may carry the account identity.
    @Test @MainActor
    func preparedJoinRoomCarriesNoAccountIdentityDuringSignOut() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let invite = try fixture.invite()
            let roomID = try IrohProtocolV1.roomID(for: R54AP01Fixture.inviteSecret)
            fixture.service.hold(.start)
            let join = Task { await model.joinIrohRoom(inviteText: invite) }
            try await fixture.waitForService(.start)
            _ = try await fixture.beginGatedSignOut(model)
            let window = try fixture.persistedRooms()
            #expect(window.rooms.map(\.roomID) == [roomID])
            #expect(window.activeRoomID == nil)
            for room in window.rooms {
                R54AP01Fixture.expectNoAccountIdentity(room.returnState)
                R54AP01Fixture.expectNoAccountIdentity(room.roomState)
            }
            let relaunched = fixture.relaunchedRoomStore()
            #expect(relaunched.roomIDs == [roomID])
            #expect(relaunched.activeRoomID == nil)
            fixture.service.release(.start)
            #expect(await join.value == false)
            try await fixture.finishSignOut(model)
            #expect(try fixture.persistedRooms() == .empty)
        }
    }

    // The transport join already ran when sign-out starts; the joined room
    // must still not be activated durably.
    @Test @MainActor
    func signOutRevokesJoinSuspendedInServiceJoin() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let recorded = fixture.recordSentry()
            defer { SentryCapture.resetForTesting() }
            let invite = try fixture.invite()
            fixture.service.hold(.join)
            let join = Task { await model.joinIrohRoom(inviteText: invite) }
            try await fixture.waitForService(.join)
            let precommit = try await fixture.beginGatedSignOut(model)
            fixture.service.release(.join)
            let joined = await join.value
            #expect(joined == false)
            #expect(fixture.service.joinCount == 1)
            #expect(fixture.deliveries.value == 1)
            #expect(fixture.service.stopCount >= 1)
            try fixture.expectOfflineWorkspaceKept(model, precommit: precommit)
            #expect(model.errorMessage == R54AP01Fixture.refusal)
            #expect(recorded.value.contains(where: { $0.contains("sign-out stage=mutation outcome=refused") }))
            #expect(recorded.value.filter { !$0.contains("sign-out stage=") }.isEmpty)
            try await fixture.finishSignOut(model)
            #expect(try fixture.persistedRooms() == .empty)
        }
    }

    // A join revoked by a sign-out that then fails to detach credentials
    // must not land. The sign-out failure stays the visible error, and the
    // released fence admits a fresh join of the same invite.
    @Test @MainActor
    func failedSignOutAfterRevokedJoinAdmitsRejoin() async throws {
        try await R54AP01Fixture.run(mode: .offline) { fixture in
            try fixture.seedAccount()
            let model = fixture.model()
            try await fixture.restoreSignedIn(model)
            let invite = try fixture.invite()
            fixture.service.hold(.start)
            let join = Task { await model.joinIrohRoom(inviteText: invite) }
            try await fixture.waitForService(.start)
            fixture.gate.failOnRelease()
            _ = try await fixture.beginGatedSignOut(model)
            fixture.gate.release()
            await fixture.waitForSignOut(model)
            let signOutMessage = try #require(model.errorMessage)
            #expect(signOutMessage != R54AP01Fixture.refusal)
            fixture.service.release(.start)
            #expect(await join.value == false)
            #expect(model.isSignedIn)
            #expect(model.errorMessage == signOutMessage)
            #expect(model.replicationMode == .offline)
            #expect(try fixture.persistedRooms() == .empty)
            #expect(try fixture.savedState().cachedUser != nil)
            #expect(await model.joinIrohRoom(inviteText: invite))
            try fixture.expectRoomKept(model, roomID: IrohProtocolV1.roomID(for: R54AP01Fixture.inviteSecret))
            #expect(fixture.service.joinCount == 1)
        }
    }

    @Test @MainActor
    func signOutRevokesLeaveSuspendedInServiceStop() async throws {
        try await expectSuspendedRoomTransitionRevoked { model in
            model.requestIrohRoomLeave()
            await model.confirmIrohRoomLeave()
        }
    }

    @Test @MainActor
    func signOutRevokesModeChangeSuspendedInServiceStop() async throws {
        try await expectSuspendedRoomTransitionRevoked { model in
            await model.setReplicationMode(.offline)
        }
    }

    // Starts a room transition that suspends in service.stop, begins a
    // gated sign-out, then lets the transition resume. The active room, the
    // mode key, and the room file must be unchanged, and later leave or
    // mode-change attempts are refused at entry without stopping the room.
    @MainActor
    private func expectSuspendedRoomTransitionRevoked(
        _ transition: @escaping @MainActor @Sendable (AppModel) async -> Void
    ) async throws {
        try await R54AP01Fixture.run(mode: .iroh) { fixture in
            let roomID = try fixture.seedIrohRoom()
            let model = fixture.model()
            try await fixture.signInToRoom(model)
            let recorded = fixture.recordSentry()
            defer { SentryCapture.resetForTesting() }
            fixture.service.hold(.stop)
            let running = Task { await transition(model) }
            try await fixture.waitForService(.stop)
            _ = try await fixture.beginGatedSignOut(model)
            fixture.service.release(.stop)
            await running.value
            try fixture.expectRoomKept(model, roomID: roomID)
            #expect(model.errorMessage == R54AP01Fixture.refusal)
            #expect(recorded.value.contains(where: { $0.contains("sign-out stage=mutation outcome=refused") }))
            #expect(recorded.value.filter { !$0.contains("sign-out stage=") }.isEmpty)
            let stops = fixture.service.stopCount
            model.requestIrohRoomLeave()
            await model.confirmIrohRoomLeave()
            await model.setReplicationMode(.offline)
            #expect(fixture.service.stopCount == stops)
            try fixture.expectRoomKept(model, roomID: roomID)
            try await fixture.finishSignOut(model)
            #expect(fixture.roomStore.activeSnapshot?.roomID == roomID)
            #expect(try fixture.persistedRooms().activeRoomID == roomID)
        }
    }
}

// Room service spy. A held step suspends until the test releases it, so a
// transition can be parked inside the service while sign-out starts.
@MainActor
private final class R54AP01RoomService: RoomReplicationServing {
    enum Step: Hashable { case start, stop, join }

    private var held: Set<Step> = []
    private var waiting: [Step: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var joinCount = 0
    // Stands in for the peer sync of a real join, which stores the room
    // genesis before `join` returns.
    var deliverJoinedRoom: ((IrohRoomInvite) throws -> Void)?
    let ticket: String

    init() throws {
        let identity = try SecretKey.fromBytes(bytes: Data(repeating: 54, count: 32))
        let address = EndpointAddr(id: identity.public(), relayUrl: nil, addresses: [])
        ticket = try EndpointTicket.fromAddr(addr: address).description
    }

    func start(_ context: IrohServiceContext) async throws -> String {
        startCount += 1
        await pause(at: .start)
        return ticket
    }

    func stop() async {
        stopCount += 1
        await pause(at: .stop)
    }

    func join(invite: IrohRoomInvite) async throws {
        joinCount += 1
        await pause(at: .join)
        try deliverJoinedRoom?(invite)
    }

    func currentEndpointTicket() async throws -> String { ticket }
    func syncNow() async {}
    func markConflict(roomID: String?) async {}

    func hold(_ step: Step) { held.insert(step) }

    func isWaiting(_ step: Step) -> Bool { !(waiting[step] ?? []).isEmpty }

    func release(_ step: Step) {
        held.remove(step)
        let continuations = waiting.removeValue(forKey: step) ?? []
        for continuation in continuations { continuation.resume() }
    }

    func releaseAll() {
        release(.start)
        release(.stop)
        release(.join)
    }

    private func pause(at step: Step) async {
        guard held.contains(step) else { return }
        await withCheckedContinuation { continuation in
            waiting[step, default: []].append(continuation)
        }
    }
}

@MainActor
private final class R54AP01Fixture {
    static let refusal = "Sign-out is in progress. Changes are paused until it finishes."
    static let modeKey = "replication-mode-v1"
    static let inviteSecret = Data(repeating: 7, count: 32)

    let suiteName = "R54AP01.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54AP01-\(UUID().uuidString)", isDirectory: true)
    let defaults: RecordingUserDefaults
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "signout-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "signout-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let identity = RecordingGoogleIdentityProvider()
    let alarms = RecordingAlarmScheduler()
    let gate = R54AP01GatedDetachStore()
    let service: R54AP01RoomService
    let secrets = MemoryIrohRoomSecretStore()
    let roomStore: IrohRoomStore
    let deliveries = LockedTestValue<Int>(0)
    let scenario = "apple-api-coverage-model-local-signout-\(UUID().uuidString)"
    let logout: LogoutDrainingSession
    var url: URL { directory.appendingPathComponent("workspace.json") }
    var roomsURL: URL { directory.appendingPathComponent("iroh-rooms.json") }

    private init(mode: ReplicationMode) throws {
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        service = try R54AP01RoomService()
        roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("iroh-rooms.json"), secretStore: secrets
        )
        logout = LogoutDrainingSession(scenario: scenario, obligations: tokens)
        let genesis = try Self.peerGenesisRecord()
        service.deliverJoinedRoom = { [roomStore, deliveries] invite in
            _ = try roomStore.insertRemoteRecords([genesis], roomID: invite.roomID)
            deliveries.value += 1
        }
    }

    static func peerGenesisRecord() throws -> IrohOperationRecord {
        let task = try #require(FocusTask(title: "Joined room task"))
        let genesis = IrohGenesis(
            canonicalTimer: nil, history: [], tasks: [task], durationsMs: .defaults,
            autoStartBreaks: false, selectedTaskId: task.id.uuidString.lowercased(),
            hlcWallMs: 0, hlcCounter: 0
        )
        return IrohOperationRecord(domain: .genesis, deviceId: "r54ap01-peer", payload: .genesis(genesis))
    }

    // Runs one test body with a fixture it owns and tears the fixture down on
    // every exit path. Releasing the room service and the detach gate first
    // lets a parked sign-out finish. The gated store keeps no obligation, so
    // the drain is defensive here; it keeps this fixture on the same
    // teardown order as the other sign-out fixtures.
    static func run(mode: ReplicationMode, _ body: @MainActor (R54AP01Fixture) async throws -> Void) async throws {
        let fixture = try R54AP01Fixture(mode: mode)
        defer { fixture.removeStorage() }
        try await fixture.logout.run(releasingHolds: {
            fixture.service.releaseAll()
            fixture.gate.release()
        }) {
            try await body(fixture)
        }
    }

    private func removeStorage() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func seedAccount() throws {
        let state = TestFixtures.syncContractState(includesPendingOperations: false)
        let bytes = try JSONEncoder.api.encode(state)
        try AtomicDurableFileStore(fileURL: url).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.resetTimerStateWrites()
    }

    func seedIrohRoom() throws -> String {
        try seedAccount()
        let roomTask = try #require(FocusTask(title: "Room selection"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try roomStore.createRoom(
            roomID: roomID, roomSecret: secret, name: nil, returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [roomTask], durationsMs: .defaults,
                autoStartBreaks: false, selectedTaskId: roomTask.id.uuidString.lowercased(),
                hlcWallMs: 0, hlcCounter: 0
            )
        )
        return roomID
    }

    func model() -> AppModel {
        let service = service
        return logout.track(AppModel(
            api: APIClient(session: logout.session, keychain: tokens, logoutRevocationStore: gate),
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: url),
            roomStore: roomStore, roomServiceFactory: { _ in service },
            alarmScheduler: alarms, googleIdentityProvider: identity,
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        ))
    }

    func invite() throws -> String {
        try IrohRoomInvite(
            roomID: IrohProtocolV1.roomID(for: Self.inviteSecret), roomName: nil,
            endpointTicket: service.ticket, roomSecret: Self.inviteSecret
        ).encoded()
    }

    func recordSentry() -> LockedTestValue<[String]> {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.resetForTesting()
        SentryCapture.setTestBackend { recorded.value.append($0.localizedDescription) }
        return recorded
    }

    func restoreSignedIn(_ model: AppModel) async throws {
        await model.restore()
        try #require(model.isSignedIn)
    }

    func signInToRoom(_ model: AppModel) async throws {
        model.signIn()
        await waitForSignOut(model)
        try #require(model.isSignedIn)
        try #require(model.replicationMode == .iroh)
    }

    func waitForSignOut(_ model: AppModel) async {
        for _ in 0..<200 where model.isWorking {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // Starts sign-out and returns the precommitted signed-out bytes once the
    // credential detach is parked in the gated revocation store.
    func beginGatedSignOut(_ model: AppModel) async throws -> Data {
        model.signOut()
        for _ in 0..<500 where gate.appendCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try #require(gate.appendCount > 0)
        try #require(model.isWorking)
        return try savedBytes()
    }

    func waitForService(_ step: R54AP01RoomService.Step) async throws {
        for _ in 0..<500 where !service.isWaiting(step) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try #require(service.isWaiting(step))
    }

    func finishSignOut(_ model: AppModel) async throws {
        gate.release()
        await waitForSignOut(model)
        await model.waitForAlarmOperations()
        #expect(!model.isWorking)
        #expect(model.sessionState == .localOnly)
        #expect(tokens.tokens == nil)
        #expect(identity.signOutCount == 1)
        #expect(model.errorMessage == nil)
        #expect(try savedState().cachedUser == nil)
    }

    func expectOfflineWorkspaceKept(_ model: AppModel, precommit: Data) throws {
        #expect(model.replicationMode == .offline)
        #expect(defaults.string(forKey: Self.modeKey) == ReplicationMode.offline.rawValue)
        #expect(model.roomInvite == nil)
        #expect(roomStore.activeSnapshot == nil)
        #expect(try persistedRooms() == .empty)
        #expect(try savedBytes() == precommit)
    }

    func expectRoomKept(_ model: AppModel, roomID: String) throws {
        #expect(model.replicationMode == .iroh)
        #expect(defaults.string(forKey: Self.modeKey) == ReplicationMode.iroh.rawValue)
        #expect(!model.isLeavingIrohRoom)
        #expect(roomStore.activeSnapshot?.roomID == roomID)
        #expect(try persistedRooms().activeRoomID == roomID)
    }

    // Reads the room file the way a relaunch would, with this device's
    // room secrets.
    func relaunchedRoomStore() -> IrohRoomStore {
        IrohRoomStore(fileURL: roomsURL, secretStore: secrets)
    }

    static func expectNoAccountIdentity(_ state: PersistedTimerState) {
        #expect(state.cachedUser == nil)
        #expect(state.pendingAccountSwitchUser == nil)
        #expect(state.bootstrapUser == nil)
        #expect(state.pendingBootstrapResolution == nil)
    }

    func savedBytes() throws -> Data { try Data(contentsOf: url) }

    func savedState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: savedBytes())
    }

    func persistedRooms() throws -> IrohReplicationState {
        guard FileManager.default.fileExists(atPath: roomsURL.path) else { return .empty }
        return try JSONDecoder.api.decode(IrohReplicationState.self, from: Data(contentsOf: roomsURL))
    }
}

// Parks the credential detach after the signed-out precommit until the
// test releases it. Blocks only the revocation actor, so the main actor
// stays free to run room transitions while sign-out owns the workspace.
private final class R54AP01GatedDetachStore: LogoutRevocationStoring, @unchecked Sendable {
    struct DetachFailure: Error {}
    private let lock = NSLock()
    private var appends = 0
    private var released = false
    private var failsAfterRelease = false
    var appendCount: Int { lock.withLock { appends } }
    func load() throws -> [LogoutRevocationObligation] { [] }
    func append(_ obligation: LogoutRevocationObligation) throws {
        lock.withLock { appends += 1 }
        while !lock.withLock({ released }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if lock.withLock({ failsAfterRelease }) { throw DetachFailure() }
    }
    func replace(_ obligation: LogoutRevocationObligation) throws {}
    func remove(id: UUID) throws {}
    func release() { lock.withLock { released = true } }
    // The released detach then fails, so sign-out takes its failed path and
    // keeps the credentials and the account workspace.
    func failOnRelease() { lock.withLock { failsAfterRelease = true } }
}

/// R54-AP06: the identity rules of a join room, pinned on the store itself.
/// A prepared join room carries none of the four account identity fields in
/// either state. Activation gives a room without an identity the account
/// user and the pending switch user of the workspace it replaces, and
/// nothing from a staged bootstrap. A room that carries any identity of its
/// own keeps it unchanged.
@Suite("R54-AP06 join room account identity")
struct R54AP06JoinRoomIdentityTests {
    @Test(arguments: R54AP06AccountIdentity.allCases) @MainActor
    func preparedJoinRoomStripsEveryAccountIdentity(_ identity: R54AP06AccountIdentity) throws {
        let fixture = try R54AP06StoreFixture()
        defer { fixture.cleanup() }
        try fixture.prepareJoin(from: identity.accountState)
        let persisted = try fixture.persistedRooms()
        #expect(persisted.activeRoomID == nil)
        let room = try #require(persisted.rooms.first)
        R54AP01Fixture.expectNoAccountIdentity(room.returnState)
        R54AP01Fixture.expectNoAccountIdentity(room.roomState)
    }

    @Test(arguments: R54AP06AccountIdentity.allCases) @MainActor
    func identitylessRoomTakesOnlyTheAccountUserAndPendingSwitch(_ identity: R54AP06AccountIdentity) throws {
        let fixture = try R54AP06StoreFixture()
        defer { fixture.cleanup() }
        R54AP01Fixture.expectNoAccountIdentity(try fixture.retainRoom(stamping: nil))
        let account = identity.accountState
        let joined = try fixture.join(from: account)
        #expect(joined.cachedUser == account.cachedUser)
        #expect(joined.pendingAccountSwitchUser == account.pendingAccountSwitchUser)
        #expect(joined.bootstrapUser == nil)
        #expect(joined.pendingBootstrapResolution == nil)
        let persisted = try fixture.persistedRooms()
        #expect(persisted.activeRoomID == fixture.roomID)
        #expect(persisted.rooms.first?.roomState.cachedUser == account.cachedUser)
        #expect(persisted.rooms.first?.roomState.pendingAccountSwitchUser == account.pendingAccountSwitchUser)
    }

    // Each case gives the retained room one of the three fields the
    // activation guard reads, then rejoins it from another account during a
    // pending switch.
    @Test(arguments: R54AP06RoomIdentity.allCases)
    func roomWithItsOwnIdentityKeepsIt(_ identity: R54AP06RoomIdentity) throws {
        let fixture = try R54AP06StoreFixture()
        defer { fixture.cleanup() }
        let owner = try fixture.retainRoom(stamping: identity)
        try #require(identity.isCarried(by: owner))
        let joined = try fixture.join(from: R54AP06AccountIdentity.pendingSwitch.accountState)
        #expect(joined.cachedUser == owner.cachedUser)
        #expect(joined.pendingAccountSwitchUser == owner.pendingAccountSwitchUser)
        #expect(joined.bootstrapUser == owner.bootstrapUser)
    }
}

// Account workspaces a join can start from: signed in, during a pending
// account switch, and with a staged bootstrap resolution.
enum R54AP06AccountIdentity: String, CaseIterable, Sendable {
    case signedIn
    case pendingSwitch
    case stagedBootstrap

    var accountState: PersistedTimerState {
        var state = PersistedTimerState.fresh()
        switch self {
        case .signedIn:
            state.cachedUser = R54AP06StoreFixture.user("account")
        case .pendingSwitch:
            state.cachedUser = R54AP06StoreFixture.user("account")
            state.pendingAccountSwitchUser = R54AP06StoreFixture.user("switch")
        case .stagedBootstrap:
            state.bootstrapUser = R54AP06StoreFixture.user("bootstrap")
            state.pendingBootstrapResolution = BootstrapResolveRequest(
                requestId: "r54ap06-bootstrap", deviceId: state.deviceId, expectedRevision: 1,
                strategy: .merge, commands: [], taskOperations: [], durationOperations: [],
                autoStartOperations: []
            )
        }
        return state
    }
}

// The identity fields the activation guard reads, one per case.
enum R54AP06RoomIdentity: String, CaseIterable, Sendable {
    case cachedUser
    case pendingAccountSwitchUser
    case bootstrapUser

    func stamp(_ user: User, on state: inout PersistedTimerState) {
        switch self {
        case .cachedUser: state.cachedUser = user
        case .pendingAccountSwitchUser: state.pendingAccountSwitchUser = user
        case .bootstrapUser: state.bootstrapUser = user
        }
    }

    func isCarried(by state: PersistedTimerState) -> Bool {
        switch self {
        case .cachedUser: return state.cachedUser != nil
        case .pendingAccountSwitchUser: return state.pendingAccountSwitchUser != nil
        case .bootstrapUser: return state.bootstrapUser != nil
        }
    }
}

// Drives IrohRoomStore directly over a temporary room file and an in-memory
// secret store, so each rule is read from the room file the store writes.
private final class R54AP06StoreFixture {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let peer = IrohPeer(endpointID: "endpoint-r54ap06", endpointTicket: "ticket-r54ap06",
                               deviceID: nil, displayName: nil, lastSeenAt: nil)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54AP06-\(UUID().uuidString)", isDirectory: true)
    let secret = Data(repeating: 6, count: 32)
    let roomID: String
    let store: IrohRoomStore

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roomID = try IrohProtocolV1.roomID(for: secret)
        store = IrohRoomStore(fileURL: directory.appendingPathComponent("rooms.json"),
                              secretStore: MemoryIrohRoomSecretStore(), now: { Self.date })
    }

    static func user(_ name: String) -> User {
        User(id: "user-r54ap06-\(name)", email: "\(name)@example.com", name: name, avatarUrl: "")
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func persistedRooms() throws -> IrohReplicationState {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("rooms.json"))
        return try JSONDecoder.api.decode(IrohReplicationState.self, from: bytes)
    }

    // Leaves a suspended room whose room state carries `identity` (no
    // identity when nil) and returns that state as the room file holds it.
    func retainRoom(stamping identity: R54AP06RoomIdentity?) throws -> PersistedTimerState {
        var roomState = try store.createRoom(
            roomID: roomID, roomSecret: secret, name: nil, returnState: .fresh(),
            genesis: IrohGenesis(canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
                                 autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0),
            now: Self.date
        )
        identity?.stamp(Self.user("owner"), on: &roomState)
        _ = try store.captureAndSuspendActiveRoom(from: roomState)
        try #require(store.activeRoomID == nil)
        return try #require(try persistedRooms().rooms.first).roomState
    }

    func prepareJoin(from account: PersistedTimerState) throws {
        let preparation = try store.prepareJoinedRoom(
            roomID: roomID, roomSecret: secret, name: nil, returnState: account,
            initialPeer: Self.peer, now: Self.date
        )
        try #require(!preparation.alreadyActive)
    }

    func join(from account: PersistedTimerState) throws -> PersistedTimerState {
        try prepareJoin(from: account)
        return try store.activateJoinedRoom(roomID: roomID, returnState: account)
    }
}
