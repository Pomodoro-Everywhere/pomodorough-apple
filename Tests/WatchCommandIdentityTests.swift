import Foundation
import Testing
#if os(iOS)
import WatchConnectivity
#endif
@testable import Pomodorough

/// Backlog 2026-09-08 Watch fixes: commands carry timer identity, the phone
/// rejects delayed commands aimed at a previous timer or timer revision.
struct WatchCommandIdentityTests {
#if os(iOS)
    @Test @MainActor
    func liveRefreshDelegateReturnsPublishedSnapshot() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        var reply: [String: Any] = [:]
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let runningData = try #require(reply[WatchSyncKeys.snapshot] as? Data)
        let running = try JSONDecoder().decode(WatchTimerSnapshot.self, from: runningData)
        #expect(running.isRunning)
        #expect(running.timerRevision == model.makeWatchSnapshot().timerRevision)
        model.pause()
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let pausedData = try #require(reply[WatchSyncKeys.snapshot] as? Data)
        let paused = try JSONDecoder().decode(WatchTimerSnapshot.self, from: pausedData)
        #expect(paused.isPaused)
        #expect(paused.timerRevision == model.makeWatchSnapshot().timerRevision)
    }
#endif
    @Test @MainActor
    func deferredStartCannotRunAfterNewerPhoneActivityOrReplay() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = WatchTimerCommand.start()
        #expect(!start.allowsDeferredDelivery)
        #expect(model.applyWatchCommand(start))
        model.finish()
        let finished = model.canonicalTimer
        #expect(!model.applyWatchCommand(start, isDeferred: true))
        #expect(model.canonicalTimer == finished)
        #expect(!model.applyWatchCommand(.start(), isDeferred: true))
        #expect(model.canonicalTimer == finished)
        #expect(WatchTimerCommand.pause(timerId: "timer").allowsDeferredDelivery)
    }

    @Test @MainActor
    func refreshReplyContainsDecodableCurrentSnapshot() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let snapshot = model.makeWatchSnapshot()
        let reply = WatchSyncService.snapshotReply(try JSONEncoder().encode(snapshot))
        let data = try #require(reply[WatchSyncKeys.snapshot])
        #expect(try JSONDecoder().decode(WatchTimerSnapshot.self, from: data) == snapshot)
    }

    @Test
    func commandRoundTripKeepsIdentities() throws {
        let command = WatchTimerCommand.pause(timerId: "timer-a")
        let decoded = try JSONDecoder().decode(
            WatchTimerCommand.self,
            from: JSONEncoder().encode(command)
        )
        #expect(decoded == command)
        #expect(decoded.timerId == "timer-a")
    }

    @Test
    func legacyCommandWithoutIdentitiesStillDecodes() throws {
        let data = try legacyPayload(from: WatchTimerCommand.pause(timerId: "timer-a"))
        let decoded = try JSONDecoder().decode(WatchTimerCommand.self, from: data)
        #expect(decoded.name == "pause")
        #expect(decoded.timerId == nil)
    }

    @Test
    func legacySnapshotWithoutTimerIdStillDecodes() throws {
        let snapshot = WatchTimerSnapshot(
            phase: "focus", status: "running", timerId: "timer-a",
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            selectedPhase: "focus",
            focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
            longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
        )
        let data = try JSONEncoder().encode(snapshot)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        dict?.removeValue(forKey: "timerId")
        let legacy = try JSONSerialization.data(withJSONObject: dict ?? [:])
        let decoded = try JSONDecoder().decode(WatchTimerSnapshot.self, from: legacy)
        #expect(decoded.timerId == nil)
        #expect(decoded.phase == "focus")
    }

    @Test @MainActor
    func snapshotCarriesActiveTimerId() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timer = try #require(model.canonicalTimer)
        #expect(model.makeWatchSnapshot().timerId == timer.id)
    }

    @Test @MainActor
    func idleSnapshotHasNilTimerId() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(model.makeWatchSnapshot().timerId == nil)
    }

    @Test @MainActor
    func stalePauseForPreviousTimerRejected() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timerA = try #require(model.canonicalTimer)
        let revisionA = try #require(model.makeWatchSnapshot().timerRevision)
        model.finish()
        model.start()
        let timerB = try #require(model.canonicalTimer)
        #expect(timerA.id != timerB.id)

        #expect(model.applyWatchCommand(WatchTimerCommand(
            timerId: timerA.id, expectedTimerRevision: revisionA,
            name: "pause", sentAt: .now
        )) == false)
        #expect(model.canonicalTimer?.id == timerB.id)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func staleFinishDoesNotCompleteNewTimer() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timerA = try #require(model.canonicalTimer)
        let revisionA = try #require(model.makeWatchSnapshot().timerRevision)
        model.finish()
        model.start()
        let timerB = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(WatchTimerCommand(
            timerId: timerA.id, expectedTimerRevision: revisionA,
            name: "finish", sentAt: .now
        )) == false)
        #expect(model.canonicalTimer?.id == timerB.id)
    }

    @Test @MainActor
    func currentPauseAccepted() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let timer = try #require(model.canonicalTimer)

        let command = WatchTimerCommand(
            timerId: timer.id,
            expectedTimerRevision: model.makeWatchSnapshot().timerRevision,
            name: "pause", sentAt: .now
        )
        let decoded = try JSONDecoder().decode(
            WatchTimerCommand.self, from: JSONEncoder().encode(command)
        )
        #expect(decoded == command)
        #expect(model.applyWatchCommand(decoded) == true)
        #expect(model.canonicalTimer?.status == .paused)
    }

    @Test @MainActor
    func legacyPauseWithoutRevisionRejected() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        _ = try #require(model.canonicalTimer)

        #expect(model.applyWatchCommand(.pause()) == false)
        #expect(model.applyWatchCommand(.pause(timerId: model.canonicalTimer?.id)) == false)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func queuedPauseCannotOverrideNewerPhoneResume() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let revision = try #require(model.makeWatchSnapshot().timerRevision)
        let queued = WatchTimerCommand(
            timerId: revision.timerId, expectedTimerRevision: revision,
            name: "pause", sentAt: .distantFuture
        )
        model.pause()
        model.resume()
        let current = model.canonicalTimer
        #expect(model.applyWatchCommand(queued) == false)
        #expect(model.canonicalTimer == current)
    }

    @Test @MainActor
    func liveResumeWinsOverOlderQueuedPauseAndReplay() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let initial = try #require(model.makeWatchSnapshot().timerRevision)
        let pause = WatchTimerCommand(
            timerId: initial.timerId, expectedTimerRevision: initial,
            name: "pause", sentAt: .distantPast
        )
        #expect(model.applyWatchCommand(pause))
        #expect(!model.applyWatchCommand(pause))
        let paused = try #require(model.makeWatchSnapshot().timerRevision)
        let resume = WatchTimerCommand(
            timerId: paused.timerId, expectedTimerRevision: paused,
            name: "resume", sentAt: .distantPast
        )
        #expect(model.applyWatchCommand(resume))
        #expect(!model.applyWatchCommand(pause))
        #expect(!model.applyWatchCommand(resume))
        #expect(model.canonicalTimer?.status == .running)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.applyWatchCommand(pause))
        #expect(!restored.applyWatchCommand(resume))
        #expect(restored.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func staleFinishRejectedAndFreshFinishAccepted() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let initial = try #require(model.makeWatchSnapshot().timerRevision)
        var finish = WatchTimerCommand(
            timerId: initial.timerId, expectedTimerRevision: initial,
            name: "finish", sentAt: .now
        )
        model.pause()
        #expect(!model.applyWatchCommand(finish))
        finish.expectedTimerRevision = model.makeWatchSnapshot().timerRevision
        #expect(model.applyWatchCommand(finish))
        #expect(!model.applyWatchCommand(finish))
    }

    @Test @MainActor
    func settingsCommandsUnaffectedByGuard() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(model.applyWatchCommand(.selectPhase("focus")) == true)
        #expect(model.applyWatchCommand(
            .setDuration(minutes: 20, forPhaseRawValue: "focus")
        ) == true)
        #expect(model.durationMinutes(for: .focus) == 20)
    }

    @Test @MainActor
    func unknownWatchCommandRejectedAndCaptured() {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        var unknown = WatchTimerCommand.start()
        unknown.name = "rewind"
        #expect(model.applyWatchCommand(unknown) == false)
        #expect(recorded.value == ["rewind"])
    }

    @Test @MainActor
    func serialQueueAppliesPauseThenResumeInOrder() async {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        let queue = WatchCommandSerialQueue()
        queue.enqueue { @MainActor in
            await Task.yield()
            model.pause()
        }
        queue.enqueue { @MainActor in model.resume() }
        await queue.flush()
        #expect(model.canonicalTimer?.status == .running)
    }

