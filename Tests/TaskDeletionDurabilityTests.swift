import Foundation
import Testing
#if os(macOS)
import AppKit
#endif
@testable import Pomodorough

/// The durable marker behind the task deletion undo window: written when the
/// board hides the task, cleared on undo and once the delete is written.
@Suite("Task deletion marker")
@MainActor
struct TaskDeletionMarkerTests {
    private let suiteName = "PomodoroughTests.TaskDeletionMarker.\(UUID().uuidString)"
    private static let local = TaskDeletionWorkspace(owner: "local", generation: UUID())

    private func store() throws -> TaskDeletionMarkerStore {
        TaskDeletionMarkerStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    @Test func requestWritesTheMarkerAndUndoClearsIt() throws {
        let markers = try store()
        defer { markers.defaults.removePersistentDomain(forName: suiteName) }
        let pending = PendingTaskDeletion(markers: markers)
        let id = UUID()

        let workspace = TaskDeletionWorkspace(owner: "account:user-1", generation: UUID())

        pending.request(id: id, title: "Draft", workspace: workspace) { _ in true }
        #expect(markers.load() == TaskDeletionMarker(taskID: id, workspace: workspace))

        pending.undo()
        #expect(markers.load() == nil)
    }

    /// In the foreground a refused delete ends the window for good: the
    /// person sees the task again, so nothing may delete it later.
    @Test func foregroundFlushClearsTheMarkerWhetherOrNotTheDeleteWasWritten() throws {
        let markers = try store()
        defer { markers.defaults.removePersistentDomain(forName: suiteName) }
        let pending = PendingTaskDeletion(markers: markers)

        pending.request(id: UUID(), title: "Refused", workspace: Self.local) { _ in false }
        #expect(pending.flush() == false)
        #expect(pending.entry == nil, "a failed delete still ends the window")
        #expect(markers.load() == nil, "a refused foreground delete is never replayed")

        pending.request(id: UUID(), title: "Written", workspace: Self.local) { _ in true }
        #expect(pending.flush())
        #expect(markers.load() == nil)
    }

    /// Leaving the foreground or quitting shows nothing, so a failed delete
    /// keeps its marker for the next foreground.
    @Test func leavingTheForegroundKeepsTheMarkerOnlyForAFailedDelete() throws {
        let markers = try store()
        defer { markers.defaults.removePersistentDomain(forName: suiteName) }
        let pending = PendingTaskDeletion(markers: markers)
        let failing = UUID()

        pending.request(id: failing, title: "Stays marked", workspace: Self.local) { _ in false }
        #expect(pending.flushLeavingForeground() == false)
        #expect(pending.entry == nil)
        #expect(markers.load()?.taskID == failing, "the marker waits for a replay")

        pending.request(id: UUID(), title: "Written", workspace: Self.local) { _ in true }
        #expect(pending.flushLeavingForeground())
        #expect(markers.load() == nil)
    }

    @Test func damagedMarkerIsDroppedInsteadOfDecoded() throws {
        let markers = try store()
        defer { markers.defaults.removePersistentDomain(forName: suiteName) }
        markers.defaults.set(Data("not a marker".utf8), forKey: TaskDeletionMarkerStore.key)

        #expect(markers.load() == nil)
        #expect(markers.defaults.data(forKey: TaskDeletionMarkerStore.key) == nil)
    }
}

/// Batch A acceptance M1: a workspace that refuses changes must not show a
/// deletion as done and then bring the task back when the window ends.
@Suite("Task deletion in a blocked workspace")
@MainActor
struct TaskDeletionRefusalTests {
    @Test func blockedWorkspaceOpensNoUndoWindowAndSaysTheTaskWasNotDeleted() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        // A staged account switch waiting for confirmation blocks every
        // change while the board still shows the account's tasks.
        var state = TestFixtures.syncContractState(includesPendingOperations: false)
        state.cachedUser = User(id: "old-user", email: "old@example.com", name: "Old", avatarUrl: "")
        state.pendingAccountSwitchUser = TestFixtures.user
        fixture.defaults.set(try JSONEncoder.api.encode(state), forKey: PersistedStateLoader.storageKey)

        let model = fixture.makeModel()
        try #require(model.isWorkspaceMutationBlocked)
        let task = try #require(model.tasks.first)
        #expect(model.requestTaskDeletion(id: task.id, title: task.title) == false)

