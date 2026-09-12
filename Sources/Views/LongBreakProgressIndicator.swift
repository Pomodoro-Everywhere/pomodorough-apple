import SwiftUI

struct LongBreakProgressIndicator: View {
    let progress: Int
    let completedToday: Int

    init(progress: Int, completedToday: Int) {
        self.progress = progress
        self.completedToday = completedToday
    }

    init(completedToday: Int) {
        self.init(progress: completedToday == 0 ? 0 : ((completedToday - 1) % 4) + 1, completedToday: completedToday)
    }

    var body: some View {
        Text(String(repeating: "●", count: progress) + String(repeating: "○", count: 4 - progress))
        .font(.caption.monospaced().bold())
        .foregroundStyle(PomodoroughTheme.ticket)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pomodoro progress")
        .accessibilityValue(String(localized: "\(progress) of 4 toward the next long break, \(completedToday) completed today"))
    }
}

struct TimerReadoutHeader: View {
    let phase: TimerPhase
    let status: String
    let completedFocusCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(phase.title.uppercased())
                .foregroundStyle(PomodoroughTheme.signal)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.uppercased())
                .foregroundStyle(PomodoroughTheme.sky)
                .frame(maxWidth: .infinity)
            LongBreakProgressIndicator(completedToday: completedFocusCount)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption2.monospaced().bold())
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

#if DEBUG
#Preview {
    LongBreakProgressIndicator(progress: 3, completedToday: 7)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
