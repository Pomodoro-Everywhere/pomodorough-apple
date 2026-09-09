import Foundation
import Synchronization

/// WatchConnectivity wire payload shared by the iOS app and the watch app.
/// Primitives only, so the watch target compiles this file without the heavy iOS deps.
/// iOS is the source of truth: it pushes snapshots, the watch sends back commands.
enum WatchSyncKeys {
    static let snapshot = "snapshot"
    static let command = "command"
    static let requestSync = "requestSync"
    static let report = "report"
}

struct WatchTimerRevision: Codable, Equatable, Sendable {
    var timerId: String
    var intentId: String?
    var phase: String
    var status: String
    var plannedDurationMs: Int64
    var elapsedAtAnchorMs: Int64
    var anchorAt: Date
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
    var timerRevision: WatchTimerRevision? = nil
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
    /// Compare-and-set precondition from the phone's last snapshot.
    var expectedTimerRevision: WatchTimerRevision? = nil
    /// "start" | "pause" | "resume" | "finish" | "selectPhase" | "setDuration".
    var name: String
    /// TimerPhase rawValue, for selectPhase / setDuration.
    var phase: String?
    /// Minutes, for setDuration.
    var minutes: Int?
    var sentAt: Date

    /// Starting later changes the meaning of a tap; only live delivery is allowed.
    var allowsDeferredDelivery: Bool { name != "start" }

    // Explicit memberwise init (a custom init(from:) below suppresses the
    // synthesized one).
    init(
        id: UUID = UUID(),
        timerId: String? = nil,
        expectedTimerRevision: WatchTimerRevision? = nil,
        name: String,
        phase: String? = nil,
        minutes: Int? = nil,
        sentAt: Date
    ) {
        self.id = id
        self.timerId = timerId
        self.expectedTimerRevision = expectedTimerRevision
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
        expectedTimerRevision = try container.decodeIfPresent(WatchTimerRevision.self, forKey: .expectedTimerRevision)
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

/// Snapshot cache missed on a refresh: no payload, never user content.
struct WatchSnapshotUnavailableError: Error, Sendable {}

/// Unknown command name only: never timer ids, revisions, or snapshots.
struct WatchUnknownCommandError: Error, Sendable {
    let name: String
}

extension WatchUnknownCommandError: LocalizedError {
    // Bare name: Sentry groups one issue per unknown command vocabulary word.
    var errorDescription: String? { name }
}

/// Attaches the snapshot's compare-and-set revision to timer controls.
/// Returns nil when no snapshot can ground the control. Pure so the
/// macOS/iOS unit-test bundle covers the watch decision without a host.
func stampWatchTimerControl(
    _ command: WatchTimerCommand,
    snapshot: WatchTimerSnapshot?
) -> WatchTimerCommand? {
    guard ["pause", "resume", "finish"].contains(command.name) else { return command }
    guard let revision = snapshot?.timerRevision,
          revision.timerId == command.timerId else { return nil }
    var stamped = command
    stamped.expectedTimerRevision = revision
    return stamped
}

/// Watch send outcome. Live/queued plans imply clearing commandError;
/// fail plans carry the user-facing failure.
enum WatchCommandSendFailure: String, Equatable, Sendable {
    case notActivated
    case startRequiresConnection
    case ungrounded
    case liveStartUnconfirmed
}

enum WatchCommandSendPlan: Equatable, Sendable {
    case live(WatchTimerCommand)
    case queued(WatchTimerCommand)
    case fail(WatchCommandSendFailure)
}

/// Pure send decision shared by the watch app and unit tests.
func planWatchCommandSend(
    _ command: WatchTimerCommand,
    snapshot: WatchTimerSnapshot?,
    isActivated: Bool,
    isReachable: Bool
) -> WatchCommandSendPlan {
    guard isActivated else { return .fail(.notActivated) }
    guard isReachable || command.allowsDeferredDelivery else {
        return .fail(.startRequiresConnection)
    }
    guard let stamped = stampWatchTimerControl(command, snapshot: snapshot) else {
        return .fail(.ungrounded)
    }
    if isReachable { return .live(stamped) }
    return .queued(stamped)
}

/// Live-send failure decision: Start never queues, others fall back ordered.
func planWatchCommandSendError(_ command: WatchTimerCommand) -> WatchCommandSendPlan {
    guard command.allowsDeferredDelivery else { return .fail(.liveStartUnconfirmed) }
    return .queued(command)
}

/// Phone-side FIFO for incoming watch commands. Each enqueue chains onto
/// the previous tail, so pause-then-resume applies in arrival order even
/// when the first work suspends. Sendable so nonisolated WC delegates share it.
final class WatchCommandSerialQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    func enqueue(_ work: @Sendable @escaping @MainActor () async -> Void) {
        tail.withLock { current in
            let previous = current
            current = Task { @MainActor in
                await previous?.value
                await work()
            }
        }
    }

    func flush() async {
        await tail.withLock { $0 }?.value
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
