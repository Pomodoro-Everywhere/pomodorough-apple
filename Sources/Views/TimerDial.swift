import Foundation
import SwiftUI

struct TimerDial: View {
    let timer: CanonicalTimer
    let model: AppModel
    let layout: TimerLayout

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = model.elapsedForDisplay(timer)
            let remaining = model.remainingForDisplay(timer)
            let progress = timer.plannedDuration > 0 ? elapsed / timer.plannedDuration : 0
            DialFace(
                progress: progress,
                phase: timer.phase,
                status: timer.status.rawValue.capitalized,
                timeText: Self.timeText(remaining),
                layout: layout
            )
            .onChange(of: remaining <= 0, initial: true) {
                if remaining <= 0 { model.completeIfNeeded(timerID: timer.id) }
            }
        }
    }

    private static func timeText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(duration)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

#if DEBUG
#Preview {
    TimerDial(timer: PreviewFixtures.runningTimer, model: AppModel.preview(.running), layout: .portrait)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
