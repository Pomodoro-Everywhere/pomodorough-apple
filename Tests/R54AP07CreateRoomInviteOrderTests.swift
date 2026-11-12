import Foundation
import IrohLib
import Testing
@testable import Pomodorough

// R54-AP07: a room create whose invite could not be encoded used to store and
// activate the room and switch the controller to Iroh before the encode
// threw. The catch then skipped the centralized resume, so the model stayed
// centralized over an active room with no centralized streams. Each failure
// leg checks the pre-call state: no stored room or secret, the controller
// centralized, centralized streams and sync resumed, and one room capture.
@Suite("R54-AP07 create room invite order", .serialized)
struct CreateRoomInviteOrderTests {
    static let rejectedTickets = [
        RejectedTicket(label: "empty", ticket: ""),
        RejectedTicket(
            label: "over 16 KiB",
            ticket: String(repeating: "a", count: IrohProtocolV1.maxEndpointTicketBytes + 1)
        ),
        RejectedTicket(label: "unparsable", ticket: "unparsable-endpoint-ticket")
    ]

    @Test(arguments: rejectedTickets) @MainActor
    func rejectedTicketLeavesNoRoomAndResumesCentralizedSync(_ rejected: RejectedTicket) async throws {
        let fixture = try await InviteOrderFixture(ticket: rejected.ticket)
        defer { fixture.remove() }
        let failure = try codecFailure(ticket: rejected.ticket, secret: fixture.secret)
        let captures = BoundaryCaptureLog()
        defer { SentryCapture.resetForTesting() }

        let transition = await fixture.createRoom()

        #expect(transition == .failed(failure.localizedDescription))
        try await expectPreCallState(fixture, captures: captures, failure: failure)
    }

    @Test @MainActor
    func injectedInviteFailureLeavesNoRoomAndResumesCentralizedSync() async throws {
        let fixture = try await InviteOrderFixture(
            ticket: Self.validTicket(),
            encodeInvite: { _, _, _, _ in throw InjectedInviteFailure() }
        )
        defer { fixture.remove() }
        let captures = BoundaryCaptureLog()
        defer { SentryCapture.resetForTesting() }

        let transition = await fixture.createRoom()

        #expect(transition == .failed("The room was not created. Try again."))
        try await expectPreCallState(fixture, captures: captures, failure: InjectedInviteFailure())
    }

