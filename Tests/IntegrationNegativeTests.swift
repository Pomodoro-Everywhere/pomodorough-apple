import Foundation
import Testing
@testable import Pomodorough

@Suite("Integration Negative")
struct IntegrationNegativeTests {
    @Test @MainActor
    func appModelIdentityFailureStopsBeforeExchangeAndSurfacesError() async throws {
        let scenario = "apple-api-coverage-model-identity-failure"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let identity = RecordingGoogleIdentityProvider()
        identity.identityTokenResult = .failure(AppError.missingIDToken)
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            api: APIClient(session: session, keychain: RecordingTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: identity
        )

        model.signIn()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isWorking)
        #expect(identity.nonces == ["model-nonce"])
        #expect(model.errorMessage == AppError.missingIDToken.localizedDescription)
        #expect(TestFixtures.recordedRequests(for: scenario).map(\.path) == [
            "/api/v1/auth/google/challenge"
        ])
    }

    @Test @MainActor
    func automaticFinishAndBreakRollBackAtomicallyWhenUuidV7TailExhausts() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.lastUuidV7 = try UUIDv7.make(
            timestampMs: UUIDv7.maxTimestampMs,
            randomHigh: UUIDv7.maxRandomHigh,
            randomLow: UUIDv7.maxRandomLow - 1
        )
        state.autoStartBreaks = true
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        state.localTimerOwners[state.canonicalTimer!.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { occurrence }
        )

        model.finish(at: occurrence)

        #expect(try persistedState(defaults) == state)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.errorMessage == AppError.invalidLocalClock.localizedDescription)
    }

    @Test @MainActor
    func rebootClockJumpPreservesQueueUntilFreshSampleAllowsMutation() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serverTime = Date(timeIntervalSince1970: 2_000)
        let localTime = serverTime.addingTimeInterval(3_600)
        let advancedServerTime = serverTime.addingTimeInterval(86_400)
        let advancedLocalTime = localTime.addingTimeInterval(86_400)
        var state = PersistedTimerState.fresh()
        try state.mergeClock(
            serverWallMs: 2_000_000,
            serverCounter: 0,
            serverTime: serverTime,
            requestWall: localTime,
            requestUptime: 100,
            responseUptime: 100
        )
        state.lastTrustedTimeMs = 2_000_000
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        state.localTimerOwners[state.canonicalTimer!.id] = state.deviceId
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.nextSequence = 2
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { advancedLocalTime },
            uptime: { 10 }
        )

        model.pause(at: advancedServerTime)

        #expect(try persistedState(defaults) == state)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(model.errorMessage == AppError.invalidLocalClock.localizedDescription)

        var resampled = try persistedState(defaults)
        try resampled.mergeClock(
            serverWallMs: 88_400_000,
            serverCounter: 0,
            serverTime: advancedServerTime,
            requestWall: advancedLocalTime,
            requestUptime: 10,
            responseUptime: 10
        )
        defaults.set(try JSONEncoder.api.encode(resampled), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let recoveredModel = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { advancedLocalTime },
            uptime: { 10 }
        )

        recoveredModel.pause(at: advancedServerTime)

        let recovered = try persistedState(defaults)
        #expect(recovered.pendingCommands.count == 2)
        #expect(recovered.pendingCommands.first?.id == state.pendingCommands.first?.id)
        #expect(recovered.pendingCommands.last?.type == .pause)
    }

    @Test @MainActor
    func automaticFinishRejectsAtomicallyWhenGeneratedStartCannotFit() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        let scheduler = RecordingAlarmScheduler()
        var state = PersistedTimerState.fresh()
        state.nextSequence = WireBounds.maxSafeInteger
        state.autoStartBreaks = true
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        state.localTimerOwners[state.canonicalTimer!.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: scheduler,
            now: { occurrence }
        )
        let original = try persistedState(defaults)

        model.finish(at: occurrence)
        await model.waitForAlarmOperations()

        #expect(try persistedState(defaults) == original)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(model.pendingCommandCount == 0)
        #expect(model.canonicalTimer == original.canonicalTimer)
        #expect(model.selectedPhase == .focus)
        #expect(scheduler.operations.isEmpty)
        #expect(model.conflictMessage?.contains("trusted-time") == true)
    }

    @Test @MainActor
    func cancellingRejectsAtomicallyWhenClearCannotFit() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        let scheduler = RecordingAlarmScheduler()
        var state = PersistedTimerState.fresh()
        state.nextSequence = WireBounds.maxSafeInteger
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: scheduler,
            now: { occurrence }
        )
        let original = try persistedState(defaults)

        model.cancel(at: occurrence)
        await model.waitForAlarmOperations()

        #expect(try persistedState(defaults) == original)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(model.pendingCommandCount == 0)
        #expect(model.canonicalTimer == original.canonicalTimer)
        #expect(scheduler.operations.isEmpty)
        #expect(model.conflictMessage?.contains("trusted-time") == true)
    }

    @Test @MainActor
    func excessiveServerTimeUncertaintyRejectsResponseAtomically() async throws {
        let scenario = "duration-sync"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serverTime = Date(timeIntervalSince1970: 1_784_620_800)
        var initial = PersistedTimerState.fresh()
        initial.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let uptime = ScriptedUptimeClock([100, 160.002])
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(
                session: session,
                keychain: StaticTokenStore(),
                wallNow: { serverTime },
                uptime: uptime.now
            ),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { serverTime }
        )

        await model.restore()

        #expect(try persistedState(defaults) == initial)
        #expect(model.errorMessage?.contains("Sync paused") == true)
        #expect(!model.isOffline)
    }

    @Test @MainActor
    func startupMigrationsCommitAllOrNothing() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = Data(
            #"{"deviceId":"device-atomic-migration","nextSequence":1,"revision":0,"hlcWallMs":1000000,"hlcCounter":9007199254740991,"pendingCommands":[],"pendingTaskOperations":[],"canonicalTimer":null,"history":[],"settings":{"shortBreakMinutes":7,"autoStartBreaks":true}}"#.utf8
        )
        defaults.set(original, forKey: "timer-state-v2")
        let legacyTasks = LocalTaskState(
            tasks: [try #require(FocusTask(title: "Atomic legacy task"))],
            selectedTaskID: nil,
            assignments: [:]
        )
        defaults.set(try JSONEncoder.api.encode(legacyTasks), forKey: "local-task-state-v1")
        defaults.resetTimerStateWrites()

        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { Date(timeIntervalSince1970: 1_000) },
            uptime: { 100 }
        )

        #expect(defaults.data(forKey: "timer-state-v2") == original)
        #expect(defaults.data(forKey: "local-task-state-v1") != nil)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(model.pendingDurationOperationCount == 0)
        #expect(model.tasks.isEmpty)
    }

    @Test @MainActor
    func everyLocalGeneratorLeavesAllQueuesUnchangedOnClockOverflow() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 1_000_000
        state.hlcCounter = WireBounds.maxSafeInteger
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { occurrence },
            uptime: { 100 }
        )
        let original = try persistedState(defaults)

        model.start()
        #expect(!(await model.addTask("Rejected task")))
        model.setDurationMinutes(30, for: .focus)
        model.autoStartBreaks = true

        let persisted = try persistedState(defaults)
        #expect(persisted == original)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(persisted.pendingCommands.isEmpty)
        #expect(persisted.pendingTaskOperations.isEmpty)
        #expect(persisted.pendingDurationOperations.isEmpty)
        #expect(persisted.pendingAutoStartOperations.isEmpty)
        #expect(model.canonicalTimer == nil)
        #expect(model.tasks.isEmpty)
        #expect(model.durationMinutes(for: .focus) == 25)
        #expect(!model.autoStartBreaks)
    }

    @Test(arguments: ["timer", "task", "duration", "auto-start"])
    @MainActor
    func normalSyncPreflightBlocksCorruptPendingRowsWithoutMutation(_ queue: String) async throws {
        let scenario = "task-sync-corrupt-preflight-\(queue)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        switch queue {
        case "timer":
            state.pendingCommands = [TimerCommand(
                id: "command-corrupt",
                deviceSequence: 0,
                timerId: "timer-corrupt",
                taskId: nil,
                type: .start,
                phase: .focus,
                plannedDurationMs: 60_000,
                occurredAt: occurrence,
                hlcWallMs: 1_000_000,
                hlcCounter: 0,
                observedElapsedMs: 0
            )]
        case "task":
            let task = try #require(FocusTask(title: "Corrupt task"))
            state.pendingTaskOperations = [TaskOperation(
                id: "task-operation-corrupt",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: occurrence,
                hlcWallMs: 1_300_001,
                hlcCounter: 0
            )]
        case "duration":
            state.pendingDurationOperations = [TestFixtures.durationOperation(
                id: "duration-operation-corrupt",
                phase: .focus,
                durationMs: 60_000,
                wallMs: 1_300_001,
                occurredAt: occurrence
            )]
        default:
            state.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
                deviceID: state.deviceId,
                enabled: true,
                wallMs: 1_300_001,
                occurredAt: occurrence
            )]
        }
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let originalData = try #require(defaults.data(forKey: "timer-state-v2"))
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { occurrence }
        )

        await model.restore()

        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/me" })
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
        #expect(defaults.data(forKey: "timer-state-v2") == originalData)
        #expect(model.pendingChangeCount == 1)
        #expect(model.conflictMessage?.contains("Queued changes") == true)
        #expect(model.errorMessage?.contains("local validation") == true)
    }

    @Test @MainActor
    func activeTimerKeepsCapturedDurationWhenFuturePreferenceChanges() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.selectedPhase = .longBreak
        model.setDurationMinutes(90, for: .focus)
        model.resume(at: timer.anchorAt.addingTimeInterval(5))
        model.clear()

        #expect(model.selectedPhase == .longBreak)
        #expect(model.durationMinutes(for: .focus) == 90)
        #expect(model.canonicalTimer == timer)
        #expect(model.canonicalTimer?.plannedDurationMs == Int64(25 * 60_000))
        #expect(model.pendingCommandCount == 1)
        #expect(model.pendingDurationOperationCount == 1)
    }

    @Test @MainActor
    func activeTimerKeepsItsTaskWhenFutureSelectionChanges() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(await model.addTask("Build"))
        #expect(await model.addTask("Review"))
        let build = try #require(model.tasks.first)
        let review = try #require(model.tasks.last)
        model.selectedTaskID = build.id
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.selectedTaskID = review.id

        #expect(model.selectedTaskID == review.id)
        #expect(model.task(forTimerID: timer.id) == build)
    }

    @Test @MainActor
    func corruptedPersistedStateFallsBackToFreshState() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        #expect(model.canonicalTimer == nil)
        #expect(model.history.isEmpty)
        #expect(model.pendingCommandCount == 0)
        #expect(model.durationMinutes(for: .focus) == 25)
    }

    @Test @MainActor
    func invalidDurationAcknowledgementKeepsQueueAndPausesAutomaticSync() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.settings.setMinutes(30, for: .focus)
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-pending",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 1
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: "duration-invalid-ack")
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session, keychain: StaticTokenStore())
        let model = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        await model.restore()

        #expect(model.pendingDurationOperationCount == 1)
        #expect(model.durationMinutes(for: .focus) == 30)
        #expect(model.errorMessage?.contains("Sync paused") == true)
        #expect(model.errorMessage?.contains("1 queued change remains") == true)
        #expect(!model.isOffline)
    }

    @Test(
        arguments: [
            "auto-start-ack-malformed",
            "auto-start-ack-missing",
            "auto-start-ack-extra",
            "auto-start-ack-duplicate",
            "auto-start-ack-absent"
        ]
    )
    @MainActor
    func invalidAutoStartAcknowledgementKeepsQueueAndCanonicalState(_ scenario: String) async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        let operation = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 1
        )
        state.cachedUser = TestFixtures.user
        state.pendingAutoStartOperations = [operation]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.autoStartBreaks)
        #expect(model.pendingAutoStartOperationCount == 1)
        #expect(model.errorMessage?.contains("Sync paused") == true)
        #expect(!model.isOffline)
        let persisted = try persistedState(defaults)
        #expect(persisted.autoStartBreaks == false)
        #expect(persisted.pendingAutoStartOperations == [operation])
    }

    @Test @MainActor
    func disabledAutoStartLeavesCompletedFocusWithoutStartingBreak() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let focus = try #require(model.canonicalTimer)

        model.finish(at: focus.anchorAt.addingTimeInterval(60))

        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.canonicalTimer?.phase == .focus)
        #expect(model.completedFocusCount == 1)
        #expect(model.pendingCommandCount == 2)
    }

    @Test @MainActor
    func timerActionsWithoutTimerAreNoOps() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.pause()
        model.resume()
        model.finish()
        model.cancel()
        model.clear()

        #expect(model.canonicalTimer == nil)
        #expect(model.history.isEmpty)
        #expect(model.pendingCommandCount == 0)
    }

    @Test func apiClientMapsServerErrorResponse() async {
        let session = TestFixtures.session(for: "server-error")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected server error")
        } catch AppError.server(let message) {
            #expect(message == "Challenge expired.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func deniedAlarmAuthorizationKeepsTimerRunningAndReportsFallback() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        scheduler.schedulingError = TimerAlarmError.authorizationDenied
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.start()
        await model.waitForAlarmOperations()

        #expect(model.canonicalTimer?.status == .running)
        #expect(model.errorMessage?.contains("Timer continues in Pomodorough") == true)
        #expect(model.errorMessage?.contains("Allow notifications or alarms in Settings") == true)
    }

    @Test @MainActor
    func clearingCancelledTimerIgnoresStaleAlarmCleanupFailure() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        var state = PersistedTimerState.fresh()
        state.canonicalTimer = TestFixtures.timer(status: .cancelled, elapsed: 10)
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)
        let timer = try #require(model.canonicalTimer)
        scheduler.cancellationError = TimerAlarmError.authorizationDenied

        model.clear()
        await model.waitForAlarmOperations()

        #expect(model.canonicalTimer == nil)
        #expect(model.errorMessage == nil)
        #expect(scheduler.operations == [.cancel(timerID: timer.id)])
    }

    @Test func apiClientMapsUnauthorizedResponse() async {
        let session = TestFixtures.session(for: "unauthorized")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected unauthorized error")
        } catch AppError.unauthorized {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func apiClientUsesFallbackForMalformedServerError() async {
        let session = TestFixtures.session(for: "fallback-server-error")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected server error")
        } catch AppError.server(let message) {
            #expect(message == "Request failed (503).")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func apiClientRejectsMalformedSuccessPayload() async {
        let session = TestFixtures.session(for: "malformed-success")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected decoding error")
        } catch is DecodingError {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func apiClientRejectsNonHTTPResponse() async {
        let session = TestFixtures.session(for: "non-http-response")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        do {
            _ = try await client.challenge()
            Issue.record("Expected invalid response error")
        } catch AppError.invalidResponse {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func revisionStreamWithoutTokensFailsBeforeNetworkRequest() async {
        let scenario = "apple-api-coverage-stream-no-tokens"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: EmptyTokenStore())

        do {
            _ = try await client.revisionEvents()
            Issue.record("Expected unauthorized error")
        } catch AppError.unauthorized {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(TestFixtures.recordedRequests(for: scenario).isEmpty)
    }

    @Test(
        arguments: [
            "non-http-response",
            "apple-api-coverage-stream-unauthorized",
            "apple-api-coverage-stream-json",
            "apple-api-coverage-stream-server-error",
            "apple-api-coverage-stream-transport"
        ]
    )
    func revisionStreamRejectsInvalidTransportResponses(_ scenario: String) async throws {
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())

        do {
            let stream = try await client.revisionEvents()
            for try await _ in stream {}
            Issue.record("Expected revision stream failure")
        } catch AppError.invalidResponse {
            #expect(scenario == "non-http-response")
        } catch AppError.unauthorized {
            #expect(scenario == "apple-api-coverage-stream-unauthorized")
        } catch AppError.server(let message) {
            let status = scenario == "apple-api-coverage-stream-json" ? 200 : 503
            #expect(message == "Invalid revision stream response (\(status)).")
        } catch let error as URLError {
            #expect(scenario == "apple-api-coverage-stream-transport")
            #expect(error.code == .networkConnectionLost)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(TestFixtures.recordedRequests(for: scenario).count == 1)
    }

    @Test func exchangeSaveFailureStopsBeforeProfileAndKeepsStoreUnchanged() async throws {
        let scenario = "apple-api-coverage-exchange-save-failure"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(failures: [.save])
        let client = APIClient(session: session, keychain: store)

        do {
            _ = try await client.exchange(NativeExchangeRequest(
                idToken: "google-id-token",
                challenge: "challenge-value",
                deviceId: "device-coverage",
                platform: "ios"
            ))
            Issue.record("Expected token save failure")
        } catch RecordingTokenStoreFailure.save {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(store.operations == [
            .save(accessToken: "exchange-access", refreshToken: "exchange-refresh")
        ])
        #expect(store.tokens == nil)
        #expect(TestFixtures.recordedRequests(for: scenario).map(\.path) == [
            "/api/v1/auth/google/exchange"
        ])
    }

    @Test func logoutServerFailurePreservesTokensWithoutDeletingStore() async throws {
        let scenario = "apple-api-coverage-logout-server-failure"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let tokens = TokenPair(
            accessToken: "logout-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "logout-refresh",
            refreshTokenExpiresAt: .distantFuture
        )
        let store = RecordingTokenStore(tokens: tokens)
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        do {
            try await client.logout()
            Issue.record("Expected logout server failure")
        } catch AppError.server(let message) {
            #expect(message == "Logout unavailable.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(store.operations == [.load])
        #expect(store.tokens?.accessToken == tokens.accessToken)
    }

    @Test func logoutDeleteFailureOccursAfterSuccessfulServerRequest() async throws {
        let scenario = "apple-api-coverage-logout-delete-failure"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(
            tokens: TokenPair(
                accessToken: "logout-access",
                accessTokenExpiresAt: .distantFuture,
                refreshToken: "logout-refresh",
                refreshTokenExpiresAt: .distantFuture
            ),
            failures: [.delete]
        )
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        do {
            try await client.logout()
            Issue.record("Expected token delete failure")
        } catch RecordingTokenStoreFailure.delete {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(store.operations == [.load, .delete])
        #expect(store.tokens?.accessToken == "logout-access")
        #expect(TestFixtures.recordedRequests(for: scenario).map(\.path) == [
            "/api/v1/auth/logout"
        ])
    }

    @Test @MainActor
    func accountDeletionStopsBeforeRemoteRequestWhenPreparedMarkerWriteFails() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Still owned"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let tokenStore = RecordingTokenStore(tokens: TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let model = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        await model.restore()
        defaults.ignoredSetKeys = ["account-deletion-state-v1"]

        await model.deleteAccount(confirmation: "DELETE")

        #expect(defaults.string(forKey: "account-deletion-state-v1") == nil)
        #expect(model.isSignedIn)
        #expect(model.tasks == [task])
        #expect(tokenStore.tokens != nil)
        #expect(!TestFixtures.recordedRequests(for: scenario).contains {
            $0.path == "/api/v1/account"
        })
    }

    @Test @MainActor
    func definitiveAccountDeletionRejectionClearsObligationAndKeepsReachableAccountState() async throws {
        let scenario = "apple-api-coverage-account-delete-rejected"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.DeleteRejected.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughDeleteRejected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = try #require(FocusTask(title: "Still reachable"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        state.pendingTaskOperations = [TaskOperation(
            id: "task-operation-delete-rejected",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_001,
            hlcCounter: 0
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let tokenStore = RecordingTokenStore(tokens: TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let journalURL = directory.appendingPathComponent("deletion.json")
        let model = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()
        model.setSceneActive(true)
        defer { model.setSceneActive(false) }
        let syncCountBeforeDeletion = TestFixtures.recordedRequests(for: scenario).count {
            $0.path == "/api/v1/sync"
        }

        await model.deleteAccount(confirmation: "DELETE")

        #expect(await TestFixtures.waitForRequest(
            in: scenario,
            path: "/api/v1/sync",
            count: syncCountBeforeDeletion + 1
        ))
        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .absent)
        #expect(model.sessionState == .signedIn(TestFixtures.user))
        #expect(model.tasks == [task])
        #expect(!model.isWorkspaceMutationBlocked)
        #expect(tokenStore.tokens != nil)
        #expect(model.errorMessage == "Deletion confirmation was rejected.")
    }

    @Test
    func accountDeletionClassifiesServerTransportAndCancellationAsOutcomeUnknown() async throws {
        for scenario in [
            "apple-api-coverage-account-delete-server-failure",
            "apple-api-coverage-account-delete-transport"
        ] {
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let client = APIClient(session: session, keychain: StaticTokenStore())
            #expect(try await client.restoreTokens())
            let outcome = await client.deleteAccount(confirmation: "DELETE")
            guard case .unknown = outcome else {
                Issue.record("Expected unknown deletion outcome for \(scenario)")
                continue
            }
        }

        let scenario = "apple-api-coverage-account-delete-cancelled"
        let session = TestFixtures.session(for: scenario)
        defer {
            TestFixtures.releaseScenario(scenario)
            session.invalidateAndCancel()
        }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())
        let deletion = Task { await client.deleteAccount(confirmation: "DELETE") }
        try #require(await TestFixtures.waitForRequest(in: scenario, path: "/api/v1/account"))
        deletion.cancel()
        guard case .unknown = await deletion.value else {
            Issue.record("Expected cancellation to leave deletion outcome unknown")
            return
        }
    }

    @Test @MainActor
    func corruptRoomMetadataRetainsDeletionMarkerWhileDiscoverableRoomSecretRemains() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.CorruptRoomDeletion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughCorruptRoomDeletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let roomURL = directory.appendingPathComponent("iroh-rooms.json")
        let journalURL = directory.appendingPathComponent("deletion.json")
        try Data("corrupt-room-metadata".utf8).write(to: roomURL)
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let malformedPrefix = "unexpected-room-credential"
        let invalidSuffix = "room-secret-v1.not-a-valid-room-id"
        let roomSecurity = RecordingKeychainSecurity(
            accountNames: ["room-secret-v1.\(roomID)", malformedPrefix, invalidSuffix],
            deleteStatusesByAccount: [invalidSuffix: errSecInteractionNotAllowed]
        )
        let roomStore = IrohRoomStore(
            fileURL: roomURL,
            secretStore: IrohRoomSecretKeychainStore(security: roomSecurity)
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let tokenStore = RecordingTokenStore(tokens: TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let model = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: roomStore,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        await model.deleteAccount(confirmation: "DELETE")

        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .record(
            .init(
                phase: .remoteCommitted,
                roomIDs: [roomID],
                roomSecretAccounts: [
                    invalidSuffix,
                    "room-secret-v1.\(roomID)",
                    malformedPrefix,
                ]
            )
        ))
        #expect(model.isWorkspaceMutationBlocked)
        #expect(roomSecurity.deleteQueries.contains { $0.account == invalidSuffix })
        #expect(roomSecurity.deleteQueries.contains { $0.account == malformedPrefix })
        #expect(roomSecurity.deleteQueries.contains { $0.account == "room-secret-v1.\(roomID)" })
    }

    @Test @MainActor
    func remoteCommittedReplacementSyncFailureDoesNotResendDeleteOnWarmRetry() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.RemoteCommitFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughRemoteCommitFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("deletion.json")
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let tokenStore = RecordingTokenStore(tokens: TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let didFailRemoteCommit = LockedTestValue(false)
        let journal = AccountDeletionJournal(fileURL: journalURL, afterReplacement: {
            guard !didFailRemoteCommit.value,
                  case .record(let record) = try AccountDeletionJournal(fileURL: journalURL).load(),
                  record.phase == .remoteCommitted else { return }
            didFailRemoteCommit.value = true
            throw CocoaError(.fileWriteUnknown)
        })
        let model = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: defaults,
            accountDeletionJournal: journal,
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        await model.deleteAccount(confirmation: "DELETE")
        await model.retryAccountDeletionRecovery()

        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .absent)
        #expect(!model.hasPendingAccountDeletionRecovery)
        #expect(TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/account"
        }.count == 1)
    }

    @Test @MainActor
    func preparedWriteObservingRemoteCommittedAdoptsStrongerPhase() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.PreparedObservesCommit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedObservesCommit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let journalURL = directory.appendingPathComponent("deletion.json")
        let injectedCommit = LockedTestValue(false)
        let journal = AccountDeletionJournal(fileURL: journalURL, beforeSave: { record in
            guard record.phase == .prepared, !injectedCommit.value else { return }
            injectedCommit.value = true
            try AccountDeletionJournal(fileURL: journalURL).save(.init(
                phase: .remoteCommitted,
                roomIDs: record.roomIDs,
                roomSecretAccounts: record.roomSecretAccounts
            ))
            throw CocoaError(.fileWriteUnknown)
        })
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            accountDeletionJournal: journal,
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        await model.deleteAccount(confirmation: "DELETE")
        await model.retryAccountDeletionRecovery()

        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .absent)
        #expect(!model.hasPendingAccountDeletionRecovery)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/account"
        })
    }

    @Test(arguments: [false, true]) @MainActor
    func preparedJournalPostReplacementSyncFailureQuarantinesWarmProcess(
        corruptsReadback: Bool
    ) async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.PreparedSyncFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughPreparedSyncFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = try #require(FocusTask(title: "Must quarantine"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let journalURL = directory.appendingPathComponent("deletion.json")
        let journal = AccountDeletionJournal(
            fileURL: journalURL,
            afterReplacement: {
                if corruptsReadback { try Data("corrupt".utf8).write(to: journalURL) }
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            accountDeletionJournal: journal,
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        await model.deleteAccount(confirmation: "DELETE")

        if corruptsReadback {
            #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .corrupt)
        } else {
            #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .record(
                .init(phase: .prepared, roomIDs: [])
            ))
        }
        #expect(model.isWorkspaceMutationBlocked)
        #expect(model.tasks.isEmpty)
        #expect(await model.addTask("Blocked") == false)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/account"
        })
    }

    @Test @MainActor
    func transientAmbiguousDeletionRetriesInSameProcess() async throws {
        let scenario = "apple-api-coverage-account-delete-transient"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.DeleteSameProcessRetry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughDeleteSameProcessRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let journalURL = directory.appendingPathComponent("deletion.json")
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()
        await model.deleteAccount(confirmation: "DELETE")
        #expect(model.hasPendingAccountDeletionRecovery)

        await model.retryAccountDeletionRecovery()

        #expect(!model.hasPendingAccountDeletionRecovery)
        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .absent)
        #expect(TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/account"
        }.count == 2)
    }

    @Test @MainActor
    func corruptJournalRetryPromotesRecoveredRoomObligationInSameProcess() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.CorruptDeleteRetry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughCorruptDeleteRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("deletion.json")
        try Data("corrupt".utf8).write(to: journalURL)
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let secretStore = MemoryIrohRoomSecretStore(secrets: [roomID: secret])
        secretStore.setDeleteFailure(true, roomID: roomID)
        let roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("rooms.json"), secretStore: secretStore
        )
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("workspace.json")
            ),
            roomStore: roomStore,
            alarmScheduler: RecordingAlarmScheduler()
        )
        #expect(model.hasPendingAccountDeletionRecovery)

        await model.retryAccountDeletionRecovery()

        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .record(
            .init(
                phase: .remoteCommitted,
                roomIDs: [roomID],
                roomSecretAccounts: ["room-secret-v1.\(roomID)"]
            )
        ))
        #expect(model.hasPendingAccountDeletionRecovery)
        #expect(model.isWorkspaceMutationBlocked)
    }

    @Test @MainActor
    func ambiguousAccountDeletionFailureStaysQuarantinedAndRetriesAfterRestart() async throws {
        let scenario = "apple-api-coverage-account-delete-server-failure"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughAmbiguousDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("deletion.json")
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        let task = try #require(FocusTask(title: "Quarantined account task"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let tokenStore = RecordingTokenStore(tokens: TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let identity = RecordingGoogleIdentityProvider()
        let model = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL),
            durableLocalStore: AtomicDurableFileStore(fileURL: workspaceURL),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: identity
        )
        await model.restore()
        let syncCallsBeforeDeletion = TestFixtures.recordedRequests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }.count

        await model.deleteAccount(confirmation: "DELETE")

        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .record(
            .init(phase: .prepared, roomIDs: [])
        ))
        #expect(model.sessionState == .localOnly)
        #expect(model.tasks.isEmpty)
        #expect(tokenStore.tokens != nil)
        let quarantinedBytes = defaults.data(forKey: "timer-state-v2")
        model.start()
        #expect(await model.addTask("Blocked task") == false)
        model.signIn()
        await model.setReplicationMode(.offline)
        #expect(await model.createIrohRoom(name: "Blocked room") == false)
        #expect(await model.joinIrohRoom(inviteText: "blocked") == false)
        await model.syncIrohNow()
        await model.refreshAfterForeground()
        model.setSceneActive(true)
        #expect(identity.nonces.isEmpty)
        #expect(defaults.data(forKey: "timer-state-v2") == quarantinedBytes)

        let restarted = AppModel(
            api: APIClient(session: session, keychain: tokenStore),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL),
            durableLocalStore: AtomicDurableFileStore(fileURL: workspaceURL),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        #expect(restarted.tasks.isEmpty)
        await restarted.restore()

        #expect(try AccountDeletionJournal(fileURL: journalURL).load() == .record(
            .init(phase: .prepared, roomIDs: [])
        ))
        #expect(restarted.sessionState == .localOnly)
        #expect(restarted.tasks.isEmpty)
        #expect(tokenStore.tokens != nil)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.filter { $0.path == "/api/v1/sync" }.count == syncCallsBeforeDeletion)
        #expect(requests.filter { $0.path == "/api/v1/account" }.count == 2)
    }

    @Test(
        arguments: [
            "apple-api-coverage-bootstrap-nonempty-timer-ack",
            "apple-api-coverage-bootstrap-nonempty-task-ack",
            "apple-api-coverage-bootstrap-nonempty-duration-ack",
            "apple-api-coverage-bootstrap-nonempty-auto-start-ack",
            "apple-api-coverage-bootstrap-nonempty-selected-task-ack"
        ]
    )
    func bootstrapRejectsEveryNonemptyAcknowledgementList(_ scenario: String) async throws {
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())

        do {
            _ = try await client.bootstrap(emptySyncRequest())
            Issue.record("Expected invalid bootstrap acknowledgement")
        } catch AppError.invalidResponse {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        arguments: [
            "apple-api-coverage-bootstrap-malformed-2xx",
            "apple-api-coverage-bootstrap-resolve-malformed-2xx",
            "apple-api-coverage-sync-malformed-2xx"
        ]
    )
    func malformedSuccessfulSyncPayloadsTranslateToInvalidResponse(_ scenario: String) async throws {
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())

        do {
            if scenario.contains("bootstrap-resolve") {
                _ = try await client.resolveBootstrap(BootstrapResolveRequest(
                    requestId: "coverage-resolution",
                    deviceId: "coverage-device",
                    expectedRevision: 1,
                    strategy: .keepRemote,
                    commands: [],
                    taskOperations: [],
                    durationOperations: [],
                    autoStartOperations: []
                ))
            } else if scenario.contains("bootstrap-malformed") {
                _ = try await client.bootstrap(emptySyncRequest())
            } else {
                _ = try await client.sync(emptySyncRequest())
            }
            Issue.record("Expected invalid response")
        } catch AppError.invalidResponse {
            // Expected error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func bootstrapRevisionConflictPreservesLocalDataAndReturnsToChooser() async throws {
        let scenario = "bootstrap-cas-conflict"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
            TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
        ]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        model.requestHistoryResolution(.keepRemote)
        await model.confirmHistoryResolution()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.history.map(\.id) == ["local-timer"])
        #expect(model.pendingCommandCount == 2)
        let persistedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let persisted = try JSONDecoder.api.decode(PersistedTimerState.self, from: persistedData)
        #expect(persisted.cachedUser == nil)
        #expect(persisted.pendingBootstrapResolution == nil)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 2)
        #expect(requests.count { $0.path == "/api/v1/bootstrap/resolve" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func missingTaskAcknowledgementPreservesQueueAndCanonicalState() async throws {
        let scenario = "task-missing-ack"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Local task"))
        let operation = TaskOperation(
            id: "task-operation-missing-ack",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002,
            hlcCounter: 0
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.pendingTaskOperations = [operation]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.pendingChangeCount == 1)
        #expect(model.tasks == [task])
        #expect(model.history.isEmpty)
        #expect(model.errorMessage?.contains("1 queued change remains") == true)
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        let persisted = try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        #expect(persisted.pendingTaskOperations == [operation])
    }

    @Test @MainActor
    func persistedBootstrapResolutionBlocksMutationsBeforeAndWithoutAuthentication() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(keychain: EmptyTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(model.isHistoryResolutionBlocking)
        #expect(model.historyResolutionState == .retryable(.merge))
        let pendingCount = model.pendingChangeCount
        let selectedPhase = model.selectedPhase
        let autoStartBreaks = model.autoStartBreaks
        let selectedTaskID = model.selectedTaskID
        let taskID = try #require(model.tasks.first?.id)

        model.start()
        model.setDurationMinutes(90, for: .focus)
        #expect(!(await model.addTask("Blocked task")))
        model.deleteTask(id: taskID)
        model.selectedPhase = .longBreak
        model.autoStartBreaks.toggle()
        model.selectedTaskID = taskID

        #expect(model.pendingChangeCount == pendingCount)
        #expect(model.selectedPhase == selectedPhase)
        #expect(model.autoStartBreaks == autoStartBreaks)
        #expect(model.selectedTaskID == selectedTaskID)

        await model.restore()

        #expect(model.sessionState == .localOnly)
        #expect(model.isHistoryResolutionBlocking)
        #expect(try persistedState(defaults) == initial)
    }

    @Test @MainActor
    func signedOutLocalStateWithoutBootstrapResolutionRemainsMutable() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            api: APIClient(keychain: EmptyTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()
        #expect(!model.isHistoryResolutionBlocking)
        model.setDurationMinutes(1, for: .focus)
        #expect(await model.addTask("Usable local task"))
        model.start()

        #expect(model.sessionState == .localOnly)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.pendingCommandCount == 1)
        #expect(model.pendingDurationOperationCount == 1)
        #expect(model.tasks.map(\.title) == ["Usable local task"])
    }

    @Test @MainActor
    func persistedBootstrapResolutionBlocksMutationsWhileProfileVerificationIsDelayed() async throws {
        let scenario = "bootstrap-delayed-me"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/me" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/me" })
        #expect(model.isHistoryResolutionBlocking)
        let pendingCount = model.pendingChangeCount

        model.start()
        model.setDurationMinutes(90, for: .focus)
        #expect(!(await model.addTask("Blocked during profile verification")))
        #expect(model.pendingChangeCount == pendingCount)
        await model.retryHistoryResolution()
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
        #expect(try persistedState(defaults).pendingBootstrapResolution == request)

        await restoreTask.value

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try decodedResolutionRequest(resolve) == request)
        #expect(model.historyResolutionState == .none)
    }

    @Test(
        arguments: [
            "bootstrap-response-missing-tasks",
            "bootstrap-response-task-ack-malformed",
            "bootstrap-response-task-ack-missing",
            "bootstrap-response-task-ack-duplicate",
            "bootstrap-response-task-ack-extra",
            "bootstrap-response-task-ack-absent",
            "bootstrap-response-timer-ack-malformed",
            "bootstrap-response-timer-ack-missing",
            "bootstrap-response-timer-ack-duplicate",
            "bootstrap-response-timer-ack-extra",
            "bootstrap-response-timer-ack-absent",
            "bootstrap-response-duration-ack-malformed",
            "bootstrap-response-duration-ack-missing",
            "bootstrap-response-duration-ack-duplicate",
            "bootstrap-response-duration-ack-extra",
            "bootstrap-response-duration-ack-absent",
            "bootstrap-response-auto-start-ack-malformed",
            "bootstrap-response-auto-start-ack-missing",
            "bootstrap-response-auto-start-ack-duplicate",
            "bootstrap-response-auto-start-ack-extra",
            "bootstrap-response-auto-start-ack-absent"
        ]
    )
    @MainActor
    func invalidBootstrapResolutionResponsePreservesEntirePersistedClaim(_ scenario: String) async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(.merge))
        #expect(model.isHistoryResolutionBlocking)
        #expect(model.pendingChangeCount == 5)
        #expect(try persistedState(defaults) == initial)
        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try decodedResolutionRequest(resolve) == request)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func bootstrapResolveUnauthorizedSurvivesSignOutAndSameUserReauthenticationWithExactRequest() async throws {
        let scenario = "bootstrap-resolve-unauthorized"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")

        do {
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(session: session, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )

            await model.restore()

            #expect(model.sessionState == .localOnly)
            #expect(model.historyResolutionState == .retryable(.merge))
            #expect(model.isHistoryResolutionBlocking)
            #expect(!model.isWorking)
            #expect(try persistedState(defaults) == initial)
            model.signOut()
            #expect(try persistedState(defaults) == initial)
        }

        let firstResolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try decodedResolutionRequest(firstResolve) == request)
        let secondSession = TestFixtures.session(for: scenario, resetsRecorder: false)
        defer { secondSession.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: secondSession, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await restored.restore()

        let resolves = TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/bootstrap/resolve"
        }
        #expect(resolves.count == 2)
        #expect(resolves[0].body == resolves[1].body)
        #expect(try decodedResolutionRequest(resolves[1]) == request)
        #expect(restored.historyResolutionState == .none)
        #expect(!restored.isHistoryResolutionBlocking)
        #expect(try persistedState(defaults).cachedUser == TestFixtures.user)
    }

    @Test @MainActor
    func bootstrapResolve404PreservesExactPersistedClaimWithoutSyncFallback() async throws {
        let scenario = "bootstrap-resolve-404"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        let request = try #require(initial.pendingBootstrapResolution)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(.merge))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isOffline)
        #expect(model.errorMessage?.contains("server update") == true)
        #expect(model.history.map(\.id) == ["local-timer"])
        #expect(model.pendingChangeCount == 5)
        let persisted = try persistedState(defaults)
        #expect(persisted == initial)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap/resolve" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
        let resolve = try #require(requests.first { $0.path == "/api/v1/bootstrap/resolve" })
        #expect(try decodedResolutionRequest(resolve) == request)
    }

    @Test @MainActor
    func bootstrapGet404RequiresExplicitUpdateRetryWithoutAutomaticLoop() async throws {
        let scenario = "bootstrap-get-404"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try unresolvedBootstrapState()
        initial.pendingBootstrapResolution = nil
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            retryDelay: .milliseconds(10)
        )

        await model.restore()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.historyResolutionState == .retryable(nil))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isOffline)
        #expect(model.errorMessage?.contains("server update") == true)
        #expect(try persistedState(defaults) == initial)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(requests.allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve" && $0.path != "/api/v1/sync"
        })
    }

    @Test @MainActor
    func replaceRemote404RaceNeverFallsBackToSyncOrClearsLocalQueues() async throws {
        let scenario = "bootstrap-resolve-race-404"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try unresolvedBootstrapState()
        initial.pendingBootstrapResolution = nil
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .retryable(.replaceRemote))
        #expect(model.isHistoryResolutionBlocking)
        #expect(!model.isOffline)
        #expect(model.errorMessage?.contains("server update") == true)
        #expect(model.history.map(\.id) == ["local-timer"])
        #expect(model.pendingChangeCount == 5)
        let persisted = try persistedState(defaults)
        let request = try #require(persisted.pendingBootstrapResolution)
        #expect(request.strategy == .replaceRemote)
        #expect(request.commands == initial.pendingCommands)
        #expect(request.taskOperations == initial.pendingTaskOperations)
        #expect(request.durationOperations == initial.pendingDurationOperations)
        #expect(persisted.bootstrapUser == initial.bootstrapUser)
        #expect(persisted.cachedUser == nil)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(requests.count { $0.path == "/api/v1/bootstrap/resolve" } == 1)
        #expect(requests.allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func verifiedDifferentUserClearsOldResolutionBeforeAnyBootstrapRequest() async throws {
        let scenario = "bootstrap-reauth-different-user"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try unresolvedBootstrapState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/me" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/me" })
        await model.retryHistoryResolution()
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
        #expect(try persistedState(defaults) == initial)

        await restoreTask.value

        let persisted = try persistedState(defaults)
        #expect(persisted.bootstrapUser?.id == "different-bootstrap-user")
        #expect(persisted.pendingBootstrapResolution == nil)
        #expect(persisted.cachedUser == nil)
        #expect(persisted.pendingCommands == initial.pendingCommands)
        #expect(model.historyResolutionState == .choosing)
        #expect(model.isHistoryResolutionBlocking)
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.contains { $0.path == "/api/v1/bootstrap" })
        #expect(requests.allSatisfy { $0.path != "/api/v1/bootstrap/resolve" })
    }

    @Test @MainActor
    func persistedBootstrapRejectsForeignAutoStartOperationBeforeUpload() async throws {
        let scenario = "bootstrap-auto-start-foreign-device"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        let foreignOperation = TestFixtures.autoStartOperation(
            deviceID: "device-foreign",
            enabled: true,
            wallMs: 1
        )
        let request = BootstrapResolveRequest(
            requestId: "bootstrap-foreign-auto-start",
            deviceId: state.deviceId,
            expectedRevision: 8,
            strategy: .merge,
            commands: [],
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: [foreignOperation]
        )
        state.bootstrapUser = TestFixtures.user
        state.pendingBootstrapResolution = request
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.contains { $0.path == "/api/v1/me" })
        #expect(requests.allSatisfy { $0.path != "/api/v1/bootstrap/resolve" })
        #expect(model.historyResolutionState == .retryable(.merge))
        #expect(model.errorMessage?.contains("invalid response") == true)
        #expect(try persistedState(defaults).pendingBootstrapResolution == request)
    }

    @Test @MainActor
    func lowerRevisionNormalSyncResponseIsRejectedAtomically() async throws {
        let scenario = "sync-contract-revision-lower"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = TestFixtures.syncContractState(includesPendingOperations: false)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(try persistedState(defaults) == initial)
        #expect(model.canonicalTimer == initial.canonicalTimer)
        #expect(model.tasks == initial.tasks)
        #expect(model.durationMinutes(for: .focus) == 25)
        #expect(!model.autoStartBreaks)
        #expect(model.errorMessage?.contains("Sync paused") == true)
        #expect(!model.isOffline)
    }

    @Test @MainActor
    func unsafeRevisionNormalSyncResponseIsRejectedAtomically() async throws {
        let scenario = "sync-contract-revision-unsafe"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = TestFixtures.syncContractState(includesPendingOperations: false)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(try persistedState(defaults) == initial)
        #expect(model.errorMessage?.contains("Sync paused") == true)
    }

    @Test @MainActor
    func invalidCanonicalTimerNormalSyncResponseIsRejectedAtomically() async throws {
        let scenario = "sync-contract-canonical-invalid"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = TestFixtures.syncContractState(includesPendingOperations: false)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(try persistedState(defaults) == initial)
        #expect(model.canonicalTimer == initial.canonicalTimer)
        #expect(model.tasks == initial.tasks)
        #expect(model.errorMessage?.contains("Sync paused") == true)
        #expect(!model.isOffline)
    }

    @Test(arguments: ["timer", "task", "duration"])
    @MainActor
    func unknownAcknowledgementOutcomeRejectsWholeResponseAtomically(_ acknowledgementType: String) async throws {
        let scenario = "sync-contract-unknown-\(acknowledgementType)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = TestFixtures.syncContractState(includesPendingOperations: true)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(try persistedState(defaults) == initial)
        #expect(model.pendingChangeCount == 12)
        #expect(model.errorMessage?.contains("12 queued changes remain") == true)
        #expect(!model.isOffline)
    }

    @Test @MainActor
    func taskWriteFailsClosedBeforePersistenceWhenSharedCoreIsUnavailable() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        let persistedBefore = defaults.data(forKey: "timer-state-v2")
        let pendingBefore = model.pendingChangeCount

        #expect(!(await model.addTask("Must not persist")))

        #expect(model.tasks.isEmpty)
        #expect(model.pendingChangeCount == pendingBefore)
        #expect(defaults.data(forKey: "timer-state-v2") == persistedBefore)
        #expect(model.errorMessage != nil)
    }

    @Test @MainActor
    func synchronizedWritesRollBackBeforePersistenceWhenProjectionCoreIsUnavailable() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = PersistedTimerState.fresh()
        let task = try #require(FocusTask(title: "Must remain"))
        initial.tasks = [task]
        initial.knownTasks = [task]
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        defaults.resetTimerStateWrites()
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            sharedCoreProvider: { throw SharedCoreError.resourceMissing }
        )
        defaults.resetTimerStateWrites()

        model.start()
        model.setDurationMinutes(30, for: .focus)
        model.autoStartBreaks = true
        model.selectedTaskID = task.id
        model.deleteTask(id: task.id)

        #expect(try persistedState(defaults) == initial)
        #expect(defaults.timerStateWrites.isEmpty)
        #expect(model.pendingChangeCount == 0)
        #expect(model.tasks == [task])
        #expect(model.errorMessage != nil)
    }

    private func unresolvedBootstrapState() throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        let task = try #require(FocusTask(title: "Persisted task"))
        let commands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
            TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
        ]
        let taskOperations = [TaskOperation(
            id: "task-operation-persisted",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002,
            hlcCounter: 0
        )]
        let durationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-persisted",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 3
        )]
        let autoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 4
        )]
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = commands
        state.pendingTaskOperations = taskOperations
        state.pendingDurationOperations = durationOperations
        state.pendingAutoStartOperations = autoStartOperations
        state.knownTasks = [task]
        state.settings.setMinutes(30, for: .focus)
        state.pendingBootstrapResolution = BootstrapResolveRequest(
            requestId: "bootstrap-resolution-persisted",
            deviceId: state.deviceId,
            expectedRevision: 8,
            strategy: .merge,
            commands: commands,
            taskOperations: taskOperations,
            durationOperations: durationOperations,
            autoStartOperations: autoStartOperations
        )
        return state
    }

    private func persistedState(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    private func decodedResolutionRequest(_ request: RecordedRequest) throws -> BootstrapResolveRequest {
        let data = try #require(request.body)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let deviceID = object["deviceId"] as? String,
           let operations = object["autoStartOperations"] as? [[String: Any]] {
            object["autoStartOperations"] = operations.map { operation in
                var operation = operation
                operation["deviceId"] = deviceID
                return operation
            }
        }
        return try JSONDecoder.api.decode(
            BootstrapResolveRequest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func emptySyncRequest() -> SyncRequest {
        SyncRequest(
            deviceId: "coverage-device",
            lastRevision: 0,
            commands: [],
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: []
        )
    }

    @Test func authenticatedIrohFrameDoesNotBypassStrictJSONValidation() throws {
        let secret = Data(0...31)
        let duplicateKeyBody = Data(#"{"kind":"hello","kind":"inventory"}"#.utf8)
        let received = try IrohFrameCodec.decode(
            try IrohFrameCodec.encode(body: duplicateKeyBody, roomSecret: secret),
            roomSecret: secret
        )

        #expect(throws: IrohProtocolError.self) {
            try StrictJSON.object(from: received)
        }
    }

    @Test @MainActor
    func corruptCurrentPersistenceDoesNotRestoreOrOverwriteStaleLegacyWorkspace() throws {
        let suiteName = "IntegrationNegativeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var staleLegacy = PersistedTimerState.fresh()
        staleLegacy.deviceId = "stale-legacy-device"
        let staleTask = try #require(FocusTask(title: "Must not resurrect"))
        staleLegacy.tasks = [staleTask]
        staleLegacy.knownTasks = [staleTask]
        defaults.set(
            try JSONEncoder.api.encode(staleLegacy),
            forKey: PersistedStateLoader.legacyStorageKey
        )
        let corruptCurrent = Data(#"{\"deviceId\":17,\"pendingCommands\":\"invalid\"}"#.utf8)
        defaults.set(corruptCurrent, forKey: PersistedStateLoader.storageKey)

        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(model.tasks.isEmpty)
        #expect(model.pendingChangeCount == 0)
        #expect(defaults.data(forKey: PersistedStateLoader.storageKey) == corruptCurrent)
        #expect(defaults.data(forKey: PersistedStateLoader.legacyStorageKey) != nil)
    }
}
