import Foundation
import IrohLib

struct IrohServiceContext: Sendable {
    let roomID: String
    let roomSecret: Data
    let deviceID: String
    let displayName: String?
    let platform: String
}

actor IrohReplicationService {
    typealias StatusHandler = @MainActor @Sendable (IrohConnectionStatus) -> Void
    typealias ProjectionHandler = @MainActor @Sendable (String, PersistedTimerState) -> Void

    private let store: IrohRoomStore
    private let keyStore: any IrohEndpointKeyStoring
    private let statusHandler: StatusHandler
    private let projectionHandler: ProjectionHandler
    private var endpoint: Endpoint?
    private var context: IrohServiceContext?
    private var endpointTicket: String?
    private var acceptTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var incomingTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingHandshakeIDs: Set<UUID> = []
    private var authenticatedConnectionIDs: Set<UUID> = []
    private var syncOwner: UUID?
    private var generation = 0

    private static let maxPendingHandshakes = 8
    private static let maxAuthenticatedConnections = 16
    private static let handshakeTimeout: Duration = .seconds(10)
    private static let requestTimeout: Duration = .seconds(30)

    private enum IncomingHandshakeResult: Sendable {
        case connected(Connection)
        case failed(String)
        case timedOut
    }

    init(
        store: IrohRoomStore,
        keyStore: any IrohEndpointKeyStoring = IrohEndpointKeychainStore(),
        statusHandler: @escaping StatusHandler,
        projectionHandler: @escaping ProjectionHandler
    ) {
        self.store = store
        self.keyStore = keyStore
        self.statusHandler = statusHandler
        self.projectionHandler = projectionHandler
    }

    deinit {
        acceptTask?.cancel()
        syncTask?.cancel()
        incomingTasks.values.forEach { $0.cancel() }
    }

    @discardableResult
    func start(_ context: IrohServiceContext) async throws -> String {
        if self.context?.roomID == context.roomID,
           let endpoint,
           !endpoint.isClosed(),
           let endpointTicket {
            return endpointTicket
        }
        await stop()
        generation += 1
        let owner = generation
        await statusHandler(.starting)
        let secret: Data
        if let stored = try keyStore.load() {
            guard stored.count == 32 else {
                throw IrohProtocolError.unavailable("Saved Iroh endpoint identity is invalid.")
            }
            secret = stored
        } else {
            secret = SecretKey.generate().toBytes()
            try keyStore.save(secret)
        }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            secretKey: secret,
            alpns: [IrohProtocolV1.alpn]
        ))
        guard owner == generation else {
            try? await endpoint.close()
            throw IrohProtocolError.unavailable("Iroh endpoint start was superseded.")
        }
        let ticket = try EndpointTicket.fromAddr(addr: endpoint.addr()).description
        self.endpoint = endpoint
        self.context = context
        endpointTicket = ticket
        acceptTask = Task { [weak self, endpoint] in
            await self?.acceptLoop(endpoint: endpoint, generation: owner)
        }
        syncTask = Task { [weak self] in
            await self?.periodicSyncLoop(generation: owner)
        }
        await statusHandler(.listening(endpointMark: endpoint.id().fmtShort()))
        guard owner == generation else {
            throw IrohProtocolError.unavailable("Iroh endpoint start was superseded.")
        }
        return ticket
    }

    func stop() async {
        generation += 1
        acceptTask?.cancel()
        syncTask?.cancel()
        incomingTasks.values.forEach { $0.cancel() }
        acceptTask = nil
        syncTask = nil
        incomingTasks.removeAll()
        pendingHandshakeIDs.removeAll()
        authenticatedConnectionIDs.removeAll()
        syncOwner = nil
        let closing = endpoint
        endpoint = nil
        endpointTicket = nil
        context = nil
        if let closing, !closing.isClosed() { try? await closing.close() }
        await statusHandler(.stopped)
    }

    func currentEndpointTicket() throws -> String {
        guard let endpoint, !endpoint.isClosed() else {
            throw IrohProtocolError.unavailable("Iroh endpoint is not running.")
        }
        let ticket = try EndpointTicket.fromAddr(addr: endpoint.addr()).description
        endpointTicket = ticket
        return ticket
    }

    func syncNow() async {
        guard let context else { return }
        _ = await syncKnownPeers(context: context, generation: generation)
    }

    func markConflict(roomID: String?) async {
        guard let roomID, context?.roomID == roomID else { return }
        await stopForConflict(generation: generation)
    }

    func join(invite: IrohRoomInvite) async throws {
        guard let endpoint, let context, context.roomID == invite.roomID else {
            throw IrohProtocolError.unavailable("Iroh endpoint is not ready for this room.")
        }
        let owner = generation
        while syncOwner != nil {
            try await Task.sleep(for: .milliseconds(25))
            guard owns(owner, roomID: invite.roomID) else { throw CancellationError() }
        }
        let joinID = UUID()
        syncOwner = joinID
        defer {
            if syncOwner == joinID { syncOwner = nil }
        }
        let ticket = try EndpointTicket.fromString(str: invite.endpointTicket)
        guard ticket.endpointAddr().id().description == invite.endpointID else {
            throw IrohProtocolError.invalidInvite("endpoint ticket identity changed")
        }
        try store.upsertPeer(
            IrohPeer(
                endpointID: invite.endpointID,
                endpointTicket: invite.endpointTicket,
                deviceID: nil,
                displayName: invite.roomName,
                lastSeenAt: nil
            ),
            roomID: invite.roomID
        )
        let connection = try await connect(
            endpoint: endpoint,
            ticket: ticket,
            generation: owner,
            roomID: context.roomID
        )
        guard owns(owner, roomID: context.roomID),
              connection.remoteId().description == invite.endpointID else {
            try? connection.close(errorCode: 1, reason: Data("ticket identity mismatch".utf8))
            throw IrohProtocolError.invalidInvite("connected endpoint does not match ticket")
        }
        try await performHello(connection: connection, context: context, generation: owner)
        let serving = serveAuthenticatedDial(
            connection,
            context: context,
            generation: owner
        )
        defer {
            serving.cancel()
            try? connection.close(errorCode: 0, reason: Data("sync complete".utf8))
        }
        try await pullUntilConverged(connection: connection, context: context, generation: owner)
        guard owns(owner, roomID: context.roomID),
              store.roomSnapshot(roomID: invite.roomID)?.operationCount ?? 0 > 0 else {
            throw IrohProtocolError.invalidMessage("room returned no genesis")
        }
    }

    private func acceptLoop(endpoint: Endpoint, generation owner: Int) async {
        while !Task.isCancelled, owner == generation, !endpoint.isClosed() {
            guard let incoming = await endpoint.acceptNext() else { return }
            guard pendingHandshakeIDs.count < Self.maxPendingHandshakes else {
                try? await incoming.ignore()
                continue
            }
            let id = UUID()
            pendingHandshakeIDs.insert(id)
            incomingTasks[id] = Task { [weak self] in
                await self?.processIncoming(incoming, id: id, generation: owner)
            }
        }
    }

    private func processIncoming(
        _ incoming: Incoming,
        id: UUID,
        generation owner: Int
    ) async {
        var connection: Connection?
        do {
            guard try await incoming.remoteAddrValidated() else {
                try await incoming.retry()
                pendingHandshakeIDs.remove(id)
                incomingTasks[id] = nil
                return
            }
            let accepting = try await incoming.accept()
            let accepted = try await connectIncoming(accepting)
            connection = accepted
            let context = try await withTimeout(after: Self.handshakeTimeout) { [self] in
                try await authenticateIncoming(connection: accepted, generation: owner)
            } onTimeout: {
                try? accepted.close(errorCode: 1, reason: Data("hello timed out".utf8))
            }
            pendingHandshakeIDs.remove(id)
            guard authenticatedConnectionIDs.count < Self.maxAuthenticatedConnections else {
                throw IrohProtocolError.limit("too many authenticated connections")
            }
            authenticatedConnectionIDs.insert(id)
            try await handleAuthenticatedConnection(
                accepted,
                context: context,
                generation: owner
            )
        } catch {
            if connection == nil { try? await incoming.ignore() }
        }
        pendingHandshakeIDs.remove(id)
        authenticatedConnectionIDs.remove(id)
        if let connection {
            try? connection.close(errorCode: 0, reason: Data("connection ended".utf8))
        }
        incomingTasks[id] = nil
    }

    private func connectIncoming(_ accepting: Accepting) async throws -> Connection {
        let events = AsyncStream<IncomingHandshakeResult> { continuation in
            Task {
                do {
                    let connection = try await accepting.connect()
                    switch continuation.yield(.connected(connection)) {
                    case .terminated:
                        try? connection.close(errorCode: 1, reason: Data("hello timed out".utf8))
                    case .enqueued, .dropped:
                        break
                    @unknown default:
                        try? connection.close(errorCode: 1, reason: Data("handshake ended".utf8))
                    }
                    continuation.finish()
                } catch {
                    _ = continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            Task {
                try? await Task.sleep(for: Self.handshakeTimeout)
                _ = continuation.yield(.timedOut)
                continuation.finish()
            }
        }
        var iterator = events.makeAsyncIterator()
        guard let result = await iterator.next() else {
            throw IrohProtocolError.unavailable("Iroh handshake did not complete.")
        }
        switch result {
        case .connected(let connection):
            return connection
        case .failed(let message):
            throw IrohProtocolError.unavailable(message)
        case .timedOut:
            throw IrohProtocolError.unavailable("Iroh handshake timed out.")
        }
    }

    private func authenticateIncoming(
        connection: Connection,
        generation owner: Int
    ) async throws -> IrohServiceContext {
        guard owner == generation, let context, connection.alpn() == IrohProtocolV1.alpn else {
            try? connection.close(errorCode: 1, reason: Data("wrong protocol".utf8))
            throw IrohProtocolError.authenticationFailed
        }
        let helloStream = try await connection.acceptBi()
        let helloMessage = try await readMessage(from: helloStream.recv(), secret: context.roomSecret)
        guard owns(owner, roomID: context.roomID) else { throw CancellationError() }
        guard case .hello(let hello) = helloMessage else {
            try? connection.close(errorCode: 1, reason: Data("hello required".utf8))
            throw IrohProtocolError.authenticationFailed
        }
        try validateHello(hello, context: context, remoteID: connection.remoteId().description)
        try store.upsertPeer(
            IrohPeer(
                endpointID: connection.remoteId().description,
                endpointTicket: hello.endpointTicket,
                deviceID: hello.deviceId,
                displayName: hello.displayName,
                lastSeenAt: .now
            ),
            roomID: context.roomID
        )
        try await writeMessage(
            .hello(try localHello(context: context, requestID: hello.requestId)),
            to: helloStream.send(),
            secret: context.roomSecret
        )
        guard owns(owner, roomID: context.roomID) else { throw CancellationError() }
        return context
    }

    private func handleAuthenticatedConnection(
        _ connection: Connection,
        context: IrohServiceContext,
        generation owner: Int
    ) async throws {
        while !Task.isCancelled, owner == generation, connection.closeReason() == nil {
            do {
                try await withTimeout(after: Self.requestTimeout) { [self] in
                    let stream = try await connection.acceptBi()
                    try await handleAuthenticatedRequest(stream, context: context)
                } onTimeout: {
                    try? connection.close(errorCode: 1, reason: Data("request timed out".utf8))
                }
            } catch {
                try? connection.close(errorCode: 0, reason: Data("connection ended".utf8))
                return
            }
        }
    }

    private func withTimeout<Value: Sendable>(
        after timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value,
        onTimeout: @escaping @Sendable () async -> Void
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await onTimeout()
                throw IrohProtocolError.unavailable("Iroh hello timed out.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw IrohProtocolError.unavailable("Iroh hello did not complete.")
            }
            return result
        }
    }

    private func handleAuthenticatedRequest(_ stream: BiStream, context: IrohServiceContext) async throws {
        let message: IrohRPCMessage
        do {
            message = try await readMessage(from: stream.recv(), secret: context.roomSecret)
        } catch IrohProtocolError.authenticationFailed, IrohProtocolError.invalidFrame {
            try? await stream.recv().stop(errorCode: 1)
            try? await stream.send().reset(errorCode: 1)
            return
        }
        let reply: IrohRPCMessage
        do {
            reply = try response(to: message, context: context)
        } catch let error as IrohProtocolError {
            reply = .error(errorResponse(for: error, requestID: message.requestID, roomID: context.roomID))
        }
        try await writeMessage(reply, to: stream.send(), secret: context.roomSecret)
    }

    private func response(to message: IrohRPCMessage, context: IrohServiceContext) throws -> IrohRPCMessage {
        switch message {
        case .inventory(let request):
            guard request.roomId == context.roomID else { throw IrohProtocolError.wrongRoom }
            let result = try store.inventory(roomID: context.roomID, after: request.after, limit: request.limit)
            return .inventoryResult(IrohInventoryResult(
                protocolVersion: IrohProtocolV1.version,
                roomId: context.roomID,
                requestId: request.requestId,
                kind: "inventoryResult",
                entries: result.entries,
                next: result.next
            ))
        case .operations(let request):
            guard request.roomId == context.roomID else { throw IrohProtocolError.wrongRoom }
            return .operationsResult(IrohOperationsResult(
                protocolVersion: IrohProtocolV1.version,
                roomId: context.roomID,
                requestId: request.requestId,
                kind: "operationsResult",
                records: try store.operations(roomID: context.roomID, references: request.refs)
            ))
        default:
            throw IrohProtocolError.invalidMessage("request kind is not accepted after hello")
        }
    }

    private func periodicSyncLoop(generation owner: Int) async {
        var delaySeconds = 2.0
        while !Task.isCancelled, owner == generation {
            guard let context else { return }
            let success = await syncKnownPeers(context: context, generation: owner)
            delaySeconds = success ? 15 : min(60, delaySeconds * 2)
            let sleepSeconds = Self.retryDelaySeconds(
                base: delaySeconds,
                jitterUnit: Double.random(in: 0...1)
            )
            do {
                try await Task.sleep(for: .seconds(sleepSeconds))
            } catch {
                return
            }
        }
    }

    nonisolated static func retryDelaySeconds(base: Double, jitterUnit: Double) -> Double {
        min(60, max(0, base) * (1 + min(1, max(0, jitterUnit)) * 0.2))
    }

    private func syncKnownPeers(context: IrohServiceContext, generation owner: Int) async -> Bool {
        guard owns(owner, roomID: context.roomID), syncOwner == nil, let endpoint else { return false }
        let syncID = UUID()
        syncOwner = syncID
        defer {
            if syncOwner == syncID { syncOwner = nil }
        }
        let peers: [IrohPeer]
        do {
            peers = try store.peers(roomID: context.roomID)
        } catch {
            await statusHandler(.unavailable(error.localizedDescription))
            return false
        }
        guard !peers.isEmpty else {
            await statusHandler(.waitingForPeers)
            return true
        }
        var synchronized = false
        for peer in peers where !Task.isCancelled && owner == generation {
            do {
                let ticket = try EndpointTicket.fromString(str: peer.endpointTicket)
                guard ticket.endpointAddr().id().description == peer.endpointID else {
                    throw IrohProtocolError.invalidMessage("saved peer ticket identity changed")
                }
                await statusHandler(.syncing(peerMark: ticket.endpointAddr().id().fmtShort()))
                let connection = try await connect(
                    endpoint: endpoint,
                    ticket: ticket,
                    generation: owner,
                    roomID: context.roomID
                )
                guard connection.remoteId().description == peer.endpointID else {
                    throw IrohProtocolError.authenticationFailed
                }
                try await performHello(connection: connection, context: context, generation: owner)
                let serving = serveAuthenticatedDial(
                    connection,
                    context: context,
                    generation: owner
                )
                defer {
                    serving.cancel()
                    try? connection.close(errorCode: 0, reason: Data("sync complete".utf8))
                }
                try await pullUntilConverged(connection: connection, context: context, generation: owner)
                guard owns(owner, roomID: context.roomID) else { return false }
                synchronized = true
            } catch IrohProtocolError.immutableConflict {
                await stopForConflict(generation: owner)
                return false
            } catch {
                continue
            }
        }
        if synchronized {
            await statusHandler(.listening(endpointMark: endpoint.id().fmtShort()))
        } else {
            await statusHandler(.waitingForPeers)
        }
        return synchronized
    }

    private func performHello(
        connection: Connection,
        context: IrohServiceContext,
        generation owner: Int
    ) async throws {
        let requestID = try IrohProtocolV1.makeRequestID()
        let response = try await request(
            .hello(try localHello(context: context, requestID: requestID)),
            on: connection,
            secret: context.roomSecret
        )
        guard case .hello(let hello) = response, hello.requestId == requestID else {
            throw IrohProtocolError.invalidMessage("peer did not return hello")
        }
        guard owns(owner, roomID: context.roomID) else { throw CancellationError() }
        try validateHello(hello, context: context, remoteID: connection.remoteId().description)
        try store.upsertPeer(
            IrohPeer(
                endpointID: connection.remoteId().description,
                endpointTicket: hello.endpointTicket,
                deviceID: hello.deviceId,
                displayName: hello.displayName,
                lastSeenAt: .now
            ),
            roomID: context.roomID
        )
    }

    private func serveAuthenticatedDial(
        _ connection: Connection,
        context: IrohServiceContext,
        generation owner: Int
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await self?.handleAuthenticatedConnection(
                connection,
                context: context,
                generation: owner
            )
        }
    }

    private func pullUntilConverged(
        connection: Connection,
        context: IrohServiceContext,
        generation owner: Int
    ) async throws {
        var foundChanges: Bool
        repeat {
            foundChanges = false
            var cursor: String?
            repeat {
                let requestID = try IrohProtocolV1.makeRequestID()
                let response = try await request(
                    .inventory(IrohInventoryRequest(
                        protocolVersion: IrohProtocolV1.version,
                        roomId: context.roomID,
                        requestId: requestID,
                        kind: "inventory",
                        after: cursor,
                        limit: IrohProtocolV1.maxInventoryEntries
                    )),
                    on: connection,
                    secret: context.roomSecret
                )
                guard case .inventoryResult(let inventory) = response,
                      inventory.requestId == requestID,
                      inventory.roomId == context.roomID else {
                    throw IrohProtocolError.invalidMessage("peer returned the wrong inventory result")
                }
                guard owns(owner, roomID: context.roomID),
                      validInventoryPage(inventory, after: cursor) else {
                    throw IrohProtocolError.invalidMessage("peer returned an invalid inventory cursor")
                }
                let missing = try store.missingReferences(roomID: context.roomID, remoteEntries: inventory.entries)
                let advertisedDigests = Dictionary(uniqueKeysWithValues: inventory.entries.map {
                    ($0.reference, $0.digest)
                })
                for start in stride(from: 0, to: missing.count, by: IrohProtocolV1.maxOperationReferences) {
                    let references = Array(missing[start..<min(missing.count, start + IrohProtocolV1.maxOperationReferences)])
                    let operationsID = try IrohProtocolV1.makeRequestID()
                    let operationsResponse = try await request(
                        .operations(IrohOperationsRequest(
                            protocolVersion: IrohProtocolV1.version,
                            roomId: context.roomID,
                            requestId: operationsID,
                            kind: "operations",
                            refs: references
                        )),
                        on: connection,
                        secret: context.roomSecret
                    )
                    guard case .operationsResult(let result) = operationsResponse,
                          result.requestId == operationsID,
                          result.roomId == context.roomID,
                          result.records.count == references.count,
                           Set(result.records.map {
                               IrohInventoryReference(domain: $0.domain, id: $0.id)
                           }) == Set(references),
                           result.records.allSatisfy({ record in
                               advertisedDigests[IrohInventoryReference(domain: record.domain, id: record.id)]
                                   == (try? record.digest())
                           }) else {
                        throw IrohProtocolError.invalidMessage("peer returned a partial operation set")
                    }
                    guard owns(owner, roomID: context.roomID) else { throw CancellationError() }
                    let projected = try store.insertRemoteRecords(result.records, roomID: context.roomID)
                    guard owns(owner, roomID: context.roomID) else { throw CancellationError() }
                    await projectionHandler(context.roomID, projected)
                    foundChanges = true
                }
                cursor = inventory.next
            } while cursor != nil
        } while foundChanges
    }

    private func request(
        _ message: IrohRPCMessage,
        on connection: Connection,
        secret: Data
    ) async throws -> IrohRPCMessage {
        let response = try await withTimeout(after: Self.requestTimeout) { [self] in
            let stream = try await connection.openBi()
            try await writeMessage(message, to: stream.send(), secret: secret)
            return try await readMessage(from: stream.recv(), secret: secret)
        } onTimeout: {
            try? connection.close(errorCode: 1, reason: Data("request timed out".utf8))
        }
        guard response.requestID == message.requestID else {
            throw IrohProtocolError.invalidMessage("response request ID does not match")
        }
        if case .error(let error) = response {
            if error.code == .immutableConflict { throw IrohProtocolError.immutableConflict }
            if error.code == .notFound { throw IrohProtocolError.notFound }
            throw IrohProtocolError.invalidMessage(error.message)
        }
        return response
    }

    private func connect(
        endpoint: Endpoint,
        ticket: EndpointTicket,
        generation owner: Int,
        roomID: String
    ) async throws -> Connection {
        let connection = try await withTimeout(after: Self.requestTimeout) {
            try await endpoint.connect(addr: ticket.endpointAddr(), alpn: IrohProtocolV1.alpn)
        } onTimeout: {}
        guard owns(owner, roomID: roomID) else {
            try? connection.close(errorCode: 1, reason: Data("connection superseded".utf8))
            throw CancellationError()
        }
        return connection
    }

    private func owns(_ owner: Int, roomID: String) -> Bool {
        owner == generation && context?.roomID == roomID
    }

    private func stopForConflict(generation owner: Int) async {
        guard owner == generation else { return }
        generation += 1
        let stoppedGeneration = generation
        acceptTask?.cancel()
        syncTask?.cancel()
        incomingTasks.values.forEach { $0.cancel() }
        acceptTask = nil
        syncTask = nil
        incomingTasks.removeAll()
        pendingHandshakeIDs.removeAll()
        authenticatedConnectionIDs.removeAll()
        syncOwner = nil
        let closing = endpoint
        endpoint = nil
        endpointTicket = nil
        context = nil
        if let closing, !closing.isClosed() { try? await closing.close() }
        guard stoppedGeneration == generation else { return }
        await statusHandler(.conflict)
    }

    private func validInventoryPage(_ inventory: IrohInventoryResult, after: String?) -> Bool {
        guard !inventory.entries.isEmpty else { return inventory.next == nil }
        if let next = inventory.next {
            guard let last = inventory.entries.last,
                  next == Self.cursor(last),
                  next != after else { return false }
        }
        guard let after else { return true }
        let parts = after.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let domain = IrohDomain(rawValue: String(parts[0])),
              let first = inventory.entries.first else { return false }
        return IrohRoomStore.referencePrecedesForProtocol(
            IrohInventoryReference(domain: domain, id: String(parts[1])),
            first.reference
        )
    }

    private static func cursor(_ entry: IrohInventoryEntry) -> String {
        entry.domain.rawValue + "\0" + entry.id
    }

    private func readMessage(from stream: RecvStream, secret: Data) async throws -> IrohRPCMessage {
        let header = try await stream.readExact(size: 36)
        let length = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= IrohProtocolV1.maxFrameBodyBytes else {
            throw IrohProtocolError.invalidFrame
        }
        let body = try await stream.readExact(size: length)
        let trailing = try await stream.read(sizeLimit: 1)
        guard trailing.isEmpty else { throw IrohProtocolError.invalidFrame }
        var frame = header
        frame.append(body)
        return try IrohMessageCodec.decode(IrohFrameCodec.decode(frame, roomSecret: secret))
    }

    private func writeMessage(_ message: IrohRPCMessage, to stream: SendStream, secret: Data) async throws {
        try await stream.writeAll(buf: IrohFrameCodec.encode(body: try message.encoded(), roomSecret: secret))
        try await stream.finish()
    }

    private func localHello(context: IrohServiceContext, requestID: String) throws -> IrohHello {
        let endpointTicket = try currentEndpointTicket()
        return IrohHello(
            protocolVersion: IrohProtocolV1.version,
            roomId: context.roomID,
            requestId: requestID,
            kind: "hello",
            deviceId: context.deviceID,
            endpointTicket: endpointTicket,
            platform: context.platform,
            displayName: context.displayName
        )
    }

    private func validateHello(_ hello: IrohHello, context: IrohServiceContext, remoteID: String) throws {
        guard hello.protocolVersion == IrohProtocolV1.version,
              hello.kind == "hello",
              hello.roomId == context.roomID,
              IrohProtocolV1.isValidRequestID(hello.requestId),
              IrohProtocolV1.isValidIdentifier(hello.deviceId),
              IrohProtocolV1.isValidDisplayName(hello.displayName),
              hello.endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes else {
            throw IrohProtocolError.invalidMessage("hello fields are invalid")
        }
        let ticket = try EndpointTicket.fromString(str: hello.endpointTicket)
        guard ticket.endpointAddr().id().description == remoteID else {
            throw IrohProtocolError.authenticationFailed
        }
    }

    private func errorResponse(
        for error: IrohProtocolError,
        requestID: String,
        roomID: String
    ) -> IrohErrorResponse {
        let code: IrohErrorCode
        switch error {
        case .immutableConflict: code = .immutableConflict
        case .notFound: code = .notFound
        case .limit: code = .limit
        case .authenticationFailed: code = .unauthorized
        case .wrongRoom: code = .wrongRoom
        case .invalidFrame: code = .badFrame
        case .invalidInvite, .invalidMessage: code = .invalidRequest
        case .unavailable: code = .internal
        }
        return IrohErrorResponse(
            protocolVersion: IrohProtocolV1.version,
            roomId: roomID,
            requestId: requestID,
            kind: "error",
            code: code,
            message: error.localizedDescription,
            retryable: code == .internal
        )
    }
}
