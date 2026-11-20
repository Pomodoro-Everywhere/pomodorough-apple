import Foundation
import SwiftUI
import Testing

/// MAC-01 and MAC-02. These tests compile the command catalog directly and
/// run without an app host, because the hosted macOS tests read the real
/// profile and must not run on a developer Mac.
@MainActor
struct MacOSSectionCommandTests {
    @Test func sectionsFollowTheToolbarOrderAndIncludePattern() {
        #expect(MacOSSectionCommands.sections == [.timer, .tasks, .pattern, .history, .network])
    }

    @Test func sectionsUseCommandAndTheirPosition() {
        let expected: [(MainTab, Character)] = [
            (.timer, "1"), (.tasks, "2"), (.pattern, "3"), (.history, "4"), (.network, "5"),
        ]
        for (section, digit) in expected {
            let shortcut = MacOSSectionCommands.shortcut(for: section)
            #expect(shortcut?.key.character == digit, "\(section)")
            #expect(shortcut?.modifiers == .command, "\(section)")
        }
    }

    @Test func settingsOpensPatternWithCommandComma() {
        #expect(MacOSSectionCommands.settingsSection == .pattern)
        #expect(MacOSSectionCommands.settingsShortcut.key.character == ",")
        #expect(MacOSSectionCommands.settingsShortcut.modifiers == .command)
    }

    /// A command with a focused window selects the section there: it does
    /// not touch other windows, open a window or leave a request behind.
    @Test func selectingASectionChangesOnlyThatWindowState() {
        let front = MacOSDestinationState()
        let back = MacOSDestinationState()
        let requests = MacOSSectionRequests()
        front.taskDraft = "Draft"
        back.selectedTab = .tasks
        var openedWindows = 0
        MacOSSectionNavigator.select(
            MacOSSectionCommands.settingsSection,
            focusedWindow: front,
            requests: requests,
            openMainWindow: { openedWindows += 1 }
        )
        #expect(front.selectedTab == .pattern)
        #expect(front.taskDraft == "Draft")
        #expect(back.selectedTab == .tasks)
        #expect(openedWindows == 0)
        #expect(requests.pendingSection == nil)
    }
}

struct MacOSShortcutCollisionTests {
    /// Shortcuts that AppKit or SwiftUI already give the standard menus.
    private static let reserved: Set<ShortcutSignature> = Set(
        Array("qwhmnacvxzfgopst").map { ShortcutSignature(key: $0, modifiers: .command) }
            + [ShortcutSignature(key: "z", modifiers: [.command, .shift])]
    )

    private static var allShortcuts: [ShortcutSignature] {
        let sections = MacOSSectionCommands.sections.compactMap(MacOSSectionCommands.shortcut(for:))
        let timer = Set(TimerMenuAction.allCases.compactMap(\.shortcut).map(ShortcutSignature.init))
        return (sections + [MacOSSectionCommands.settingsShortcut]).map(ShortcutSignature.init) + timer
    }

    @Test func shortcutsAreUniqueAcrossMenus() {
        let shortcuts = Self.allShortcuts
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func shortcutsAvoidStandardMenuShortcuts() {
        for shortcut in Self.allShortcuts {
            #expect(!Self.reserved.contains(shortcut), "\(shortcut)")
            #expect(shortcut.usesCommand, "\(shortcut)")
        }
    }

    @Test func primaryTimerActionsShareOneShortcut() {
        let primary = [TimerMenuAction.start, .pause, .resume].map { $0.shortcut.map(ShortcutSignature.init) }
        #expect(Set(primary).count == 1)
        #expect(primary.first == ShortcutSignature(key: KeyEquivalent.return.character, modifiers: [.command]))
        #expect(TimerMenuAction.finish.shortcut.map(ShortcutSignature.init)
            == ShortcutSignature(key: KeyEquivalent.return.character, modifiers: [.command, .shift]))
        #expect(TimerMenuAction.skip.shortcut.map(ShortcutSignature.init)
            == ShortcutSignature(key: "]", modifiers: [.command]))
    }

    /// Cancel discards the session without asking, so no chord triggers it;
    /// Command-period in particular dismisses sheets and dialogs.
    @Test func destructiveAndAlertActionsHaveNoShortcut() {
        #expect(TimerMenuAction.cancel.shortcut == nil)
        #expect(TimerMenuAction.stopSound.shortcut == nil)
        let period = ShortcutSignature(key: ".", modifiers: [.command])
        #expect(!Self.allShortcuts.contains(period))
    }
}

/// KeyboardShortcut is not Hashable, so the tests compare its parts.
struct ShortcutSignature: Hashable, CustomStringConvertible {
    let key: Character
    let modifiers: EventModifiers.RawValue

    init(key: Character, modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers.rawValue
    }

    init(_ shortcut: KeyboardShortcut) {
        self.init(key: shortcut.key.character, modifiers: shortcut.modifiers)
    }

    var usesCommand: Bool { EventModifiers(rawValue: modifiers).contains(.command) }

    var description: String { "\(modifiers)+\(key.unicodeScalars.map(\.value))" }
}
