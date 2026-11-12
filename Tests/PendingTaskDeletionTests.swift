import Foundation
import Testing
@testable import Pomodorough

/// Undo-window semantics for board task deletion: the window has no time
/// limit, and the mutation runs exactly once, on flush, never after an undo.
@Suite("Pending task deletion undo window")
@MainActor
struct PendingTaskDeletionTests {
    @MainActor
    private final class DeleteLog {
        var ids: [UUID] = []

        func record(_ id: UUID) -> Bool {
            ids.append(id)
            return true
        }
    }

    private static let workspace = TaskDeletionWorkspace(owner: "local", generation: UUID())

    /// The window used to end after five seconds. It now has no clock: no
    /// stored task, timer, work item or deadline can end it on its own.
    /// The 7 s UI pair in `PomodoroughTaskDeletionUndoUITests` covers the
    /// running app.
    @Test func undoWindowHasNoClock() {
        let pending = PendingTaskDeletion()
        let log = DeleteLog()
        let id = UUID()
        pending.request(id: id, title: "Write release notes", workspace: Self.workspace, delete: log.record)

        let storedTypes = Mirror(reflecting: pending).children.map { String(describing: type(of: $0.value)) }
        let clocks = ["Task<", "Timer", "DispatchWorkItem", "DispatchSource", "Date", "Duration", "ContinuousClock"]
        #expect(!storedTypes.contains { stored in clocks.contains { stored.contains($0) } }, "\(storedTypes)")
        #expect(pending.entry == PendingTaskDeletion.Entry(id: id, title: "Write release notes"))
        #expect(log.ids.isEmpty, "the window ends only when the user moves on")
        pending.flush()
        #expect(log.ids == [id])
        #expect(pending.entry == nil)
    }

    @Test func undoCancelsTheDeletion() {
        let pending = PendingTaskDeletion()
        let log = DeleteLog()
        pending.request(id: UUID(), title: "Keep me", workspace: Self.workspace, delete: log.record)
        pending.undo()
        #expect(pending.entry == nil)
        pending.flush()
        #expect(log.ids.isEmpty, "flush after undo has nothing to commit")
    }

    @Test func secondRequestFlushesTheFirst() {
        let pending = PendingTaskDeletion()
        let log = DeleteLog()
        let first = UUID()
        let second = UUID()
        pending.request(id: first, title: "First", workspace: Self.workspace, delete: log.record)
        pending.request(id: second, title: "Second", workspace: Self.workspace, delete: log.record)
        #expect(log.ids == [first])
        #expect(pending.entry?.id == second)
        pending.flush()
        #expect(log.ids == [first, second])
    }

    @Test func flushIsIdempotent() {
        let pending = PendingTaskDeletion()
        let log = DeleteLog()
        let id = UUID()
        pending.request(id: id, title: "Once", workspace: Self.workspace, delete: log.record)
        pending.flush()
        pending.flush()
        #expect(log.ids == [id])
        #expect(pending.entry == nil)
    }

    @Test func flushWithoutRequestDoesNothing() {
        let pending = PendingTaskDeletion()
        pending.flush()
        pending.undo()
        #expect(pending.entry == nil)
    }

    @Test func bannerAnnouncementNamesTheTaskAndTheUndo() {
        let spoken = TaskDeletionUndoBanner.announcement(title: "Write release notes")
        #expect(spoken == "Deleted “Write release notes”. Undo is available.")
    }
}

/// While the undo window is open the task still exists in the workspace and
/// is only hidden on the board. Nothing may act on it: an intent that would
/// do so commits the deletion first.
@Suite("Task deletion undo window fences the hidden task")
@MainActor
struct TaskDeletionUndoWindowFenceTests {
    private func modelWithHiddenFocusTask(_ fixture: UndoWindowModelFixture) async throws -> (AppModel, FocusTask) {
        let model = fixture.makeModel()
        #expect(await model.addTask("Hidden focus task"))
        let task = try #require(model.tasks.first)
        model.selectedTaskID = task.id
        #expect(model.selectedTaskID == task.id)
        model.requestTaskDeletion(id: task.id, title: task.title)
        #expect(model.tasks == [task], "the window only hides the task")
        return (model, task)
    }

    @Test func startCommitsTheDeletionBeforeTheTimerStarts() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let (model, _) = try await modelWithHiddenFocusTask(fixture)

        #expect(model.start())

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(model.tasks.isEmpty)
        #expect(model.selectedTaskID == nil)
        let timer = try #require(model.activeTimer)
        #expect(timer.taskId == nil, "a timer must not start on a task that is being deleted")
        #expect(model.errorMessage == nil)
    }

    @Test func selectingTheHiddenTaskCommitsTheDeletionInstead() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let (model, task) = try await modelWithHiddenFocusTask(fixture)
        model.selectedTaskID = nil

        model.selectedTaskID = task.id

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(model.tasks.isEmpty)
        #expect(model.selectedTaskID == nil)
    }

    @Test func unrelatedIntentsLeaveTheUndoWindowOpen() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let (model, task) = try await modelWithHiddenFocusTask(fixture)
        model.selectedTaskID = nil

        #expect(model.start(), "a timer without the hidden task does not end the window")
        #expect(model.pause())

        #expect(model.pendingTaskDeletion.entry?.id == task.id)
        #expect(model.tasks == [task])
        model.pendingTaskDeletion.undo()
        #expect(model.tasks == [task], "undo keeps the task untouched")
    }
}

/// Offline model on isolated defaults and files, so task and timer intents
/// run through the real workspace mutation path without any network.
@MainActor
struct UndoWindowModelFixture {
    let suiteName = "PomodoroughTests.TaskDeletionUndoWindow.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    }

    func makeModel() -> AppModel {
        AppModel(
            api: APIClient(
                session: TestFixtures.session(for: suiteName),
                keychain: EmptyTokenStore(),
                logoutRevocationStore: TestLogoutRevocationStore()
            ),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(
                fileURL: directory.appendingPathComponent("account-deletion.json")
            ),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("timer-state.json")
            ),
            roomStore: IrohRoomStore(
                fileURL: directory.appendingPathComponent("iroh-rooms.json"),
                secretStore: MemoryIrohRoomSecretStore()
            ),
            endpointKeyStore: PreviewEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
    }

    /// The persisted workspace generation every model of this fixture reads;
    /// written here first when no model has created it yet.
    func workspaceGeneration() throws -> UUID {
        let key = "watch-workspace-generation-v1"
        if let raw = defaults.string(forKey: key) {
            return try #require(UUID(uuidString: raw))
        }
        let generation = UUID()
        defaults.set(generation.uuidString, forKey: key)
        return generation
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
