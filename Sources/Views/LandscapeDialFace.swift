import SwiftUI

struct LandscapeDialFace: View {
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String
    var completedFocusCount = 0

    var body: some View {
        GeometryReader { geometry in
            readout(size: geometry.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .digitalReadoutPanel(cornerRadius: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(PomodoroughTheme.porcelain.opacity(0.55), lineWidth: 1.5)
            GeometryReader { geometry in
                let inset = min(geometry.size.width, geometry.size.height) * 0.04
                RoundedRectangle(cornerRadius: max(0, 24 - inset))
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(
                        PomodoroughTheme.accent(for: phase), style: StrokeStyle(lineWidth: min(12, inset), lineCap: .butt)
                    )
                    .padding(inset)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityRepresentation {
            TimerAccessibilityElement(phase: phase, status: status, timeText: timeText)
            LongBreakProgressIndicator(completedToday: completedFocusCount)
        }
    }

    private func readout(size: CGSize) -> some View {
        let labelSize = max(captionSize, Self.digitSize(for: size) * 0.075)
        let labelFont = Font.system(size: labelSize, weight: .bold, design: .monospaced)
        return VStack(spacing: labelSize * 0.35) {
            Spacer(minLength: 0)
            Text(phase.title.localizedUppercase)
                .font(labelFont)
                .foregroundStyle(PomodoroughTheme.accent(for: phase))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(timeText)
                .font(
                    .system(
                        size: Self.digitSize(for: size),
                        weight: .black,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .foregroundStyle(PomodoroughTheme.ticket)
            HStack(spacing: labelSize * 0.75) {
                Text(status.localizedUppercase)
                    .font(labelFont)
                    .foregroundStyle(PomodoroughTheme.sky)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                LongBreakProgressIndicator(completedToday: completedFocusCount, font: labelFont)
            }

            Spacer(minLength: 0)
        }
        .padding(min(size.width, size.height) * 0.08)
        .frame(width: size.width, height: size.height)
    }

    /// Digits fill the face from either dimension: tall faces are capped
    /// by width (five glyphs at ~0.65em advance), wide faces by height.
    static func digitSize(for size: CGSize) -> CGFloat {
        min(size.height * 0.5, size.width / 3.3)
    }
}

#if DEBUG
#Preview {
    LandscapeDialFace(progress: 0.42, phase: .focus, status: "Running", timeText: "17:00")
        .frame(width: 700, height: 300)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
