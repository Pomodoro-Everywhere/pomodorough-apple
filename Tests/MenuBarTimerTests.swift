#if os(macOS)
import Foundation
import Testing
@testable import Pomodorough

@Suite("Menu bar timer presentation")
struct MenuBarTimerTests {
    @Test
    func countdownRoundsUpAndTotalRoundsDown() {
        #expect(MenuBarTimerStatus.clock(59.2, roundingUp: true) == "1:00")
        #expect(MenuBarTimerStatus.clock(59.2, roundingUp: false) == "0:59")
        #expect(MenuBarTimerStatus.clock(-1, roundingUp: true) == "0:00")
        #expect(MenuBarTimerStatus.clock(3661, roundingUp: false) == "1:01:01")
    }

    @Test
    func displayModesKeepTotalDistinct() {
        #expect(MenuBarTimerDisplay.current.text(current: "24:59", total: "1:00:01") == "24:59")
        #expect(MenuBarTimerDisplay.total.text(current: "24:59", total: "1:00:01") == "Σ 1:00:01")
        #expect(MenuBarTimerDisplay.both.text(current: "24:59", total: "1:00:01") == "24:59 · Σ 1:00:01")
    }

    @Test
    func iconsDistinguishFocusBreakAndPause() {
        #expect(status(.focus, .running).symbol == "timer")
        #expect(status(.shortBreak, .running).symbol == "cup.and.saucer")
        #expect(status(.longBreak, .running).symbol == "cup.and.saucer")
        #expect(status(.focus, .paused).symbol == "pause.circle")
    }

    private func status(_ phase: TimerPhase, _ status: CanonicalTimer.Status) -> MenuBarTimerStatus {
        MenuBarTimerStatus(phase: phase, status: status, remaining: 300, total: 1500)
    }
}
#endif
