import CoreFoundation
import CryptoKit
import Foundation
import IrohLib

enum ReplicationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case offline
    case iroh
    case centralized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .offline: "On device"
        case .iroh: "Iroh room"
        case .centralized: "Pomodorough Cloud"
        }
    }
}

enum IrohConnectionStatus: Equatable, Sendable {
    case stopped
    case starting
    case listening(endpointMark: String)
    case syncing(peerMark: String)
    case waitingForPeers
    case conflict
    case unavailable(String)

    var label: String {
        switch self {
        case .stopped: "Not connected"
        case .starting: "Opening route"
        case .listening: "Ready for peers"
        case .syncing: "Exchanging changes"
        case .waitingForPeers: "Waiting for peers"
        case .conflict: "Repair required"
        case .unavailable: "Unavailable"
        }
    }
}

enum IrohProtocolError: Error, LocalizedError, Sendable {
    case invalidInvite(String)
    case invalidFrame
    case authenticationFailed
    case wrongRoom
    case invalidMessage(String)
    case immutableConflict
    case limit(String)
    case notFound
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInvite(let reason): "Invalid room invite: \(reason)"
        case .invalidFrame: "Peer sent a malformed synchronization frame."
        case .authenticationFailed: "Room authentication failed."
        case .wrongRoom: "Peer requested a different room."
        case .invalidMessage(let reason): "Peer sent an invalid synchronization message: \(reason)"
        case .immutableConflict: "Room contains two different operations with the same immutable ID."
        case .limit(let reason): "Synchronization limit exceeded: \(reason)"
        case .notFound: "Requested room operation was not found."
        case .unavailable(let reason): reason
        }
    }
}

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

enum StrictJSON {
    static func object(from data: Data) throws -> [String: Any]? {
        guard let source = String(data: data, encoding: .utf8) else {
            throw IrohProtocolError.invalidMessage("JSON must be valid UTF-8")
        }
        var scanner = Scanner(source)
        try scanner.validateDocument()
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func isExactUnixEpoch(_ value: String) -> Bool {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let standard = Date.ISO8601FormatStyle()
        let date = (try? fractional.parse(value)) ?? (try? standard.parse(value))
        return date == Date(timeIntervalSince1970: 0)
    }

    private struct Scanner {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ source: String) {
            scalars = Array(source.unicodeScalars)
        }

        mutating func validateDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == scalars.count else { throw invalidJSON }
        }

        private mutating func parseValue() throws {
            guard let scalar = current else { throw invalidJSON }
            switch scalar.value {
            case 0x7b: try parseObject()
            case 0x5b: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try parseLiteral("true")
            case 0x66: try parseLiteral("false")
            case 0x6e: try parseLiteral("null")
            case 0x2d, 0x30...0x39: try parseNumber()
            default: throw invalidJSON
            }
        }

