#if os(macOS)
import SwiftUI

/// The focused window's section state, published by MainContainer so the
/// menu commands act on the window in front.
struct MacOSDestinationFocusKey: FocusedValueKey {
    typealias Value = MacOSDestinationState
}

extension FocusedValues {
    var macOSDestination: MacOSDestinationState? {
        get { self[MacOSDestinationFocusKey.self] }
        set { self[MacOSDestinationFocusKey.self] = newValue }
    }
}

extension AppModel: TimerMenuTarget {}

/// MAC-01: menu commands and keyboard shortcuts for the timer, the window
/// sections and Settings (Pattern).
struct MacOSAppCommands: Commands {
    let model: AppModel
    let sectionRequests: MacOSSectionRequests
    @FocusedValue(\.macOSDestination) private var destination

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            MacOSSectionCommand(
                title: MacOSSectionCommands.settingsTitle,
                section: MacOSSectionCommands.settingsSection,
                shortcut: MacOSSectionCommands.settingsShortcut,
                target: sectionTarget
            )
        }
        CommandMenu("Timer") {
            TimerMenuCommands(model: model)
        }
        CommandGroup(before: .toolbar) {
            ForEach(MacOSSectionCommands.sections, id: \.self) { section in
                MacOSSectionCommand(
                    title: MacOSSectionTitle.title(for: section),
                    section: section,
                    shortcut: MacOSSectionCommands.shortcut(for: section),
                    target: sectionTarget
                )
            }
            Divider()
        }
    }

    private var sectionTarget: MacOSSectionCommandTarget {
        MacOSSectionCommandTarget(
            focusedWindow: destination,
            requests: sectionRequests,
            gate: model.sectionNavigationGate
        )
    }
}

/// Where Settings and the section commands act: the focused window, or a
/// main window that the command opens first.
private struct MacOSSectionCommandTarget {
    let focusedWindow: MacOSDestinationState?
    let requests: MacOSSectionRequests
    let gate: MacOSSectionNavigationGate
}

private struct MacOSSectionCommand: View {
    let title: String
    let section: MainTab
    let shortcut: KeyboardShortcut?
    let target: MacOSSectionCommandTarget
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            MacOSSectionNavigator.select(
                section,
                focusedWindow: target.focusedWindow,
                requests: target.requests,
                openMainWindow: { openWindow(id: "main") }
            )
        }
        .keyboardShortcut(shortcut)
        .disabled(!target.gate.allowsSectionCommands)
    }
}

private struct TimerMenuCommands: View {
    let model: AppModel

    var body: some View {
        ForEach(TimerMenuCatalog.entries(for: state), id: \.action) { entry in
            Button(TimerMenuCatalog.title(for: entry.action, phases: phaseTitles)) {
                TimerMenuCatalog.perform(entry.action, on: model)
            }
            .keyboardShortcut(entry.action.shortcut)
            .disabled(!entry.isEnabled)
        }
    }

    private var state: TimerMenuState {
        TimerMenuState(
            status: TimerMenuState.Status(model.canonicalTimer?.status),
            hasCompletionAlert: model.hasActiveCompletionAlert,
            acceptsCommands: model.acceptsTimerMenuCommands
        )
    }

    private var phaseTitles: TimerMenuPhaseTitles {
        TimerMenuPhaseTitles(
            selectedPhase: model.selectedPhase.title,
            skipDestination: model.skipDestination.title
        )
    }
}

extension AppModel {
    /// The menu bar extra and the Timer menu refuse timer changes in the
    /// same states, while the workspace cannot take them.
    var acceptsTimerMenuCommands: Bool {
        sessionState != .restoring && !isWorkspaceMutationBlocked && !needsPermissionIntroduction
    }

    var sectionNavigationGate: MacOSSectionNavigationGate {
        MacOSSectionNavigationGate(
            isRestoring: sessionState == .restoring,
            hasSnapshotLoadFailure: snapshotLoadFailure != nil,
            needsPermissionIntroduction: needsPermissionIntroduction,
            isHistoryResolutionBlocking: isHistoryResolutionBlocking
        )
    }
}
#endif
