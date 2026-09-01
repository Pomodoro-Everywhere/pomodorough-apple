import Foundation
import Testing
@testable import Pomodorough

@Suite("Timer completion deadline task")
struct TimerCompletionDeadlineTests {
    @Test @MainActor
    func realDeadlineFiresWithoutAnyView() async {
        var completions = 0
        let task = TimerCompletionScheduler().schedule(after: 0.01) { completions += 1 }
        #expect(completions == 0)
        await task.value
        #expect(completions == 1)
    }

    @Test @MainActor
    func cancellationRejectsAlreadyResumedSleeper() async throws {
        let sleeper = CompletionSleepGate()
        defer { sleeper.releaseAll() }
        var completions = 0
        let scheduler = TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) })
        let task = scheduler.schedule(after: 60) { completions += 1 }
        try await completionEventually { sleeper.count == 1 }
        sleeper.release(0)
        task.cancel()
        await task.value
        #expect(completions == 0)
    }

    @Test @MainActor
    func replacementDeadlineRejectsUncooperativeCancelledSleep() async throws {
        let sleeper = CompletionSleepGate()
        defer { sleeper.releaseAll() }
        var completions: [String] = []
        let scheduler = TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) })
        let previous = scheduler.schedule(after: 60) { completions.append("previous") }
        try await completionEventually { sleeper.count == 1 }
        previous.cancel()
        let replacement = scheduler.schedule(after: 40) { completions.append("replacement") }
        try await completionEventually { sleeper.count == 2 }
        sleeper.release(0)
        await previous.value
        #expect(completions.isEmpty)
        sleeper.release(1)
        await replacement.value
        #expect(completions == ["replacement"])
    }

    @Test @MainActor
    func throwingCancellationDoesNotComplete() async {
        var completions = 0
        let scheduler = TimerCompletionScheduler(sleep: { _ in throw CancellationError() })
        let task = scheduler.schedule(after: 60) { completions += 1 }
        await task.value
        #expect(completions == 0)
    }

    @Test @MainActor
    func cancellationBeforeTaskStartsNeverEntersSleeper() async {
        var sleeps = 0
        var completions = 0
        let scheduler = TimerCompletionScheduler(sleep: { _ in sleeps += 1 })
        let task = scheduler.schedule(after: 0) { completions += 1 }
        task.cancel()
        await task.value
        #expect(sleeps == 0)
        #expect(completions == 0)
    }
}

@MainActor
private final class CompletionSleepGate {
    private var continuations: [CheckedContinuation<Void, any Error>?] = []
    private(set) var durations: [Duration] = []
    var count: Int { durations.count }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            durations.append(duration)
            continuations.append(continuation)
        }
    }

    func release(_ index: Int) {
        guard continuations.indices.contains(index) else { return }
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume()
    }

    func releaseAll() {
        for index in continuations.indices { release(index) }
    }
}

@MainActor
private func completionEventually(_ predicate: () -> Bool) async throws {
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate(), ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(predicate())
}

@Suite("AppModel owns timer completion")
struct TimerCompletionSchedulingTests {
    @Test @MainActor
    func offlineFocusStartsBreakAndRecordsHistoryWithoutTimerView() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setDurationMinutes(1, for: .focus)
        model.autoStartBreaks = true
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.selectPhase(.longBreak)
        try await completionEventually { fixture.sleeper.count == 1 }

        fixture.clock.elapsed = 60
        fixture.sleeper.release(0)