        private mutating func parseObject() throws {
            try consume(0x7b)
            skipWhitespace()
            if consumeIfPresent(0x7d) { return }
            var keys = Set<String>()
            while true {
                guard current?.value == 0x22 else { throw invalidJSON }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw IrohProtocolError.invalidMessage("JSON contains a duplicate object key")
                }
                skipWhitespace()
                try consume(0x3a)
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consumeIfPresent(0x7d) { return }
                try consume(0x2c)
                skipWhitespace()
            }
        }

        private mutating func parseArray() throws {
            try consume(0x5b)
            skipWhitespace()
            if consumeIfPresent(0x5d) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consumeIfPresent(0x5d) { return }
                try consume(0x2c)
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            try consume(0x22)
            var result = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                switch scalar.value {
                case 0x22:
                    return String(result)
                case 0x00...0x1f:
                    throw invalidJSON
                case 0x5c:
                    guard let escaped = current else { throw invalidJSON }
                    index += 1
                    switch escaped.value {
                    case 0x22, 0x2f, 0x5c: result.append(escaped)
                    case 0x62: result.append(Unicode.Scalar(0x08)!)
                    case 0x66: result.append(Unicode.Scalar(0x0c)!)
                    case 0x6e: result.append(Unicode.Scalar(0x0a)!)
                    case 0x72: result.append(Unicode.Scalar(0x0d)!)
                    case 0x74: result.append(Unicode.Scalar(0x09)!)
                    case 0x75: try appendUnicodeEscape(to: &result)
                    default: throw invalidJSON
                    }
                default:
                    result.append(scalar)
                }
            }
            throw invalidJSON
        }

        private mutating func appendUnicodeEscape(to result: inout String.UnicodeScalarView) throws {
            let first = try parseHexQuad()
            switch first {
            case 0xd800...0xdbff:
                try consume(0x5c)
                try consume(0x75)
                let second = try parseHexQuad()
                guard (0xdc00...0xdfff).contains(second),
                      let scalar = Unicode.Scalar(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00) else {
                    throw invalidJSON
                }
                result.append(scalar)
            case 0xdc00...0xdfff:
                throw invalidJSON
            default:
                guard let scalar = Unicode.Scalar(first) else { throw invalidJSON }
                result.append(scalar)
            }
        }

        private mutating func parseHexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let scalar = current, let digit = hexValue(scalar.value) else { throw invalidJSON }
                index += 1
                value = (value << 4) | digit
            }
            return value
        }

        private mutating func parseNumber() throws {
            _ = consumeIfPresent(0x2d)
            guard let scalar = current else { throw invalidJSON }
            if scalar.value == 0x30 {
                index += 1
                if let next = current, (0x30...0x39).contains(next.value) { throw invalidJSON }
            } else {
                guard (0x31...0x39).contains(scalar.value) else { throw invalidJSON }
                repeat { index += 1 } while current.map { (0x30...0x39).contains($0.value) } == true
            }
            if consumeIfPresent(0x2e) {
                guard current.map({ (0x30...0x39).contains($0.value) }) == true else { throw invalidJSON }
                repeat { index += 1 } while current.map { (0x30...0x39).contains($0.value) } == true
            }
            if current?.value == 0x65 || current?.value == 0x45 {
                index += 1
                if current?.value == 0x2b || current?.value == 0x2d { index += 1 }
                guard current.map({ (0x30...0x39).contains($0.value) }) == true else { throw invalidJSON }
                repeat { index += 1 } while current.map { (0x30...0x39).contains($0.value) } == true
            }
        }

        private mutating func parseLiteral(_ literal: StaticString) throws {
            for byte in literal.withUTF8Buffer({ Array($0) }) {
                try consume(UInt32(byte))
            }
        }

        private mutating func consume(_ value: UInt32) throws {
            guard current?.value == value else { throw invalidJSON }
            index += 1
        }

        private mutating func consumeIfPresent(_ value: UInt32) -> Bool {
            guard current?.value == value else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while let value = current?.value, value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d {
                index += 1
            }
        }

        private var current: Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        private func hexValue(_ value: UInt32) -> UInt32? {
            switch value {
            case 0x30...0x39: value - 0x30
            case 0x41...0x46: value - 0x41 + 10
            case 0x61...0x66: value - 0x61 + 10
            default: nil
            }
        }

        private var invalidJSON: IrohProtocolError {
            .invalidMessage("body is not strict JSON")
        }
    }
}

struct IrohRoomInvite: Equatable, Sendable {
    let roomID: String
    let roomName: String?
    let endpointTicket: String
    let endpointID: String
    let roomSecret: Data

    init(roomID: String, roomName: String?, endpointTicket: String, roomSecret: Data) throws {
        guard try IrohProtocolV1.roomID(for: roomSecret) == roomID else {
            throw IrohProtocolError.invalidInvite("room ID does not match room secret")
        }
        guard IrohProtocolV1.isValidDisplayName(roomName) else {
            throw IrohProtocolError.invalidInvite("room name must contain 1 through 64 Unicode scalars")
        }
        guard !endpointTicket.isEmpty,
              endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes else {
            throw IrohProtocolError.invalidInvite("endpoint ticket exceeds 16 KiB")
        }
        let parsedTicket: EndpointTicket
        do {
            parsedTicket = try EndpointTicket.fromString(str: endpointTicket)
        } catch {
            throw IrohProtocolError.invalidInvite("endpoint ticket is malformed")
        }
        self.roomID = roomID
        self.roomName = roomName
        self.endpointTicket = endpointTicket
        endpointID = parsedTicket.endpointAddr().id().description
        self.roomSecret = roomSecret
    }

    func encoded() throws -> String {
        var object: [String: Any] = [
            "v": IrohProtocolV1.version,
            "roomId": roomID,
            "endpointTicket": endpointTicket,
            "roomSecret": Base64URL.encode(roomSecret),
        ]
        if let roomName { object["roomName"] = roomName }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return IrohProtocolV1.invitePrefix + Base64URL.encode(data)
    }

