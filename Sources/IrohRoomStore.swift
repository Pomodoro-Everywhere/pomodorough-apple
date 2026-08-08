import Foundation

struct IrohPeer: Codable, Equatable, Sendable {
    let endpointID: String
    var endpointTicket: String
    var deviceID: String?
    var displayName: String?
    var lastSeenAt: Date?
}

struct IrohConflictEvidence: Codable, Equatable, Sendable {
    let domain: IrohDomain
    let id: String
    let localDigest: String
    let receivedDigest: String
    let detectedAt: Date
}

struct IrohStoredRecord: Codable, Equatable, Sendable {
    let record: IrohOperationRecord
    let digest: String
    let canonicalData: Data

    init(record: IrohOperationRecord, digest: String, canonicalData: Data) throws {
        self.record = try JSONDecoder.api.decode(IrohOperationRecord.self, from: canonicalData)
            .preservingCanonicalBytes(canonicalData)
        self.digest = digest
        self.canonicalData = canonicalData
    }

    private enum CodingKeys: String, CodingKey { case record, digest, canonicalData }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canonicalData = try values.decode(Data.self, forKey: .canonicalData)
        record = try values.decode(IrohOperationRecord.self, forKey: .record)
            .preservingCanonicalBytes(canonicalData)
        digest = try values.decode(String.self, forKey: .digest)
    }
}

struct IrohRoomWorkspace: Codable, Equatable, Sendable {
    let roomID: String
    var roomSecret: Data?
    var roomName: String?
    var returnState: PersistedTimerState
    var roomState: PersistedTimerState
    var peers: [IrohPeer]
    var records: [IrohStoredRecord]
    var conflict: IrohConflictEvidence?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case roomID, roomSecret, roomName, returnState, roomState, peers, records, conflict, createdAt
    }

    init(
        roomID: String,
        roomSecret: Data,
        roomName: String?,
        returnState: PersistedTimerState,
        roomState: PersistedTimerState,
        peers: [IrohPeer],
        records: [IrohStoredRecord],
        conflict: IrohConflictEvidence?,
        createdAt: Date
    ) {
        self.roomID = roomID
        self.roomSecret = roomSecret
        self.roomName = roomName
        self.returnState = returnState
        self.roomState = roomState
        self.peers = peers
        self.records = records
        self.conflict = conflict
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try values.decode(String.self, forKey: .roomID)
        roomSecret = try values.decodeIfPresent(Data.self, forKey: .roomSecret)
        roomName = try values.decodeIfPresent(String.self, forKey: .roomName)
        returnState = try values.decode(PersistedTimerState.self, forKey: .returnState)
        roomState = try values.decode(PersistedTimerState.self, forKey: .roomState)
        peers = try values.decode([IrohPeer].self, forKey: .peers)
        records = try values.decode([IrohStoredRecord].self, forKey: .records)
        conflict = try values.decodeIfPresent(IrohConflictEvidence.self, forKey: .conflict)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        if let roomSecret, try IrohProtocolV1.roomID(for: roomSecret) != roomID {
            throw IrohProtocolError.invalidMessage("saved room secret does not match its room")
        }
        guard IrohProtocolV1.isValidRoomID(roomID),
              IrohProtocolV1.isValidDisplayName(roomName),
              peers.count <= IrohProtocolV1.maxPeers,
              peers.allSatisfy({
                  $0.endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes
                      && IrohProtocolV1.isValidDisplayName($0.displayName)
              }) else {
            throw IrohProtocolError.invalidMessage("saved room metadata is invalid")
        }
        try IrohRoomStore.validateRecordSet(records)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(roomID, forKey: .roomID)
        try values.encodeIfPresent(roomName, forKey: .roomName)
        try values.encode(returnState, forKey: .returnState)
        try values.encode(roomState, forKey: .roomState)
        try values.encode(peers, forKey: .peers)
        try values.encode(records, forKey: .records)
        try values.encodeIfPresent(conflict, forKey: .conflict)
        try values.encode(createdAt, forKey: .createdAt)
    }

    var genesis: IrohGenesis? {
        records.lazy.compactMap { stored in
            guard case .genesis(let genesis) = stored.record.payload else { return nil }
            return genesis
        }.first
    }
}