        try await completionEventually { model.completedFocusCount == 1 }
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.canonicalTimer?.id != focus.id)
        #expect(model.selectedPhase == .longBreak)
        #expect(model.pendingCommandCount == 3)
        model.setSceneActive(true)
        await model.refreshAfterForeground()
        #expect(model.completedFocusCount == 1)
        #expect(model.pendingCommandCount == 3)
    }

    @Test @MainActor
    func pauseInvalidatesDeadlineAndResumeUsesRemainingTime() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setDurationMinutes(1, for: .focus)
        model.start()
        try await completionEventually { fixture.sleeper.count == 1 }
        fixture.clock.elapsed = 20
        model.pause()
        fixture.clock.elapsed = 70
        fixture.sleeper.release(0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.canonicalTimer?.status == .paused)
        #expect(model.completedFocusCount == 0)

        model.resume()
        try await completionEventually { fixture.sleeper.count == 2 }
        #expect(fixture.sleeper.durations[1] == .seconds(40))
        fixture.clock.elapsed = 110
        fixture.sleeper.release(1)
        try await completionEventually { model.completedFocusCount == 1 }
    }

    @Test @MainActor
    func cancelledTimerCannotCompleteReplacement() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setDurationMinutes(1, for: .focus)
        model.start()
        try await completionEventually { fixture.sleeper.count == 1 }
        fixture.clock.elapsed = 10
        model.cancel()
        model.start()
        let replacement = try #require(model.canonicalTimer)
        try await completionEventually { fixture.sleeper.count == 2 }

        fixture.clock.elapsed = 60
        fixture.sleeper.release(0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.canonicalTimer?.id == replacement.id)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.completedFocusCount == 0)
        fixture.clock.elapsed = 70
        fixture.sleeper.release(1)
        try await completionEventually { model.completedFocusCount == 1 }
    }

    @Test @MainActor
    func foregroundReconcilesMissedDeadlineBeforeSleeperReturns() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setDurationMinutes(1, for: .focus)
        model.start()
        try await completionEventually { fixture.sleeper.count == 1 }
        model.setSceneActive(false)
        fixture.clock.elapsed = 90

        model.setSceneActive(true)
        #expect(model.completedFocusCount == 1)
        #expect(model.canonicalTimer?.status == .completed)
        let commandCount = model.pendingCommandCount
        fixture.sleeper.releaseAll()
        await model.refreshAfterForeground()
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.completedFocusCount == 1)
        #expect(model.pendingCommandCount == commandCount)
    }

    @Test @MainActor
    func earlyWakeRearmsWithoutFinishing() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setDurationMinutes(1, for: .focus)
        model.start()
        try await completionEventually { fixture.sleeper.count == 1 }
        fixture.clock.elapsed = 59
        fixture.sleeper.release(0)
        try await completionEventually { fixture.sleeper.count == 2 }
        #expect(model.completedFocusCount == 0)
        #expect(fixture.sleeper.durations[1] == .seconds(1))
        fixture.clock.elapsed = 60
        fixture.sleeper.release(1)
        try await completionEventually { model.completedFocusCount == 1 }
    }

    @Test @MainActor
    func modeChangeInvalidatesOldDeadlineEvenForSameTimer() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        model.setDurationMinutes(1, for: .focus)
        model.start()
        try await completionEventually { fixture.sleeper.count == 1 }
        await model.setReplicationMode(.centralized)
        try await completionEventually { fixture.sleeper.count == 2 }
        fixture.clock.elapsed = 60
        fixture.sleeper.release(0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.completedFocusCount == 0)
        fixture.sleeper.release(1)
        try await completionEventually { model.completedFocusCount == 1 }
    }

    @Test @MainActor
    func deinitializingModelCancelsPendingCompletion() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        var model: AppModel? = fixture.makeModel()
        weak let observedModel = model
        model?.start()
        try await completionEventually { fixture.sleeper.count == 1 }
        await model?.waitForAlarmOperations()
        model = nil
        try await completionEventually { observedModel == nil }
        fixture.clock.elapsed = 1_800
        fixture.sleeper.releaseAll()
        #expect(observedModel == nil)
    }

    @Test @MainActor
    func restoredExpiredTimerCompletesWithoutForegroundOrView() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        try fixture.seedTimer(owned: true)
        fixture.clock.elapsed = 90
        let model = fixture.makeModel()
        try await completionEventually { fixture.sleeper.count == 1 }
        fixture.sleeper.release(0)
        try await completionEventually { model.completedFocusCount == 1 }
        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.pendingCommandCount == 1)
    }

    @Test @MainActor
    func remoteOwnedTimerCannotFinishOrGenerateLocalBreak() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        try fixture.seedTimer(owned: false)
        let model = fixture.makeModel()
        model.autoStartBreaks = true
        let remoteTimerID = try #require(model.canonicalTimer?.id)
        try await completionEventually { fixture.sleeper.count == 1 }
        fixture.clock.elapsed = 60
        fixture.sleeper.release(0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.pendingCommandCount == 0)
        #expect(model.canonicalTimer?.id == remoteTimerID)
        model.setDurationMinutes(2, for: .shortBreak)
        try await Task.sleep(for: .milliseconds(10))
        #expect(fixture.sleeper.count == 1)
        model.setSceneActive(true)
        #expect(model.pendingCommandCount == 0)
        #expect(model.canonicalTimer?.id == remoteTimerID)
    }

    @Test @MainActor
    func irohCaptureRollbackRetriesWithoutForegroundAndCommitsOneBreak() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        try fixture.seedIrohTimer(owned: true)
        try fixture.expectIrohCompletionDecision(owned: true)
        let model = fixture.makeModel()
        let focus = try #require(fixture.roomStore.activeRoomState?.canonicalTimer)
        let operationCount = try #require(fixture.roomStore.activeSnapshot?.operationCount)
        try await completionEventually { fixture.sleeper.count == 1 }
        try fixture.blockRoomWrites()
        fixture.clock.elapsed = 60

        for index in 0..<3 {
            fixture.sleeper.release(index)
            try await completionEventually { fixture.sleeper.count == index + 2 }
            #expect(fixture.sleeper.durations[index + 1] == .seconds(5))
            #expect(fixture.roomStore.activeRoomState?.canonicalTimer == focus)
            #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount)
            fixture.clock.elapsed += 5
        }

        try fixture.restoreRoomWrites()
        for _ in 0..<100 { #expect(model.rebuildOptimisticState()) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(fixture.sleeper.count == 4)
        fixture.sleeper.release(3)
        try await completionEventually { model.canonicalTimer?.phase == .shortBreak }
        let automaticBreak = model.canonicalTimer
        #expect(automaticBreak?.status == .running)
        #expect(model.completedFocusCount == 1)
        #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount + 1)
        model.setSceneActive(true)
        #expect(model.canonicalTimer == automaticBreak)
        #expect(model.completedFocusCount == 1)
        #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount + 1)
    }

    @Test @MainActor
    func irohNonownershipDoesNotRetryOrGenerateBreak() async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        try fixture.seedIrohTimer(owned: false)
        try fixture.expectIrohCompletionDecision(owned: false)
        let model = fixture.makeModel()
        let operationCount = fixture.roomStore.activeSnapshot?.operationCount
        try await completionEventually { fixture.sleeper.count == 1 }
        fixture.clock.elapsed = 60
        fixture.sleeper.release(0)
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<100 { #expect(model.rebuildOptimisticState()) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(fixture.sleeper.count == 1)
        #expect(model.canonicalTimer?.phase == .focus)
        #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount)
    }

    @Test(arguments: [false, true]) @MainActor
    func irohExplicitPhaseSelectionClearsExpiredFocus(owned: Bool) async throws {
        let fixture = try CompletionModelFixture()
        defer { fixture.cleanUp() }
        try fixture.seedIrohTimer(owned: owned)
        let model = fixture.makeModel()
        let focus = try #require(fixture.roomStore.activeRoomState?.canonicalTimer)
        let operationCount = try #require(fixture.roomStore.activeSnapshot?.operationCount)
        try await completionEventually { fixture.sleeper.count == 1 }
        if owned { try fixture.blockRoomWrites() }
        fixture.clock.elapsed = 60
        fixture.sleeper.release(0)
        if owned {
            try await completionEventually { fixture.sleeper.count == 2 }
            #expect(fixture.sleeper.durations[1] == .seconds(5))
            #expect(fixture.roomStore.activeRoomState?.canonicalTimer == focus)
            try fixture.restoreRoomWrites()
        }
        try await completionEventually { model.canonicalTimer?.status == .completed }
        #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount)
        model.selectPhase(.focus)
        #expect(model.canonicalTimer == nil)
        #expect(fixture.roomStore.activeRoomState?.canonicalTimer == nil)
        #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount + 1)
        #expect(model.completedFocusCount == 1)
        fixture.clock.elapsed = 65
        fixture.sleeper.releaseAll()
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.canonicalTimer == nil)
        #expect(fixture.sleeper.count == (owned ? 2 : 1))
        #expect(fixture.roomStore.activeSnapshot?.operationCount == operationCount + 1)
        #expect(model.completedFocusCount == 1)
    }
}