    static func decode(_ text: String) throws -> Self {
        guard text.hasPrefix(IrohProtocolV1.invitePrefix) else {
            throw IrohProtocolError.invalidInvite("expected \(IrohProtocolV1.invitePrefix) prefix")
        }
        let encoded = String(text.dropFirst(IrohProtocolV1.invitePrefix.count))
        let data = try Base64URL.decode(encoded)
        guard let object = try StrictJSON.object(from: data) else {
            throw IrohProtocolError.invalidInvite("payload must be a JSON object")
        }
        let required = Set(["v", "roomId", "endpointTicket", "roomSecret"])
        let allowed = required.union(["roomName"])
        guard required.isSubset(of: object.keys), Set(object.keys).isSubset(of: allowed) else {
            throw IrohProtocolError.invalidInvite("payload has missing or unknown fields")
        }
        guard let version = object["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == IrohProtocolV1.version,
              version.doubleValue == Double(version.intValue) else {
            throw IrohProtocolError.invalidInvite("unsupported version")
        }
        guard let roomID = object["roomId"] as? String,
              IrohProtocolV1.isValidRoomID(roomID),
              let endpointTicket = object["endpointTicket"] as? String,
              let secretText = object["roomSecret"] as? String else {
            throw IrohProtocolError.invalidInvite("payload field types are invalid")
        }
        if object.keys.contains("roomName"), object["roomName"] is NSNull {
            throw IrohProtocolError.invalidInvite("roomName must be omitted instead of null")
        }
        let roomName = object["roomName"] as? String
        let secret = try Base64URL.decode(secretText)
        guard secret.count == 32 else {
            throw IrohProtocolError.invalidInvite("room secret must be 32 bytes")
        }
        return try Self(
            roomID: roomID,
            roomName: roomName,
            endpointTicket: endpointTicket,
            roomSecret: secret
        )
    }
}

enum IrohFrameCodec {
    private static let macPrefix = Data("pomodorough-iroh-frame-v1\0".utf8)

    static func encode(body: Data, roomSecret: Data) throws -> Data {
        guard roomSecret.count == 32,
              body.count <= IrohProtocolV1.maxFrameBodyBytes,
              body.count <= Int(UInt32.max) else {
            throw IrohProtocolError.invalidFrame
        }
        var authenticated = macPrefix
        authenticated.append(body)
        let mac = HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: roomSecret)
        )
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(contentsOf: mac)
        frame.append(body)
        return frame
    }

    static func decode(_ frame: Data, roomSecret: Data) throws -> Data {
        guard roomSecret.count == 32, frame.count >= 36 else {
            throw IrohProtocolError.invalidFrame
        }
        let lengthData = frame.prefix(4)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= IrohProtocolV1.maxFrameBodyBytes,
              frame.count == 36 + Int(length) else {
            throw IrohProtocolError.invalidFrame
        }
        let suppliedMAC = frame[4..<36]
        let body = Data(frame.dropFirst(36))
        var authenticated = macPrefix
        authenticated.append(body)
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: roomSecret)
        ))
        guard constantTimeEqual(Data(suppliedMAC), expectedMAC) else {
            throw IrohProtocolError.authenticationFailed
        }
        return body
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

enum IrohDomain: String, Codable, CaseIterable, Sendable {
    case genesis
    case timer
    case task
    case duration
    case autoStart
}

struct IrohGenesis: Codable, Equatable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        IrohSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs
        ) && ((hlcWallMs == 0 && hlcCounter == 0)
            || WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter))
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalTimer, history, tasks, durationsMs, autoStartBreaks, hlcWallMs, hlcCounter
    }

    init(
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durationsMs: DurationValues,
        autoStartBreaks: Bool,
        hlcWallMs: Int64,
        hlcCounter: Int64
    ) {
        self.canonicalTimer = canonicalTimer
        self.history = history
        self.tasks = tasks
        self.durationsMs = durationsMs
        self.autoStartBreaks = autoStartBreaks
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.canonicalTimer) else {
            throw DecodingError.keyNotFound(
                CodingKeys.canonicalTimer,
                .init(codingPath: values.codingPath, debugDescription: "Genesis requires canonicalTimer.")
            )
        }
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decode([FocusTask].self, forKey: .tasks)
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        hlcWallMs = try values.decode(Int64.self, forKey: .hlcWallMs)
        hlcCounter = try values.decode(Int64.self, forKey: .hlcCounter)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let canonicalTimer {
            try values.encode(canonicalTimer, forKey: .canonicalTimer)
        } else {
            try values.encodeNil(forKey: .canonicalTimer)
        }
        try values.encode(history, forKey: .history)
        try values.encode(tasks, forKey: .tasks)
        try values.encode(durationsMs, forKey: .durationsMs)
        try values.encode(autoStartBreaks, forKey: .autoStartBreaks)
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
    }
}

enum IrohSnapshotValidation {
    static func isValid(
        timer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durations: DurationValues
    ) -> Bool {
        durations.isValid
            && (timer.map(isValidTimer) ?? true)
            && history.allSatisfy(isValidHistory)
            && tasks.allSatisfy(\.isValid)
            && Set(history.map(\.id)).count == history.count
            && Set(history.map(\.timerId)).count == history.count
            && Set(tasks.map(\.id)).count == tasks.count
    }

