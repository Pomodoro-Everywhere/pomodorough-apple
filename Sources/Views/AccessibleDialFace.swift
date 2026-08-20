import SwiftUI

struct AccessibleDialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phase.title)
                .font(.title2.bold())
                .foregroundStyle(PomodoroughTheme.signal)
            Text(timeText)
                .font(.system(size: 56, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(PomodoroughTheme.ticket)
            Text(status)
                .font(.headline)
            ProgressView(value: max(0, min(1, progress)))
                .tint(PomodoroughTheme.danger)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .digitalReadoutPanel(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.porcelain.opacity(0.8), lineWidth: 2)
        }
        .accessibilityRepresentation {
            TimerAccessibilityElement(phase: phase, status: status, timeText: timeText)
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
