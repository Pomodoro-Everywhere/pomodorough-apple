import SwiftUI

struct RouteClockMark: View {
    var compact = false

    var body: some View {
        ZStack {
            Circle().fill(PomodoroughTheme.ticket)
            Circle().stroke(PomodoroughTheme.porcelain, lineWidth: compact ? 2 : 4)
            Circle().stroke(PomodoroughTheme.platform, lineWidth: compact ? 4 : 8).padding(compact ? 5 : 8)
            Text("P")
                .font(.system(size: compact ? 20 : 42, weight: .black, design: .rounded))
                .foregroundStyle(PomodoroughTheme.platform)
        }
        .frame(width: compact ? 44 : 88, height: compact ? 44 : 88)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    RouteClockMark()
        .padding()
}
#endif
