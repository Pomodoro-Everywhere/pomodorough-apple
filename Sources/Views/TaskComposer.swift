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
                .foregroundStyle(PomodoroughTheme.signalText)
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
        // R49-U03: the prominent style resolves the shorthand label color
        // from the button level on some SDKs, so carry the fill-derived
        // foreground on both the inner label and the button itself.
        Button(action: add) {
            Label("Add task", systemImage: "plus")
                .foregroundStyle(PomodoroughTheme.taskComposerLabel)
        }
        .buttonStyle(.borderedProminent)
        .tint(PomodoroughTheme.signal)
        .foregroundStyle(PomodoroughTheme.taskComposerLabel)
        .disabled(!canAdd)
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
