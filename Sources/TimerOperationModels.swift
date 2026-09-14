import Foundation

enum CommandType: String, Codable, Sendable {
    case start, pause, resume, finish, cancel, clear, retarget
}

struct TimerCommand: Identifiable, Equatable, Sendable {
    let id: String
    let deviceSequence: Int64
    let timerId: String
    let taskId: String?
    let type: CommandType
    let phase: TimerPhase
    let plannedDurationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64
    let observedElapsedMs: Int64

    init(
        id: String,
        deviceSequence: Int64,
        timerId: String,
        taskId: String?,
        type: CommandType,
        phase: TimerPhase,
        plannedDurationMs: Int64,
        occurredAt: Date,
        hlcWallMs: Int64,
        hlcCounter: Int64,
        observedElapsedMs: Int64
    ) {
        self.id = id
        self.deviceSequence = deviceSequence
        self.timerId = timerId
        self.taskId = taskId
        self.type = type
        self.phase = phase
        self.plannedDurationMs = plannedDurationMs
        self.occurredAt = occurredAt
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
        self.observedElapsedMs = observedElapsedMs
    }

    var isValid: Bool {
        !id.isEmpty
            && !timerId.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && (type != .retarget || phase == .focus)
            && (1...WireBounds.maxSafeInteger).contains(deviceSequence)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && (0...plannedDurationMs).contains(observedElapsedMs)
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter)
            && WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt)
    }
}

extension TimerCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, deviceSequence, timerId, taskId, type, phase
        case plannedDurationMs, occurredAt, hlcWallMs, hlcCounter, observedElapsedMs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        deviceSequence = try values.decode(Int64.self, forKey: .deviceSequence)
        timerId = try values.decode(String.self, forKey: .timerId)
        type = try values.decode(CommandType.self, forKey: .type)
        // Retarget keeps explicit null (unassign) distinct from omission:
        // decodeIfPresent collapses omission to nil, so require the key.
        if type == .retarget, !values.contains(.taskId) {
            throw DecodingError.keyNotFound(
                CodingKeys.taskId,
                .init(codingPath: values.codingPath, debugDescription: "Retarget requires taskId.")
            )
        }
        taskId = try values.decodeIfPresent(String.self, forKey: .taskId)
        phase = try values.decode(TimerPhase.self, forKey: .phase)
        plannedDurationMs = try values.decode(Int64.self, forKey: .plannedDurationMs)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        hlcWallMs = try values.decode(Int64.self, forKey: .hlcWallMs)
        hlcCounter = try values.decode(Int64.self, forKey: .hlcCounter)
        observedElapsedMs = try values.decode(Int64.self, forKey: .observedElapsedMs)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(deviceSequence, forKey: .deviceSequence)
        try values.encode(timerId, forKey: .timerId)
        if type == .retarget {
            if let taskId {
                try values.encode(taskId, forKey: .taskId)
            } else {
                try values.encodeNil(forKey: .taskId)
            }
        } else {
            try values.encodeIfPresent(taskId, forKey: .taskId)
        }
        try values.encode(type, forKey: .type)
        try values.encode(phase, forKey: .phase)
        try values.encode(plannedDurationMs, forKey: .plannedDurationMs)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
        try values.encode(observedElapsedMs, forKey: .observedElapsedMs)
    }
}

@propertyWrapper
struct EmptyStringIfMissing: Codable, Equatable, Sendable {
    var wrappedValue: String

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(String.self)
    }
}

private extension KeyedDecodingContainer {
    func decode(_ type: EmptyStringIfMissing.Type, forKey key: Key) throws -> EmptyStringIfMissing {
        guard contains(key) else { return EmptyStringIfMissing(wrappedValue: "") }
        guard let value = try decodeIfPresent(String.self, forKey: key) else {
            throw DecodingError.valueNotFound(
                String.self,
                .init(codingPath: codingPath + [key], debugDescription: "Acknowledgement reason cannot be null.")
            )
        }
        return EmptyStringIfMissing(wrappedValue: value)
    }
}

struct Acknowledgement: Codable, Equatable, Sendable {
    let commandId: String
    let outcome: AcknowledgementOutcome
    @EmptyStringIfMissing var reason: String
}

enum TaskOperationType: String, Codable, Sendable {
    case upsert, delete
}

struct TaskOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let taskId: String
    let type: TaskOperationType
    let title: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !id.isEmpty
            && UUID(uuidString: taskId) != nil
            && ((type == .delete && title == nil)
                || (type == .upsert
                    && title.flatMap(FocusTask.init(title:))?.id == UUID(uuidString: taskId)))
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter)
            && WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt)
    }
}

