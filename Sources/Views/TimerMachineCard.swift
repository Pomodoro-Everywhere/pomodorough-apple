import SwiftUI

struct TimerMachineCard: View {
    let model: AppModel
    let layout: TimerLayout
    var usesCompactDial = false
    /// Fixed content height for the iOS landscape card, measured by the
    /// parent from available geometry. GeometryReader dials need a bounded
    /// height; inside a vertical ScrollView they collapse to zero.
    var landscapeHeight: CGFloat? = nil

    var body: some View {
        Group {
            #if os(macOS)
            VStack(spacing: layout == .landscape ? 8 : 18) {
                if layout == .landscape {
                    GeometryReader { geometry in
                        // Leave room for the controls and the progress indicator below the dial.
                        let diameter = max(0, min(geometry.size.width - 288, geometry.size.height - 48))
                        HStack(spacing: 28) {
                            dial(layout: .portrait)
                                .frame(width: diameter)
                            VStack(spacing: 14) {
                                TimerTaskPicker(model: model, layout: layout)
                                TimerControls(model: model, layout: layout)
                            }
                            .frame(width: 260)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    dial(layout: layout)
                    TimerTaskPicker(model: model, layout: layout)
                    TimerControls(model: model, layout: layout)
                }
            }
            .padding(24)
            #else
            if layout == .landscape {
                HStack(spacing: 14) {
                    dial(layout: .landscape)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        TimerTaskPicker(model: model, layout: layout)
                        TimerControls(model: model, layout: layout)
                    }
                    .frame(width: 280)
                }
                .frame(height: landscapeHeight)
                .padding(14)
            } else {
                VStack(spacing: usesCompactDial ? 12 : 14) {
                    dial(layout: layout)
                    TimerTaskPicker(model: model, layout: layout)
                    TimerControls(model: model, layout: layout)
                }
                .padding(usesCompactDial ? 14 : 16)
            }
            #endif
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(maxWidth: .infinity, maxHeight: layout == .landscape ? .infinity : nil)
        #endif
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
                    TimerDial(timer: timer, model: model, layout: usesCompactDial ? .landscape : layout)
                } else {
                    IdleTimerDial(
                        phase: model.selectedPhase,
                        minutes: model.durationMinutes(for: model.selectedPhase),
                        layout: usesCompactDial ? .landscape : layout
                    )
                }
            }
            .frame(height: usesCompactDial ? 120 : nil)
            LongBreakProgressIndicator(progress: model.longBreakProgress, completedToday: model.completedFocusCountToday)
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
