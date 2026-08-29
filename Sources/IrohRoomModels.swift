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
