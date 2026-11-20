#if os(macOS)
import Foundation
import SwiftUI

/// The macOS window sections in the order of the toolbar picker. Each one
/// gets Command and its position as its shortcut (Command-1 is Timer).
enum MacOSSectionCommands {
    static let sections: [MainTab] = [.timer, .tasks, .pattern, .history, .network]

    /// The section that Settings (Command-comma) opens: Pattern holds the
    /// timer settings, so the app has no separate Settings window.
    static let settingsSection = MainTab.pattern
    static let settingsShortcut = KeyboardShortcut(",", modifiers: .command)
    static var settingsTitle: String { String(localized: "Settings…") }

    static func shortcut(for section: MainTab) -> KeyboardShortcut? {
        guard let index = sections.firstIndex(of: section) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }
}

/// Section names shared by the window title and the section menu.
enum MacOSSectionTitle {
    static func title(for section: MainTab) -> String {
        switch section {
        case .timer: String(localized: "Timer")
        case .tasks: String(localized: "Tasks")
        case .history: String(localized: "Arrivals")
        case .network: String(localized: "Network")
        case .pattern: String(localized: "Pattern")
        }
    }
}

/// One item of the Timer menu.
enum TimerMenuAction: CaseIterable, Hashable, Sendable {
    case start
    case pause
    case resume
    case finish
    case cancel
    case skip
    case stopSound

    /// Start, Pause and Resume share one shortcut because they are one
    /// control. Cancel has none: it discards the session without asking,
    /// and Command-period is the chord that dismisses sheets and dialogs,
    /// so a menu shortcut there would cancel the timer by accident. Stop
    /// sound has none: Escape and Space belong to sheets and text fields,
    /// and the alert already offers its own button.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .start, .pause, .resume: KeyboardShortcut(.return, modifiers: .command)
        case .finish: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .skip: KeyboardShortcut("]", modifiers: .command)
        case .cancel, .stopSound: nil
        }
    }
}

/// What the timer looks like to the Timer menu.
struct TimerMenuState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case idle
        case running
        case paused
    }

    var status: Status
    var hasCompletionAlert: Bool
    /// False while the workspace refuses timer changes (restoring, blocked,
    /// permission introduction); the menu bar extra uses the same rule.
    var acceptsCommands: Bool
}

extension TimerMenuState.Status {
    /// Reads the canonical timer's status as the Timer screen does: only a
    /// running or paused timer is active. Completed, cancelled, superseded
    /// or no timer leaves the menu idle. The switch names every case, so a
    /// new or renamed status does not compile until it is mapped here.
    init(_ canonicalStatus: CanonicalTimerStatus?) {
        switch canonicalStatus {
        case .running: self = .running
        case .paused: self = .paused
        case .completed, .cancelled, .superseded, nil: self = .idle
        }
    }
}

/// The phase names that the Start and Skip titles show.
struct TimerMenuPhaseTitles: Equatable, Sendable {
    var selectedPhase: String
    var skipDestination: String
}

struct TimerMenuEntry: Equatable, Sendable {
    let action: TimerMenuAction
    let isEnabled: Bool
}

/// The Timer menu mirrors the Timer screen controls: one primary control,
/// Finish and Cancel while a timer is active, Skip while idle, and Stop sound
/// while the completion alert plays. Every entry stays in the menu and is
/// disabled when the screen would not offer it, so the menu does not jump.
enum TimerMenuCatalog {
    static func entries(for state: TimerMenuState) -> [TimerMenuEntry] {
        let isActive = state.status != .idle
        let accepts = state.acceptsCommands
        return [
            TimerMenuEntry(action: primaryAction(for: state.status), isEnabled: accepts),
            TimerMenuEntry(action: .finish, isEnabled: accepts && isActive),
            TimerMenuEntry(action: .cancel, isEnabled: accepts && isActive),
            TimerMenuEntry(action: .skip, isEnabled: accepts && !isActive && !state.hasCompletionAlert),
            TimerMenuEntry(action: .stopSound, isEnabled: accepts && state.hasCompletionAlert),
        ]
    }

    static func primaryAction(for status: TimerMenuState.Status) -> TimerMenuAction {
        switch status {
        case .idle: .start
        case .running: .pause
        case .paused: .resume
        }
    }

    /// The Timer screen's own control titles, so the menu and the screen
    /// share their localization keys.
    static func title(for action: TimerMenuAction, phases: TimerMenuPhaseTitles) -> String {
        switch action {
        case .start: String(localized: "Start \(phases.selectedPhase.lowercased())")
        case .pause: String(localized: "Pause timer")
        case .resume: String(localized: "Resume timer")
        case .finish: String(localized: "Finish timer")
        case .cancel: String(localized: "Cancel timer")
        case .skip: String(localized: "Skip to \(phases.skipDestination)")
        case .stopSound: String(localized: "Stop sound")
        }
    }

    @MainActor
    static func perform(_ action: TimerMenuAction, on target: some TimerMenuTarget) {
        switch action {
        case .start: _ = target.start()
        case .pause: _ = target.pause(at: nil)
        case .resume: _ = target.resume(at: nil)
        case .finish: _ = target.finish(at: nil)
        case .cancel: target.cancel(at: nil)
        case .skip: _ = target.skipSelectedPhase()
        case .stopSound: target.stopSound()
        }
    }
}

/// The timer operations the Timer menu calls. AppModel is the production
/// target; the command tests replace it with a recording fake because the
/// macOS tests must not start an app host.
@MainActor
protocol TimerMenuTarget: AnyObject {
    func start() -> Bool
    func pause(at explicitDate: Date?) -> Bool
    func resume(at explicitDate: Date?) -> Bool
    func finish(at explicitDate: Date?) -> Bool
    func cancel(at explicitDate: Date?)
    func skipSelectedPhase() -> Bool
    func stopSound()
}
#endif
