import SwiftUI

struct TimerAccessibilityElement: View {
    let phase: TimerPhase
    let status: String
    let timeText: String

    var body: some View {
        Text("\(phase.title) timer")
            .accessibilityValue("\(timeText) remaining, \(status)")
    }
}

#if DEBUG
#Preview {
    TimerAccessibilityElement(phase: .focus, status: "Running", timeText: "17:00")
        .padding()
}
#endif