#if os(iOS)
    @Test @MainActor
    func roomSwapRefreshReplyConvergesWithoutLocalMutation() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        // Room swap without any local mutation: the reply cache must follow.
        model.adoptRoomWorkspace(PersistedTimerState.fresh())
        var reply: [String: Any] = [:]
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let data = try #require(reply[WatchSyncKeys.snapshot] as? Data)
        let served = try JSONDecoder().decode(WatchTimerSnapshot.self, from: data)
        // updatedAt advances on every snapshot, so compare the converged
        // content: identity, revision, and status (idle after the swap).
        let expected = model.makeWatchSnapshot()
        #expect(served.timerId == expected.timerId)
        #expect(served.timerRevision == expected.timerRevision)
        #expect(served.status == expected.status)
        #expect(!served.isRunning)
    }
#endif

    @Test
    func watchSnapshotOrderingAdoptsNewerRejectsStale() {
        func snapshot(sequence: UInt64, status: String) -> WatchTimerSnapshot {
            WatchTimerSnapshot(
                phase: "focus", status: status, sequence: sequence,
                timerId: "timer-a",
                plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
                anchorAt: TestFixtures.anchor,
                selectedPhase: "focus",
                focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
                longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
            )
        }
        let current = snapshot(sequence: 10, status: "paused")
        #expect(!shouldAdoptWatchSnapshot(snapshot(sequence: 9, status: "running"), over: current))
        #expect(!shouldAdoptWatchSnapshot(snapshot(sequence: 10, status: "paused"), over: current))
        #expect(shouldAdoptWatchSnapshot(snapshot(sequence: 11, status: "running"), over: current))
        #expect(!shouldAdoptWatchSnapshot(snapshot(sequence: 0, status: "running"), over: current))
        #expect(shouldAdoptWatchSnapshot(snapshot(sequence: 12, status: "running"), over: nil))
        #expect(shouldAdoptWatchSnapshot(
            snapshot(sequence: 12, status: "running"),
            over: snapshot(sequence: 0, status: "paused")
        ))
    }

    @Test
    func delayedRefreshReplyCannotResurrectStaleCountdown() {
        func snapshot(sequence: UInt64, status: String) -> WatchTimerSnapshot {
            WatchTimerSnapshot(
                phase: "focus", status: status, sequence: sequence,
                timerId: "timer-a",
                plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
                anchorAt: TestFixtures.anchor,
                selectedPhase: "focus",
                focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
                longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
            )
        }
        // Watch adopted the newer paused context (seq 5); a delayed running
        // refresh reply (seq 4) must not resurrect the old countdown.
        let adopted = snapshot(sequence: 5, status: "paused")
        #expect(!shouldAdoptWatchSnapshot(snapshot(sequence: 4, status: "running"), over: adopted))
        #expect(shouldAdoptWatchSnapshot(snapshot(sequence: 6, status: "paused"), over: adopted))
    }

    @Test
    func reinstallSeedChangeAdoptsDespiteNumericallySmallerSequence() {
        func snapshot(sequence: UInt64, status: String) -> WatchTimerSnapshot {
            WatchTimerSnapshot(
                phase: "focus", status: status, sequence: sequence,
                timerId: "timer-a",
                plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
                anchorAt: TestFixtures.anchor,
                selectedPhase: "focus",
                focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
                longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
            )
        }
        // Pre-reinstall install (seed 5, high counter) vs post-reinstall or
        // seed-wrapped install (seed 2, low counter): the new epoch adopts
        // even though its full sequence is numerically smaller, so snapshots
        // can never brick behind a pre-reinstall sequence.
        let preReinstall = snapshot(sequence: (UInt64(5) << 32) | 9_000, status: "paused")
        let postReinstall = snapshot(sequence: (UInt64(2) << 32) | 3, status: "running")
        #expect(postReinstall.sequence < preReinstall.sequence)
        #expect(shouldAdoptWatchSnapshot(postReinstall, over: preReinstall))
        // Same-epoch ordering is unchanged: stale rejected, newer accepted.
        let sameEpoch = snapshot(sequence: (UInt64(2) << 32) | 4, status: "paused")
        #expect(!shouldAdoptWatchSnapshot(postReinstall, over: sameEpoch))
        #expect(shouldAdoptWatchSnapshot(sameEpoch, over: postReinstall))
    }

    @Test
    func saturatedCounterRollsEpochAndStaysMonotonic() {
        let saturated = (sequence: (UInt64(7) << 32) | UInt64(UInt32.max), seed: UInt32(7), count: UInt32.max)
        let rolled = nextWatchSnapshotSequence(seed: saturated.seed, count: saturated.count)
        #expect(rolled.seed == 8)
        #expect(rolled.count == 1)
        #expect(rolled.sequence == (UInt64(8) << 32) | 1)
        #expect(rolled.sequence > saturated.sequence)
        let steady = nextWatchSnapshotSequence(seed: 7, count: 41)
        #expect(steady.sequence == (UInt64(7) << 32) | 42)
        #expect(steady.seed == 7)
        #expect(steady.count == 42)
    }

    @Test
    func preSequenceSnapshotDecodesAsZeroAndAdoptsOnlyOverLegacy() throws {
        let current = WatchTimerSnapshot(
            phase: "focus", status: "paused", sequence: (UInt64(9) << 32) | 500,
            timerId: "timer-a",
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            selectedPhase: "focus",
            focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
            longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
        )
        let data = try JSONEncoder().encode(current)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        dict?.removeValue(forKey: "sequence")
        let legacy = try JSONSerialization.data(withJSONObject: dict ?? [:])
        let decoded = try JSONDecoder().decode(WatchTimerSnapshot.self, from: legacy)
        #expect(decoded.sequence == 0)
        #expect(shouldAdoptWatchSnapshot(decoded, over: nil))
        #expect(shouldAdoptWatchSnapshot(
            decoded,
            over: WatchTimerSnapshot(
                phase: "focus", status: "paused", sequence: 0,
                timerId: "timer-a",
                plannedDurationMs: 60_000, elapsedAtAnchorMs: 0,
                anchorAt: TestFixtures.anchor,
                selectedPhase: "focus",
                focusDurationMs: 60_000, shortBreakDurationMs: 60_000,
                longBreakDurationMs: 60_000, updatedAt: TestFixtures.anchor
            )
        ))
        #expect(!shouldAdoptWatchSnapshot(decoded, over: current))
        #expect(shouldAdoptWatchSnapshot(current, over: decoded))
    }

    @Test
    func installSeedIsNonzeroRandomPerInstall() {
        var seeds = Set<UInt32>()
        for _ in 0..<256 {
            let seed = makeWatchInstallSeed()
            #expect(seed != 0)
            seeds.insert(seed)
        }
        #expect(seeds.count > 1)
    }

