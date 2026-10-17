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
        // R49-U03 rework: borderedProminent forces white on Xcode 26.6 /
        // iPhone 17 standard size even with inner+outer foregroundStyle.
        // Plain leaves foreground alone, so explicit signal fill plus
        // fill-derived black label survive both themes and sizes.
        Button(action: add) {
            Label("Add task", systemImage: "plus")
                .foregroundStyle(PomodoroughTheme.taskComposerLabel)
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
