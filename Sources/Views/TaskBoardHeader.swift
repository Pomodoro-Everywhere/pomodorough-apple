import SwiftUI

struct TaskBoardHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: 10) {
                Text("TASK")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("FINISHED")
                    .frame(width: 68, alignment: .center)
                Text("TIME")
                    .frame(width: 70, alignment: .center)
                Text("ACTION")
                    .frame(width: 52, alignment: .center)
            }
            .font(.caption2.monospaced().bold())
            .foregroundStyle(PomodoroughTheme.sky)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .background(PomodoroughTheme.track)
            .accessibilityHidden(true)
        }
    }
}

#if DEBUG
#Preview {
    TaskBoardHeader()
}
#endif