    @Test @MainActor
    func rejectedTicketKeepsPreviousSuspendedRoom() async throws {
        let fixture = try await InviteOrderFixture(ticket: "unparsable-endpoint-ticket")
        defer { fixture.remove() }
        let priorRoomID = try fixture.seedSuspendedRoom()
        let roomsBefore = try Data(contentsOf: fixture.roomsURL)
        let preferredBefore = fixture.store.preferredRoomID
        let failure = try codecFailure(ticket: "unparsable-endpoint-ticket", secret: fixture.secret)
        let captures = BoundaryCaptureLog()
        defer { SentryCapture.resetForTesting() }

        let transition = await fixture.createRoom()

        #expect(transition == .failed(failure.localizedDescription))
        #expect(try Data(contentsOf: fixture.roomsURL) == roomsBefore)
        #expect(fixture.store.preferredRoomID == preferredBefore)
        #expect(fixture.store.roomIDs == [priorRoomID])
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.secrets.contains(roomID: priorRoomID))
        #expect(!fixture.secrets.contains(roomID: fixture.roomID))
        #expect(fixture.isCentralized)
        #expect(try await eventually { fixture.operations.value.count == 1 })
        try expectSingleRoomCapture(captures, failure: failure)
    }

    // Sign-out revokes the lease while the endpoint starts. The revocation
    // must win over the invite failure: no capture and no failed message.
    @Test @MainActor
    func revokedLeaseWinsOverInviteFailure() async throws {
        let fixture = try await InviteOrderFixture(ticket: "unparsable-endpoint-ticket")
        defer { fixture.remove() }
        await fixture.service.suspendStart()
        let captures = BoundaryCaptureLog()
        defer { SentryCapture.resetForTesting() }

        let create = Task { @MainActor in await fixture.createRoom() }
        try #require(try await eventually { await fixture.service.startCount == 1 })
        fixture.controller.revokeTransitions()
        await fixture.service.releaseStart()

        #expect(await create.value == .ownershipRevoked)
        #expect(captures.errors.isEmpty, "captures: \(captures.summary)")
        #expect(fixture.store.roomIDs.isEmpty)
        #expect(!fixture.secrets.contains(roomID: fixture.roomID))
    }

    @Test @MainActor
    func validTicketCreatesRoomWithEncodedInvite() async throws {
        let ticket = try Self.validTicket()
        let fixture = try await InviteOrderFixture(ticket: ticket)
        defer { fixture.remove() }
        let invite = try IrohRoomInvite(
            roomID: fixture.roomID, roomName: InviteOrderFixture.roomName,
            endpointTicket: ticket, roomSecret: fixture.secret
        ).encoded()
        let captures = BoundaryCaptureLog()
        defer { SentryCapture.resetForTesting() }

        let transition = await fixture.createRoom()

        let roomState = try #require(fixture.store.activeRoomState)
        let status = IrohConnectionStatus.listening(endpointMark: String(ticket.suffix(6)))
        #expect(transition == .roomCreated(roomState, invite: invite, status: status))
        #expect(fixture.store.activeRoomID == fixture.roomID)
        #expect(fixture.secrets.contains(roomID: fixture.roomID))
        #expect(!fixture.isCentralized)
        #expect(await fixture.service.stopCount == 0)
        #expect(captures.errors.isEmpty, "captures: \(captures.summary)")
    }

    // The model-level path: the failed create keeps the model and the
    // controller centralized, so the next foreground refresh syncs and
    // releases the gate instead of reaching the retained Iroh outcome. A
    // relaunch over the same files finds no room and no Iroh mode.
    @Test @MainActor
    func rejectedTicketReleasesForegroundGateThroughModel() async throws {
        let fixture = try InviteOrderModelFixture(ticket: "unparsable-endpoint-ticket")
        defer { fixture.remove() }
        let failure = try codecFailure(ticket: "unparsable-endpoint-ticket", secret: Data(repeating: 3, count: 32))
        let model = fixture.model()
        model.setSceneActive(true)
        await model.restore()
        try #require(model.replicationMode == .centralized)
        try #require(try await eventually { !model.isSyncing })
        let captures = BoundaryCaptureLog()
        defer { SentryCapture.resetForTesting() }
        let postsBeforeCreate = fixture.postCount

        #expect(await model.createIrohRoom(name: InviteOrderFixture.roomName) == false)

        #expect(model.errorMessage == failure.localizedDescription)
        #expect(model.replicationMode == .centralized)
        #expect(fixture.roomStore.activeSnapshot == nil)
        #expect(try await eventually { fixture.postCount > postsBeforeCreate && !model.isSyncing })
        let identity = DiagnosticPrivacy.diagnostic(failure, operation: .room).userInfo["identity"] as? String
        #expect(captures.errors(identity: identity ?? "").count == 1, "captures: \(captures.summary)")
        let postsBeforeForeground = fixture.postCount
        model.setSceneActive(false)
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == false)
        #expect(fixture.postCount > postsBeforeForeground)
        #expect(captures.errors(identity: "Iroh.foregroundRefresh").isEmpty, "captures: \(captures.summary)")
        try expectRelaunchFindsNoRoom(fixture)
    }

    @MainActor
    private func expectPreCallState(
        _ fixture: InviteOrderFixture,
        captures: BoundaryCaptureLog,
        failure: any Error
    ) async throws {
        #expect(fixture.isCentralized)
        #expect(fixture.store.activeSnapshot == nil)
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.store.roomIDs.isEmpty)
        #expect(!fixture.secrets.contains(roomID: fixture.roomID))
        #expect(await fixture.service.stopCount == 1)
        #expect(try await eventually {
            fixture.revisionRequests.value == 2 && !fixture.operations.value.isEmpty
        })
        #expect(fixture.operations.value == [.synchronize(force: true, showsActivity: true)])
        try expectSingleRoomCapture(captures, failure: failure)
    }

    private func expectSingleRoomCapture(_ captures: BoundaryCaptureLog, failure: any Error) throws {
        let expected = DiagnosticPrivacy.diagnostic(failure, operation: .room)
        try #require(captures.errors.count == 1, "captures: \(captures.summary)")
        let sent = captures.errors[0]
        #expect(sent.userInfo["identity"] as? String == expected.userInfo["identity"] as? String)
        #expect(sent.userInfo["operation"] as? String == DiagnosticOperation.room.rawValue)
        #expect(sent.localizedDescription == expected.localizedDescription)
        #expect(sent.code == expected.code)
    }

    @MainActor
    private func expectRelaunchFindsNoRoom(_ fixture: InviteOrderModelFixture) throws {
        let relaunched = IrohRoomStore(fileURL: fixture.roomsURL, secretStore: fixture.secrets)
        #expect(relaunched.roomIDs.isEmpty)
        #expect(relaunched.preferredRoomID == nil)
        #expect(try fixture.secrets.accountDeletionAccounts().isEmpty)
        #expect(fixture.defaults.string(forKey: "replication-mode-v1") != ReplicationMode.iroh.rawValue)
    }

    // The error the production codec raises for this ticket, so each leg
    // asserts the message and capture the real encoder produces.
    private func codecFailure(ticket: String, secret: Data) throws -> any Error {
        let roomID = try IrohProtocolV1.roomID(for: secret)
        do {
            _ = try IrohRoomInvite(
                roomID: roomID, roomName: InviteOrderFixture.roomName,
                endpointTicket: ticket, roomSecret: secret
            ).encoded()
        } catch {
            return error
        }
        Issue.record("the codec accepted ticket \(ticket.prefix(32))")
        throw InjectedInviteFailure()
    }

    static func validTicket() throws -> String {
        let identity = try SecretKey.fromBytes(bytes: Data(repeating: 41, count: 32))
        let address = EndpointAddr(id: identity.public(), relayUrl: nil, addresses: [])
        return try EndpointTicket.fromAddr(addr: address).description
    }
}

