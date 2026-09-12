import SwiftUI

struct DialFace: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String
    let layout: TimerLayout
    /// Minutes of the displayed timer; drives the portrait tick count.
    var minutes: Int = 60

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            AccessibleDialFace(progress: progress, phase: phase, status: status, timeText: timeText)
        } else if layout == .landscape {
            LandscapeDialFace(progress: progress, phase: phase, status: status, timeText: timeText)
        } else {
            PortraitDialFace(progress: progress, phase: phase, status: status, timeText: timeText, minutes: minutes)
        }
    }
}

#if DEBUG
#Preview {
    DialFace(progress: 0.42, phase: .focus, status: "Running", timeText: "17:00", layout: .portrait)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
