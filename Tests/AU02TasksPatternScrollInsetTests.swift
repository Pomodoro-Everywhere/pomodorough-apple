import Foundation
import Testing
@testable import Pomodorough

// Pins R53-AU02 (F2): Tasks and Pattern scroll clearance goes through the
// AU02/AU03-shared tab-bar-measured helper, never the old fixed 80pt. SE2
// evidence pins the ruler: the XXXL tab bar measures 83pt portrait and 64pt
// landscape — both must clear content through the measured value, where the
// fixed inset covered the Tasks date row and the Pattern lower card only by
// luck. Also pins the helper's generic contract (zero at standard sizes,
// touch-minimum fallback unmeasured) since this is its only test suite.
@Suite("AU02 tasks pattern scroll inset")
struct AU02TasksPatternScrollInsetTests {
    @Test func standardSizesNeedNoInset() {
        #expect(TabBarScrollInset.bottom(safeBottom: 83, isAccessibilitySize: false) == 0)
        #expect(TabBarScrollInset.bottom(safeBottom: 0, isAccessibilitySize: false) == 0)
    }

    @Test func xxxlPortraitClearsMeasuredBar() {
        #expect(TabBarScrollInset.bottom(safeBottom: 83, isAccessibilitySize: true) == 83)
    }

    @Test func xxxlLandscapeClearsMeasuredBar() {
        #expect(TabBarScrollInset.bottom(safeBottom: 64, isAccessibilitySize: true) == 64)
    }

    @Test func unmeasuredBarFallsBackToTouchMinimum() {
        #expect(TabBarScrollInset.bottom(safeBottom: 0, isAccessibilitySize: true) == 44)
        #expect(TabBarScrollInset.minimumClearance == 44)
    }

    @Test func arrivalsEmptyBottomForwardsToSharedHelper() {
        #expect(HistoryScreen.emptyBottomInset(safeBottom: 83, isAccessibilitySize: true) == 83)
        #expect(HistoryScreen.emptyBottomInset(safeBottom: 64, isAccessibilitySize: true) == 64)
        #expect(HistoryScreen.emptyBottomInset(safeBottom: 0, isAccessibilitySize: true) == 44)
        #expect(HistoryScreen.emptyBottomInset(safeBottom: 83, isAccessibilitySize: false) == 0)
    }
}