    private static func isValidTimer(_ timer: CanonicalTimer) -> Bool {
        IrohProtocolV1.isValidIdentifier(timer.id)
            && (timer.taskId.map(IrohProtocolV1.isValidTaskID) ?? true)
            && (60_000...14_400_000).contains(timer.plannedDurationMs)
            && (0...timer.plannedDurationMs).contains(timer.elapsedAtAnchorMs)
            && WireBounds.physicalMilliseconds(for: timer.anchorAt) != nil
            && (timer.startedByDeviceId.map(IrohProtocolV1.isValidIdentifier) ?? true)
            && (timer.lastIntent?.isValid ?? true)
    }

    private static func isValidHistory(_ item: HistoryItem) -> Bool {
        let hasValidTerminalDate: Bool
        switch item.status {
        case CanonicalTimer.Status.completed.rawValue:
            hasValidTerminalDate = item.completedAt != nil
        case CanonicalTimer.Status.cancelled.rawValue,
             CanonicalTimer.Status.superseded.rawValue:
            hasValidTerminalDate = item.completedAt == nil && item.endedAt != nil
        default:
            hasValidTerminalDate = false
        }
        return IrohProtocolV1.isValidIdentifier(item.id)
            && IrohProtocolV1.isValidIdentifier(item.timerId)
            && (item.commandId.map(IrohProtocolV1.isValidIdentifier) ?? true)
            && (item.taskId.map(IrohProtocolV1.isValidTaskID) ?? true)
            && (60_000...14_400_000).contains(item.plannedDurationMs)
            && hasValidTerminalDate
            && item.date.flatMap(WireBounds.physicalMilliseconds(for:)) != nil
            && (item.endedAt == nil || item.endedAt.flatMap(WireBounds.physicalMilliseconds(for:)) != nil)
    }
}

enum IrohOperationPayload: Equatable, Sendable {
    case genesis(IrohGenesis)
    case timer(TimerCommand)
    case task(TaskOperation)
    case duration(DurationOperation)
    case autoStart(IrohAutoStartOperation)
}

struct IrohAutoStartOperation: Codable, Equatable, Sendable {
    let id: String
    let enabled: Bool
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(id: String, enabled: Bool, occurredAt: Date, hlcWallMs: Int64, hlcCounter: Int64) {
        self.id = id
        self.enabled = enabled
        self.occurredAt = occurredAt
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
    }

