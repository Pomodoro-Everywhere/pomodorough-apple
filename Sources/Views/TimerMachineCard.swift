import SwiftUI

struct TimerMachineCard: View {
    let model: AppModel
    let layout: TimerLayout

    var body: some View {
        VStack(spacing: layout == .landscape ? 8 : 18) {
            #if os(macOS)
            if layout == .landscape {
                HStack(spacing: 18) {
                    dial(layout: .portrait)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 14) {
                        TimerTaskPicker(model: model, layout: layout)
                        TimerControls(model: model, layout: layout)
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                }
            } else {
                dial(layout: layout)
                TimerTaskPicker(model: model, layout: layout)
                TimerControls(model: model, layout: layout)
            }
            #else
            dial(layout: layout)
            TimerTaskPicker(model: model, layout: layout)
            TimerControls(model: model, layout: layout)
            #endif
        }
        .padding(layout == .landscape ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: layout == .landscape ? .infinity : nil)
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(PomodoroughTheme.platform.opacity(0.9))
                .shadow(color: PomodoroughTheme.signal.opacity(0.9), radius: 0, x: 7, y: 7)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func dial(layout: TimerLayout) -> some View {
        VStack(spacing: 8) {
            Group {
                if let timer = model.activeTimer {
                    TimerDial(timer: timer, model: model, layout: layout)
                } else {
                    IdleTimerDial(
                        phase: model.selectedPhase,
                        minutes: model.durationMinutes(for: model.selectedPhase),
                        layout: layout
                    )
                }
            }
            LongBreakProgressIndicator(progress: model.longBreakProgress)
        }
    }
}

#if DEBUG
#Preview {
    TimerMachineCard(model: AppModel.preview(.running), layout: .portrait)
        .padding()
        .background(TimerBackdrop())
}
#endif
