import Foundation
import Testing
@testable import Pomodorough

// Pins other-agent dial-face/compact work: progress derivation,
// indicator color defaults, backwards-compatible defaults, toolbar
// preference max.
@Suite("Dial face pinning")
struct DialFacePinningTests {
    @Test func longBreakIndicatorDerivesProgressFromCompletedToday() {
        let cases: [(completed: Int, progress: Int)] = [
            (0, 0), (1, 1), (2, 2), (3, 3), (4, 4),
            (5, 1), (6, 2), (7, 3), (8, 4), (9, 1), (12, 4),
        ]
        for item in cases {
            let indicator = LongBreakProgressIndicator(completedToday: item.completed)
            #expect(indicator.progress == item.progress)
            #expect(indicator.completedToday == item.completed)
        }
    }

    @Test func longBreakIndicatorExplicitInitPreservesBothValues() {
        let indicator = LongBreakProgressIndicator(progress: 3, completedToday: 7)
        #expect(indicator.progress == 3)
        #expect(indicator.completedToday == 7)
    }

    @Test func longBreakIndicatorMatchesAppModelProgressFormula() {
        for completed in 0 ... 12 {
            let expected = completed == 0 ? 0 : ((completed - 1) % 4) + 1
            #expect(LongBreakProgressIndicator(completedToday: completed).progress == expected)
        }
    }

    @Test func dialFacesDefaultToZeroCompletedFocus() {
        #expect(PortraitDialFace(progress: 0.5, phase: .focus, status: "Running", timeText: "17:00").completedFocusCount == 0)
        #expect(LandscapeDialFace(progress: 0.5, phase: .focus, status: "Running", timeText: "17:00").completedFocusCount == 0)
        #expect(AccessibleDialFace(progress: 0.5, phase: .focus, status: "Running", timeText: "17:00").completedFocusCount == 0)
        #expect(IdleTimerDial(phase: .focus, minutes: 25, layout: .portrait).completedFocusCount == 0)
        #expect(DialFace(progress: 0.5, phase: .focus, status: "Running", timeText: "17:00", layout: .portrait).completedFocusCount == 0)
    }

    @Test func longBreakIndicatorDefaultsToTicketAndAcceptsCustomColor() {
        #expect(LongBreakProgressIndicator(completedToday: 5).color == PomodoroughTheme.ticket)
        #expect(LongBreakProgressIndicator(completedToday: 5, color: PomodoroughTheme.platform).color == PomodoroughTheme.platform)
        #expect(LongBreakProgressIndicator(progress: 2, completedToday: 6, color: PomodoroughTheme.platform).color == PomodoroughTheme.platform)
    }

    @Test func syncToolbarPreferenceTakesMax() {
        var value: CGFloat = 3
        SyncToolbarBottomPreferenceKey.reduce(value: &value) { 7 }
        #expect(value == 7)
        SyncToolbarBottomPreferenceKey.reduce(value: &value) { 2 }
        #expect(value == 7)
        #expect(SyncToolbarBottomPreferenceKey.defaultValue == 0)
    }
}
