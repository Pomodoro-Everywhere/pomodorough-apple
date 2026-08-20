import SwiftUI

struct LongBreakProgressIndicator: View {
    let progress: Int

    var body: some View {
        Text(String(repeating: "●", count: progress) + String(repeating: "○", count: 4 - progress))
        .font(.caption.monospaced().bold())
        .foregroundStyle(PomodoroughTheme.ticket)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(PomodoroughTheme.track.opacity(0.58), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pomodoro progress")
        .accessibilityValue("\(progress) of 4 pomodoros today")
    }
}

#if DEBUG
#Preview {
    LongBreakProgressIndicator(progress: 3)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