struct RejectedTicket: Sendable, CustomTestStringConvertible {
    let label: String
    let ticket: String

    var testDescription: String { label }
}

private struct InjectedInviteFailure: LocalizedError {
    var errorDescription: String? { "AP07 injected invite failure" }
}

// Polls for up to five seconds. A false result fails the caller's
// expectation, so the pre-fix tree reports instead of hanging.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async throws -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// A centralized, signed-in controller with live centralized streams and the
// production invite codec unless a test injects another encoder.
@MainActor
private struct InviteOrderFixture {
    nonisolated static let roomName = "AP07 room"
    let secret = Data(repeating: 3, count: 32)
    let roomID: String
    let directory: URL
    let roomsURL: URL
    let secrets = MemoryIrohRoomSecretStore()
    let store: IrohRoomStore
    let service: InviteOrderRoomService
    let operations = LockedTestValue<[RoomReplicationOperation]>([])
    let revisionRequests = LockedTestValue(0)
    let environment: RoomReplicationEnvironment
    let controller: RoomReplicationController

    init(
        ticket: String,
        encodeInvite: (@Sendable (String, String?, String, Data) throws -> String)? = nil
    ) async throws {
        roomID = try IrohProtocolV1.roomID(for: secret)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("R54AP07-\(UUID().uuidString)", isDirectory: true)
        roomsURL = directory.appendingPathComponent("rooms.json")
        store = IrohRoomStore(fileURL: roomsURL, secretStore: secrets)
        service = InviteOrderRoomService(ticket: ticket)
        let local = PersistedTimerState.fresh()
        environment = RoomReplicationEnvironment(deviceID: local.deviceId, displayName: nil, platform: "macos")
        controller = RoomReplicationController(
            mode: .centralized,
            dependencies: Self.dependencies(
                store: store, service: service, local: local, secret: secret,
                revisionRequests: revisionRequests, encodeInvite: encodeInvite ?? Self.productionEncoder
            ),
            eventHandler: { _ in },
            operationHandler: { [operations] in operations.value.append($0) }
        )
        controller.setSceneActive(true, environment: environment)
        controller.startCentralizedStreams()
        try #require(try await eventually { revisionRequests.value == 1 })
    }

    var isCentralized: Bool {
        controller.owns(controller.ownership(sessionGeneration: 7), sessionGeneration: 7)
    }

    func createRoom() async -> RoomReplicationTransition {
        await controller.createRoom(name: Self.roomName, environment: environment)
    }

