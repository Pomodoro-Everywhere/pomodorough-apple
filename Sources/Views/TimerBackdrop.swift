import SwiftUI

struct TimerBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backdropColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(PomodoroughTheme.ticket.opacity(colorScheme == .dark ? 0.16 : 0.3))
                .frame(width: 280, height: 280)
                .blur(radius: 18)
                .offset(x: -150, y: -220)
            RoundedRectangle(cornerRadius: 80)
                .fill(PomodoroughTheme.signal.opacity(colorScheme == .dark ? 0.14 : 0.2))
                .frame(width: 360, height: 150)
                .rotationEffect(.degrees(-14))
                .blur(radius: 20)
                .offset(x: 170, y: 260)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var backdropColors: [Color] {
        if colorScheme == .dark {
            [PomodoroughTheme.night, PomodoroughTheme.platformDeep, PomodoroughTheme.nightSurface]
        } else {
            [PomodoroughTheme.sky, PomodoroughTheme.mint.opacity(0.82), PomodoroughTheme.sky]
        }
    }
}

#if DEBUG
#Preview {
    TimerBackdrop()
}
#endif
