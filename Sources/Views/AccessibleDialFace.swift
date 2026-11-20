import SwiftUI

struct AccessibleDialFace: View {
    static let progressIdentifier = "timer-dial-progress"

    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String
    var completedFocusCount = 0

    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 56

    var body: some View {
        dialContent
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .digitalReadoutPanel(cornerRadius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(PomodoroughTheme.porcelain.opacity(0.8), lineWidth: 2)
            }
    }

    private var dialContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout
            LongBreakProgressIndicator(completedToday: completedFocusCount)
            // The timer element already reads the remaining time, so the
            // bar stays out of VoiceOver except for the UITest probe.
            ProgressView(value: max(0, min(1, progress)))
                .tint(PomodoroughTheme.accent(for: phase))
                .accessibilityIdentifier(Self.progressIdentifier)
                .accessibilityHidden(!TimerAccessibilityElement.showsDigitProbe)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phase.title)
                .font(.title2.bold())
                .foregroundStyle(PomodoroughTheme.accent(for: phase))
            Text(timeText)
                .font(.system(size: countdownSize, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(PomodoroughTheme.ticket)
                .accessibilityIdentifier("AP08-countdown-digits")
            Text(status)
                .font(.headline)
        }
        .timerAccessibilityElement(phase: phase, status: status, timeText: timeText)
    }
}

#if DEBUG
#Preview {
    AccessibleDialFace(progress: 0.42, phase: .focus, status: "Running", timeText: "17:00")
        .padding()
        .background(PomodoroughTheme.platform)
        .environment(\.dynamicTypeSize, .accessibility1)
}
#endif