struct IrohReplicationState: Codable, Equatable, Sendable {
    var activeRoomID: String?
    var rooms: [IrohRoomWorkspace]

    static let empty = Self(activeRoomID: nil, rooms: [])
}

struct IrohRoomSnapshot: Equatable, Sendable {
    let roomID: String
    let roomName: String?
    let peerCount: Int
    let operationCount: Int
    let conflict: IrohConflictEvidence?
}

final class IrohRoomStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let secretStore: any IrohRoomSecretStoring
    private var state: IrohReplicationState
    private var loadError: String?

    init(
        fileURL: URL = IrohRoomStore.defaultFileURL(),
        secretStore: any IrohRoomSecretStoring = IrohRoomSecretKeychainStore()
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        state = .empty
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                state = try JSONDecoder.api.decode(IrohReplicationState.self, from: data)
                var migratedLegacySecret = false
                for index in state.rooms.indices {
                    let roomID = state.rooms[index].roomID
                    let legacySecret = state.rooms[index].roomSecret
                    let storedSecret = try secretStore.load(roomID: roomID)
                    let secret: Data
                    if let storedSecret {
                        guard legacySecret == nil || legacySecret == storedSecret else {
                            throw IrohProtocolError.immutableConflict
                        }
                        secret = storedSecret
                        migratedLegacySecret = legacySecret != nil
                    } else if let legacySecret {
                        try secretStore.save(legacySecret, roomID: roomID)
                        secret = legacySecret
                        migratedLegacySecret = true
                    } else {
                        throw IrohProtocolError.unavailable("Saved room secret is missing from this device.")
                    }
                    guard try IrohProtocolV1.roomID(for: secret) == roomID else {
                        throw IrohProtocolError.invalidMessage("saved room secret does not match its room")
                    }
                    state.rooms[index].roomSecret = secret
                }
                if migratedLegacySecret { try persistLocked() }
            } else {
                state = .empty
            }
        } catch {
            state = .empty
            loadError = "Saved Iroh room data could not be decoded. Original file was left unchanged."
        }
    }

    var activeSnapshot: IrohRoomSnapshot? {
        lock.withLock {
            guard let room = activeWorkspaceLocked else { return nil }
            return snapshot(of: room)
        }
    }

    var activeRoomID: String? {
        lock.withLock { state.activeRoomID }
    }

    var activeRoomState: PersistedTimerState? {
        lock.withLock { activeWorkspaceLocked?.roomState }
    }

    var activeReturnState: PersistedTimerState? {
        lock.withLock { activeWorkspaceLocked?.returnState }
    }

    var activeRoomSecret: Data? {
        lock.withLock { activeWorkspaceLocked?.roomSecret }
    }

    var preferredRoomID: String? {
        lock.withLock {
            state.activeRoomID ?? state.rooms.max(by: { $0.createdAt < $1.createdAt })?.roomID
        }
    }

    func roomSnapshot(roomID: String) -> IrohRoomSnapshot? {
        lock.withLock {
            state.rooms.first(where: { $0.roomID == roomID }).map(snapshot)
        }
    }

    func createRoom(
        roomID: String,
        roomSecret: Data,
        name: String?,
        returnState: PersistedTimerState,
        genesis: IrohGenesis,
        now: Date = .now
    ) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard IrohProtocolV1.isValidRoomID(roomID),
                  try IrohProtocolV1.roomID(for: roomSecret) == roomID,
                  IrohProtocolV1.isValidDisplayName(name),
                  genesis.isValid else {
                throw IrohProtocolError.invalidMessage("room genesis is invalid")
            }
            guard state.rooms.first(where: { $0.roomID == roomID }) == nil else {
                throw IrohProtocolError.immutableConflict
            }
            var roomState = Self.makeRoomDeviceState(from: returnState)
            let genesisRecord = IrohOperationRecord(
                domain: .genesis,
                deviceId: returnState.deviceId,
                payload: .genesis(genesis)
            )
            guard genesisRecord.isValid,
                  try genesisRecord.operationByteCount() <= IrohProtocolV1.maxOperationBytes else {
                throw IrohProtocolError.invalidMessage("room genesis exceeds operation limits")
            }
            let canonicalData = try genesisRecord.canonicalBytes()
            let stored = try IrohStoredRecord(
                record: genesisRecord,
                digest: try genesisRecord.digest(),
                canonicalData: canonicalData
            )
            if let timer = genesis.canonicalTimer,
               timer.status == .running || timer.status == .paused,
               timer.startedByDeviceId == returnState.deviceId {
                roomState.localTimerOwners[timer.id] = returnState.deviceId
            }
            var workspace = IrohRoomWorkspace(
                roomID: roomID,
                roomSecret: roomSecret,
                roomName: name,
                returnState: returnState,
                roomState: roomState,
                peers: [],
                records: [stored],
                conflict: nil,
                createdAt: now
            )
            roomState = try IrohRoomProjection.project(workspace)
            workspace.roomState = roomState
            let installedSecret = try installSecretLocked(roomID: roomID, secret: roomSecret)
            do {
                return try committingLocked {
                    state.rooms.append(workspace)
                    state.activeRoomID = roomID
                    return roomState
                }
            } catch {
                if installedSecret { try? secretStore.delete(roomID: roomID) }
                throw error
            }
        }
    }

    func prepareJoinedRoom(
        roomID: String,
        roomSecret: Data,
        name: String?,
        returnState: PersistedTimerState,
        initialPeer: IrohPeer,
        now: Date = .now
    ) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard IrohProtocolV1.isValidRoomID(roomID),
                  try IrohProtocolV1.roomID(for: roomSecret) == roomID,
                  IrohProtocolV1.isValidDisplayName(name) else {
                throw IrohProtocolError.invalidInvite("room metadata is invalid")
            }
            let installedSecret = try installSecretLocked(roomID: roomID, secret: roomSecret)
            do {
                try committingLocked {
                    if let existingIndex = roomIndexLocked(roomID) {
                        guard state.activeRoomID != roomID,
                              state.rooms[existingIndex].genesis == nil,
                              state.rooms[existingIndex].conflict == nil,
                              state.rooms[existingIndex].roomSecret == roomSecret else {
                            throw IrohProtocolError.immutableConflict
                        }
                        state.rooms.remove(at: existingIndex)
                    }
                    state.rooms.append(IrohRoomWorkspace(
                        roomID: roomID,
                        roomSecret: roomSecret,
                        roomName: name,
                        returnState: returnState,
                        roomState: Self.makeRoomDeviceState(from: returnState),
                        peers: [initialPeer],
                        records: [],
                        conflict: nil,
                        createdAt: now
                    ))
                }
            } catch {
                if installedSecret { try? secretStore.delete(roomID: roomID) }
                throw error
            }
        }
    }

    func activateJoinedRoom(
        roomID: String,
        returnState: PersistedTimerState
    ) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let index = roomIndexLocked(roomID),
                  state.rooms[index].genesis != nil,
                  state.rooms[index].conflict == nil else {
                throw IrohProtocolError.invalidMessage("joined room has no valid genesis")
            }
            let projected = try IrohRoomProjection.project(state.rooms[index])
            return try committingLocked {
                state.rooms[index].returnState = returnState
                state.rooms[index].roomState = projected
                state.activeRoomID = roomID
                return projected
            }
        }
    }

    func activateExistingRoom(roomID: String, returnState: PersistedTimerState) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let index = roomIndexLocked(roomID), state.rooms[index].conflict == nil else {
                throw IrohProtocolError.invalidMessage("room is unavailable or requires repair")
            }
            return try committingLocked {
                state.rooms[index].returnState = returnState
                state.activeRoomID = roomID
                let projected = try IrohRoomProjection.project(state.rooms[index])
                state.rooms[index].roomState = projected
                return projected
            }
        }
    }

    func discardUnconflictedInactiveRoom(roomID: String) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard state.activeRoomID != roomID else {
                throw IrohProtocolError.invalidMessage("active room cannot be discarded")
            }
            guard let index = roomIndexLocked(roomID), state.rooms[index].conflict == nil else { return }
            try committingLocked { _ = state.rooms.remove(at: index) }
            try secretStore.delete(roomID: roomID)
        }
    }

    func captureLocalOperations(from stateToCapture: PersistedTimerState) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let roomID = state.activeRoomID, let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.unavailable("No Iroh room is active.")
            }
            let workspace = try capturedWorkspaceLocked(from: stateToCapture, index: index)
            return try committingLocked {
                state.rooms[index] = workspace
                return workspace.roomState
            }
        }
    }

    func captureAndSuspendActiveRoom(from stateToCapture: PersistedTimerState) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let roomID = state.activeRoomID, let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.unavailable("No Iroh room is active.")
            }
            let returnState = state.rooms[index].returnState
            let workspace = try capturedWorkspaceLocked(from: stateToCapture, index: index)
            return try committingLocked {
                state.rooms[index] = workspace
                state.activeRoomID = nil
                return returnState
            }
        }
    }

    @discardableResult
    func insertRemoteRecords(
        _ records: [IrohOperationRecord],
        roomID: String,
        now: Date = .now
    ) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard !records.isEmpty,
                  records.count <= IrohProtocolV1.maxOperationReferences,
                  let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.invalidMessage("operation batch is invalid")
            }
            guard state.rooms[index].conflict == nil else { throw IrohProtocolError.immutableConflict }

            let original = state.rooms[index]
            let incoming = try records.map { record -> IrohStoredRecord in
                guard record.isValid,
                      try record.operationByteCount() <= IrohProtocolV1.maxOperationBytes else {
                    throw IrohProtocolError.invalidMessage("operation record failed validation")
                }
                return try IrohStoredRecord(
                    record: record,
                    digest: try record.digest(),
                    canonicalData: try record.canonicalBytes()
                )
            }
            guard Set(incoming.map { $0.record.domain.rawValue + "\0" + $0.record.id }).count == incoming.count else {
                throw IrohProtocolError.invalidMessage("operation batch contains duplicate references")
            }

            for candidate in incoming {
                guard let existing = original.records.first(where: {
                    $0.record.domain == candidate.record.domain && $0.record.id == candidate.record.id
                }) else { continue }
                guard existing.digest == candidate.digest else {
                    var conflicted = original
                    conflicted.conflict = IrohConflictEvidence(
                        domain: candidate.record.domain,
                        id: candidate.record.id,
                        localDigest: existing.digest,
                        receivedDigest: candidate.digest,
                        detectedAt: now
                    )
                    try committingLocked { state.rooms[index] = conflicted }
                    throw IrohProtocolError.immutableConflict
                }
            }

            var staged = try inserting(records, into: original)
            if staged.genesis != nil {
                staged.roomState = try IrohRoomProjection.project(staged)
            }
            return try committingLocked {
                state.rooms[index] = staged
                return staged.roomState
            }
        }
    }

    func inventory(
        roomID: String,
        after: String?,
        limit: Int
    ) throws -> (entries: [IrohInventoryEntry], next: String?) {
        try lock.withLock {
            try ensureAvailableLocked()
            guard (1...IrohProtocolV1.maxInventoryEntries).contains(limit),
                  let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.invalidMessage("inventory request is invalid")
            }
            let ordered = room.records.map {
                IrohInventoryEntry(domain: $0.record.domain, id: $0.record.id, digest: $0.digest)
            }.sorted(by: Self.inventoryPrecedes)
            let start: Int
            if let after {
                guard let separator = after.firstIndex(of: "\0"),
                      let domain = IrohDomain(rawValue: String(after[..<separator])) else {
                    throw IrohProtocolError.invalidMessage("inventory cursor is invalid")
                }
                let id = String(after[after.index(after: separator)...])
                let cursor = IrohInventoryReference(domain: domain, id: id)
                start = ordered.firstIndex { entry in
                    Self.referencePrecedes(cursor, entry.reference)
                } ?? ordered.endIndex
            } else {
                start = ordered.startIndex
            }
            let end = min(ordered.endIndex, start + limit)
            let page = Array(ordered[start..<end])
            let next = end < ordered.endIndex ? page.last.map(Self.cursor) : nil
            return (page, next)
        }
    }

    func operations(
        roomID: String,
        references: [IrohInventoryReference]
    ) throws -> [IrohOperationRecord] {
        try lock.withLock {
            try ensureAvailableLocked()
            guard !references.isEmpty,
                  references.count <= IrohProtocolV1.maxOperationReferences,
                  Set(references).count == references.count,
                  let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.invalidMessage("operation request is invalid")
            }
            let records = try references.map { reference in
                guard let stored = room.records.first(where: {
                    $0.record.domain == reference.domain && $0.record.id == reference.id
                }) else { throw IrohProtocolError.notFound }
                return stored.record
            }
            guard records.count == references.count else { throw IrohProtocolError.notFound }
            return records
        }
    }

    func missingReferences(
        roomID: String,
        remoteEntries: [IrohInventoryEntry]
    ) throws -> [IrohInventoryReference] {
        try lock.withLock {
            try ensureAvailableLocked()
            guard remoteEntries.count <= IrohProtocolV1.maxInventoryEntries,
                  let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.invalidMessage("inventory result is invalid")
            }
            var missing: [IrohInventoryReference] = []
            for entry in remoteEntries {
                if let local = room.records.first(where: {
                    $0.record.domain == entry.domain && $0.record.id == entry.id
                }) {
                    guard local.digest == entry.digest else {
                        guard let index = roomIndexLocked(roomID) else {
                            throw IrohProtocolError.immutableConflict
                        }
                        try committingLocked {
                            state.rooms[index].conflict = IrohConflictEvidence(
                                domain: entry.domain,
                                id: entry.id,
                                localDigest: local.digest,
                                receivedDigest: entry.digest,
                                detectedAt: .now
                            )
                        }
                        throw IrohProtocolError.immutableConflict
                    }
                } else {
                    missing.append(entry.reference)
                }
            }
            return missing
        }
    }

    func upsertPeer(_ peer: IrohPeer, roomID: String) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard peer.endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes,
                  IrohProtocolV1.isValidDisplayName(peer.displayName),
                  let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.invalidMessage("peer metadata is invalid")
            }
            var workspace = state.rooms[index]
            if let peerIndex = workspace.peers.firstIndex(where: { $0.endpointID == peer.endpointID }) {
                workspace.peers[peerIndex] = peer
            } else {
                guard workspace.peers.count < IrohProtocolV1.maxPeers else {
                    throw IrohProtocolError.limit("room address book contains 64 peers")
                }
                workspace.peers.append(peer)
            }
            try committingLocked { state.rooms[index] = workspace }
        }
    }

    func replaceActiveReturnState(_ returnState: PersistedTimerState) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let roomID = state.activeRoomID, let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.notFound
            }
            try committingLocked { state.rooms[index].returnState = returnState }
        }
    }

    func peers(roomID: String) throws -> [IrohPeer] {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.notFound
            }
            return room.peers
        }
    }

    private func inserting(
        _ records: [IrohOperationRecord],
        into original: IrohRoomWorkspace
    ) throws -> IrohRoomWorkspace {
        var workspace = original
        for record in records {
            guard record.isValid else {
                throw IrohProtocolError.invalidMessage("operation record failed validation")
            }
            let digest = try record.digest()
            if let existing = workspace.records.first(where: {
                $0.record.domain == record.domain && $0.record.id == record.id
            }) {
                guard existing.digest == digest else { throw IrohProtocolError.immutableConflict }
                continue
            }
            workspace.records.append(try IrohStoredRecord(
                record: record,
                digest: digest,
                canonicalData: try record.canonicalBytes()
            ))
        }
        try Self.validateRecordSet(workspace.records)
        return workspace
    }

    private func capturedWorkspaceLocked(
        from stateToCapture: PersistedTimerState,
        index: Int
    ) throws -> IrohRoomWorkspace {
        guard state.rooms[index].conflict == nil else { throw IrohProtocolError.immutableConflict }
        var records: [IrohOperationRecord] = []
        records += stateToCapture.pendingCommands.map {
            IrohOperationRecord(domain: .timer, deviceId: stateToCapture.deviceId, payload: .timer($0))
        }
        records += stateToCapture.pendingTaskOperations.map {
            IrohOperationRecord(domain: .task, deviceId: stateToCapture.deviceId, payload: .task($0))
        }
        records += stateToCapture.pendingDurationOperations.map {
            IrohOperationRecord(domain: .duration, deviceId: stateToCapture.deviceId, payload: .duration($0))
        }
        records += stateToCapture.pendingAutoStartOperations.map {
            IrohOperationRecord(
                domain: .autoStart,
                deviceId: stateToCapture.deviceId,
                payload: .autoStart(IrohAutoStartOperation($0))
            )
        }
        let existingWorkspace = state.rooms[index]
        for record in records {
            guard let existing = existingWorkspace.records.first(where: {
                $0.record.domain == record.domain && $0.record.id == record.id
            }) else { continue }
            let receivedDigest = try record.digest()
            guard existing.digest == receivedDigest else {
                let evidence = IrohConflictEvidence(
                    domain: record.domain,
                    id: record.id,
                    localDigest: existing.digest,
                    receivedDigest: receivedDigest,
                    detectedAt: .now
                )
                try committingLocked { state.rooms[index].conflict = evidence }
                throw IrohProtocolError.immutableConflict
            }
        }
        var workspace = state.rooms[index]
        workspace.roomState = stateToCapture
        workspace.roomState.pendingCommands = []
        workspace.roomState.localCommandDates = [:]
        workspace.roomState.pendingTaskOperations = []
        workspace.roomState.pendingDurationOperations = []
        workspace.roomState.pendingAutoStartOperations = []
        workspace.roomState.provisionalBreaks = []
        workspace = try inserting(records, into: workspace)
        if workspace.genesis != nil {
            workspace.roomState = try IrohRoomProjection.project(workspace)
        }
        return workspace
    }

    fileprivate static func validateRecordSet(_ records: [IrohStoredRecord]) throws {
        let genesis = records.filter { $0.record.domain == .genesis && $0.record.id == "genesis" }
        guard genesis.count <= 1,
              records.allSatisfy({ $0.record.isValid }),
              records.allSatisfy({ stored in
                  guard let decoded = try? JSONDecoder.api.decode(
                      IrohOperationRecord.self,
                      from: stored.canonicalData
                  ) else { return false }
                  return decoded == stored.record
              }),
              records.allSatisfy({ (try? $0.record.digest()) == $0.digest }),
              records.allSatisfy({ (try? $0.record.operationByteCount()) ?? .max <= IrohProtocolV1.maxOperationBytes }),
              Set(records.map { $0.record.domain.rawValue + "\0" + $0.record.id }).count == records.count else {
            throw IrohProtocolError.invalidMessage("room operation set is invalid")
        }
        var sequences: [String: String] = [:]
        for stored in records {
            guard case .timer(let command) = stored.record.payload else { continue }
            let key = stored.record.deviceId + "\0" + String(command.deviceSequence)
            if let existing = sequences[key], existing != command.id {
                throw IrohProtocolError.invalidMessage("device sequence is reused")
            }
            sequences[key] = command.id
        }
    }

    private func ensureAvailableLocked() throws {
        if let loadError { throw IrohProtocolError.unavailable(loadError) }
    }

    private func installSecretLocked(roomID: String, secret: Data) throws -> Bool {
        if let existing = try secretStore.load(roomID: roomID) {
            guard existing == secret else { throw IrohProtocolError.immutableConflict }
            return false
        }
        try secretStore.save(secret, roomID: roomID)
        return true
    }

    private func persistLocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.api.encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func committingLocked<Value>(_ mutation: () throws -> Value) throws -> Value {
        let original = state
        do {
            let value = try mutation()
            try persistLocked()
            return value
        } catch {
            state = original
            throw error
        }
    }

    private var activeWorkspaceLocked: IrohRoomWorkspace? {
        guard let activeRoomID = state.activeRoomID else { return nil }
        return state.rooms.first(where: { $0.roomID == activeRoomID })
    }

    private func roomIndexLocked(_ roomID: String) -> Int? {
        state.rooms.firstIndex(where: { $0.roomID == roomID })
    }

    private func snapshot(of room: IrohRoomWorkspace) -> IrohRoomSnapshot {
        IrohRoomSnapshot(
            roomID: room.roomID,
            roomName: room.roomName,
            peerCount: room.peers.count,
            operationCount: room.records.count,
            conflict: room.conflict
        )
    }

    private static func makeRoomDeviceState(from local: PersistedTimerState) -> PersistedTimerState {
        var state = local
        state.revision = 0
        state.serverTimeOffsetMs = nil
        state.serverTimeUncertaintyMs = nil
        state.serverTimeAnchorMs = nil
        state.serverTimeAnchorUptime = nil
        state.lastTrustedTimeMs = nil
        state.pendingCommands = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        state.pendingAutoStartOperations = []
        state.localTimerOwners = [:]
        state.provisionalBreaks = []
        state.bootstrapUser = nil
        state.pendingBootstrapResolution = nil
        return state
    }

    private static func cursor(_ entry: IrohInventoryEntry) -> String {
        entry.domain.rawValue + "\0" + entry.id
    }

    private static func inventoryPrecedes(_ lhs: IrohInventoryEntry, _ rhs: IrohInventoryEntry) -> Bool {
        referencePrecedes(lhs.reference, rhs.reference)
    }

    private static func referencePrecedes(
        _ lhs: IrohInventoryReference,
        _ rhs: IrohInventoryReference
    ) -> Bool {
        if lhs.domain != rhs.domain {
            return IrohProtocolV1.utf8Precedes(lhs.domain.rawValue, rhs.domain.rawValue)
        }
        return IrohProtocolV1.utf8Precedes(lhs.id, rhs.id)
    }

    static func referencePrecedesForProtocol(
        _ lhs: IrohInventoryReference,
        _ rhs: IrohInventoryReference
    ) -> Bool {
        referencePrecedes(lhs, rhs)
    }

    static func resetDefaultStorage() throws {
        let url = defaultFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Pomodorough", isDirectory: true)
            .appendingPathComponent("iroh-rooms-v1.json")
    }
}

