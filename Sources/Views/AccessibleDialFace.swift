import SwiftUI

struct AccessibleDialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String
    var completedFocusCount = 0

    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 56

    /// UITest probe flag. Production never sets POMODOROUGH_UI_TEST_DIAL,
    /// so VoiceOver keeps the single substitute element with identical
    /// visuals. Probe runs skip the representation so XCTest can measure
    /// the actual rendered countdown instead of the substitute.
    private var showsDigitProbe: Bool {
        ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_DIAL"] == "1"
    }

    @ViewBuilder
    var body: some View {
        if showsDigitProbe {
            dialShell
        } else {
            dialShell
                .accessibilityRepresentation {
                    TimerAccessibilityElement(phase: phase, status: status, timeText: timeText)
                    LongBreakProgressIndicator(completedToday: completedFocusCount)
                }
        }
    }

    private var dialShell: some View {
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
            LongBreakProgressIndicator(completedToday: completedFocusCount)
            ProgressView(value: max(0, min(1, progress)))
                .tint(PomodoroughTheme.accent(for: phase))
        }
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