    // An earlier room the user left: stored and keyed, but not active.
    func seedSuspendedRoom() throws -> String {
        let priorSecret = Data(repeating: 9, count: 32)
        let priorRoomID = try IrohProtocolV1.roomID(for: priorSecret)
        _ = try store.createRoom(
            roomID: priorRoomID, roomSecret: priorSecret, name: "Earlier room",
            returnState: .fresh(), genesis: Self.emptyGenesis
        )
        let roomState = try #require(store.activeRoomState)
        _ = try store.captureAndSuspendActiveRoom(from: roomState)
        try #require(store.activeRoomID == nil)
        return priorRoomID
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let productionEncoder: @Sendable (String, String?, String, Data) throws -> String = {
        roomID, roomName, endpointTicket, roomSecret in
        try IrohRoomInvite(
            roomID: roomID, roomName: roomName, endpointTicket: endpointTicket, roomSecret: roomSecret
        ).encoded()
    }

    private static let emptyGenesis = IrohGenesis(
        canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
        autoStartBreaks: false, selectedTaskId: nil, hlcWallMs: 0, hlcCounter: 0
    )

    // The revision stream never yields, so the only operation a test sees
    // is the resume sync. Polling sleeps throw, so pollers exit at once.
    private static func dependencies(
        store: IrohRoomStore,
        service: InviteOrderRoomService,
        local: PersistedTimerState,
        secret: Data,
        revisionRequests: LockedTestValue<Int>,
        encodeInvite: @escaping @Sendable (String, String?, String, Data) throws -> String
    ) -> RoomReplicationController.Dependencies {
        RoomReplicationController.Dependencies(
            roomStore: store,
            retryDelay: .seconds(5),
            centralizedState: {
                RoomReplicationCentralizedState(
                    sessionGeneration: 7, isSignedIn: true, isWorkspaceMutationBlocked: false,
                    isSessionVerified: true, localRevision: 0, isSyncing: false,
                    isTimerActive: false, isHistoryResolutionBlocking: false
                )
            },
            workspaceSnapshot: { RoomReplicationWorkspaceSnapshot(state: local, genesis: emptyGenesis) },
            revisionEvents: {
                revisionRequests.value += 1
                return AsyncThrowingStream { _ in }
            },
            sleep: { _ in throw CancellationError() },
            secureRandomBytes: { _ in secret },
            encodeInvite: encodeInvite,
            makeService: { _ in service }
        )
    }
}

// A signed-in centralized model on the R48-AP04 sync stub, whose room
// service hands out one fixed endpoint ticket.
@MainActor
private struct InviteOrderModelFixture {
    let scenario: String
    let suite: String
    let defaults: UserDefaults
    let directory: URL
    let roomsURL: URL
    let secrets = MemoryIrohRoomSecretStore()
    let roomStore: IrohRoomStore
    let service: InviteOrderRoomService

    init(ticket: String) throws {
        scenario = "R54AP07.\(UUID().uuidString)"
        R48AP04StubState.shared.configure(scenario: scenario, mode: .succeed)
        suite = "PomodoroughTests.R54AP07.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        roomsURL = directory.appendingPathComponent("iroh-rooms.json")
        roomStore = IrohRoomStore(fileURL: roomsURL, secretStore: secrets)
        service = InviteOrderRoomService(ticket: ticket)
        let seed = TestFixtures.syncContractState(includesPendingOperations: false)
        defaults.set(try JSONEncoder.api.encode(seed), forKey: PersistedStateLoader.storageKey)
    }

    var postCount: Int { R48AP04StubState.shared.postCount(for: scenario) }

    func model() -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R48AP04StubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-R48AP04-Scenario": scenario]
        let service = service
        return AppModel(
            api: APIClient(session: URLSession(configuration: configuration), keychain: StaticTokenStore()),
            defaults: defaults, roomStore: roomStore, roomServiceFactory: { _ in service },
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            retryDelay: .seconds(3600),
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func remove() {
        R48AP04StubState.shared.release(scenario)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor InviteOrderRoomService: RoomReplicationServing {
    let ticket: String
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var suspendsStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(ticket: String) {
        self.ticket = ticket
    }

    func suspendStart() { suspendsStart = true }

    func releaseStart() {
        suspendsStart = false
        startContinuation?.resume()
        startContinuation = nil
    }

    func start(_ context: IrohServiceContext) async throws -> String {
        startCount += 1
        if suspendsStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        return ticket
    }

    func stop() async { stopCount += 1 }
    func currentEndpointTicket() async throws -> String { ticket }
    func syncNow() async {}
    func foregroundSync() async -> Bool { true }
    func markConflict(roomID: String?) async {}
    func join(invite: IrohRoomInvite) async throws {}
}
