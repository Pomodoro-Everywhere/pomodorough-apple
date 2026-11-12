import SwiftUI

struct TaskRenameDraft: Identifiable, Equatable {
    let id: UUID
    var title: String
}

/// Alert prompt that renames a board task. Shared by the context menu on
/// every platform and the macOS double-click on a row title.
struct TaskRenameDialog: ViewModifier {
    @Binding var draft: TaskRenameDraft?
    let rename: (UUID, String) -> Void

    func body(content: Content) -> some View {
        content.alert("Rename task", isPresented: presented, presenting: draft) { presentedDraft in
            TextField("Task title", text: title)
            Button("Rename") {
                rename(presentedDraft.id, draft?.title ?? presentedDraft.title)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { draft != nil },
            set: { if !$0 { draft = nil } }
        )
    }

    private var title: Binding<String> {
        Binding(
            get: { draft?.title ?? "" },
            set: { draft?.title = $0 }
        )
    }
}

extension View {
    func taskRenameDialog(
        draft: Binding<TaskRenameDraft?>,
        rename: @escaping (UUID, String) -> Void
    ) -> some View {
        modifier(TaskRenameDialog(draft: draft, rename: rename))
    }
}
