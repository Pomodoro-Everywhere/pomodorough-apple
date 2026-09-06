import Foundation

/// WatchConnectivity wire payload shared by the iOS app and the watch app.
/// Primitives only, so the watch target compiles this file without the heavy iOS deps.
/// iOS is the source of truth: it pushes snapshots, the watch sends back commands.
enum WatchSyncKeys {
    static let snapshot = "snapshot"
    static let command = "command"
}

struct WatchTimerSnapshot: Codable, Equatable, Sendable {
    /// TimerPhase rawValue ("focus" | "short_break" | "long_break"); active timer's phase.
    var phase: String
    /// "running" | "paused" | "idle" (no active timer).
    var status: String
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
    /// "start" | "pause" | "resume" | "finish" | "selectPhase" | "setDuration".
    var name: String
    /// TimerPhase rawValue, for selectPhase / setDuration.
    var phase: String?
    /// Minutes, for setDuration.
    var minutes: Int?
    var sentAt: Date

    static func start() -> Self { Self(name: "start", sentAt: .now) }
    static func pause() -> Self { Self(name: "pause", sentAt: .now) }
    static func resume() -> Self { Self(name: "resume", sentAt: .now) }
    static func finish() -> Self { Self(name: "finish", sentAt: .now) }
    static func selectPhase(_ rawValue: String) -> Self {
        Self(name: "selectPhase", phase: rawValue, sentAt: .now)
    }
    static func setDuration(minutes: Int, forPhaseRawValue rawValue: String) -> Self {
        Self(name: "setDuration", phase: rawValue, minutes: minutes, sentAt: .now)
    }
}
