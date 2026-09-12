import SwiftUI

struct TaskBoardHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    var body: some View {
        if showsColumns {
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

    private var showsColumns: Bool {
#if os(iOS)
        !dynamicTypeSize.isAccessibilitySize && horizontalSizeClass != .compact
#else
        !dynamicTypeSize.isAccessibilitySize
#endif
    }
}

#if DEBUG
#Preview {
    TaskBoardHeader()
}
#endif