        #expect(model.pendingTaskDeletion.entry == nil, "no window opens, so the row stays on the board")
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
        #expect(model.tasks.contains(task))
        #expect(model.errorMessage == String(localized: "The task was not deleted. Changes are paused right now."))
    }

    @Test func pendingAccountDeletionRecoveryOpensNoUndoWindow() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let seeding = fixture.makeModel()
        #expect(await seeding.addTask("Kept while recovery runs"))
        let task = try #require(seeding.tasks.first)
        // An account deletion whose recovery is pending blocks every change.
        fixture.defaults.set("prepared", forKey: "account-deletion-state-v1")

        let model = fixture.makeModel()
        try #require(model.isWorkspaceMutationBlocked)
        #expect(model.requestTaskDeletion(id: task.id, title: task.title) == false)

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
        #expect(model.errorMessage == String(localized: "The task was not deleted. Changes are paused right now."))
    }
}

/// Rule 7 of the durable-deletion rule, on the signed-out local workspace:
/// a deletion survives a process kill, Undo survives a restart, and a
/// marker that does not match the workspace deletes nothing.
@Suite("Task deletion survives a restart")
@MainActor
struct TaskDeletionRestartTests {
    private func modelWithHiddenTask(
        _ fixture: UndoWindowModelFixture,
        title: String = "Hidden across launches"
    ) async throws -> (AppModel, FocusTask) {
        let model = fixture.makeModel()
        #expect(await model.addTask(title))
        let task = try #require(model.tasks.first { $0.title == title })
        model.requestTaskDeletion(id: task.id, title: task.title)
        return (model, task)
    }

    @Test func killDuringTheWindowFinishesTheDeletionAtTheNextStart() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let (killed, task) = try await modelWithHiddenTask(fixture)
        #expect(killed.tasks.contains(task), "the window only hides the task")

        let relaunched = fixture.makeModel()
        await relaunched.restore()

        #expect(!relaunched.tasks.contains { $0.id == task.id }, "a deleted task must not come back")
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
        #expect(relaunched.errorMessage == nil)
    }

    @Test func undoThenRestartKeepsTheTask() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let (model, task) = try await modelWithHiddenTask(fixture)
        model.pendingTaskDeletion.undo()

        let relaunched = fixture.makeModel()
        await relaunched.restore()

        #expect(relaunched.tasks.contains(task))
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
    }

    @Test func markerForAnotherOwnerDeletesNothing() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Local task"))
        let task = try #require(model.tasks.first)
        let markers = TaskDeletionMarkerStore(defaults: fixture.defaults)
        let generation = try fixture.workspaceGeneration()
        markers.save(TaskDeletionMarker(
            taskID: task.id,
            workspace: TaskDeletionWorkspace(owner: "account:someone-else", generation: generation)
        ))

        let relaunched = fixture.makeModel()
        await relaunched.restore()

        #expect(relaunched.tasks.contains(task), "a marker from another workspace must not delete here")
        #expect(markers.load() == nil, "the foreign marker is dropped")
    }

    @Test func markerFromAnEarlierWorkspaceGenerationDeletesNothing() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Same owner, later workspace"))
        let task = try #require(model.tasks.first)
        _ = try fixture.workspaceGeneration()
        let markers = TaskDeletionMarkerStore(defaults: fixture.defaults)
        markers.save(TaskDeletionMarker(
            taskID: task.id,
            workspace: TaskDeletionWorkspace(owner: TaskDeletionWorkspace.signedOutOwner, generation: UUID())
        ))

        let relaunched = fixture.makeModel()
        await relaunched.restore()

        #expect(relaunched.tasks.contains(task), "a sign-out and sign-in in between makes it another workspace")
        #expect(markers.load() == nil)
    }

    @Test func markerForAMissingTaskDeletesNothingElse() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Unrelated task"))
        let before = model.tasks
        let markers = TaskDeletionMarkerStore(defaults: fixture.defaults)
        markers.save(TaskDeletionMarker(
            taskID: UUID(),
            workspace: TaskDeletionWorkspace(
                owner: TaskDeletionWorkspace.signedOutOwner,
                generation: try fixture.workspaceGeneration()
            )
        ))

        let relaunched = fixture.makeModel()
        await relaunched.restore()

        #expect(relaunched.tasks == before)
        #expect(markers.load() == nil)
        #expect(relaunched.errorMessage == nil)
    }
}

