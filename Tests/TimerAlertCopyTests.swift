#if os(iOS)
import Testing
@testable import Pomodorough

/// IOS18-04: iOS 18 through 25 have no system timer alarm, so their copy
/// must not promise one or call the running device "older".
@Suite("Timer alert copy")
struct TimerAlertCopyTests {
    @Test func notificationOnlyCopyPromisesNoAlarmAndNoOlderDevice() {
        let copy = TimerAlertCopy.notificationOnly
        for text in [copy.introductionSummary, copy.accountSummary, copy.notificationDetail] {
            #expect(!text.localizedCaseInsensitiveContains("alarm"))
            #expect(!text.localizedCaseInsensitiveContains("older"))
        }
    }

    @Test func notificationOnlyCopyKeepsTheDeliveryGuarantee() {
        let copy = TimerAlertCopy.notificationOnly
        let guarantee = "subject to the operating system's delivery policy"
        #expect(copy.introductionSummary.contains(guarantee))
        #expect(copy.accountSummary.contains(guarantee))
    }

    @Test func currentCopyMatchesTheRunningSystem() {
        if #available(iOS 26.0, *) {
            #expect(TimerAlertCopy.current == .alarmAndNotification)
        } else {
            #expect(TimerAlertCopy.current == .notificationOnly)
        }
    }
}
#endif