enum IrohRoomProjection {
    static func project(_ workspace: IrohRoomWorkspace) throws -> PersistedTimerState {
        guard workspace.conflict == nil,
              let genesis = workspace.genesis,
              genesis.isValid else {
            throw IrohProtocolError.invalidMessage("room genesis is missing or invalid")
        }
        let operations = workspace.records.map(\.record).filter { $0.domain != .genesis }.sorted(by: precedes)
        var timer = genesis.canonicalTimer
        var history = genesis.history
        var tasks = genesis.tasks
        var durations = genesis.durationsMs
        var autoStartBreaks = genesis.autoStartBreaks
        var knownTasks = Dictionary(uniqueKeysWithValues: genesis.tasks.map { ($0.id, $0) })
        let genesisDeviceID = workspace.records.first {
            $0.record.domain == .genesis && $0.record.id == "genesis"
        }!.record.deviceId
        var timerStarters = Dictionary(
            uniqueKeysWithValues: genesis.history.map { ($0.timerId, genesisDeviceID) }
        )
        if let genesisTimer = genesis.canonicalTimer {
            timerStarters[genesisTimer.id] = genesisTimer.startedByDeviceId ?? genesisDeviceID
        }

        for record in operations {
            switch record.payload {
            case .genesis:
                throw IrohProtocolError.invalidMessage("room contains an extra genesis record")
            case .timer(let command):
                let result = TimerReducer.apply(command, to: timer, history: history)
                if command.type == .start,
                   result.0?.id == command.timerId,
                   result.0?.lastIntent?.commandId == command.id {
                    timerStarters[command.timerId] = record.deviceId
                }
                timer = result.0.map { projectedTimer in
                    guard projectedTimer.lastIntent?.commandId == command.id,
                          let intent = projectedTimer.lastIntent else { return projectedTimer }
                    let startedByDeviceId = command.type == .start
                        && projectedTimer.lastIntent?.commandId == command.id
                        ? record.deviceId
                        : projectedTimer.startedByDeviceId ?? timerStarters[projectedTimer.id]
                    return CanonicalTimer(
                        id: projectedTimer.id,
                        taskId: projectedTimer.taskId,
                        phase: projectedTimer.phase,
                        status: projectedTimer.status,
                        plannedDurationMs: projectedTimer.plannedDurationMs,
                        elapsedAtAnchorMs: projectedTimer.elapsedAtAnchorMs,
                        anchorAt: projectedTimer.anchorAt,
                        startedByDeviceId: startedByDeviceId,
                        lastIntent: TimerIntent(
                            type: intent.type,
                            commandId: intent.commandId,
                            occurredAt: intent.occurredAt,
                            deviceId: record.deviceId
                        )
                    )
                }
                history = result.1
            case .task(let operation):
                tasks = TaskReducer.applying([operation], to: tasks)
                if operation.type == .upsert,
                   let title = operation.title,
                   let task = FocusTask(title: title) {
                    knownTasks[task.id] = task
                }
            case .duration(let operation):
                durations = DurationReducer.applying([operation], to: durations)
            case .autoStart(let operation):
                autoStartBreaks = operation.enabled
            }
        }

        guard IrohSnapshotValidation.isValid(
            timer: timer,
            history: history,
            tasks: tasks,
            durations: durations
        ) else {
            throw IrohProtocolError.invalidMessage("room projection is invalid")
        }
        tasks.sort(by: taskPrecedes)
        history.sort(by: historyPrecedes)

        var state = workspace.roomState
        state.canonicalTimer = timer
        state.history = history
        state.tasks = tasks
        state.knownTasks = Array(knownTasks.values)
        state.settings.durationsMs = durations
        state.autoStartBreaks = autoStartBreaks
        state.pendingCommands = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        state.pendingAutoStartOperations = []
        state.provisionalBreaks = []
        if let selected = state.selectedTaskID, !tasks.contains(where: { $0.id == selected }) {
            state.selectedTaskID = nil
        }
        let maximum = ([
            (genesis.hlcWallMs, genesis.hlcCounter),
            (state.hlcWallMs, state.hlcCounter),
        ] + operations.map(\.order)).max { $0 < $1 } ?? (0, 0)
        state.hlcWallMs = maximum.0
        state.hlcCounter = maximum.1
        return state
    }

