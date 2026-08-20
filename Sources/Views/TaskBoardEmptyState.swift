import SwiftUI

struct TaskBoardEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "signpost.right.and.left")
                .font(.title2)
                .foregroundStyle(PomodoroughTheme.signal)
                .accessibilityHidden(true)
            Text("No tasks yet")
                .font(.headline)
            Text("Add a task, then assign it before starting focus.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .accessibilityRepresentation {
            Text("No tasks yet")
                .accessibilityValue("Add a task, then assign it before starting focus.")
        }
    }
}

#if DEBUG
#Preview {
    TaskBoardEmptyState()
}
#endif
