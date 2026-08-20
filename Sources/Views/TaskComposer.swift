import SwiftUI

struct TaskComposer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var title: String
    var focused: FocusState<Bool>.Binding
    let canAdd: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD TASK")
                .font(.caption2.monospaced().bold())
                .tracking(1.2)
                .foregroundStyle(PomodoroughTheme.signal)
                .accessibilityHidden(true)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) { composerControls }
                } else {
                    HStack(spacing: 10) { composerControls }
                }
            }
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.steel, lineWidth: 2)
        }
    }

    @ViewBuilder
    private var composerControls: some View {
        TextField("Write release notes", text: $title)
            .focused(focused)
            .submitLabel(.done)
            .onSubmit(add)
            .accessibilityLabel("New task")
            .accessibilityAction(named: "Add task") {
                guard canAdd else { return }
                add()
            }
        Button("Add task", systemImage: "plus", action: add)
            .buttonStyle(.borderedProminent)
            .tint(PomodoroughTheme.signal)
            .disabled(!canAdd)
            .accessibilityHidden(true)
    }
}

#if DEBUG
private struct TaskComposerPreview: View {
    @State private var title = "Write release notes"
    @FocusState private var focused: Bool

    var body: some View {
        TaskComposer(
            title: $title,
            focused: $focused,
            canAdd: FocusTask(title: title) != nil,
            add: { title = "" }
        )
        .padding()
    }
}

#Preview {
    TaskComposerPreview()
}
#endif
