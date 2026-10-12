import Foundation

enum WorkspaceIntentCategory: String, Sendable {
    case timerStart = "timerStart"
    case timerPause = "timerPause"
    case timerResume = "timerResume"
    case timerCancel = "timerCancel"
    case timerClear = "timerClear"
    case phase = "phase"
    case taskUpsert = "taskUpsert"
    case taskDelete = "taskDelete"
    case selectTask = "selectTask"
    case setDuration = "setDuration"
    case setAutoStart = "setAutoStart"
    case command = "command"
}

struct WorkspaceMutationDiagnostics: Sendable {
    let category: WorkspaceIntentCategory
    let coreReason: String
    let pendingCommands: Int
    let pendingTasks: Int
    let pendingDurations: Int
    let pendingAutoStart: Int
    let pendingSelected: Int
    let queued: Int
    let applied: Int
    let isIgnoredRetarget: Bool
    let provenance: String

    func publicMessage() -> String {
        String(localized: "mutation category=\(category.rawValue) reason=\(coreReason) ")
            + String(localized: "pending=\(pendingCommands)/\(pendingTasks)/\(pendingDurations)/")
            + String(localized: "\(pendingAutoStart)/\(pendingSelected) queued=\(queued) ")
            + String(localized: "applied=\(applied) ignoredRetarget=\(isIgnoredRetarget) ")
            + String(localized: "core=\(provenance)")
    }
}

enum WorkspaceIntentProvenance {
    static func current() -> String {
        let tag = bundledValue(name: "CORE_RELEASE_TAG")
        let commit = bundledValue(name: "CORE_COMMIT")
        let sha = bundledValue(name: "CORE_SHA256")
        if tag.isEmpty, commit.isEmpty, sha.isEmpty { return "unknown" }
        let shortCommit = String(commit.prefix(12))
        let shortSHA = String(sha.prefix(12))
        return "\(tag)/\(shortCommit)/\(shortSHA)"
    }

    private static func bundledValue(name: String) -> String {
        for bundle in [Bundle.main] + Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "SharedCore"),
               let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            if let url = bundle.url(forResource: name, withExtension: nil),
               let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

struct WorkspaceIntentSelection: Codable, Sendable {
    let phase: TimerPhase
    let generation: String
    let explicit: Bool
}

struct WorkspaceIntentHLC: Codable, Sendable {
    let wallMs: Int64
    let counter: Int64
}

struct WorkspaceIntentAllocation: Codable, Sendable {
    let deviceId: String
    let deviceSequence: Int64
    let hlc: WorkspaceIntentHLC
    let lastUuid: String?
}

struct WorkspaceIntentObservation: Codable, Sendable {
    let canonicalAnchorAt: String?
    let commandTimes: [String: String]
}

struct WorkspaceIntentClock: Codable, Sendable {
    let occurredAt: Date
    let physicalNow: Date
    let observedAt: Date
}

struct WorkspaceIntentIdentities: Codable, Sendable {
    let commandUuids: [String]
    let timerUuid: String?
}

struct WorkspaceIntentInterval: Codable, Sendable {
    let start: String
    let end: String
}

struct WorkspaceIntentOwnership: Sendable, Encodable {
    let expectedOwnerId: String?
    let ownerId: String?

    private enum CodingKeys: String, CodingKey {
        case expectedOwnerId
        case ownerId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let expectedOwnerId {
            try container.encode(expectedOwnerId, forKey: .expectedOwnerId)
        } else {
            try container.encodeNil(forKey: .expectedOwnerId)
        }
        if let ownerId {
            try container.encode(ownerId, forKey: .ownerId)
        } else {
            try container.encodeNil(forKey: .ownerId)
        }
    }
}

struct WorkspaceIntentDurability: Codable, Sendable {
    let outgoingDurationOperationIds: [String]
    let localTabId: String?
}

struct WorkspaceIntentHead: Codable, Sendable {
    let wallMs: Int64
    let counter: Int64
}