#if os(iOS)
    @Test @MainActor
    func watchPushStampsIncreasingSequences() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        model.watchSync.push()
        var reply: [String: Any] = [:]
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let first = try JSONDecoder().decode(
            WatchTimerSnapshot.self,
            from: try #require(reply[WatchSyncKeys.snapshot] as? Data)
        )
        model.watchSync.push()
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let second = try JSONDecoder().decode(
            WatchTimerSnapshot.self,
            from: try #require(reply[WatchSyncKeys.snapshot] as? Data)
        )
        #expect(first.sequence != 0)
        #expect(second.sequence > first.sequence)
    }

    @Test @MainActor
    func watchPushFirstSequenceCarriesNonzeroSeedAndInitialCount() throws {
        let (model, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.start()
        model.watchSync.push()
        var reply: [String: Any] = [:]
        model.watchSync.session(WCSession.default, didReceiveMessage: [WatchSyncKeys.requestSync: true]) {
            reply = $0
        }
        let first = try JSONDecoder().decode(
            WatchTimerSnapshot.self,
            from: try #require(reply[WatchSyncKeys.snapshot] as? Data)
        )
        #expect(first.installSeed != 0)
        #expect(first.sequence == (UInt64(first.installSeed) << 32) | 1)
    }
#endif

    // MARK: - Helpers

    @MainActor
    private func makeModel() -> (AppModel, UserDefaults, String) {
        let suite = "PomodoroughTests.WatchIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        return (model, defaults, suite)
    }

    private func legacyPayload(from command: WatchTimerCommand) throws -> Data {
        let data = try JSONEncoder().encode(command)
        var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        dict?.removeValue(forKey: "id")
        dict?.removeValue(forKey: "timerId")
        return try JSONSerialization.data(withJSONObject: dict ?? [:])
    }
}
