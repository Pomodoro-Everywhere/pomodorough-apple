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
        // R49-U03 label: LabelStyle.automatic resolves standard-path title to
        // white on Xcode 26.6 / iPhone 17 even under .plain + foregroundStyle.
        // Explicit Text + decorative Image remove Label from color path.
        Button(action: add) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .accessibilityHidden(true)
                    .foregroundStyle(PomodoroughTheme.taskComposerLabel)
                Text("Add task")
                    .foregroundStyle(PomodoroughTheme.taskComposerLabel)
            }
            .padding()
            .background(PomodoroughTheme.signal, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(canAdd ? 1 : 0.5)
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
