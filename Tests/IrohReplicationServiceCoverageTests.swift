import Foundation
import IrohLib
import Testing
@testable import Pomodorough

@Suite("Iroh service positive unit")
struct IrohServicePositiveUnitCoverageTests {
    @Test func retryDelayClampsNegativeInputsAndOversizedJitter() {
        #expect(IrohReplicationService.retryDelaySeconds(base: -10, jitterUnit: 0.5) == 0)
        #expect(IrohReplicationService.retryDelaySeconds(base: 10, jitterUnit: -1) == 10)
        #expect(IrohReplicationService.retryDelaySeconds(base: 10, jitterUnit: 2) == 12)
    }
}

@Suite("Iroh service negative unit")
@MainActor
struct IrohServiceNegativeUnitCoverageTests {
    @Test func invalidSavedEndpointIdentityFailsBeforeBinding() async throws {
        let fixture = try IrohServiceFixture(
            keyStore: FixedEndpointKeyStore(secret: Data(repeating: 1, count: 31))
        )

        await #expect(throws: IrohProtocolError.self) {
            try await fixture.service.start(fixture.context)
        }
        #expect(fixture.statuses == [.stopped, .starting])
        await #expect(throws: IrohProtocolError.self) {
            try await fixture.service.currentEndpointTicket()
        }
    }

    @Test func endpointIdentityPersistenceFailureStopsBeforeBinding() async throws {
        let fixture = try IrohServiceFixture(keyStore: FailingEndpointKeyStore())

        await #expect(throws: EndpointKeyStoreTestError.self) {
            try await fixture.service.start(fixture.context)
        }
        #expect(fixture.statuses == [.stopped, .starting])
        await #expect(throws: IrohProtocolError.self) {
            try await fixture.service.currentEndpointTicket()
        }
    }
}

@Suite("Iroh service positive integration")
@MainActor
struct IrohServicePositiveIntegrationCoverageTests {
    @Test func endpointLifecycleReusesIdentityWaitsForPeersAndStopsCleanly() async throws {
        let fixture = try IrohServiceFixture()

        let ticket = try await fixture.service.start(fixture.context)
        #expect(try await fixture.service.start(fixture.context) == ticket)
        #expect(try await fixture.service.currentEndpointTicket() == ticket)
        await fixture.service.syncNow()
        await fixture.service.stop()

        #expect(fixture.statuses.contains { status in
            if case .listening = status { return true }
            return false
        })
        #expect(fixture.statuses.contains(.waitingForPeers))
        #expect(fixture.statuses.last == .stopped)
        await #expect(throws: IrohProtocolError.self) {
            try await fixture.service.currentEndpointTicket()
        }
    }

    @Test func generatedIdentityIsPersistedAndReusedAcrossRestart() async throws {
        let keyStore = RecordingEndpointKeyStore()
        let fixture = try IrohServiceFixture(keyStore: keyStore)

        _ = try await fixture.service.start(fixture.context)
        let generated = try #require(keyStore.savedSecret)
        #expect(generated.count == 32)
        await fixture.service.stop()
        _ = try await fixture.service.start(fixture.context)

        #expect(keyStore.savedSecrets.count == 1)
        #expect(try keyStore.load() == generated)
        await fixture.service.stop()
    }

    @Test func incomingMacPeerAuthenticatesAndServesRoomRecords() async throws {
        let fixture = try IrohServiceFixture()
        let session = try await IncomingMacPeerSession.connect(to: fixture)
        defer { Task { await session.close(service: fixture.service) } }

        let inventory = try await session.requestInventory(roomID: fixture.context.roomID)
        let genesis = try #require(inventory.entries.first { entry in
            entry.reference == .init(domain: .genesis, id: "genesis")
        })
        let operations = try await session.requestOperations(
            [genesis.reference],
            roomID: fixture.context.roomID
        )

        #expect(operations.records.count == 1)
        #expect(operations.records.first?.domain == .genesis)
        #expect(try operations.records.first?.digest() == genesis.digest)
        let peers = try fixture.store.peers(roomID: fixture.context.roomID)
        #expect(peers.first?.deviceID == "device-macos-peer")
        #expect(peers.first?.displayName == "Mac peer")
    }
}

