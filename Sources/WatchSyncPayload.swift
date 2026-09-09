import Foundation

/// WatchConnectivity wire payload shared by the iOS app and the watch app.
/// Primitives only, so the watch target compiles this file without the heavy iOS deps.
/// iOS is the source of truth: it pushes snapshots, the watch sends back commands.
enum WatchSyncKeys {
    static let snapshot = "snapshot"
    static let command = "command"
    static let requestSync = "requestSync"
    static let report = "report"
}

struct WatchTimerSnapshot: Codable, Equatable, Sendable {
    /// TimerPhase rawValue ("focus" | "short_break" | "long_break"); active timer's phase.
    var phase: String
    /// "running" | "paused" | "idle" (no active timer).
    var status: String
    /// Canonical timer id when a timer is active; nil when idle. Lets the
    /// phone reject delayed watch commands aimed at a previous timer.
    /// Defaults nil so snapshots from older iOS apps still decode.
    var timerId: String? = nil
    var plannedDurationMs: Int64
    var elapsedAtAnchorMs: Int64
    var anchorAt: Date
    /// TimerPhase rawValue of the selected phase.
    var selectedPhase: String
    var focusDurationMs: Int64
    var shortBreakDurationMs: Int64
    var longBreakDurationMs: Int64
    var updatedAt: Date

    var isRunning: Bool { status == "running" }
    var isPaused: Bool { status == "paused" }

    func durationMs(forPhaseRawValue rawValue: String) -> Int64 {
        switch rawValue {
        case "short_break": shortBreakDurationMs
        case "long_break": longBreakDurationMs
        default: focusDurationMs
        }
    }

    func remaining(at date: Date) -> TimeInterval {
        let planned = TimeInterval(plannedDurationMs) / 1_000
        let anchored = TimeInterval(elapsedAtAnchorMs) / 1_000
        let elapsed: TimeInterval
        if isRunning {
            elapsed = min(planned, anchored + max(0, date.timeIntervalSince(anchorAt)))
        } else {
            elapsed = min(planned, anchored)
        }
        return max(0, planned - elapsed)
    }
}

struct WatchTimerCommand: Codable, Equatable, Sendable {
    /// Unique command identity for dedupe/diagnostics.
    /// Defaults to a fresh id so commands from older watch apps still decode.
    var id: UUID = UUID()
    /// Target canonical timer id for pause/resume/finish; nil for start,
    /// selectPhase, setDuration and for payloads from older watch apps.
    var timerId: String? = nil
    /// "start" | "pause" | "resume" | "finish" | "selectPhase" | "setDuration".
    var name: String
    /// TimerPhase rawValue, for selectPhase / setDuration.
    var phase: String?
    /// Minutes, for setDuration.
    var minutes: Int?
    var sentAt: Date

    // Explicit memberwise init (a custom init(from:) below suppresses the
    // synthesized one).
    init(
        id: UUID = UUID(),
        timerId: String? = nil,
        name: String,
        phase: String? = nil,
        minutes: Int? = nil,
        sentAt: Date
    ) {
        self.id = id
        self.timerId = timerId
        self.name = name
        self.phase = phase
        self.minutes = minutes
        self.sentAt = sentAt
    }

    // Custom decoding: keys absent from older watch apps fall back to the
    // defaults above instead of failing the whole command.
    init(from decoder: Decoder) throws {        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timerId = try container.decodeIfPresent(String.self, forKey: .timerId)
        name = try container.decode(String.self, forKey: .name)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        minutes = try container.decodeIfPresent(Int.self, forKey: .minutes)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
    }

    static func start(timerId: String? = nil) -> Self {
        Self(id: UUID(), timerId: timerId, name: "start", sentAt: .now)
    }
    static func pause(timerId: String? = nil) -> Self {
        Self(id: UUID(), timerId: timerId, name: "pause", sentAt: .now)
    }
    static func resume(timerId: String? = nil) -> Self {
        Self(id: UUID(), timerId: timerId, name: "resume", sentAt: .now)
    }
    static func finish(timerId: String? = nil) -> Self {
        Self(id: UUID(), timerId: timerId, name: "finish", sentAt: .now)
    }
    static func selectPhase(_ rawValue: String) -> Self {
        Self(id: UUID(), timerId: nil, name: "selectPhase", phase: rawValue, sentAt: .now)
    }
    static func setDuration(minutes: Int, forPhaseRawValue rawValue: String) -> Self {
        Self(id: UUID(), timerId: nil, name: "setDuration", phase: rawValue, minutes: minutes, sentAt: .now)
    }
}

// Log dedupe shared by iOS/watchOS sync: first failure per key logs,
// repeats stay silent. No Sentry here; keeps flaky-link failures from
// spamming dev logs. Lives in this shared payload file so the macOS/iOS
// unit-test bundle can cover the decision without a watchOS test host.
enum WatchSyncLogDedupe {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var seen = Set<String>()
    }

    private static let state = State()

    static func shouldLog(key: String) -> Bool {
        state.lock.withLock {
            guard !state.seen.contains(key) else { return false }
            state.seen.insert(key)
            return true
        }
    }
}
