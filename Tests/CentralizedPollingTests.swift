import Foundation
import Testing
@testable import Pomodorough

// S1 (POMODOROUGH-37 watchdog OOM): the 5s poller fired 57KB syncs while
// backgrounded or while a sync was already in flight, stacking concurrent
// wasm reconciliations. Poll only when foregrounded and idle.
@Suite("Centralized polling gate")
struct CentralizedPollingTests {
    @Test func syncsOnlyWhenActiveAndIdle() {
        #expect(CentralizedPolling.shouldSync(isSceneActive: true, isSyncing: false))
    }

    @Test func skipsWhileBackgrounded() {
        #expect(!CentralizedPolling.shouldSync(isSceneActive: false, isSyncing: false))
        #expect(!CentralizedPolling.shouldSync(isSceneActive: false, isSyncing: true))
    }

    @Test func skipsWhileSyncInFlight() {
        #expect(!CentralizedPolling.shouldSync(isSceneActive: true, isSyncing: true))
    }

    @Test func pollIntervalUnchanged() {
        #expect(RemotePolling.interval(isTimerActive: true) == 2)
        #expect(RemotePolling.interval(isTimerActive: false) == 5)
    }
}