@Suite("Iroh service negative integration")
@MainActor
struct IrohServiceNegativeIntegrationCoverageTests {
    @Test func conflictCancellationIgnoresStaleRoomsThenQuarantinesCurrentRoom() async throws {
        let fixture = try IrohServiceFixture()
        let ticket = try await fixture.service.start(fixture.context)

        await fixture.service.markConflict(roomID: nil)
        await fixture.service.markConflict(roomID: "stale-room")
        #expect(try await fixture.service.currentEndpointTicket() == ticket)

        await fixture.service.markConflict(roomID: fixture.context.roomID)
        #expect(fixture.statuses.last == .conflict)
        await #expect(throws: IrohProtocolError.self) {
            try await fixture.service.currentEndpointTicket()
        }
    }

    @Test func authenticatedMacPeerGetsTypedErrorsAndConnectionRecovers() async throws {
        let fixture = try IrohServiceFixture()
        let session = try await IncomingMacPeerSession.connect(to: fixture)
        defer { Task { await session.close(service: fixture.service) } }

        let wrongRoom = try await session.request(.inventory(.init(
            protocolVersion: IrohProtocolV1.version,
            roomId: try IrohProtocolV1.roomID(for: Data(repeating: 42, count: 32)),
            requestId: IrohProtocolV1.makeRequestID(),
            kind: "inventory",
            after: nil,
            limit: 1
        )))
        let rejectedKind = try await session.request(.hello(try session.peerHello(
            roomID: fixture.context.roomID,
            requestID: IrohProtocolV1.makeRequestID()
        )))
        let missing = try await session.requestOperationsMessage(
            [.init(domain: .timer, id: "missing-operation")],
            roomID: fixture.context.roomID
        )

        #expect(errorCode(in: wrongRoom) == .wrongRoom)
        #expect(errorCode(in: rejectedKind) == .invalidRequest)
        #expect(errorCode(in: missing) == .notFound)
        let recovered = try await session.requestInventory(roomID: fixture.context.roomID)
        #expect(recovered.entries.contains { $0.domain == .genesis })
    }

    private func errorCode(in message: IrohRPCMessage) -> IrohErrorCode? {
        guard case .error(let response) = message else { return nil }
        return response.code
    }
}

@MainActor
private final class IrohServiceFixture {
    let context: IrohServiceContext
    let service: IrohReplicationService
    let store: IrohRoomStore
    private let statusRecorder: IrohStatusRecorder
    var statuses: [IrohConnectionStatus] { statusRecorder.statuses }

    init(keyStore: any IrohEndpointKeyStoring = FixedEndpointKeyStore()) throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        store = IrohRoomStore(
            fileURL: Self.temporaryURL(),
            secretStore: MemoryIrohRoomSecretStore()
        )
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Coverage room",
            returnState: .fresh(),
            genesis: Self.emptyGenesis()
        )
        let recorder = IrohStatusRecorder()
        context = IrohServiceContext(
            roomID: roomID,
            roomSecret: secret,
            deviceID: "device-service01",
            displayName: "Service",
            platform: "macos"
        )
        service = IrohReplicationService(
            store: store,
            keyStore: keyStore,
            statusHandler: { [weak recorder] status in recorder?.statuses.append(status) },
            projectionHandler: { _, _ in }
        )
        statusRecorder = recorder
    }

    private static func temporaryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PomodoroughTests", isDirectory: true)
            .appendingPathComponent("IrohService-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rooms.json")
    }

    private static func emptyGenesis() -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: nil,
            history: [],
            tasks: [],
            durationsMs: .defaults,
            autoStartBreaks: false,
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }
}

@MainActor
private final class IrohStatusRecorder {
    var statuses: [IrohConnectionStatus] = []
}

private struct FixedEndpointKeyStore: IrohEndpointKeyStoring {
    let secret: Data?

    init(secret: Data? = Data(repeating: 7, count: 32)) {
        self.secret = secret
    }

    func load() throws -> Data? { secret }
    func save(_ secret: Data) throws {}
}

private final class RecordingEndpointKeyStore: IrohEndpointKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: Data?
    private var saved: [Data] = []
    var savedSecret: Data? { lock.withLock { saved.last } }
    var savedSecrets: [Data] { lock.withLock { saved } }

    func load() throws -> Data? { lock.withLock { secret } }

    func save(_ secret: Data) throws {
        lock.withLock {
            self.secret = secret
            saved.append(secret)
        }
    }
}

private enum EndpointKeyStoreTestError: Error { case saveFailed }

