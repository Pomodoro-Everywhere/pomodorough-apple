import SwiftUI

struct LongBreakProgressIndicator: View {
    let progress: Int
    let completedToday: Int
    var color: Color = PomodoroughTheme.ticket
    var font: Font = .caption.monospaced().bold()

    init(progress: Int, completedToday: Int, color: Color = PomodoroughTheme.ticket) {
        self.progress = progress
        self.completedToday = completedToday
        self.color = color
    }

    init(completedToday: Int, color: Color = PomodoroughTheme.ticket, font: Font = .caption.monospaced().bold()) {
        self.init(progress: completedToday == 0 ? 0 : ((completedToday - 1) % 4) + 1, completedToday: completedToday, color: color)
        self.font = font
    }

    var body: some View {
        Text(String(repeating: "●", count: progress) + String(repeating: "○", count: 4 - progress))
        .font(font)
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Pomodoro progress"))
        .accessibilityValue(String(localized: "\(progress) of 4 toward the next long break, \(completedToday) completed today"))
    }
}

#if DEBUG
#Preview {
    LongBreakProgressIndicator(progress: 3, completedToday: 7)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
