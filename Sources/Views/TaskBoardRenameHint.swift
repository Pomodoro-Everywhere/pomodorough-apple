import SwiftUI

/// IOS27-18: rename lives in each row's context menu, which nothing on the
/// board revealed. This caption under the board names the gesture.
struct TaskBoardRenameHint: View {
    var body: some View {
        Text("Touch and hold a task to rename it.")
            .font(.footnote)
            .foregroundStyle(PomodoroughTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("tasks.rename-hint")
    }
}
