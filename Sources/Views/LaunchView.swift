import SwiftUI

struct LaunchView: View {
    var body: some View {
        ZStack {
            PomodoroughTheme.platform.ignoresSafeArea()
            VStack(spacing: 18) {
                RouteClockMark()
                ProgressView()
                    .tint(PomodoroughTheme.ticket)
                Text("CHECKING LINE")
                    .font(.caption.monospaced().bold())
                    .tracking(2)
                    .foregroundStyle(PomodoroughTheme.sky)
            }
            .accessibilityRepresentation {
                Text("Checking line")
            }
        }
    }
}

#if DEBUG
#Preview {
    LaunchView()
}
#endif
