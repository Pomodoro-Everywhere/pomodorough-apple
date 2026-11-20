import Foundation
import Testing

/// MAC-01: the values that MacOSAppCommands hands to its menu items. The
/// hostless bundle cannot render the menus, so these tests pin every input
/// of the item views: the timer status, the titles and the enabled rules.
struct TimerMenuStatusMappingTests {
    @Test func runningAndPausedTimersAreActive() {
        #expect(TimerMenuState.Status(.running) == .running)
        #expect(TimerMenuState.Status(.paused) == .paused)
    }

    /// The Timer screen treats a finished or replaced timer as no timer.
    @Test(arguments: [nil, .completed, .cancelled, .superseded] as [CanonicalTimerStatus?])
    func endedOrMissingTimersLeaveTheMenuIdle(canonicalStatus: CanonicalTimerStatus?) {
        #expect(TimerMenuState.Status(canonicalStatus) == .idle)
    }

    @Test func mappedStatusPicksThePrimaryControl() {
        let primary = [CanonicalTimerStatus.running, .paused, .completed].map {
            TimerMenuCatalog.primaryAction(for: TimerMenuState.Status($0))
        }
        #expect(primary == [.pause, .resume, .start])
    }
}

struct TimerMenuTitleTests {
    private let phases = TimerMenuPhaseTitles(selectedPhase: "Short break", skipDestination: "Long break")

    @Test func startNamesTheSelectedPhaseInLowercase() {
        #expect(TimerMenuCatalog.title(for: .start, phases: phases) == "Start short break")
    }

    @Test func skipNamesTheNextPhase() {
        #expect(TimerMenuCatalog.title(for: .skip, phases: phases) == "Skip to Long break")
    }

    @Test func otherActionsUseTheTimerScreenTitles() {
        let titles = [TimerMenuAction.pause, .resume, .finish, .cancel, .stopSound]
            .map { TimerMenuCatalog.title(for: $0, phases: phases) }
        #expect(titles == ["Pause timer", "Resume timer", "Finish timer", "Cancel timer", "Stop sound"])
    }
}

struct MacOSSectionTitleTests {
    @Test func sectionsUseTheToolbarNames() {
        let titles = MacOSSectionCommands.sections.map(MacOSSectionTitle.title(for:))
        #expect(titles == ["Timer", "Tasks", "Pattern", "Arrivals", "Network"])
    }

    @Test func settingsKeepsTheStandardTitle() {
        #expect(MacOSSectionCommands.settingsTitle == "Settings…")
    }
}

struct MacOSSectionNavigationGateTests {
    @Test func readyWorkspaceAllowsSectionCommands() {
        #expect(MacOSSectionNavigationGate.ready.allowsSectionCommands)
    }

    /// The permission introduction replaces the section view, so no window
    /// publishes a destination; an enabled command would open one more
    /// introduction window for every keystroke.
    @Test(arguments: [
        \MacOSSectionNavigationGate.isRestoring,
        \.hasSnapshotLoadFailure,
        \.needsPermissionIntroduction,
        \.isHistoryResolutionBlocking,
    ])
    func eachBlockingStateDisablesSectionCommands(state: WritableKeyPath<MacOSSectionNavigationGate, Bool> & Sendable) {
        var gate = MacOSSectionNavigationGate.ready
        gate[keyPath: state] = true
        #expect(!gate.allowsSectionCommands)
    }
}

extension MacOSSectionNavigationGate {
    static let ready = MacOSSectionNavigationGate(
        isRestoring: false,
        hasSnapshotLoadFailure: false,
        needsPermissionIntroduction: false,
        isHistoryResolutionBlocking: false
    )
}
