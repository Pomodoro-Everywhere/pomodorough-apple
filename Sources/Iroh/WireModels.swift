import CryptoKit
import Foundation

enum IrohProtocolV1 {
    static let version = 1
    static let alpn = Data("me.egigoka.pomodorough/sync/1".utf8)
    static let invitePrefix = "pomodorough1."
    static let maxFrameBodyBytes = 16 * 1_024 * 1_024
    static let maxOperationBytes = 64 * 1_024
    static let maxEndpointTicketBytes = 16 * 1_024
    static let maxInventoryEntries = 1_024
    static let maxOperationReferences = 255
    static let maxPeers = 64

    static func roomID(for secret: Data) throws -> String {
        guard secret.count == 32 else { throw IrohProtocolError.invalidInvite("room secret must be 32 bytes") }
        var input = Data("pomodorough-room-v1\0".utf8)
        input.append(secret)
        return Base64URL.encode(Data(SHA256.hash(data: input)))
    }

    static func makeRequestID(at date: Date = .now) throws -> String {
        guard let milliseconds = WireBounds.physicalMilliseconds(for: date),
              milliseconds <= UUIDv7.maxTimestampMs else {
            throw IrohProtocolError.invalidMessage("request clock is outside UUIDv7 range")
        }
        return try UUIDv7.reserve(timestampMs: milliseconds, previous: nil)[0]
            .uuidString.lowercased()
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (8...128).contains(bytes.count), let first = bytes.first else { return false }
        func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard isAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isAlphaNumeric($0) || $0 == 46 || $0 == 58 || $0 == 95 || $0 == 45
        }
    }

    static func isValidRequestID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return (try? UUIDv7.parts(of: uuid)) != nil
    }

    static func isValidTaskID(_ value: String) -> Bool {
        isValidIdentifier(value) && UUID(uuidString: value) != nil
    }

    static func isValidRoomID(_ value: String) -> Bool {
        guard let data = try? Base64URL.decode(value), data.count == 32 else { return false }
        return Base64URL.encode(data) == value
    }

    static func isValidDisplayName(_ value: String?) -> Bool {
        guard let value else { return true }
        return (1...64).contains(value.unicodeScalars.count)
    }

    static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }) else {
            throw IrohProtocolError.invalidInvite("malformed base64url")
        }
        let remainder = value.utf8.count % 4
        guard remainder != 1 else { throw IrohProtocolError.invalidInvite("malformed base64url") }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - remainder) % 4)
        guard let data = Data(base64Encoded: standard), encode(data) == value else {
            throw IrohProtocolError.invalidInvite("malformed base64url")
        }
        return data
    }
}

enum IrohDomain: String, Codable, CaseIterable, Sendable {
    case genesis
    case timer
    case task
    case duration
    case autoStart
    case selectedTask
}

struct IrohInventoryReference: Codable, Equatable, Hashable, Sendable {
    let domain: IrohDomain
    let id: String
}

struct IrohInventoryEntry: Codable, Equatable, Sendable {
    let domain: IrohDomain
    let id: String
    let digest: String

    var reference: IrohInventoryReference { .init(domain: domain, id: id) }
}

struct IrohHello: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let roomId: String
    let requestId: String
    let kind: String
    let deviceId: String
    let endpointTicket: String
    let platform: String
    let displayName: String?
}

struct IrohInventoryRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let roomId: String
    let requestId: String
    let kind: String
    let after: String?
    let limit: Int

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, roomId, requestId, kind, after, limit
    }

    init(
        protocolVersion: Int,
        roomId: String,
        requestId: String,
        kind: String,
        after: String?,
        limit: Int
    ) {
        self.protocolVersion = protocolVersion
        self.roomId = roomId
        self.requestId = requestId
        self.kind = kind
        self.after = after
        self.limit = limit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.after) else {
            throw DecodingError.keyNotFound(
                CodingKeys.after,
                .init(codingPath: values.codingPath, debugDescription: "Inventory requires after.")
            )
        }
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        roomId = try values.decode(String.self, forKey: .roomId)
        requestId = try values.decode(String.self, forKey: .requestId)
        kind = try values.decode(String.self, forKey: .kind)
        after = try values.decodeIfPresent(String.self, forKey: .after)
        limit = try values.decode(Int.self, forKey: .limit)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(roomId, forKey: .roomId)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(kind, forKey: .kind)
        if let after { try values.encode(after, forKey: .after) } else { try values.encodeNil(forKey: .after) }
        try values.encode(limit, forKey: .limit)
    }
}

struct IrohInventoryResult: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let roomId: String
    let requestId: String
    let kind: String
    let entries: [IrohInventoryEntry]
    let next: String?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, roomId, requestId, kind, entries, next
    }

    init(
        protocolVersion: Int,
        roomId: String,
        requestId: String,
        kind: String,
        entries: [IrohInventoryEntry],
        next: String?
    ) {
        self.protocolVersion = protocolVersion
        self.roomId = roomId
        self.requestId = requestId
        self.kind = kind
        self.entries = entries
        self.next = next
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.next) else {
            throw DecodingError.keyNotFound(
                CodingKeys.next,
                .init(codingPath: values.codingPath, debugDescription: "Inventory result requires next.")
            )
        }
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        roomId = try values.decode(String.self, forKey: .roomId)
        requestId = try values.decode(String.self, forKey: .requestId)
        kind = try values.decode(String.self, forKey: .kind)
        entries = try values.decode([IrohInventoryEntry].self, forKey: .entries)
        next = try values.decodeIfPresent(String.self, forKey: .next)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(roomId, forKey: .roomId)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(kind, forKey: .kind)
        try values.encode(entries, forKey: .entries)
        if let next { try values.encode(next, forKey: .next) } else { try values.encodeNil(forKey: .next) }
    }
}

struct IrohOperationsRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let roomId: String
    let requestId: String
    let kind: String
    let refs: [IrohInventoryReference]
}

struct IrohOperationsResult: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let roomId: String
    let requestId: String
    let kind: String
    let records: [IrohOperationRecord]
}

enum IrohErrorCode: String, Codable, Sendable {
    case badFrame = "bad_frame"
    case unauthorized
    case wrongRoom = "wrong_room"
    case unsupportedVersion = "unsupported_version"
    case invalidRequest = "invalid_request"
    case notFound = "not_found"
    case immutableConflict = "immutable_conflict"
    case limit
    case `internal`
}

struct IrohErrorResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let roomId: String
    let requestId: String
    let kind: String
    let code: IrohErrorCode
    let message: String
    let retryable: Bool
}
