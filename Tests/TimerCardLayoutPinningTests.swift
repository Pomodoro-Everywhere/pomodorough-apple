import Foundation
import Testing
@testable import Pomodorough

// Pins AP99/AP100 layout decisions: the iOS card stretch rule and the
// portrait top-gap math that keeps the card clear of the toolbar row.
@Suite("Timer card layout pinning")
struct TimerCardLayoutPinningTests {
    @Test func iOSCardStretchesOnlyInLandscape() {
        #expect(TimerMachineCard.iOSCardMaxHeight(for: .landscape) == .infinity)
        #expect(TimerMachineCard.iOSCardMaxHeight(for: .portrait) == nil)
    }

    @Test func portraitTopGapFallsBackWithoutToolbarRow() {
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: 0, globalMinY: 120) == 16)
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: -4, globalMinY: 120) == 16)
    }

    @Test func portraitTopGapClearsReportedToolbarRow() {
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: 200, globalMinY: 100) == 116)
    }

    @Test func portraitTopGapNeverGoesNegative() {
        #expect(TimerScreen.portraitTopGap(syncStatusBottom: 100, globalMinY: 120) == 0)
    }

    @Test func portraitMinimumHeightFloorsAtZero() {
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 30, topGap: 16) == 0)
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 0, topGap: 16) == 0)
    }

    @Test func portraitMinimumHeightDefersToConflictBanner() {
        // Caller contract: portraitContent passes nil while a conflict
        // banner is shown so the card sizes to content; the helper covers
        // the stretch branch only (caller mapping is pinned by
        // check_interface_contract.py).
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 800, topGap: 16) == 761)
    }

    @Test func portraitMinimumHeightFillsTallScreens() {
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 900, topGap: 16) == 861)
        #expect(TimerScreen.portraitMinimumHeight(availableHeight: 1366, topGap: 16) == 1327)
    }
}