    init(_ operation: AutoStartOperation) {
        id = operation.id.uuidString.lowercased()
        enabled = operation.enabled
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    var isValid: Bool {
        IrohProtocolV1.isValidIdentifier(id)
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter, allowsLegacySentinel: true)
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(wallMs: hlcWallMs, counter: hlcCounter, occurredAt: occurredAt)
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

struct IrohOperationRecord: Codable, Equatable, Sendable {
    let domain: IrohDomain
    let deviceId: String
    let payload: IrohOperationPayload
    private var canonicalData: Data?

    var id: String {
        switch payload {
        case .genesis: "genesis"
        case .timer(let value): value.id
        case .task(let value): value.id
        case .duration(let value): value.id
        case .autoStart(let value): value.id
        }
    }

    var order: (wallMs: Int64, counter: Int64) {
        switch payload {
        case .genesis(let value): (value.hlcWallMs, value.hlcCounter)
        case .timer(let value): (value.hlcWallMs, value.hlcCounter)
        case .task(let value): (value.hlcWallMs, value.hlcCounter)
        case .duration(let value): (value.hlcWallMs, value.hlcCounter)
        case .autoStart(let value): (value.hlcWallMs, value.hlcCounter)
        }
    }

    var isValid: Bool {
        guard IrohProtocolV1.isValidIdentifier(deviceId) else { return false }
        switch (domain, payload) {
        case (.genesis, .genesis(let value)):
            return value.isValid
        case (.timer, .timer(let value)):
            return (1...WireBounds.maxSafeInteger).contains(value.deviceSequence)
                && (60_000...14_400_000).contains(value.plannedDurationMs)
                && (-WireBounds.maxSafeInteger...WireBounds.maxSafeInteger).contains(value.observedElapsedMs)
                && WireBounds.isValidClock(wallMs: value.hlcWallMs, counter: value.hlcCounter)
                && WireBounds.isWithinClockSkew(wallMs: value.hlcWallMs, occurredAt: value.occurredAt)
                && IrohProtocolV1.isValidIdentifier(value.id)
                && IrohProtocolV1.isValidIdentifier(value.timerId)
                && (value.taskId.map(IrohProtocolV1.isValidTaskID) ?? true)
                && (value.taskId == nil || (value.type == .start && value.phase == .focus))
        case (.task, .task(let value)):
            return value.isValid
                && IrohProtocolV1.isValidIdentifier(value.id)
                && IrohProtocolV1.isValidTaskID(value.taskId)
        case (.duration, .duration(let value)):
            return value.isValid && IrohProtocolV1.isValidIdentifier(value.id)
        case (.autoStart, .autoStart(let value)):
            return value.isValid
        default:
            return false
        }
    }

    func digest() throws -> String {
        Base64URL.encode(Data(SHA256.hash(data: try canonicalBytes())))
    }

    func operationByteCount() throws -> Int {
        try canonicalBytes().count
    }

    func canonicalBytes() throws -> Data {
        if let canonicalData { return canonicalData }
        let encoded = try JSONEncoder.api.encode(self)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw IrohProtocolError.invalidMessage("operation record is not an object")
        }
        if domain == .genesis,
           var operation = object["operation"] as? [String: Any],
           var timer = operation["canonicalTimer"] as? [String: Any],
           var intent = timer["lastIntent"] as? [String: Any] {
            intent.removeValue(forKey: "deviceId")
            timer["lastIntent"] = intent
            operation["canonicalTimer"] = timer
            object["operation"] = operation
        }
        return try JSONCanonicalizer.encodeJSONObject(object)
    }

    func preservingCanonicalBytes(_ data: Data) -> Self {
        var copy = self
        copy.canonicalData = data
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case domain, deviceId, operation
    }

    init(domain: IrohDomain, deviceId: String, payload: IrohOperationPayload) {
        self.domain = domain
        self.deviceId = deviceId
        self.payload = payload
        canonicalData = nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        domain = try values.decode(IrohDomain.self, forKey: .domain)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        canonicalData = nil
        switch domain {
        case .genesis:
            payload = .genesis(try values.decode(IrohGenesis.self, forKey: .operation))
        case .timer:
            payload = .timer(try values.decode(TimerCommand.self, forKey: .operation))
        case .task:
            payload = .task(try values.decode(TaskOperation.self, forKey: .operation))
        case .duration:
            payload = .duration(try values.decode(DurationOperation.self, forKey: .operation))
        case .autoStart:
            payload = .autoStart(try values.decode(IrohAutoStartOperation.self, forKey: .operation))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(domain, forKey: .domain)
        try values.encode(deviceId, forKey: .deviceId)
        switch payload {
        case .genesis(let value): try values.encode(value, forKey: .operation)
        case .timer(let value): try values.encode(value, forKey: .operation)
        case .task(let value): try values.encode(value, forKey: .operation)
        case .duration(let value): try values.encode(value, forKey: .operation)
        case .autoStart(let value): try values.encode(value, forKey: .operation)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.domain == rhs.domain && lhs.deviceId == rhs.deviceId && lhs.payload == rhs.payload
    }
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

enum IrohRPCMessage: Equatable, Sendable {
    case hello(IrohHello)
    case inventory(IrohInventoryRequest)
    case inventoryResult(IrohInventoryResult)
    case operations(IrohOperationsRequest)
    case operationsResult(IrohOperationsResult)
    case error(IrohErrorResponse)

    var requestID: String {
        switch self {
        case .hello(let value): value.requestId
        case .inventory(let value): value.requestId
        case .inventoryResult(let value): value.requestId
        case .operations(let value): value.requestId
        case .operationsResult(let value): value.requestId
        case .error(let value): value.requestId
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .hello(let value): try JSONEncoder.api.encode(value)
        case .inventory(let value): try JSONEncoder.api.encode(value)
        case .inventoryResult(let value): try JSONEncoder.api.encode(value)
        case .operations(let value): try JSONEncoder.api.encode(value)
        case .operationsResult(let value):
            try JSONSerialization.data(withJSONObject: [
                "protocolVersion": value.protocolVersion,
                "roomId": value.roomId,
                "requestId": value.requestId,
                "kind": value.kind,
                "records": try value.records.map {
                    try JSONSerialization.jsonObject(with: $0.canonicalBytes())
                },
            ])
        case .error(let value): try JSONEncoder.api.encode(value)
        }
    }
}

enum IrohMessageCodec {
    static func decode(_ data: Data) throws -> IrohRPCMessage {
        guard data.count <= IrohProtocolV1.maxFrameBodyBytes,
              let object = try StrictJSON.object(from: data),
              let kind = object["kind"] as? String else {
            throw IrohProtocolError.invalidMessage("body must be a JSON object with a kind")
        }
        try validateEnvelope(object)
        let decoder = JSONDecoder.api
        switch kind {
        case "hello":
            try exactKeys(object, required: [
                "protocolVersion", "roomId", "requestId", "kind", "deviceId",
                "endpointTicket", "platform",
            ], optional: ["displayName"])
            let value = try decoder.decode(IrohHello.self, from: data)
            guard value.kind == "hello",
                  IrohProtocolV1.isValidIdentifier(value.deviceId),
                  value.endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes,
                   ["ios", "macos", "android", "linux", "windows"].contains(value.platform),
                  IrohProtocolV1.isValidDisplayName(value.displayName) else {
                throw IrohProtocolError.invalidMessage("hello fields are invalid")
            }
            return .hello(value)
        case "inventory":
            try exactKeys(object, required: [
                "protocolVersion", "roomId", "requestId", "kind", "after", "limit",
            ])
            let value = try decoder.decode(IrohInventoryRequest.self, from: data)
            guard value.kind == "inventory", (1...IrohProtocolV1.maxInventoryEntries).contains(value.limit),
                  value.after.map(validCursor) ?? true else {
                throw IrohProtocolError.invalidMessage("inventory fields are invalid")
            }
            return .inventory(value)
        case "inventoryResult":
            try exactKeys(object, required: [
                "protocolVersion", "roomId", "requestId", "kind", "entries", "next",
            ])
            try validateInventoryEntries(object["entries"])
            let value = try decoder.decode(IrohInventoryResult.self, from: data)
            guard value.kind == "inventoryResult",
                  value.entries.count <= IrohProtocolV1.maxInventoryEntries,
                  value.next.map(validCursor) ?? true,
                  entriesAreStrictlyOrdered(value.entries) else {
                throw IrohProtocolError.invalidMessage("inventory result is invalid")
            }
            return .inventoryResult(value)
        case "operations":
            try exactKeys(object, required: [
                "protocolVersion", "roomId", "requestId", "kind", "refs",
            ])
            try validateReferences(object["refs"])
            let value = try decoder.decode(IrohOperationsRequest.self, from: data)
            guard value.kind == "operations", !value.refs.isEmpty,
                  value.refs.count <= IrohProtocolV1.maxOperationReferences,
                  Set(value.refs).count == value.refs.count else {
                throw IrohProtocolError.invalidMessage("operation references are invalid")
            }
            return .operations(value)
        case "operationsResult":
            try exactKeys(object, required: [
                "protocolVersion", "roomId", "requestId", "kind", "records",
            ])
            try validateRecordObjects(object["records"])
            var value = try decoder.decode(IrohOperationsResult.self, from: data)
            let rawRecords = try (object["records"] as? [Any] ?? []).map(JSONCanonicalizer.encodeJSONObject)
            guard rawRecords.count == value.records.count else {
                throw IrohProtocolError.invalidMessage("operations result records are invalid")
            }
            value = IrohOperationsResult(
                protocolVersion: value.protocolVersion,
                roomId: value.roomId,
                requestId: value.requestId,
                kind: value.kind,
                records: zip(value.records, rawRecords).map { $0.preservingCanonicalBytes($1) }
            )
            guard value.kind == "operationsResult",
                  value.records.count <= IrohProtocolV1.maxOperationReferences,
                  value.records.allSatisfy(\.isValid) else {
                throw IrohProtocolError.invalidMessage("operation records are invalid")
            }
            for record in value.records where try record.operationByteCount() > IrohProtocolV1.maxOperationBytes {
                throw IrohProtocolError.limit("operation exceeds 64 KiB")
            }
            return .operationsResult(value)
        case "error":
            try exactKeys(object, required: [
                "protocolVersion", "roomId", "requestId", "kind", "code", "message", "retryable",
            ])
            let value = try decoder.decode(IrohErrorResponse.self, from: data)
            guard value.kind == "error", value.message.utf8.count <= 1_024 else {
                throw IrohProtocolError.invalidMessage("error response is invalid")
            }
            return .error(value)
        default:
            throw IrohProtocolError.invalidMessage("unknown message kind")
        }
    }

    private static func validateEnvelope(_ object: [String: Any]) throws {
        guard let version = integer(object["protocolVersion"]), version == IrohProtocolV1.version,
              let roomID = object["roomId"] as? String, IrohProtocolV1.isValidRoomID(roomID),
              let requestID = object["requestId"] as? String,
              IrohProtocolV1.isValidRequestID(requestID) else {
            throw IrohProtocolError.invalidMessage("envelope is invalid")
        }
    }

    private static func exactKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw IrohProtocolError.invalidMessage("message has missing or unknown fields")
        }
    }

    private static func validateInventoryEntries(_ raw: Any?) throws {
        guard let entries = raw as? [[String: Any]] else {
            throw IrohProtocolError.invalidMessage("entries must be objects")
        }
        for entry in entries {
            try exactKeys(entry, required: ["domain", "id", "digest"])
            guard let domainText = entry["domain"] as? String,
                  IrohDomain(rawValue: domainText) != nil,
                  let id = entry["id"] as? String,
                  validRecordID(domain: domainText, id: id),
                  let digest = entry["digest"] as? String,
                  (try? Base64URL.decode(digest))?.count == 32 else {
                throw IrohProtocolError.invalidMessage("inventory entry is invalid")
            }
        }
    }

    private static func validateReferences(_ raw: Any?) throws {
        guard let references = raw as? [[String: Any]] else {
            throw IrohProtocolError.invalidMessage("refs must be objects")
        }
        for reference in references {
            try exactKeys(reference, required: ["domain", "id"])
            guard let domain = reference["domain"] as? String,
                  IrohDomain(rawValue: domain) != nil,
                  let id = reference["id"] as? String,
                  validRecordID(domain: domain, id: id) else {
                throw IrohProtocolError.invalidMessage("operation reference is invalid")
            }
        }
    }

    private static func validateRecordObjects(_ raw: Any?) throws {
        guard let records = raw as? [[String: Any]] else {
            throw IrohProtocolError.invalidMessage("records must be objects")
        }
        for record in records {
            try exactKeys(record, required: ["domain", "deviceId", "operation"])
            guard let domainText = record["domain"] as? String,
                  let domain = IrohDomain(rawValue: domainText),
                  let operation = record["operation"] as? [String: Any] else {
                throw IrohProtocolError.invalidMessage("record wrapper is invalid")
            }
            try validateOperation(operation, domain: domain)
        }
    }

    private static func validateOperation(_ operation: [String: Any], domain: IrohDomain) throws {
        switch domain {
        case .genesis:
            try exactKeys(operation, required: [
                "canonicalTimer", "history", "tasks", "durationsMs", "autoStartBreaks",
                "hlcWallMs", "hlcCounter",
            ])
            try validateCanonicalTimer(operation["canonicalTimer"])
            try validateHistory(operation["history"])
            try validateTasks(operation["tasks"])
            guard let durations = operation["durationsMs"] as? [String: Any] else {
                throw IrohProtocolError.invalidMessage("genesis durations are invalid")
            }
            try exactKeys(durations, required: ["focus", "short_break", "long_break"])
        case .timer:
            try exactKeys(operation, required: [
                "id", "deviceSequence", "timerId", "type", "phase", "plannedDurationMs",
                "occurredAt", "hlcWallMs", "hlcCounter", "observedElapsedMs",
            ], optional: ["taskId"])
            try rejectNull(operation, keys: ["taskId"])
            try validateRawClock(operation, allowsEpochSentinel: false)
        case .task:
            try exactKeys(operation, required: [
                "id", "taskId", "type", "occurredAt", "hlcWallMs", "hlcCounter",
            ], optional: ["title"])
            try rejectNull(operation, keys: ["title"])
            guard let taskID = operation["taskId"] as? String,
                  IrohProtocolV1.isValidTaskID(taskID) else {
                throw IrohProtocolError.invalidMessage("task ID is invalid")
            }
            try validateRawClock(operation, allowsEpochSentinel: false)
        case .duration:
            try exactKeys(operation, required: [
                "id", "phase", "durationMs", "occurredAt", "hlcWallMs", "hlcCounter",
            ])
            try validateRawClock(operation, allowsEpochSentinel: true)
        case .autoStart:
            try exactKeys(operation, required: [
                "id", "enabled", "occurredAt", "hlcWallMs", "hlcCounter",
            ])
            try validateRawClock(operation, allowsEpochSentinel: true)
        }
    }

    private static func validateCanonicalTimer(_ raw: Any?) throws {
        if raw is NSNull { return }
        guard let timer = raw as? [String: Any] else {
            throw IrohProtocolError.invalidMessage("canonical timer is invalid")
        }
        try exactKeys(timer, required: [
            "id", "phase", "status", "plannedDurationMs", "elapsedAtAnchorMs", "anchorAt",
        ], optional: ["taskId", "startedByDeviceId", "lastIntent"])
        try rejectNull(timer, keys: ["taskId", "startedByDeviceId"])
        if let taskID = timer["taskId"] as? String, !IrohProtocolV1.isValidTaskID(taskID) {
            throw IrohProtocolError.invalidMessage("canonical timer task ID is invalid")
        }
        if timer.keys.contains("lastIntent") {
            guard let intent = timer["lastIntent"] as? [String: Any] else {
                throw IrohProtocolError.invalidMessage("timer intent is invalid")
            }
            try exactKeys(intent, required: ["type", "commandId", "occurredAt"])
        }
    }

    private static func validateHistory(_ raw: Any?) throws {
        guard let history = raw as? [[String: Any]] else {
            throw IrohProtocolError.invalidMessage("genesis history is invalid")
        }
        for item in history {
            try exactKeys(item, required: [
                "id", "timerId", "phase", "status", "plannedDurationMs",
            ], optional: ["commandId", "taskId", "completedAt", "endedAt"])
            try rejectNull(item, keys: ["commandId", "taskId", "completedAt", "endedAt"])
            if let taskID = item["taskId"] as? String, !IrohProtocolV1.isValidTaskID(taskID) {
                throw IrohProtocolError.invalidMessage("history task ID is invalid")
            }
        }
    }

    private static func validateTasks(_ raw: Any?) throws {
        guard let tasks = raw as? [[String: Any]] else {
            throw IrohProtocolError.invalidMessage("genesis tasks are invalid")
        }
        for task in tasks {
            try exactKeys(task, required: ["id", "title"])
            guard let id = task["id"] as? String, IrohProtocolV1.isValidTaskID(id) else {
                throw IrohProtocolError.invalidMessage("task ID is invalid")
            }
        }
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private static func rejectNull(_ object: [String: Any], keys: [String]) throws {
        guard keys.allSatisfy({ !object.keys.contains($0) || !(object[$0] is NSNull) }) else {
            throw IrohProtocolError.invalidMessage("optional fields must be omitted instead of null")
        }
    }

    private static func validateRawClock(
        _ operation: [String: Any],
        allowsEpochSentinel: Bool
    ) throws {
        guard let wall = integer(operation["hlcWallMs"]),
              let counter = integer(operation["hlcCounter"]),
              let occurredAt = operation["occurredAt"] as? String else {
            throw IrohProtocolError.invalidMessage("operation clock is invalid")
        }
        if wall == 0 || counter == 0 && wall == 0 {
            guard allowsEpochSentinel,
                  wall == 0,
                  counter == 0,
                  StrictJSON.isExactUnixEpoch(occurredAt) else {
                throw IrohProtocolError.invalidMessage("legacy sentinel must use exact Unix epoch")
            }
        }
    }

    private static func validRecordID(domain: String, id: String) -> Bool {
        domain == IrohDomain.genesis.rawValue ? id == "genesis" : IrohProtocolV1.isValidIdentifier(id)
    }

    private static func validCursor(_ cursor: String) -> Bool {
        let parts = cursor.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count == 2, let domain = IrohDomain(rawValue: String(parts[0])) else { return false }
        return validRecordID(domain: domain.rawValue, id: String(parts[1]))
    }

    private static func entriesAreStrictlyOrdered(_ entries: [IrohInventoryEntry]) -> Bool {
        guard Set(entries.map(\.reference)).count == entries.count else { return false }
        return zip(entries, entries.dropFirst()).allSatisfy { precedes($0, $1) }
    }

    private static func precedes(_ lhs: IrohInventoryEntry, _ rhs: IrohInventoryEntry) -> Bool {
        if lhs.domain.rawValue != rhs.domain.rawValue {
            return IrohProtocolV1.utf8Precedes(lhs.domain.rawValue, rhs.domain.rawValue)
        }
        return IrohProtocolV1.utf8Precedes(lhs.id, rhs.id)
    }
}

enum JSONCanonicalizer {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder.api.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        return Data(try canonicalString(object).utf8)
    }

    static func encodeJSONObject(_ value: Any) throws -> Data {
        Data(try canonicalString(value).utf8)
    }

    private static func canonicalString(_ value: Any) throws -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return quote(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let double = number.doubleValue
            guard double.isFinite,
                  double.rounded(.towardZero) == double,
                  abs(double) <= Double(WireBounds.maxSafeInteger) else {
                throw IrohProtocolError.invalidMessage("canonical records require integer numbers")
            }
            return String(number.int64Value)
        case let array as [Any]:
            return "[" + (try array.map(canonicalString)).joined(separator: ",") + "]"
        case let object as [String: Any]:
            let keys = object.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            return "{" + (try keys.map { key in
                quote(key) + ":" + (try canonicalString(object[key] as Any))
            }).joined(separator: ",") + "}"
        default:
            throw IrohProtocolError.invalidMessage("record contains unsupported JSON")
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x00...0x1f: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

struct IrohEndpointLifecycle: Sendable {
    private(set) var generation = 0
    private(set) var isActive = false

    mutating func setActive(_ active: Bool) -> Int {
        guard active != isActive else { return generation }
        generation += 1
        isActive = active
        return generation
    }

    func owns(_ candidate: Int) -> Bool {
        isActive && candidate == generation
    }
}
