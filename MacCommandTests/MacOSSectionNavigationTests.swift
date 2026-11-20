import AppKit
import SwiftUI
import Testing

/// MAC-01: Settings and the section commands act on the focused window, and
/// without one they open the main window first and then select the section.
@MainActor
struct MacOSSectionNavigationTests {
    @Test func withoutAFocusedWindowTheCommandOpensTheMainWindowFirst() {
        let requests = MacOSSectionRequests()
        var pendingWhenOpened: [MainTab?] = []
        MacOSSectionNavigator.select(
            MacOSSectionCommands.settingsSection,
            focusedWindow: nil,
            requests: requests,
            openMainWindow: { pendingWhenOpened.append(requests.pendingSection) }
        )
        // The request exists before the open call, because SwiftUI may
        // create the window and its view while openWindow runs.
        #expect(pendingWhenOpened == [.pattern])
    }

    @Test func theOpenedWindowShowsTheRequestedSection() {
        let requests = MacOSSectionRequests()
        MacOSSectionNavigator.select(.history, focusedWindow: nil, requests: requests, openMainWindow: {})
        let opened = MacOSDestinationState()
        opened.adoptRequestedSection(from: requests)
        #expect(opened.selectedTab == .history)
        #expect(requests.pendingSection == nil)
    }

    @Test func onlyTheFirstOpenedWindowTakesTheRequest() {
        let requests = MacOSSectionRequests()
        MacOSSectionNavigator.select(.network, focusedWindow: nil, requests: requests, openMainWindow: {})
        let first = MacOSDestinationState()
        let second = MacOSDestinationState()
        first.adoptRequestedSection(from: requests)
        second.adoptRequestedSection(from: requests)
        #expect(first.selectedTab == .network)
        #expect(second.selectedTab == .timer)
    }

    @Test func aWindowOpenedWithoutARequestKeepsItsSection() {
        let window = MacOSDestinationState()
        window.selectedTab = .tasks
        window.adoptRequestedSection(from: MacOSSectionRequests())
        #expect(window.selectedTab == .tasks)
    }
}

/// MAC-01: the hand-over that MainContainer installs. The section view takes
/// the pending request when SwiftUI shows it. The window is never ordered on
/// screen; hosting the view is enough for SwiftUI to run onAppear.
@MainActor
struct MacOSSectionRequestAdoptionTests {
    @Test func theSectionViewTakesTheRequestWhenItAppears() async {
        let requests = MacOSSectionRequests()
        requests.request(.history)
        let destination = MacOSDestinationState()
        let window = OffscreenSectionWindow(destination: destination, requests: requests)
        await window.waitUntilAppeared()
        #expect(destination.selectedTab == .history)
        #expect(requests.pendingSection == nil)
    }

    @Test func aSectionViewWithoutTheRequestStoreKeepsItsSection() async {
        let destination = MacOSDestinationState()
        destination.selectedTab = .tasks
        let window = OffscreenSectionWindow(destination: destination, requests: nil)
        await window.waitUntilAppeared()
        #expect(destination.selectedTab == .tasks)
    }
}

/// Hosts a stand-in section view with the adoption modifier in a window that
/// is never shown, and reports when SwiftUI has run its onAppear.
@MainActor
private final class OffscreenSectionWindow {
    private let window: NSWindow
    private let appearance = AppearanceProbe()

    init(destination: MacOSDestinationState, requests: MacOSSectionRequests?) {
        let probe = appearance
        let section = Color.clear
            .adoptsRequestedSection(into: destination)
            .onAppear { probe.hasAppeared = true }
        let root = requests.map { AnyView(section.environment($0)) } ?? AnyView(section)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
    }

    /// Runs the main loop until onAppear has run, for at most two seconds.
    func waitUntilAppeared() async {
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<200 where !appearance.hasAppeared {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(appearance.hasAppeared, "SwiftUI never showed the section view")
        window.close()
    }
}

@MainActor
private final class AppearanceProbe {
    var hasAppeared = false
}
