import SwiftUI

struct TimerBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Glow diameter follows the smaller container dimension so the wash
    /// covers phones and wide windows alike instead of banding past a
    /// fixed 280pt circle.
    static func glowDiameter(for size: CGSize) -> CGFloat {
        max(0, min(size.width, size.height) * 0.7)
    }

    /// Glow center stays at the same relative corner at any size,
    /// matching the shipped -150/-220 on a 390x844 canvas.
    static func glowOffset(for size: CGSize) -> CGSize {
        CGSize(width: -size.width * 0.38, height: -size.height * 0.26)
    }

    /// Signal band spans nearly the full width with a height floor, so
    /// wide windows get a repeating wash instead of a fixed 360x150 bar.
    static func bandSize(for size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width * 0.92), height: max(120, size.height * 0.18))
    }

    /// Band center stays at the same relative corner at any size,
    /// matching the shipped 170/260 on a 390x844 canvas.
    static func bandOffset(for size: CGSize) -> CGSize {
        CGSize(width: size.width * 0.44, height: size.height * 0.31)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: backdropColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
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
        Circle()
            .fill(PomodoroughTheme.ticket.opacity(colorScheme == .dark ? 0.16 : 0.3))
            .frame(width: Self.glowDiameter(for: size), height: Self.glowDiameter(for: size))
            .blur(radius: 18)
            .offset(Self.glowOffset(for: size))
    }

    private func band(in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 80)
            .fill(PomodoroughTheme.signal.opacity(colorScheme == .dark ? 0.14 : 0.2))
            .frame(width: Self.bandSize(for: size).width, height: Self.bandSize(for: size).height)
            .rotationEffect(.degrees(-14))
            .blur(radius: 20)
            .offset(Self.bandOffset(for: size))
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
