import CoreFoundation
import CryptoKit
import Foundation

struct IrohGenesis: Codable, Equatable, Sendable {
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        IrohSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs
        ) && (selectedTaskId.map(IrohProtocolV1.isValidIdentifier) ?? true)
            && ((hlcWallMs == 0 && hlcCounter == 0)
            || WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter))
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalTimer, history, tasks, durationsMs, autoStartBreaks, selectedTaskId, hlcWallMs, hlcCounter
    }

    init(
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durationsMs: DurationValues,
        autoStartBreaks: Bool,
        selectedTaskId: String? = nil,
        hlcWallMs: Int64,
        hlcCounter: Int64
    ) {
        self.canonicalTimer = canonicalTimer
        self.history = history
        self.tasks = tasks
        self.durationsMs = durationsMs
        self.autoStartBreaks = autoStartBreaks
        self.selectedTaskId = selectedTaskId
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
        selectedTaskId = try values.decodeIfPresent(String.self, forKey: .selectedTaskId)
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
        if let selectedTaskId {
            try values.encode(selectedTaskId, forKey: .selectedTaskId)
        } else {
            try values.encodeNil(forKey: .selectedTaskId)
        }
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
    }
}

enum IrohOperationPayload: Equatable, Sendable {
    case genesis(IrohGenesis)
    case timer(TimerCommand)
    case task(TaskOperation)
    case duration(DurationOperation)
    case autoStart(IrohAutoStartOperation)
    case selectedTask(IrohSelectedTaskOperation)
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

struct IrohSelectedTaskOperation: Codable, Equatable, Sendable {
    let id: String
    let taskId: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(id: String, taskId: String?, occurredAt: Date, hlcWallMs: Int64, hlcCounter: Int64) {
        self.id = id
        self.taskId = taskId
        self.occurredAt = occurredAt
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
    }

    init(_ operation: SelectedTaskOperation) {
        id = operation.id.uuidString.lowercased()
        taskId = operation.taskId
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskId, occurredAt, hlcWallMs, hlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.taskId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.taskId,
                .init(codingPath: values.codingPath, debugDescription: "Selected task requires taskId.")
            )
        }
        id = try values.decode(String.self, forKey: .id)
        taskId = try values.decodeIfPresent(String.self, forKey: .taskId)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        hlcWallMs = try values.decode(Int64.self, forKey: .hlcWallMs)
        hlcCounter = try values.decode(Int64.self, forKey: .hlcCounter)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        if let taskId {
            try values.encode(taskId, forKey: .taskId)
        } else {
            try values.encodeNil(forKey: .taskId)
        }
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
    }

    var isValid: Bool {
        IrohProtocolV1.isValidIdentifier(id)
            && (taskId.map(IrohProtocolV1.isValidIdentifier) ?? true)
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter)
            && WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt)
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
        case .selectedTask(let value): value.id
        }
    }

    var order: (wallMs: Int64, counter: Int64) {
        switch payload {
        case .genesis(let value): (value.hlcWallMs, value.hlcCounter)
        case .timer(let value): (value.hlcWallMs, value.hlcCounter)
        case .task(let value): (value.hlcWallMs, value.hlcCounter)
        case .duration(let value): (value.hlcWallMs, value.hlcCounter)
        case .autoStart(let value): (value.hlcWallMs, value.hlcCounter)
        case .selectedTask(let value): (value.hlcWallMs, value.hlcCounter)
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
        case (.selectedTask, .selectedTask(let value)):
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
        return try IrohCanonicalRecordCodec.encodeJSONObject(object)
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
        case .selectedTask:
            payload = .selectedTask(try values.decode(IrohSelectedTaskOperation.self, forKey: .operation))
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
        case .selectedTask(let value): try values.encode(value, forKey: .operation)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.domain == rhs.domain && lhs.deviceId == rhs.deviceId && lhs.payload == rhs.payload
    }
}

enum IrohCanonicalRecordCodec {
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
