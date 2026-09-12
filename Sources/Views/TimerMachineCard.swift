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
        TimerMachineCardContent(
            model: model,
            layout: layout,
            usesCompactDial: usesCompactDial,
            landscapeHeight: landscapeHeight
        )
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

private struct TimerMachineCardContent: View {
    let model: AppModel
    let layout: TimerLayout
    var usesCompactDial = false
    var landscapeHeight: CGFloat? = nil

    var body: some View {
        Group {
            #if os(macOS)
            TimerMachineMacOSCard(model: model, layout: layout, usesCompactDial: usesCompactDial)
            #else
            if layout == .landscape {
                TimerMachineIOSLandscapeCard(
                    model: model,
                    layout: layout,
                    usesCompactDial: usesCompactDial,
                    landscapeHeight: landscapeHeight
                )
            } else {
                TimerMachineIOSPortraitCard(model: model, layout: layout, usesCompactDial: usesCompactDial)
            }
            #endif
        }
    }
}

private struct TimerMachineDialSection: View {
    let model: AppModel
    let layout: TimerLayout
    var usesCompactDial = false

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let timer = model.activeTimer {
                    TimerDial(timer: timer, model: model, layout: usesCompactDial ? .landscape : layout)
                } else {
                    IdleTimerDial(
                        phase: model.selectedPhase,
                        minutes: model.durationMinutes(for: model.selectedPhase),
                        layout: usesCompactDial ? .landscape : layout,
                        completedFocusCount: model.completedFocusCountToday
                    )
                }
            }
            .frame(height: usesCompactDial ? 120 : nil)
        }
    }
}

private struct TimerMachineMacOSCard: View {
    let model: AppModel
    let layout: TimerLayout
    var usesCompactDial = false

    var body: some View {
        VStack(spacing: layout == .landscape ? 8 : 18) {
            if layout == .landscape {
                GeometryReader { geometry in
                    let diameter = max(0, min(geometry.size.width - 288, geometry.size.height))
                    HStack(spacing: 28) {
                        TimerMachineDialSection(model: model, layout: .portrait, usesCompactDial: usesCompactDial)
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
                TimerMachineDialSection(model: model, layout: layout, usesCompactDial: usesCompactDial)
                TimerTaskPicker(model: model, layout: layout)
                TimerControls(model: model, layout: layout)
            }
        }
        .padding(24)
    }
}

private struct TimerMachineIOSLandscapeCard: View {
    let model: AppModel
    let layout: TimerLayout
    var usesCompactDial = false
    var landscapeHeight: CGFloat? = nil

    var body: some View {
        HStack(spacing: 14) {
            TimerMachineDialSection(model: model, layout: .landscape, usesCompactDial: usesCompactDial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                TimerTaskPicker(model: model, layout: layout)
                TimerControls(model: model, layout: layout)
            }
            .frame(width: 280)
        }
        .frame(height: landscapeHeight)
        .padding(14)
    }
}

private struct TimerMachineIOSPortraitCard: View {
    let model: AppModel
    let layout: TimerLayout
    var usesCompactDial = false

    var body: some View {
        VStack(spacing: usesCompactDial ? 8 : 14) {
            TimerMachineDialSection(model: model, layout: layout)
                .frame(width: usesCompactDial ? 270 : nil)
            TimerTaskPicker(model: model, layout: layout)
            TimerControls(model: model, layout: layout, compact: usesCompactDial)
        }
        .padding(usesCompactDial ? 14 : 16)
    }
}

#if DEBUG
#Preview {
    TimerMachineCard(model: AppModel.preview(.running), layout: .portrait)
        .padding()
        .background(TimerBackdrop())
}
#endif
