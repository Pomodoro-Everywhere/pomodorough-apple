import SwiftUI

struct PortraitDialFace: View {
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String
    /// Minutes of the displayed timer; drives the tick count.
    var minutes: Int = 60
    var completedFocusCount = 0

    var body: some View {
        GeometryReader { geometry in
            face(diameter: geometry.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func face(diameter: CGFloat) -> some View {
        let labelSize = max(captionSize, diameter * 0.035)
        let labelFont = Font.system(size: labelSize, weight: .bold, design: .monospaced)
        return ZStack {
            Circle().fill(PomodoroughTheme.sky)
            Circle().stroke(PomodoroughTheme.porcelain, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(PomodoroughTheme.danger, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .padding(16)
            TickMarks(count: minutes).stroke(PomodoroughTheme.track, lineWidth: 1)
            VStack(spacing: labelSize * 0.35) {
                Text(phase.title.localizedUppercase)
                    .font(labelFont)
                    .foregroundStyle(PomodoroughTheme.signalText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                VStack {
                    Text(timeText)
                        .font(.system(size: diameter * 0.27, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.48)
                        .lineLimit(1)
                        .foregroundStyle(PomodoroughTheme.ticket)
                }
                .padding(diameter * 0.04)
                .frame(width: diameter * 0.8, height: diameter * 0.42)
                .digitalReadoutPanel(cornerRadius: 18)
                .overlay { RoundedRectangle(cornerRadius: 18).stroke(PomodoroughTheme.porcelain.opacity(0.8), lineWidth: 2) }
                Text(status.localizedUppercase)
                    .font(labelFont)
                    .foregroundStyle(PomodoroughTheme.platform)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                LongBreakProgressIndicator(completedToday: completedFocusCount, color: PomodoroughTheme.platform, font: labelFont)
            }
            .frame(width: diameter * 0.84)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityRepresentation {
            TimerAccessibilityElement(phase: phase, status: status, timeText: timeText)
            LongBreakProgressIndicator(completedToday: completedFocusCount)
        }
    }
}

#if DEBUG
#Preview {
    PortraitDialFace(progress: 0.42, phase: .focus, status: "Running", timeText: "17:00")
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