struct TaskAcknowledgement: Codable, Equatable, Sendable {
    let operationId: String
    let outcome: AcknowledgementOutcome
    @EmptyStringIfMissing var reason: String
}

struct DurationOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let phase: TimerPhase
    let durationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !id.isEmpty
            && DurationValues.isValidWireDuration(durationMs)
            && WireBounds.isValidClock(
                wallMs: hlcWallMs,
                counter: hlcCounter,
                allowsLegacySentinel: true
            )
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(
                    wallMs: hlcWallMs,
                    counter: hlcCounter,
                    occurredAt: occurredAt
                )
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

struct DurationAcknowledgement: Codable, Equatable, Sendable {
    let operationId: String
    let outcome: AcknowledgementOutcome
    @EmptyStringIfMissing var reason: String
}

struct AutoStartOperation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceId: String
    let enabled: Bool
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !deviceId.isEmpty
            && WireBounds.isValidClock(
                wallMs: hlcWallMs,
                counter: hlcCounter,
                allowsLegacySentinel: true
            )
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(
                    wallMs: hlcWallMs,
                    counter: hlcCounter,
                    occurredAt: occurredAt
                )
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

enum AcknowledgementOutcome: String, Codable, Equatable, Sendable {
    case applied, ignored, rejected
}

struct AutoStartAcknowledgement: Codable, Equatable, Sendable {
    let operationId: UUID
    let outcome: AcknowledgementOutcome
    @EmptyStringIfMissing var reason: String
}

struct SelectedTaskOperation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceId: String
    let taskId: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !deviceId.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && WireBounds.isValidClock(
                wallMs: hlcWallMs,
                counter: hlcCounter,
                allowsLegacySentinel: true
            )
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(
                    wallMs: hlcWallMs,
                    counter: hlcCounter,
                    occurredAt: occurredAt
                )
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

struct SelectedTaskAcknowledgement: Codable, Equatable, Sendable {
    let operationId: UUID
    let outcome: AcknowledgementOutcome
    @EmptyStringIfMissing var reason: String
}

struct ProvisionalBreak: Codable, Equatable, Sendable {
    let focusTimerId: String
    let finishCommandId: String
    let breakTimerId: String
    let startCommandId: String
}

struct ProvisionalPhaseAdvance: Codable, Equatable, Sendable {
    let sourceTimerId: String
    let finishCommandId: String
    let previousPhase: TimerPhase
    let advancedPhase: TimerPhase
    let generation: Int64
}

enum AcknowledgementSet {
    static func exactlyMatches<ID: Hashable>(sent: [ID], acknowledged: [ID]) -> Bool {
        guard sent.count == acknowledged.count else { return false }
        let sentSet = Set(sent)
        let acknowledgedSet = Set(acknowledged)
        return sentSet.count == sent.count
            && acknowledgedSet.count == acknowledged.count
            && sentSet == acknowledgedSet
    }
}

struct TimerIntent: Codable, Equatable, Sendable {
    let type: CommandType
    let commandId: String
    let occurredAt: Date
    let deviceId: String?

    var isValid: Bool {
        !commandId.isEmpty
            && WireBounds.physicalMilliseconds(for: occurredAt) != nil
            && (deviceId == nil || deviceId?.isEmpty == false)
    }

}

struct CanonicalTimer: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, paused, completed, cancelled, superseded
    }

    let id: String
    let taskId: String?
    let phase: TimerPhase
    let status: Status
    let plannedDurationMs: Int64
    let elapsedAtAnchorMs: Int64
    let anchorAt: Date
    var startedByDeviceId: String? = nil
    let lastIntent: TimerIntent?

    var plannedDuration: TimeInterval { TimeInterval(plannedDurationMs) / 1_000 }

    var isValid: Bool {
        !id.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && (0...plannedDurationMs).contains(elapsedAtAnchorMs)
            && WireBounds.physicalMilliseconds(for: anchorAt) != nil
            && (startedByDeviceId == nil || startedByDeviceId?.isEmpty == false)
            && (lastIntent?.isValid ?? true)
    }

    func elapsed(at date: Date) -> TimeInterval {
        let anchored = TimeInterval(elapsedAtAnchorMs) / 1_000
        guard status == .running else { return min(plannedDuration, anchored) }
        return min(plannedDuration, anchored + max(0, date.timeIntervalSince(anchorAt)))
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, plannedDuration - elapsed(at: date))
    }
}

extension CanonicalTimer.Status {
    var localizedText: String {
        switch self {
        case .running: String(localized: "Running")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        case .cancelled: String(localized: "Cancelled")
        case .superseded: String(localized: "Superseded")
        }
    }
}