/// The undo window outlasts `.inactive` and ends when the scene moves to
/// the background or the app quits. A delete that fails then opens no
/// alert; the marker stays and the next foreground replays it.
@Suite("Task deletion leaving the foreground")
@MainActor
struct TaskDeletionForegroundTests {
    /// Makes the workspace folder read-only, so the next durable write of
    /// the delete fails the way a full or locked disk would.
    private func refuseDurableWrites(_ fixture: UndoWindowModelFixture, _ refused: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: refused ? 0o500 : 0o700],
            ofItemAtPath: fixture.directory.path
        )
    }

    private func hiddenTask(in model: AppModel) async throws -> FocusTask {
        #expect(await model.addTask("Leaving with the window open"))
        let task = try #require(model.tasks.first)
        model.requestTaskDeletion(id: task.id, title: task.title)
        return task
    }

    @Test func sceneGoingInactiveKeepsTheUndoWindow() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setSceneActive(true)
        let task = try await hiddenTask(in: model)

        // Control Center, a system sheet or the app switcher.
        model.setSceneActive(false)
        model.setSceneActive(true)

        #expect(model.pendingTaskDeletion.entry?.id == task.id, "Undo is still offered on return")
        #expect(model.tasks.contains(task))
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load()?.taskID == task.id)
    }

    @Test func sceneMovingToTheBackgroundCompletesTheDeletion() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setSceneActive(true)
        _ = try await hiddenTask(in: model)

        // `PomodoroughApp` calls this when the scene phase becomes `.background`.
        model.completeTaskDeletionLeavingForeground()
        model.setSceneActive(false)

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(model.tasks.isEmpty)
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
    }

    @Test func quittingCompletesTheDeletion() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        _ = try await hiddenTask(in: model)

        // macOS calls this from `NSApplication.willTerminateNotification`.
        model.completeTaskDeletionLeavingForeground()

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(model.tasks.isEmpty)
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
    }

    @Test func failedCompletionInTheBackgroundOpensNoAlertAndReplaysOnReturn() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setSceneActive(true)
        let task = try await hiddenTask(in: model)

        try refuseDurableWrites(fixture, true)
        model.completeTaskDeletionLeavingForeground()
        model.setSceneActive(false)
        #expect(model.errorMessage == nil, "no alert while the scene leaves the foreground")
        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load()?.taskID == task.id)

        try refuseDurableWrites(fixture, false)
        model.setSceneActive(true)
        #expect(!model.tasks.contains(task), "the next foreground finishes the deletion")
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
        #expect(model.errorMessage == nil)
    }

    /// Android rule: a delete refused while the app is in front ends the
    /// window for good. The marker is cleared, the task is shown again with
    /// the reason, and no later foreground, replay or restart deletes it.
    @Test func refusedForegroundDeleteShowsTheTaskAgainAndNeverReplays() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setSceneActive(true)
        let task = try await hiddenTask(in: model)
        try refuseDurableWrites(fixture, true)

        #expect(model.pendingTaskDeletion.flush() == false) // what opening Account does
        try refuseDurableWrites(fixture, false)

        let markers = TaskDeletionMarkerStore(defaults: fixture.defaults)
        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(markers.load() == nil)
        #expect(model.tasks.contains { $0.id == task.id }, "the task is back in the list")
        #expect(model.errorMessage == "Could not delete “Leaving with the window open”. The task is back in your list.")

        model.selectedTaskID = task.id
        #expect(model.start(), "the task can be used again")
        #expect(model.activeTimer?.taskId.flatMap(UUID.init(uuidString:)) == task.id)
        model.completeTaskDeletionLeavingForeground()
        model.setSceneActive(false)
        model.setSceneActive(true)
        #expect(model.tasks.contains { $0.id == task.id }, "returning to the app deletes nothing")

        let relaunched = fixture.makeModel()
        await relaunched.restore()
        #expect(relaunched.tasks.contains { $0.id == task.id }, "a restart deletes nothing")
        #expect(relaunched.activeTimer?.taskId.flatMap(UUID.init(uuidString:)) == task.id)
        #expect(markers.load() == nil)
    }

