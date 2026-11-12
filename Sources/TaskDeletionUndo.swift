import Foundation
import Observation

/// One task deletion waiting out its undo window. The board hides the task
/// as soon as the deletion is requested. The window has no time limit: it
/// stays open until the user undoes it or chooses Delete now, deletes
/// another task, leaves the Tasks screen, opens Account, or the scene moves
/// to the background. The
/// workspace mutation runs exactly once, when the window ends without an
/// undo.
///
/// While the window is open a durable marker names the task and its
/// workspace, so a process that dies inside the window still
/// finishes the deletion at the next start. The marker is cleared on undo
/// and once the delete is written. A delete that fails in the foreground
/// clears it too: the task shows again, so nothing may delete it later on
/// its own. Only a delete that fails while the scene leaves the foreground
/// or the app quits keeps the marker for a replay.
@Observable
@MainActor
final class PendingTaskDeletion {
    struct Entry: Equatable, Sendable {
        let id: UUID
        let title: String
    }

    private(set) var entry: Entry?
    private var commit: (@MainActor (UUID) -> Bool)?
    @ObservationIgnored private let markers: TaskDeletionMarkerStore?

    /// `markers` is nil only for previews, which have no workspace to keep.
    init(markers: TaskDeletionMarkerStore? = nil) {
        self.markers = markers
    }

    /// The marker left by a deletion that has not been written yet.
    var marker: TaskDeletionMarker? { markers?.load() }

    /// Hides the task and opens the undo window. A deletion already waiting
    /// is flushed first, so at most one task is pending at a time. The
    /// marker is written before the task is hidden. `delete` returns
    /// whether the workspace delete was written.
    func request(
        id: UUID,
        title: String,
        workspace: TaskDeletionWorkspace,
        delete: @escaping @MainActor (UUID) -> Bool
    ) {
        flush()
        markers?.save(TaskDeletionMarker(taskID: id, workspace: workspace))
        entry = Entry(id: id, title: title)
        commit = delete
    }

    /// Restores the task without touching the workspace.
    func undo() {
        guard entry != nil else { return }
        entry = nil
        commit = nil
        markers?.clear()
    }

    /// Ends the undo window in the foreground and commits the pending
    /// deletion now. Safe to call repeatedly: the first call clears the
    /// entry, so later calls do nothing. Returns false only when a delete
    /// ran and was not written. The marker is cleared either way, because a
    /// refused delete shows the task again and the person sees why.
    @discardableResult
    func flush() -> Bool {
        guard let written = commitOpenWindow() else { return true }
        markers?.clear()
        return written
    }

    /// Ends the undo window while the scene leaves the foreground or the app
    /// quits. No one sees a refusal now, so a delete that is not written
    /// keeps the marker and the next foreground or start replays it.
    @discardableResult
    func flushLeavingForeground() -> Bool {
        guard let written = commitOpenWindow() else { return true }
        if written { markers?.clear() }
        return written
    }

    /// Closes the open window and runs its delete. Nil when no window is open.
    private func commitOpenWindow() -> Bool? {
        guard let entry, let commit else { return nil }
        self.entry = nil
        self.commit = nil
        return commit(entry.id)
    }

    /// Drops the marker after a replay wrote the delete or found nothing
    /// that may be deleted. Never touches an open window.
    func clearMarker() {
        guard entry == nil else { return }
        markers?.clear()
    }
}
