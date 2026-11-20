#if os(macOS)
import Observation
import SwiftUI

/// A section picked from the menu while no main window was focused, for
/// example after the user closed the window and the app kept running in the
/// menu bar. The command opens a main window, and that window takes the
/// section when it appears.
@MainActor
@Observable
final class MacOSSectionRequests {
    private(set) var pendingSection: MainTab?

    func request(_ section: MainTab) {
        pendingSection = section
    }

    /// Hands the pending section to one window only, so a second window
    /// opened later starts on its own default section.
    func claimPendingSection() -> MainTab? {
        defer { pendingSection = nil }
        return pendingSection
    }
}

/// Settings and the section commands act on the focused window. Without one
/// they record the section first and then open the main window, so the new
/// window finds the request even when it appears during the open call.
@MainActor
enum MacOSSectionNavigator {
    static func select(
        _ section: MainTab,
        focusedWindow: MacOSDestinationState?,
        requests: MacOSSectionRequests,
        openMainWindow: () -> Void
    ) {
        if let focusedWindow {
            focusedWindow.selectedTab = section
            return
        }
        requests.request(section)
        openMainWindow()
    }
}

/// The app states in which no window can show a section: the workspace is
/// restoring, its snapshot failed to load, the first-launch permission
/// introduction is showing, or history resolution covers the window. A
/// focused window cannot be in the first three states, because only the
/// section view publishes itself to the menu commands; without the gate a
/// command would open one more window for every keystroke.
struct MacOSSectionNavigationGate: Equatable, Sendable {
    var isRestoring: Bool
    var hasSnapshotLoadFailure: Bool
    var needsPermissionIntroduction: Bool
    var isHistoryResolutionBlocking: Bool

    var allowsSectionCommands: Bool {
        !isRestoring && !hasSnapshotLoadFailure && !needsPermissionIntroduction
            && !isHistoryResolutionBlocking
    }
}

/// Hands a section that a menu command requested before this window existed
/// to the window's state when its section view appears.
struct MacOSSectionRequestAdoption: ViewModifier {
    @Environment(MacOSSectionRequests.self) private var requests: MacOSSectionRequests?
    let destination: MacOSDestinationState

    func body(content: Content) -> some View {
        content.onAppear {
            guard let requests else { return }
            destination.adoptRequestedSection(from: requests)
        }
    }
}

extension View {
    func adoptsRequestedSection(into destination: MacOSDestinationState) -> some View {
        modifier(MacOSSectionRequestAdoption(destination: destination))
    }
}
#endif
