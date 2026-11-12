import SwiftUI

/// The Tasks screen's undo window: the bottom banner while a deletion
/// waits, and the end of the window when the screen goes away.
struct TaskDeletionUndoWindow: ViewModifier {
    @Environment(PendingTaskDeletion.self) private var pendingDeletion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) { banner }
            // Leaving the Tasks screen ends the undo window.
            .onDisappear { pendingDeletion.flush() }
    }

    /// Bottom inset so the banner clears the tab bar and keeps the board
    /// scrollable above it.
    @ViewBuilder
    private var banner: some View {
        if let entry = pendingDeletion.entry {
            TaskDeletionUndoBanner(
                title: entry.title,
                undo: pendingDeletion.undo,
                deleteNow: { pendingDeletion.flush() }
            )
                // A new deletion is a new banner, so it is announced again.
                .id(entry.id)
                .padding(.horizontal)
                .padding(.bottom, TabBarScrollInset.minimumClearance / 4)
                .frame(maxWidth: 760)
                .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    func taskDeletionUndoWindow() -> some View {
        modifier(TaskDeletionUndoWindow())
    }
}
