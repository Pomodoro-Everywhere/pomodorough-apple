import Foundation
import Testing
@testable import Pomodorough

/// Wire shape and identity budget for the `renameTask` workspace intent.
@Suite("Task rename workspace intent")
struct TaskRenameIntentTests {
    @Test func renameTaskEncodesKindTaskIdAndTitle() throws {
        let kind = WorkspaceIntentKind.renameTask(taskId: "11111111-2222-4333-8444-555555555555", title: "Ship it")
        let data = try JSONEncoder().encode(kind)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["kind"] as? String == "renameTask")
        #expect(json["taskId"] as? String == "11111111-2222-4333-8444-555555555555")
        #expect(json["title"] as? String == "Ship it")
        #expect(Set(json.keys) == ["kind", "taskId", "title"])
    }

    @MainActor
    @Test func renameTaskReservesFourIdentities() {
        let admission = WorkspaceIntentAdmission(sharedCoreProvider: { try SharedCore.bundled() })
        #expect(admission.identityCount(kind: .renameTask(taskId: "t", title: "x")) == 4)
        #expect(admission.identityCount(kind: .deleteTask("t")) == 3)
        #expect(admission.identityCount(kind: .start) == 2)
        #expect(!admission.needsTimerUuid(kind: .renameTask(taskId: "t", title: "x")))
    }

    @MainActor
    @Test func renameIntentMapsToDurableRenameKind() throws {
        let controller = SynchronizedWorkspaceMutationController(
            timerSessionController: TimerSessionController { try SharedCore.bundled() },
            timerIDProvider: { "timer-rename-test" }
        )
        let task = try #require(FocusTask(title: "Old title"))
        let (kind, category) = controller.intentKind(for: .renameTask(task, "New title"))
        guard case .renameTask(let taskId, let title)? = kind else {
            Issue.record("expected renameTask kind, got \(String(describing: kind))")
            return
        }
        #expect(taskId == task.id.uuidString.lowercased())
        #expect(title == "New title")
        #expect(category == .taskRename)
    }

    @MainActor
    @Test func optimisticRenameMergesTheNewIdentityIntoKnownTasks() throws {
        let admission = WorkspaceIntentAdmission(sharedCoreProvider: { try SharedCore.bundled() })
        let old = try #require(FocusTask(title: "Old title"))
        let renamed = try #require(FocusTask(title: "New title"))
        var state = PersistedTimerState.fresh()
        state.mergeKnownTasks([old])
        let snapshot = SynchronizedWorkspaceMutationController.Snapshot(
            state: state,
            canonicalTimer: state.canonicalTimer,
            tasks: state.tasks,
            projectedAutoStartBreaks: state.autoStartBreaks,
            projectedSelectedTaskID: state.selectedTaskID,
            replicationMode: .centralized,
            localDate: Date(timeIntervalSince1970: 1_710_000_001),
            trustedClockUptime: 100,
            isWorkspaceMutationBlocked: false
        )
        admission.applyOptimistic(
            kind: .renameTask(taskId: old.id.uuidString.lowercased(), title: "New title"),
            snapshot: snapshot,
            state: &state
        )
        #expect(state.knownTasks.contains(renamed))
        #expect(state.knownTasks.contains(old), "the old identity stays until Core's delete lands")
    }

    /// Core 0.56.0 plans a rename as a `rename` operation. The wire and the
    /// persisted queue decode it by its raw type, so this test builds it
    /// from JSON.
    @Test func renameOperationNeedsATitleWithANewIdentity() throws {
        let old = try #require(FocusTask(title: "Old title"))
        func operation(title: String?) throws -> TaskOperation {
            var json: [String: Any] = [
                "id": "task-operation-rename",
                "taskId": old.id.uuidString.lowercased(),
                "type": "rename",
                "occurredAt": "2024-03-09T16:00:01.000Z",
                "hlcWallMs": 1_710_000_001_000,
                "hlcCounter": 0,
            ]
            json["title"] = title
            return try JSONDecoder.api.decode(
                TaskOperation.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        }

        let rename = try operation(title: "New title")
        #expect(rename.type.rawValue == "rename")
        #expect(rename.isValid)
        #expect(try !operation(title: nil).isValid, "a rename names its new title")
        #expect(try !operation(title: "Old title").isValid, "the new identity must differ")
    }

    @MainActor
    @Test func offlineRenameMovesTheTaskToItsNewIdentity() async throws {
        let fixture = try UndoWindowModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(await model.addTask("Old title"))
        let old = try #require(model.tasks.first)
        let renamed = try #require(FocusTask(title: "New title"))

        // backlog-ux Core follow-up: Core's retained_entrypoint returns false
        // for AppleWorkspace (projection.rs:106), so without a canonical head
        // the safe replay drops the pending upsert and rename finds no task.
        // Fails on Core 0.55 too. When Core fixes it, the known issue stops
        // occurring and this test turns red: remove the wrapper then.
        await withKnownIssue("Core drops pending upserts from the rename input without a canonical head") {
            #expect(await model.renameTask(id: old.id, title: "New title"))
            #expect(model.errorMessage == nil)
            #expect(model.tasks == [renamed])
            let restarted = fixture.makeModel()
            #expect(restarted.tasks == [renamed], "the persisted rename reloads")
        }
    }
}
