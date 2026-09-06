#if os(macOS)
import AppKit
import Combine
import SwiftUI

enum MenuBarTimerDisplay: String, CaseIterable, Identifiable {
    case current, total, both

    static let defaultsKey = "menuBarTimerDisplay"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: String(localized: "Current timer")
        case .total: String(localized: "Total Pomodoro time")
        case .both: String(localized: "Both")
        }
    }

    func text(current: String, total: String) -> String {
        switch self {
        case .current: current
        case .total: "Σ \(total)"
        case .both: "\(current) · Σ \(total)"
        }
    }
}

struct MenuBarTimerStatus {
    let phase: TimerPhase
    let status: CanonicalTimer.Status?
    let remaining: TimeInterval
    let total: TimeInterval

    var symbol: String {
        if status == .paused { return "pause.circle" }
        if status == .completed { return "checkmark.circle" }
        return phase == .focus ? "timer" : "cup.and.saucer"
    }

    var currentText: String { Self.clock(remaining, roundingUp: true) }
    var totalText: String { Self.clock(total, roundingUp: false) }

    static func clock(_ interval: TimeInterval, roundingUp: Bool) -> String {
        let seconds = Int(max(0, interval).rounded(roundingUp ? .up : .down))
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }
}

@MainActor
final class MenuBarTimerClock: ObservableObject {
    @Published private(set) var date = Date.now
    private var subscription: AnyCancellable?

    init() {
        subscription = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] in self?.date = $0 }
    }
}

struct MenuBarTimerLabel: View {
    let model: AppModel
    let date: Date
    let display: MenuBarTimerDisplay

    var body: some View {
        let timer = model.activeTimer
        let status = MenuBarTimerStatus(
            phase: timer?.phase ?? model.selectedPhase,
            status: timer?.status,
            remaining: timer.map(model.remainingForDisplay)
                ?? Double(model.durationMinutes(for: model.selectedPhase) * 60),
            total: Double(model.dayFocusTotals(for: date).timeSpentMs) / 1000
                + (timer?.phase == .focus ? timer.map(model.elapsedForDisplay) ?? 0 : 0)
        )
        HStack {
            Image(systemName: status.symbol)
            Text(display.text(current: status.currentText, total: status.totalText))
                .monospacedDigit()
        }
    }
}

struct MenuBarTimerPicker: View {
    @AppStorage(MenuBarTimerDisplay.defaultsKey) private var display = MenuBarTimerDisplay.current

    var body: some View {
        Picker("Menu bar display", selection: $display) {
            ForEach(MenuBarTimerDisplay.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }
}

struct MenuBarTimerMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.activeTimer?.phase.title ?? model.selectedPhase.title)
        if let timer = model.activeTimer,
           let task = model.task(forTimerID: timer.id) {
            Text(verbatim: task.title)
        }
        Group {
            if model.canonicalTimer?.status == .running {
                Button("Pause timer", systemImage: "pause.fill") { model.pause() }
            } else if model.canonicalTimer?.status == .paused {
                Button("Resume timer", systemImage: "play.fill") { model.resume() }
            } else {
                Button("Start \(model.selectedPhase.title.lowercased())", systemImage: "play.fill", action: model.start)
            }
            if model.hasActiveCompletionAlert {
                Button("Stop sound", systemImage: "speaker.slash", action: model.stopSound)
            }
        }
        .disabled(model.sessionState == .restoring || model.isWorkspaceMutationBlocked || model.needsPermissionIntroduction)
        Divider()
        MenuBarTimerPicker()
        Text("Total includes today’s completed Pomodoros and the current focus session.")
        Divider()
        Button("Open Pomodorough") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Pomodorough") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
#endif