#if os(macOS)
    /// The app, not a window, observes quitting: a Mac app can quit with
    /// every window closed while the undo window is still open.
    @Test func applicationTerminationCompletesTheDeletionWithoutAWindow() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let center = NotificationCenter()
        model.observeApplicationTermination(on: center)
        let task = try await hiddenTask(in: model)

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(!model.tasks.contains { $0.id == task.id })
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
    }
#endif

    @Test func replayThatFailsAgainTellsThePerson() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let task = try await hiddenTask(in: model)
        try refuseDurableWrites(fixture, true)
        defer { try? refuseDurableWrites(fixture, false) }
        model.completeTaskDeletionLeavingForeground()
        model.setSceneActive(false)

        model.setSceneActive(true)

        #expect(model.errorMessage == String(localized: "A task you deleted could not be removed yet. Pomodorough will try again the next time it opens."))
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load()?.taskID == task.id)
    }
}

/// Surfaces outside the Tasks board reach the workspace through the model.
/// Each one completes the deletion before it acts on the hidden task.
@Suite("Task deletion entry points outside the board")
@MainActor
struct TaskDeletionEntryPointTests {
    @Test func widgetToggleCompletesTheDeletionBeforeResumingItsTimer() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Paused focus task"))
        let task = try #require(model.tasks.first)
        model.selectedTaskID = task.id
        #expect(model.start())
        #expect(model.pause())
        model.requestTaskDeletion(id: task.id, title: task.title)

        // Widget and Live Activity links call `toggleTimer`, which resumes.
        model.toggleTimer()

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(!model.tasks.contains { $0.id == task.id })
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
    }

    @Test func watchStartCompletesTheDeletionFirst() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Selected on the phone"))
        let task = try #require(model.tasks.first)
        model.selectedTaskID = task.id
        model.requestTaskDeletion(id: task.id, title: task.title)

        #expect(model.applyWatchCommand(WatchTimerCommand(name: "start", sentAt: .now)))

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(model.tasks.isEmpty)
        #expect(model.activeTimer?.taskId == nil)
    }

    @Test func renameOfTheHiddenTaskCompletesTheDeletionFirst() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Renamed elsewhere"))
        let task = try #require(model.tasks.first)
        model.requestTaskDeletion(id: task.id, title: task.title)

        _ = await model.renameTask(id: task.id, title: "Must not land")

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(!model.tasks.contains { $0.id == task.id })
    }

    /// Changing the replication mode, creating a room and joining one
    /// replace the workspace, so the model writes the hidden delete first,
    /// whichever surface asked. Each change here then stops early, which
    /// keeps the test offline.
    @Test(arguments: WorkspaceOwnershipChange.allCases)
    func workspaceOwnershipChangeCompletesTheDeletionFirst(_ change: WorkspaceOwnershipChange) async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Hidden before the workspace changes"))
        let task = try #require(model.tasks.first)
        model.requestTaskDeletion(id: task.id, title: task.title)

        await change.apply(to: model)

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
        // A mode change shows another workspace; return to the local one.
        if model.replicationMode != .offline { await model.setReplicationMode(.offline) }
        #expect(model.replicationMode == .offline)
        #expect(!model.tasks.contains { $0.id == task.id }, "the local workspace no longer holds the task")
    }

    @Test func signInCompletesTheDeletionInTheSignedOutWorkspace() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Signed-out task"))
        let task = try #require(model.tasks.first)
        model.requestTaskDeletion(id: task.id, title: task.title)

        model.signIn()

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(!model.tasks.contains { $0.id == task.id })
        #expect(TaskDeletionMarkerStore(defaults: fixture.defaults).load() == nil)
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// The model entry points that replace the workspace, other than sign-out
/// and room leave, which need a signed-in fixture.
enum WorkspaceOwnershipChange: CaseIterable, Sendable {
    case replicationMode
    case createRoom
    case joinRoom

    @MainActor
    func apply(to model: AppModel) async {
        switch self {
        case .replicationMode:
            await model.setReplicationMode(.centralized)
        case .createRoom:
            // Over the 64-character limit, so no room is created.
            _ = await model.createIrohRoom(name: String(repeating: "r", count: 65))
        case .joinRoom:
            _ = await model.joinIrohRoom(inviteText: "not an invite")
        }
    }
}
