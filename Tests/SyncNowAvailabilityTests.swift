import Testing
@testable import Pomodorough

// IOS27-11: "Sync now" keeps its earlier gating, and every blocked case
// carries a visible reason, so a disabled button never looks available.
@Suite("Sync now availability")
struct SyncNowAvailabilityTests {
    private func availability(
        _ mode: ReplicationMode,
        signedIn: Bool = true,
        syncing: Bool = false,
        resolving: Bool = false
    ) -> SyncNowAvailability {
        SyncNowAvailability(
            replicationMode: mode,
            isSignedIn: signedIn,
            isSyncing: syncing,
            isHistoryResolutionBlocking: resolving
        )
    }

    @Test func blockedCasesNameTheirCondition() {
        #expect(availability(.offline) == .onDevice)
        #expect(availability(.offline, signedIn: false) == .onDevice)
        #expect(availability(.centralized, signedIn: false) == .signedOut)
        #expect(availability(.centralized, resolving: true) == .resolvingHistory)
        #expect(availability(.centralized, syncing: true) == .syncing)
        #expect(availability(.iroh, signedIn: false, syncing: true) == .syncing)
    }

    @Test func availableOnlyWhenNothingBlocks() {
        #expect(availability(.centralized).isAvailable)
        #expect(availability(.iroh, signedIn: false).isAvailable)
        #expect(availability(.centralized).unavailableReason == nil)
    }

    /// Matches the boolean gate the Account view used before IOS27-11.
    @Test(arguments: ReplicationMode.allCases)
    func gatingMatchesEarlierRule(mode: ReplicationMode) {
        for signedIn in [false, true] {
            for syncing in [false, true] {
                for resolving in [false, true] {
                    let earlierDisabled = mode == .offline
                        || (mode == .centralized && !signedIn)
                        || syncing
                        || resolving
                    let value = availability(mode, signedIn: signedIn, syncing: syncing, resolving: resolving)
                    #expect(value.isAvailable == !earlierDisabled)
                    #expect((value.unavailableReason != nil) == earlierDisabled)
                }
            }
        }
    }
}
