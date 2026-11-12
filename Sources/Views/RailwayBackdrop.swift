import SwiftUI

/// Always-navy station wall behind setup and resolution flows. It reuses
/// the timer backdrop's glow and band geometry so full-screen surfaces
/// read as the same place as the timer, whatever the OS appearance.
struct RailwayBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [PomodoroughTheme.platformDeep, PomodoroughTheme.platform],
                    startPoint: .top,
                    endPoint: .bottom
                )
                glow(in: proxy.size)
                band(in: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func glow(in size: CGSize) -> some View {
        let diameter = TimerBackdrop.glowDiameter(for: size)
        return Circle()
            .fill(PomodoroughTheme.ticket.opacity(0.18))
            .frame(width: diameter, height: diameter)
            .blur(radius: 18)
            .offset(TimerBackdrop.glowOffset(for: size))
    }

    private func band(in size: CGSize) -> some View {
        let bandSize = TimerBackdrop.bandSize(for: size)
        return RoundedRectangle(cornerRadius: 80)
            .fill(PomodoroughTheme.signal.opacity(0.16))
            .frame(width: bandSize.width, height: bandSize.height)
            .rotationEffect(.degrees(-14))
            .blur(radius: 20)
            .offset(TimerBackdrop.bandOffset(for: size))
    }
}

#if DEBUG
#Preview {
    RailwayBackdrop()
}
#endif