    static func precedes(_ lhs: IrohOperationRecord, _ rhs: IrohOperationRecord) -> Bool {
        if lhs.order.wallMs != rhs.order.wallMs { return lhs.order.wallMs < rhs.order.wallMs }
        if lhs.order.counter != rhs.order.counter { return lhs.order.counter < rhs.order.counter }
        if lhs.deviceId != rhs.deviceId {
            return IrohProtocolV1.utf8Precedes(lhs.deviceId, rhs.deviceId)
        }
        return IrohProtocolV1.utf8Precedes(lhs.id, rhs.id)
    }

    private static func taskPrecedes(_ lhs: FocusTask, _ rhs: FocusTask) -> Bool {
        if lhs.title != rhs.title {
            return IrohProtocolV1.utf8Precedes(lhs.title, rhs.title)
        }
        return IrohProtocolV1.utf8Precedes(
            lhs.id.uuidString.lowercased(),
            rhs.id.uuidString.lowercased()
        )
    }

    private static func historyPrecedes(_ lhs: HistoryItem, _ rhs: HistoryItem) -> Bool {
        let lhsDate = lhs.completedAt ?? lhs.endedAt ?? .distantPast
        let rhsDate = rhs.completedAt ?? rhs.endedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return IrohProtocolV1.utf8Precedes(lhs.timerId, rhs.timerId)
    }
}
