#if os(macOS)
import Observation

/// The section and per-section drafts of one macOS window. The window owns
/// it; menu commands reach it through the focused scene value.
@MainActor
@Observable
final class MacOSDestinationState {
    var selectedTab = MainTab.timer
    var taskDraft = ""
    var networkRoomName = ""
    var isCreatingRoom = false
    var showsCompletedFocusBreakdown = false

    /// Takes the section a menu command asked for before this window existed.
    func adoptRequestedSection(from requests: MacOSSectionRequests) {
        guard let section = requests.claimPendingSection() else { return }
        selectedTab = section
    }
}
#endif
