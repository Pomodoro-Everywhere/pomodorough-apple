#if DEBUG
import Foundation

struct PreviewTokenStore: TokenStoring {
    func load() throws -> TokenPair? { nil }
    func save(_ tokens: TokenPair) throws {}
    func delete() throws {}
}

struct PreviewEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { nil }
    func save(_ key: Data) throws {}
}

struct PreviewRoomSecretStore: IrohRoomSecretStoring {
    func load(roomID: String) throws -> Data? { nil }
    func save(_ secret: Data, roomID: String) throws {}
    func delete(roomID: String) throws {}
}

@MainActor
final class PreviewAlarmScheduler: TimerAlarmScheduling {
    func requestAuthorization() async throws {}
    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {}
    func pause(timerID: String) async throws {}
    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {}
    func cancel(timerID: String) async throws {}
}

@MainActor
struct PreviewGoogleIdentityProvider: GoogleIdentityProviding {
    func identityToken(nonce: String) async throws -> String { throw AppError.configuration }
    func handle(_ url: URL) -> Bool { false }
    func signOut() {}
}

enum PreviewFixtures {
    static let now = Date(timeIntervalSince1970: 1_725_000_000)
    static let task = FocusTask(title: "Write release notes")!
    static let secondTask = FocusTask(title: "Review pull request")!

    static let runningTimer = CanonicalTimer(
        id: "preview-timer",
        taskId: task.id.uuidString.lowercased(),
        phase: .focus,
        status: .running,
        plannedDurationMs: 25 * 60_000,
        elapsedAtAnchorMs: 8 * 60_000,
        anchorAt: now,
        startedByDeviceId: "preview-device",
        lastIntent: nil
    )

    static let history = [
        HistoryItem(
            id: "preview-history-1",
            timerId: "preview-completed-1",
            commandId: nil,
            taskId: task.id.uuidString.lowercased(),
            phase: .focus,
            status: CanonicalTimer.Status.completed.rawValue,
            plannedDurationMs: 25 * 60_000,
            completedAt: now.addingTimeInterval(-3_600),
            endedAt: nil
        ),
        HistoryItem(
            id: "preview-history-2",
            timerId: "preview-completed-2",
            commandId: nil,
            taskId: secondTask.id.uuidString.lowercased(),
            phase: .shortBreak,
            status: CanonicalTimer.Status.completed.rawValue,
            plannedDurationMs: 5 * 60_000,
            completedAt: now.addingTimeInterval(-1_800),
            endedAt: nil
        )
    ]

    static let taskSummary = TaskDailySummary(
        task: task,
        finishedPomodoros: 3,
        timeSpentMs: 75 * 60_000
    )
}
#endif
