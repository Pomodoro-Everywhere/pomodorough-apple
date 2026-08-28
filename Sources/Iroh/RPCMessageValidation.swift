import CoreFoundation
import Foundation

enum IrohRPCMessageValidation {
    static func validateEnvelope(_ object: [String: Any]) throws {
        guard let version = integer(object["protocolVersion"]), version == IrohProtocolV1.version,
              let roomID = object["roomId"] as? String, IrohProtocolV1.isValidRoomID(roomID),
              let requestID = object["requestId"] as? String,
              IrohProtocolV1.isValidRequestID(requestID) else {
            throw IrohProtocolError.invalidMessage("envelope is invalid")
        }
    }

    static func exactKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw IrohProtocolError.invalidMessage("message has missing or unknown fields")
        }
    }

    static func validateInventoryEntries(_ raw: Any?) throws {
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

    static func validateReferences(_ raw: Any?) throws {
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

    static func validateRecordObjects(_ raw: Any?) throws {
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

    static func validateOperation(_ operation: [String: Any], domain: IrohDomain) throws {
        switch domain {
        case .genesis: try validateGenesisOperation(operation)
        case .timer: try validateTimerOperation(operation)
        case .task: try validateTaskOperation(operation)
        case .duration: try validateDurationOperation(operation)
        case .autoStart: try validateAutoStartOperation(operation)
        case .selectedTask: try validateSelectedTaskOperation(operation)
        }
    }

    static func validateGenesisOperation(_ operation: [String: Any]) throws {
        try exactKeys(operation, required: [
            "canonicalTimer", "history", "tasks", "durationsMs", "autoStartBreaks",
            "hlcWallMs", "hlcCounter"
        ], optional: ["selectedTaskId"])
        try validateCanonicalTimer(operation["canonicalTimer"])
        try validateHistory(operation["history"])
        try validateTasks(operation["tasks"])
        guard operation["selectedTaskId"] == nil
                || operation["selectedTaskId"] is NSNull
                || (operation["selectedTaskId"] as? String).map(IrohProtocolV1.isValidIdentifier) == true else {
            throw IrohProtocolError.invalidMessage("genesis selected task ID is invalid")
        }
        guard let durations = operation["durationsMs"] as? [String: Any] else {
            throw IrohProtocolError.invalidMessage("genesis durations are invalid")
        }
        try exactKeys(durations, required: ["focus", "short_break", "long_break"])
    }

    static func validateTimerOperation(_ operation: [String: Any]) throws {
        try exactKeys(operation, required: [
            "id", "deviceSequence", "timerId", "type", "phase", "plannedDurationMs",
            "occurredAt", "hlcWallMs", "hlcCounter", "observedElapsedMs"
        ], optional: ["taskId"])
        try rejectNull(operation, keys: ["taskId"])
        try validateRawClock(operation, allowsEpochSentinel: false)
    }

    static func validateTaskOperation(_ operation: [String: Any]) throws {
        try exactKeys(operation, required: [
            "id", "taskId", "type", "occurredAt", "hlcWallMs", "hlcCounter"
        ], optional: ["title"])
        try rejectNull(operation, keys: ["title"])
        guard let taskID = operation["taskId"] as? String,
              IrohProtocolV1.isValidTaskID(taskID) else {
            throw IrohProtocolError.invalidMessage("task ID is invalid")
        }
        try validateRawClock(operation, allowsEpochSentinel: false)
    }

    static func validateDurationOperation(_ operation: [String: Any]) throws {
        try exactKeys(operation, required: [
            "id", "phase", "durationMs", "occurredAt", "hlcWallMs", "hlcCounter"
        ])
        try validateRawClock(operation, allowsEpochSentinel: true)
    }

    static func validateAutoStartOperation(_ operation: [String: Any]) throws {
        try exactKeys(operation, required: [
            "id", "enabled", "occurredAt", "hlcWallMs", "hlcCounter"
        ])
        try validateRawClock(operation, allowsEpochSentinel: true)
    }

    static func validateSelectedTaskOperation(_ operation: [String: Any]) throws {
        try exactKeys(operation, required: [
            "id", "taskId", "occurredAt", "hlcWallMs", "hlcCounter"
        ])
        guard operation["taskId"] is NSNull
                || (operation["taskId"] as? String).map(IrohProtocolV1.isValidIdentifier) == true else {
            throw IrohProtocolError.invalidMessage("selected task ID is invalid")
        }
        try validateRawClock(operation, allowsEpochSentinel: false)
    }

    static func validateCanonicalTimer(_ raw: Any?) throws {
        if raw is NSNull { return }
        guard let timer = raw as? [String: Any] else {
            throw IrohProtocolError.invalidMessage("canonical timer is invalid")
        }
        try exactKeys(timer, required: [
            "id", "phase", "status", "plannedDurationMs", "elapsedAtAnchorMs", "anchorAt"
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

    static func validateHistory(_ raw: Any?) throws {
        guard let history = raw as? [[String: Any]] else {
            throw IrohProtocolError.invalidMessage("genesis history is invalid")
        }
        for item in history {
            try exactKeys(item, required: [
                "id", "timerId", "phase", "status", "plannedDurationMs"
            ], optional: ["commandId", "taskId", "completedAt", "endedAt"])
            try rejectNull(item, keys: ["commandId", "taskId", "completedAt", "endedAt"])
            if let taskID = item["taskId"] as? String, !IrohProtocolV1.isValidTaskID(taskID) {
                throw IrohProtocolError.invalidMessage("history task ID is invalid")
            }
        }
    }

    static func validateTasks(_ raw: Any?) throws {
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

    static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    static func rejectNull(_ object: [String: Any], keys: [String]) throws {
        guard keys.allSatisfy({ !object.keys.contains($0) || !(object[$0] is NSNull) }) else {
            throw IrohProtocolError.invalidMessage("optional fields must be omitted instead of null")
        }
    }

    static func validateRawClock(
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

    static func validRecordID(domain: String, id: String) -> Bool {
        domain == IrohDomain.genesis.rawValue ? id == "genesis" : IrohProtocolV1.isValidIdentifier(id)
    }

    static func validCursor(_ cursor: String) -> Bool {
        let parts = cursor.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count == 2, let domain = IrohDomain(rawValue: String(parts[0])) else { return false }
        return validRecordID(domain: domain.rawValue, id: String(parts[1]))
    }

    static func entriesAreStrictlyOrdered(_ entries: [IrohInventoryEntry]) -> Bool {
        guard Set(entries.map(\.reference)).count == entries.count else { return false }
        return zip(entries, entries.dropFirst()).allSatisfy { precedes($0, $1) }
    }

    static func precedes(_ lhs: IrohInventoryEntry, _ rhs: IrohInventoryEntry) -> Bool {
        if lhs.domain.rawValue != rhs.domain.rawValue {
            return IrohProtocolV1.utf8Precedes(lhs.domain.rawValue, rhs.domain.rawValue)
        }
        return IrohProtocolV1.utf8Precedes(lhs.id, rhs.id)
    }
}
