import Foundation
import SwiftUI

struct IdleTimerDial: View {
    let phase: TimerPhase
    let minutes: Int
    let layout: TimerLayout

    var body: some View {
        DialFace(
            progress: 0,
            phase: phase,
            status: "Idle",
            timeText: String(format: "%02d:00", minutes),
            layout: layout
        )
    }
}

#if DEBUG
#Preview {
    IdleTimerDial(phase: .focus, minutes: 25, layout: .portrait)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
