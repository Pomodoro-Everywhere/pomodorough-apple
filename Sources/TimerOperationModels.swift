import Foundation

enum CommandType: String, Codable, Sendable {
    case start, pause, resume, finish, cancel, clear
}

struct TimerCommand: Codable, Identifiable, Equatable, Sendable {
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

    var isValid: Bool {
        !id.isEmpty
            && !timerId.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && (1...WireBounds.maxSafeInteger).contains(deviceSequence)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && (0...plannedDurationMs).contains(observedElapsedMs)
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter)
            && WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt)
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
