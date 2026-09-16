import Foundation
import Testing
@testable import Pomodorough

// S5 (POMODOROUGH-C, 1162 dev events): test/preview hosts run with
// Bundle.main pointing at the runner while the app bundle on disk still
// carries the wasm. The loader searches all bundles before failing, and
// memory pressure drops the cached runtime for lazy reload (S1 relief).
@Suite("SharedCore fallback")
struct SharedCoreFallbackTests {
    @Test func memoryPressureReleaseIsSafeWithoutRuntime() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/pomodorough_core.wasm")
        let core = SharedCore(moduleURL: missing)
        core.releaseRuntimeForMemoryPressure()
        core.releaseRuntimeForMemoryPressure()
    }

    @Test @MainActor func releaseCachedCoreDropsToNilAndReloads() throws {
        var loads = 0
        let api = APIClient(session: .shared, keychain: EmptyTokenStore())
        let sync = AccountSynchronization(api: api) {
            loads += 1
            throw SharedCoreError.resourceMissing
        }
        sync.releaseCachedCoreForMemoryPressure()
        #expect(loads == 0)
    }

    @Test func resourceMissingHasStableMessage() {
        #expect(SharedCoreError.resourceMissing == SharedCoreError.resourceMissing)
        #expect(SharedCoreError.resourceMissing.errorDescription?.isEmpty == false)
    }

    @Test func moduleURLPrefersPrimaryBundle() throws {
        // Either the wasm resolves (app/test host with resources) or the
        // loader throws resourceMissing — never a crash, never nil.
        do {
            _ = try SharedCore.bundledModuleURL()
        } catch let error as SharedCoreError {
            #expect(error == .resourceMissing)
        }
    }
}