private struct FailingEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { nil }
    func save(_ secret: Data) throws { throw EndpointKeyStoreTestError.saveFailed }
}

private final class IncomingMacPeerSession: @unchecked Sendable {
    let endpoint: Endpoint
    let connection: Connection
    let endpointTicket: String
    let secret: Data

    private init(endpoint: Endpoint, connection: Connection, endpointTicket: String, secret: Data) {
        self.endpoint = endpoint
        self.connection = connection
        self.endpointTicket = endpointTicket
        self.secret = secret
    }

    static func connect(to fixture: IrohServiceFixture) async throws -> IncomingMacPeerSession {
        let serviceTicket = try await fixture.service.start(fixture.context)
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            relayMode: RelayMode.disabled()
        ))
        let endpointTicket = try EndpointTicket.fromAddr(addr: endpoint.addr()).description
        let ticket = try EndpointTicket.fromString(str: serviceTicket)
        let connection = try await endpoint.connect(
            addr: ticket.endpointAddr(),
            alpn: IrohProtocolV1.alpn
        )
        let session = IncomingMacPeerSession(
            endpoint: endpoint,
            connection: connection,
            endpointTicket: endpointTicket,
            secret: fixture.context.roomSecret
        )
        try await session.authenticate(roomID: fixture.context.roomID, platform: fixture.context.platform)
        return session
    }

    func peerHello(roomID: String, requestID: String) throws -> IrohHello {
        IrohHello(
            protocolVersion: IrohProtocolV1.version,
            roomId: roomID,
            requestId: requestID,
            kind: "hello",
            deviceId: "device-macos-peer",
            endpointTicket: endpointTicket,
            platform: "macos",
            displayName: "Mac peer"
        )
    }

    func requestInventory(roomID: String) async throws -> IrohInventoryResult {
        let response = try await request(.inventory(.init(
            protocolVersion: IrohProtocolV1.version,
            roomId: roomID,
            requestId: IrohProtocolV1.makeRequestID(),
            kind: "inventory",
            after: nil,
            limit: IrohProtocolV1.maxInventoryEntries
        )))
        guard case .inventoryResult(let inventory) = response else {
            throw IrohProtocolError.invalidMessage("expected inventory result")
        }
        return inventory
    }

    func requestOperations(
        _ references: [IrohInventoryReference],
        roomID: String
    ) async throws -> IrohOperationsResult {
        let response = try await requestOperationsMessage(references, roomID: roomID)
        guard case .operationsResult(let operations) = response else {
            throw IrohProtocolError.invalidMessage("expected operations result")
        }
        return operations
    }

    func requestOperationsMessage(
        _ references: [IrohInventoryReference],
        roomID: String
    ) async throws -> IrohRPCMessage {
        try await request(.operations(.init(
            protocolVersion: IrohProtocolV1.version,
            roomId: roomID,
            requestId: IrohProtocolV1.makeRequestID(),
            kind: "operations",
            refs: references
        )))
    }

    func request(_ message: IrohRPCMessage) async throws -> IrohRPCMessage {
        let stream = try await connection.openBi()
        try await write(message, to: stream.send())
        return try await read(from: stream.recv())
    }

    func close(service: IrohReplicationService) async {
        try? connection.close(errorCode: 0, reason: Data("coverage complete".utf8))
        try? await endpoint.close()
        await service.stop()
    }

    private func authenticate(roomID: String, platform: String) async throws {
        let requestID = try IrohProtocolV1.makeRequestID()
        let response = try await request(.hello(try peerHello(roomID: roomID, requestID: requestID)))
        guard case .hello(let hello) = response,
              hello.requestId == requestID,
              hello.platform == platform else {
            throw IrohProtocolError.authenticationFailed
        }
    }

    private func read(from stream: RecvStream) async throws -> IrohRPCMessage {
        let header = try await stream.readExact(size: 36)
        let length = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = try await stream.readExact(size: length)
        var frame = header
        frame.append(body)
        return try IrohMessageCodec.decode(IrohFrameCodec.decode(frame, roomSecret: secret))
    }

    private func write(_ message: IrohRPCMessage, to stream: SendStream) async throws {
        let frame = try IrohFrameCodec.encode(body: message.encoded(), roomSecret: secret)
        try await stream.writeAll(buf: frame)
        try await stream.finish()
    }
}