@MainActor
private final class CompletionClock {
    let anchor = Date(timeIntervalSince1970: 1_780_000_000)
    var elapsed: TimeInterval = 0
    var now: Date { anchor.addingTimeInterval(elapsed) }
}

@MainActor
private struct CompletionModelFixture {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let clock = CompletionClock()
    let sleeper = CompletionSleepGate()
    let roomStore: IrohRoomStore

    init() throws {
        suiteName = "PomodoroughTests.CompletionDeadline.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let clock = clock
        roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("iroh-rooms.json"),
            secretStore: MemoryIrohRoomSecretStore(),
            now: { clock.now }
        )
    }

    func makeModel() -> AppModel {
        let clock = clock
        let sleeper = sleeper
        return AppModel(
            api: APIClient(
                session: TestFixtures.session(for: suiteName),
                keychain: EmptyTokenStore(),
                logoutRevocationStore: TestLogoutRevocationStore()
            ),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(
                fileURL: directory.appendingPathComponent("account-deletion.json")
            ),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("timer-state.json")
            ),
            roomStore: roomStore,
            endpointKeyStore: CompletionEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            completionScheduler: TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) }),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { clock.now },
            uptime: { clock.elapsed }
        )
    }

    func seedTimer(owned: Bool) throws {
        var state = PersistedTimerState.fresh()
        let owner = owned ? state.deviceId : "remote-device"
        state.canonicalTimer = CanonicalTimer(
            id: "timer-restored-completion", taskId: nil, phase: .focus, status: .running,
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0, anchorAt: clock.anchor,
            startedByDeviceId: owner,
            lastIntent: TimerIntent(
                type: .start, commandId: "restored-start", occurredAt: clock.anchor, deviceId: owner
            )
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
    }

    func seedIrohTimer(owned: Bool) throws {
        let state = PersistedTimerState.fresh()
        let owner = owned ? state.deviceId : "remote-device"
        let timer = CanonicalTimer(
            id: "timer-iroh-retry", taskId: nil, phase: .focus, status: .running,
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0, anchorAt: clock.anchor,
            startedByDeviceId: owner,
            lastIntent: TimerIntent(
                type: .start, commandId: "iroh-start", occurredAt: clock.anchor, deviceId: owner
            )
        )
        let secret = Data(0...31)
        _ = try roomStore.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret, name: nil,
            returnState: state,
            genesis: IrohGenesis(
                canonicalTimer: timer, history: [], tasks: [], durationsMs: .defaults,
                autoStartBreaks: true, hlcWallMs: 0, hlcCounter: 0
            ), now: clock.anchor
        )
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
    }

    func expectIrohCompletionDecision(owned: Bool) throws {
        let state = try #require(roomStore.activeRoomState)
        let timer = try #require(state.canonicalTimer)
        #expect(timer.status == .running)
        #expect((timer.startedByDeviceId == state.deviceId) == owned)
        #expect((state.localTimerOwners[timer.id] == state.deviceId) == owned)
        let controller = TimerSessionController(sharedCoreProvider: { try SharedCore.bundled() })
        let beforeDeadline = try controller.completionDecision(
            for: timer, at: clock.anchor, state: state, replicationMode: .iroh,
            physicalNow: clock.anchor, autoStartsBreak: true
        )
        #expect(beforeDeadline == nil)
        let deadline = clock.anchor.addingTimeInterval(60)
        let afterDeadline = try controller.completionDecision(
            for: timer, at: deadline, state: state, replicationMode: .iroh,
            physicalNow: deadline, autoStartsBreak: true
        )
        let decision = try #require(afterDeadline)
        #expect(decision.completedAt == deadline)
        #expect(decision.selectedPhase == .shortBreak)
        #expect(decision.generatedBreakPhase == (owned ? .shortBreak : nil))
    }

    func blockRoomWrites() throws {
        let roomURL = directory.appendingPathComponent("iroh-rooms.json")
        try FileManager.default.moveItem(at: roomURL, to: roomURL.appendingPathExtension("saved"))
        try FileManager.default.createDirectory(at: roomURL, withIntermediateDirectories: false)
    }

    func restoreRoomWrites() throws {
        let roomURL = directory.appendingPathComponent("iroh-rooms.json")
        try FileManager.default.removeItem(at: roomURL)
        try FileManager.default.moveItem(at: roomURL.appendingPathExtension("saved"), to: roomURL)
    }

    func cleanUp() {
        sleeper.releaseAll()
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
    }
}

private struct CompletionEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { nil }
    func save(_ secret: Data) throws {}
}
