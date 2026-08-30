import Foundation
import Testing
@testable import Pomodorough

@Suite("Integration Positive")
struct IntegrationPositiveTests {
    @Test @MainActor
    func appModelSignInUsesInjectedGoogleIdentityProvider() async throws {
        let scenario = "apple-api-coverage-model-sign-in"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore()
        let identity = RecordingGoogleIdentityProvider()
        identity.identityTokenResult = .success("injected-id-token")
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: store),
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
        #expect(model.user == TestFixtures.user)
        let exchange = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/auth/google/exchange"
        })
        let body = try #require(exchange.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["idToken"] as? String == "injected-id-token")
        #expect(object["challenge"] as? String == "model-challenge")

        let callback = try #require(URL(string: "com.example:/oauth2callback?code=value"))
        #expect(PomodoroughApp.handleGoogleSignInURL(callback, model: model))
        #expect(identity.handledURLs == [callback])
        model.signOut()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isWorking)
        #expect(identity.signOutCount == 1)
    }

    @Test @MainActor
    func localSignOutPublishesDespiteActiveCredentialDeleteFailure() async throws {
        let scenario = "apple-api-coverage-model-local-signout"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(failures: [.delete])
        let identity = RecordingGoogleIdentityProvider()
        identity.identityTokenResult = .success("injected-id-token")
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: store),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: identity
        )

        model.signIn()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isSignedIn)

        model.signOut()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.sessionState == .localOnly)
        #expect(model.user == nil)
        #expect(model.errorMessage == nil)
        #expect(identity.signOutCount == 1)
        let pending: [LogoutRevocationObligation] = try store.load()
        #expect(!pending.isEmpty)
        #expect(store.tokens != nil)
        store.replaceFailures([])
        for _ in 0..<600 {
            let remaining: [LogoutRevocationObligation] = try store.load()
            if remaining.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let remaining: [LogoutRevocationObligation] = try store.load()
        #expect(remaining.isEmpty)
        #expect(store.tokens == nil)
    }

    @Test @MainActor
    func accountSwitchRequiresDurableConfirmationBeforeRemovingOrMutatingLocalWorkspace() async throws {
        let scenario = "apple-api-coverage-model-sign-in"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldUser = User(id: "old-user", email: "old@example.com", name: "Old", avatarUrl: "")
        let oldTask = try #require(FocusTask(title: "Previous account task"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = oldUser
        state.tasks = [oldTask]
        state.knownTasks = [oldTask]
        state.history = [TestFixtures.history(
            id: "previous-account-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor,
            taskID: oldTask.id.uuidString.lowercased()
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: RecordingTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )

        model.signIn()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.user == TestFixtures.user)
        #expect(model.tasks == [oldTask])
        #expect(model.history.map(\.id) == ["previous-account-history"])
        #expect(!(await model.addTask("Must remain blocked")))
        let persistedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let persisted = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
        let pendingUser = try #require(persisted["pendingAccountSwitchUser"] as? [String: Any])
        #expect(pendingUser["id"] as? String == TestFixtures.user.id)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })

        let relaunched = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(relaunched.tasks == [oldTask])
        #expect(!(await relaunched.addTask("Still blocked after relaunch")))
    }

    @Test @MainActor
    func cancellingAccountSwitchKeepsPreviousWorkspaceAndClearsDurablePrompt() async throws {
        let scenario = "apple-api-coverage-model-sign-in"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldUser = User(id: "old-user", email: "old@example.com", name: "Old", avatarUrl: "")
        let oldTask = try #require(FocusTask(title: "Previous account task"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = oldUser
        state.tasks = [oldTask]
        state.knownTasks = [oldTask]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: RecordingTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        model.signIn()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        await model.cancelAccountSwitch()

        #expect(model.sessionState == .localOnly)
        #expect(model.tasks == [oldTask])
        #expect(try persistedState(defaults).pendingAccountSwitchUser == nil)
        let relaunched = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(relaunched.tasks == [oldTask])
        #expect(relaunched.pendingAccountSwitchUser == nil)
        #expect(await relaunched.addTask("Local work resumes"))
    }

    @Test @MainActor
    func confirmingAccountSwitchDurablyRemovesPreviousWorkspaceBeforeSyncing() async throws {
        let scenario = "apple-api-coverage-model-sign-in"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldUser = User(id: "old-user", email: "old@example.com", name: "Old", avatarUrl: "")
        let oldTask = try #require(FocusTask(title: "Previous account task"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = oldUser
        state.tasks = [oldTask]
        state.knownTasks = [oldTask]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: RecordingTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
        model.signIn()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        await model.confirmAccountSwitch()

        let persisted = try persistedState(defaults)
        #expect(persisted.cachedUser == TestFixtures.user)
        #expect(persisted.pendingAccountSwitchUser == nil)
        #expect(!persisted.knownTasks.contains(oldTask))
        #expect(!model.tasks.contains(oldTask))
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/sync" })
        let relaunched = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!relaunched.tasks.contains(oldTask))
        #expect(relaunched.pendingAccountSwitchUser == nil)
    }

    @Test @MainActor
    func timerCommandAllocationReachesMaxSafeSequenceExactly() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.nextSequence = WireBounds.maxSafeInteger
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { occurrence }
        )

        model.start()

        let persisted = try persistedState(defaults)
        #expect(persisted.pendingCommands.map(\.deviceSequence) == [WireBounds.maxSafeInteger])
        #expect(persisted.nextSequence == WireBounds.maxSafeInteger)
        #expect(persisted.sequenceExhausted)
        #expect(model.canonicalTimer?.status == .running)
    }

    @Test @MainActor
    func automaticFinishAndBreakCanAtomicallyConsumeLastTwoSequences() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.nextSequence = WireBounds.maxSafeInteger - 1
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

        let persisted = try persistedState(defaults)
        #expect(persisted.pendingCommands.map(\.deviceSequence) == [
            WireBounds.maxSafeInteger - 1,
            WireBounds.maxSafeInteger
        ])
        let commandIds = try persisted.pendingCommands.map {
            try #require(UUIDv7.payload(from: $0.id))
        }
        #expect(UUIDv7.isLess(commandIds[0], than: commandIds[1]))
        #expect(persisted.lastUuidV7 == commandIds[1])
        #expect(persisted.sequenceExhausted)
        #expect(persisted.provisionalBreaks.count == 1)
        #expect(defaults.timerStateWrites.count == 1)
        #expect(model.canonicalTimer?.phase == .shortBreak)
    }

    @Test @MainActor
    func trustedServerOffsetAlignsGeneratorsPersistsAndIgnoresWallJumps() async throws {
        for deviceSkewSeconds in [-3_600, 3_600] {
            let scenario = "duration-sync"
            let suiteName = "PomodoroughTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let serverTime = Date(timeIntervalSince1970: 1_784_620_800)
            let wallClock = LockedTestValue(
                serverTime.addingTimeInterval(TimeInterval(deviceSkewSeconds))
            )
            let uptime = LockedTestValue<TimeInterval>(1_000)
            var state = PersistedTimerState.fresh()
            state.cachedUser = TestFixtures.user
            defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(
                    session: session,
                    keychain: StaticTokenStore(),
                    wallNow: { wallClock.value },
                    uptime: { uptime.value }
                ),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler(),
                now: { wallClock.value },
                uptime: { uptime.value }
            )

            await model.restore()

            var persisted = try persistedState(defaults)
            #expect(persisted.serverTimeOffsetMs == Int64(-deviceSkewSeconds * 1_000))
            #expect(persisted.serverTimeUncertaintyMs == 0)
            let localModel = AppModel(
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler(),
                now: { wallClock.value },
                uptime: { uptime.value }
            )
            localModel.start()
            #expect(await localModel.addTask("Trusted task \(deviceSkewSeconds)"))
            localModel.setDurationMinutes(30, for: .focus)
            localModel.autoStartBreaks = true
            persisted = try persistedState(defaults)
            let command = try #require(persisted.pendingCommands.first)
            let taskOperation = try #require(persisted.pendingTaskOperations.first)
            let durationOperation = try #require(persisted.pendingDurationOperations.first)
            let autoStartOperation = try #require(persisted.pendingAutoStartOperations.first)
            let generatedIds = try [
                command.id,
                taskOperation.id,
                durationOperation.id,
                autoStartOperation.id.uuidString
            ].map { try #require(UUIDv7.payload(from: $0)) }
            #expect(zip(generatedIds, generatedIds.dropFirst()).allSatisfy { pair in
                UUIDv7.isLess(pair.0, than: pair.1)
            })
            #expect(persisted.lastUuidV7 == autoStartOperation.id)
            let operationDates = [
                command.occurredAt,
                taskOperation.occurredAt,
                durationOperation.occurredAt,
                autoStartOperation.occurredAt
            ]
            #expect(operationDates.allSatisfy { abs($0.timeIntervalSince(serverTime)) < 1 })
            #expect(localModel.canonicalTimer?.anchorAt == wallClock.value)

            wallClock.value = wallClock.value.addingTimeInterval(6 * 3_600)
            uptime.value += 1
            #expect(await localModel.addTask("After forward jump \(deviceSkewSeconds)"))
            wallClock.value = wallClock.value.addingTimeInterval(-12 * 3_600)
            uptime.value += 1
            #expect(await localModel.addTask("After rollback \(deviceSkewSeconds)"))
            persisted = try persistedState(defaults)
            let jumpedDates = persisted.pendingTaskOperations.suffix(2).map(\.occurredAt)
            #expect(jumpedDates == [
                serverTime.addingTimeInterval(1),
                serverTime.addingTimeInterval(2)
            ])

            wallClock.value = serverTime
                .addingTimeInterval(TimeInterval(deviceSkewSeconds))
                .addingTimeInterval(2)
            let restored = AppModel(
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler(),
                now: { wallClock.value },
                uptime: { uptime.value }
            )
            #expect(await restored.addTask("After restart \(deviceSkewSeconds)"))
            let restoredState = try persistedState(defaults)
            #expect(restoredState.serverTimeOffsetMs == persisted.serverTimeOffsetMs)
            #expect(restoredState.serverTimeUncertaintyMs == persisted.serverTimeUncertaintyMs)
            #expect(restoredState.pendingTaskOperations.last?.occurredAt == serverTime.addingTimeInterval(2))
            #expect(restored.canonicalTimer?.anchorAt == persisted.localCommandDates[command.id])
        }
    }

    @Test @MainActor
    func optimisticTimerWorkflowSurvivesPersistenceRoundTrip() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.setDurationMinutes(1, for: .focus)
        model.start()
        let started = try #require(model.canonicalTimer)
        model.pause(at: started.anchorAt.addingTimeInterval(10))

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let paused = try #require(restored.canonicalTimer)
        #expect(paused.status == .paused)
        #expect(paused.elapsedAtAnchorMs == 10_000)
        #expect(restored.pendingCommandCount == 2)

        restored.resume(at: paused.anchorAt.addingTimeInterval(5))
        let resumed = try #require(restored.canonicalTimer)
        restored.finish(at: resumed.anchorAt.addingTimeInterval(20))

        let finalModel = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(finalModel.canonicalTimer?.status == .completed)
        #expect(finalModel.canonicalTimer?.elapsedAtAnchorMs == 60_000)
        #expect(finalModel.history.count == 1)
        #expect(finalModel.pendingCommandCount == 4)
    }

    @Test @MainActor
    func idleConfigurationSurvivesPersistenceRoundTrip() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.selectedPhase = .longBreak
        model.setDurationMinutes(45, for: .longBreak)
        model.autoStartBreaks = true

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.selectedPhase == .longBreak)
        #expect(restored.durationMinutes(for: .longBreak) == 45)
        #expect(restored.autoStartBreaks)
    }

    @Test @MainActor
    func durationEditsClampCompactPersistAndIgnoreNoOps() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.setDurationMinutes(25, for: .focus)
        #expect(defaults.data(forKey: "timer-state-v2") == nil)

        model.setDurationMinutes(1, for: .focus)
        let firstData = try #require(defaults.data(forKey: "timer-state-v2"))
        let firstState = try JSONDecoder.api.decode(PersistedTimerState.self, from: firstData)
        let firstOperation = try #require(firstState.pendingDurationOperations.first)
        model.setDurationMinutes(0, for: .focus)
        #expect(defaults.data(forKey: "timer-state-v2") == firstData)

        model.setDurationMinutes(999, for: .focus)
        model.setDurationMinutes(10, for: .shortBreak)
        let finalData = try #require(defaults.data(forKey: "timer-state-v2"))
        let finalState = try JSONDecoder.api.decode(PersistedTimerState.self, from: finalData)
        let focusOperation = try #require(finalState.pendingDurationOperations.first { $0.phase == .focus })

        #expect(finalState.pendingDurationOperations.count == 2)
        #expect(focusOperation.id != firstOperation.id)
        #expect((focusOperation.hlcWallMs, focusOperation.hlcCounter) > (firstOperation.hlcWallMs, firstOperation.hlcCounter))
        #expect(focusOperation.hlcWallMs > 0)
        #expect(focusOperation.durationMs == 180 * 60_000)
        #expect(model.durationMinutes(for: .focus) == 180)
        #expect(model.pendingDurationOperationCount == 2)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.durationMinutes(for: .focus) == 180)
        #expect(restored.durationMinutes(for: .shortBreak) == 10)
        #expect(restored.pendingDurationOperationCount == 2)
    }

    @Test @MainActor
    func legacyDurationMigrationQueuesOnlyNonDefaultPhasesOnce() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let json = Data(
            #"{"deviceId":"device-legacy","nextSequence":1,"revision":0,"pendingCommands":[],"pendingTaskOperations":[],"canonicalTimer":null,"history":[],"settings":{"selectedPhase":"long_break","focusMinutes":25,"shortBreakMinutes":7,"longBreakMinutes":30,"autoStartBreaks":true}}"#.utf8
        )
        defaults.set(json, forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let migratedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let migrated = try JSONDecoder.api.decode(PersistedTimerState.self, from: migratedData)

        #expect(Set(migrated.pendingDurationOperations.map(\.phase)) == [.shortBreak, .longBreak])
        #expect(migrated.pendingDurationOperations.first { $0.phase == .shortBreak }?.durationMs == Int64(7 * 60_000))
        #expect(migrated.pendingDurationOperations.first { $0.phase == .longBreak }?.durationMs == Int64(30 * 60_000))
        #expect(migrated.pendingDurationOperations.allSatisfy {
            $0.hlcWallMs == 0
                && $0.hlcCounter == 0
                && $0.occurredAt == Date(timeIntervalSince1970: 0)
                && $0.isValid
        })
        #expect(migrated.pendingAutoStartOperations.count == 1)
        #expect(migrated.pendingAutoStartOperations.first?.enabled == true)
        #expect(migrated.pendingAutoStartOperations.first?.deviceId == "device-legacy")
        #expect(model.selectedPhase == .longBreak)
        #expect(model.autoStartBreaks)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.pendingDurationOperationCount == 2)
    }

    @Test @MainActor
    func legacyStorageKeyRestoresMigratedStateAcrossRelaunch() throws {
        let suiteName = "IntegrationPositiveTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = Data(
            #"{"deviceId":"legacy-key-device","nextSequence":1,"revision":7,"pendingCommands":[],"pendingTaskOperations":[],"canonicalTimer":null,"history":[],"settings":{"focusMinutes":40,"shortBreakMinutes":5,"longBreakMinutes":15,"autoStartBreaks":false}}"#.utf8
        )
        defaults.set(legacy, forKey: PersistedStateLoader.legacyStorageKey)

        let migrated = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(migrated.durationMinutes(for: .focus) == 40)
        #expect(migrated.pendingDurationOperationCount == 1)
        #expect(defaults.data(forKey: PersistedStateLoader.legacyStorageKey) == legacy)

        let relaunched = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        #expect(relaunched.durationMinutes(for: .focus) == 40)
        #expect(relaunched.pendingDurationOperationCount == 1)
    }

    @Test @MainActor
    func signedInPullAppliesCanonicalDurationsWithoutSyncingLocalOnlySettings() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.settings.selectedPhase = .longBreak
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: "duration-sync")
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session, keychain: StaticTokenStore())
        let model = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        await model.restore()

        #expect(model.sessionState == .signedIn(TestFixtures.user))
        #expect(model.durationMinutes(for: .focus) == 40)
        #expect(model.durationMinutes(for: .shortBreak) == 6)
        #expect(model.durationMinutes(for: .longBreak) == 20)
        #expect(model.selectedPhase == .longBreak)
        #expect(!model.autoStartBreaks)
        #expect(model.pendingDurationOperationCount == 0)
    }

    @Test @MainActor
    func changingDurationClearsInactiveTimerAndUpdatesNextRun() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)
        model.cancel(at: timer.anchorAt.addingTimeInterval(10))

        model.setDurationMinutes(15, for: .focus)

        #expect(model.canonicalTimer == nil)
        #expect(model.durationMinutes(for: .focus) == 15)
        model.start()
        let nextTimer = try #require(model.canonicalTimer)
        #expect(nextTimer.plannedDurationMs == Int64(15 * 60_000))
    }

    @Test @MainActor
    func inactivePersistedTimerDoesNotOverrideConfiguredDuration() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.settings.setMinutes(15, for: .focus)
        state.canonicalTimer = CanonicalTimer(
            id: "timer-stale",
            taskId: nil,
            phase: .focus,
            status: .completed,
            plannedDurationMs: 25 * 60_000,
            elapsedAtAnchorMs: 25 * 60_000,
            anchorAt: TestFixtures.anchor,
            lastIntent: nil
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let staleTimer = try #require(model.canonicalTimer)

        #expect(staleTimer.plannedDurationMs == Int64(25 * 60_000))
        #expect(model.activeTimer == nil)
        #expect(model.durationMinutes(for: .focus) == 15)
    }

    @Test @MainActor
    func localTaskAssignmentSurvivesDeletionPersistenceAndRecreation() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        #expect(await model.addTask("\tWrite release notes\n"))
        #expect(await model.addTask("Write release notes"))
        let task = try #require(model.tasks.first)
        #expect(model.tasks.count == 1)
        model.selectedTaskID = task.id
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let timer = try #require(model.canonicalTimer)
        #expect(model.task(forTimerID: timer.id) == task)
        model.finish(at: timer.anchorAt.addingTimeInterval(60))

        model.deleteTask(id: task.id)
        #expect(model.tasks.isEmpty)
        #expect(model.taskSummaries().isEmpty)
        #expect(model.completedFocusSummaries() == [
            CompletedFocusSummary(
                id: task.id.uuidString.lowercased(),
                taskTitle: task.title,
                completedPomodoros: 1,
                timeSpentMs: 60_000
            )
        ])
        let deletedRestore = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(deletedRestore.tasks.isEmpty)
        #expect(deletedRestore.completedFocusSummaries().first?.taskTitle == task.title)
        #expect(await model.addTask("Write release notes"))

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let recreated = try #require(restored.tasks.first)
        let summary = try #require(restored.taskSummaries().first)
        #expect(recreated.id == task.id)
        #expect(restored.task(forTimerID: timer.id) == task)
        #expect(restored.completedFocusSummaries().first?.taskTitle == task.title)
        #expect(summary.finishedPomodoros == 1)
        #expect(summary.timeSpentMs == 60_000)
    }

    @Test @MainActor
    func taskSummariesCountOnlyCompletedFocusPomodorosFromRequestedDay() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 12)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let writing = try #require(FocusTask(title: "Writing"))
        let review = try #require(FocusTask(title: "Review"))
        var timerState = PersistedTimerState.fresh()
        timerState.history = [
            TestFixtures.history(id: "write-25", durationMs: 25 * 60_000, date: today),
            TestFixtures.history(id: "write-10", durationMs: 10 * 60_000, date: today.addingTimeInterval(60)),
            TestFixtures.history(id: "review-50", durationMs: 50 * 60_000, date: today),
            TestFixtures.history(id: "write-cancelled", status: "cancelled", durationMs: 90 * 60_000, date: today),
            TestFixtures.history(id: "write-break", phase: .shortBreak, durationMs: 5 * 60_000, date: today),
            TestFixtures.history(id: "write-yesterday", durationMs: 40 * 60_000, date: yesterday)
        ]
        let assignments = Dictionary(
            uniqueKeysWithValues: timerState.history.map { item in
                (item.timerId, item.timerId == "review-50" ? review : writing)
            }
        )
        let localTasks = LocalTaskState(
            tasks: [writing, review],
            selectedTaskID: writing.id,
            assignments: assignments
        )
        defaults.set(try JSONEncoder.api.encode(timerState), forKey: "timer-state-v2")
        defaults.set(try JSONEncoder.api.encode(localTasks), forKey: "local-tasks-v1")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let summaries = model.taskSummaries(for: today, calendar: calendar)
        let migratedData = try #require(defaults.data(forKey: "timer-state-v2"))
        let migratedState = try JSONDecoder.api.decode(PersistedTimerState.self, from: migratedData)

        #expect(summaries.count == 2)
        #expect(summaries.first(where: { $0.task.id == writing.id }) ==
            TaskDailySummary(task: writing, finishedPomodoros: 2, timeSpentMs: 35 * 60_000))
        #expect(summaries.first(where: { $0.task.id == review.id }) ==
            TaskDailySummary(task: review, finishedPomodoros: 1, timeSpentMs: 50 * 60_000))
        #expect(defaults.data(forKey: "local-tasks-v1") == nil)
        #expect(Set(migratedState.pendingTaskOperations.map(\.taskId)) == Set([writing, review].map { $0.id.uuidString.lowercased() }))
        #expect(migratedState.legacyTaskAssignments.count == timerState.history.count)
        #expect(migratedState.history.allSatisfy { $0.taskId != nil })
    }

    @Test @MainActor
    func localTimerSurvivesOfflineLaunchWithoutCredentials() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let api = APIClient(keychain: EmptyTokenStore())
        let model = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.start()

        let restored = AppModel(api: api, defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        await restored.restore()

        #expect(restored.sessionState == .localOnly)
        #expect(restored.canonicalTimer?.status == .running)
        #expect(restored.pendingCommandCount == 1)
        #expect(restored.syncLabel == "On device")
    }

    #if os(iOS) || os(macOS)
    @Test @MainActor
    func permissionIntroductionRequestsAccessOnceAndPersistsCompletion() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        #expect(model.needsPermissionIntroduction)
        await model.allowTimerAlerts()

        #expect(!model.needsPermissionIntroduction)
        #expect(scheduler.operations == [.requestAuthorization])
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.needsPermissionIntroduction)
    }

    @Test @MainActor
    func permissionIntroductionCanBeSkippedWithoutRequestingAccess() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.skipTimerAlertPermissions()

        #expect(!model.needsPermissionIntroduction)
        #expect(scheduler.operations.isEmpty)
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.needsPermissionIntroduction)
    }
    #endif

    @Test @MainActor
    func completedFocusAutomaticallyStartsShortBreak() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.autoStartBreaks = true
        model.start()
        let focus = try #require(model.canonicalTimer)

        model.finish(at: focus.anchorAt.addingTimeInterval(60))

        #expect(model.canonicalTimer?.status == .running)
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.selectedPhase == .shortBreak)
        #expect(model.completedFocusCount == 1)
        #expect(model.pendingCommandCount == 3)
    }

    @Test @MainActor
    func manualCompletionPreservesPhaseExplicitlySelectedDuringActiveTimer() throws {
        let suiteName = "PomodoroughTests.ExplicitPhaseManual.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let focus = try #require(model.canonicalTimer)

        model.selectPhase(.longBreak)
        model.finish(at: focus.anchorAt.addingTimeInterval(60))

        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.selectedPhase == .longBreak)
    }

    @Test @MainActor
    func automaticCompletionPreservesExplicitPhaseWhileStartingComputedBreak() throws {
        let suiteName = "PomodoroughTests.ExplicitPhaseAutomatic.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.autoStartBreaks = true
        model.start()
        let focus = try #require(model.canonicalTimer)

        model.selectPhase(.longBreak)
        model.completeIfNeeded(timerID: focus.id, at: focus.anchorAt.addingTimeInterval(60))

        #expect(model.canonicalTimer?.status == .running)
        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.selectedPhase == .longBreak)
    }

    @Test @MainActor
    func completionAdvancesThroughRepeatingPomodoroCycle() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.setDurationMinutes(1, for: .shortBreak)
        model.setDurationMinutes(1, for: .longBreak)
        let expectedBreaks: [TimerPhase] = [
            .shortBreak, .shortBreak, .shortBreak, .longBreak, .shortBreak,
        ]

        model.start()
        for (index, expectedBreak) in expectedBreaks.enumerated() {
            let focus = try #require(model.canonicalTimer)
            #expect(focus.phase == .focus)
            if index.isMultiple(of: 2) {
                model.finish(at: focus.anchorAt.addingTimeInterval(60))
            } else {
                model.completeIfNeeded(timerID: focus.id, at: focus.anchorAt.addingTimeInterval(60))
            }
            #expect(model.selectedPhase == expectedBreak)
            #expect(model.activeTimer == nil)
            #expect(model.durationMinutes(for: model.selectedPhase) == 1)

            model.start()
            let breakTimer = try #require(model.canonicalTimer)
            #expect(breakTimer.phase == expectedBreak)
            model.finish(at: breakTimer.anchorAt.addingTimeInterval(60))
            #expect(model.selectedPhase == .focus)
            #expect(model.activeTimer == nil)
            #expect(model.durationMinutes(for: model.selectedPhase) == 1)

            if index < expectedBreaks.count - 1 {
                model.start()
            }
        }

        #expect(model.completedFocusCount == 5)
    }

    @Test @MainActor
    func exactBoundaryAutomaticCompletionSurvivesSameClockCycle() throws {
        let suiteName = "PomodoroughTests.ExactBoundaryCycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let instant = Date(timeIntervalSince1970: 1_784_620_800.001)
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { instant },
            uptime: { 100 }
        )
        model.setDurationMinutes(1, for: .focus)
        model.setDurationMinutes(1, for: .shortBreak)

        model.start()
        let firstFocus = try #require(model.canonicalTimer)
        model.finish(at: firstFocus.anchorAt.addingTimeInterval(60))
        model.start()
        let shortBreak = try #require(model.canonicalTimer)
        model.finish(at: shortBreak.anchorAt.addingTimeInterval(60))
        model.start()
        let secondFocus = try #require(model.canonicalTimer)
        model.completeIfNeeded(
            timerID: secondFocus.id,
            at: secondFocus.anchorAt.addingTimeInterval(60)
        )

        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.selectedPhase == .shortBreak)
        #expect(model.completedFocusCount == 2)
    }

    @Test @MainActor
    func longBreakProgressCountsOnlyCurrentLocalDay() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_774_166_400))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        var currentDate = today.addingTimeInterval(12 * 60 * 60)
        var currentUptime: TimeInterval = 1_000
        var state = PersistedTimerState.fresh()
        state.history = [
            TestFixtures.history(id: "yesterday", durationMs: 60_000, date: yesterday),
            TestFixtures.history(id: "today-1", durationMs: 60_000, date: today.addingTimeInterval(1)),
            TestFixtures.history(id: "today-2", durationMs: 60_000, date: today.addingTimeInterval(2)),
            TestFixtures.history(id: "today-3", durationMs: 60_000, date: today.addingTimeInterval(3)),
            TestFixtures.history(id: "today-4", durationMs: 60_000, date: today.addingTimeInterval(4)),
        ]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { currentDate },
            uptime: { currentUptime }
        )

        #expect(model.completedFocusCount == 5)
        #expect(model.completedFocusCountToday == 4)
        #expect(model.longBreakProgress == 4)
        #expect(model.nextBreakPhase() == .longBreak)

        currentDate = try #require(calendar.date(byAdding: .day, value: 1, to: currentDate))
        currentUptime += 24 * 60 * 60
        #expect(model.completedFocusCountToday == 0)
        #expect(model.longBreakProgress == 0)
        #expect(model.nextBreakPhase() == .shortBreak)
    }

    @Test @MainActor
    func automaticBreakIsNotDuplicatedAfterPersistenceReload() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.autoStartBreaks = true
        model.start()
        let focus = try #require(model.canonicalTimer)
        defaults.resetTimerStateWrites()
        model.completeIfNeeded(timerID: focus.id, at: focus.anchorAt.addingTimeInterval(60))
        let atomicWrite = try #require(defaults.timerStateWrites.first)
        let atomicState = try JSONDecoder.api.decode(PersistedTimerState.self, from: atomicWrite)

        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        restored.completeIfNeeded(timerID: focus.id, at: focus.anchorAt.addingTimeInterval(61))
        let persisted = try persistedState(defaults)

        #expect(restored.canonicalTimer?.phase == .shortBreak)
        #expect(restored.canonicalTimer?.status == .running)
        #expect(restored.pendingCommandCount == 3)
        #expect(defaults.timerStateWrites.count == 1)
        #expect(atomicState.pendingCommands.suffix(2).map(\.type) == [.finish, .start])
        #expect(persisted.pendingCommands.count { $0.type == .start && $0.phase == .shortBreak } == 1)
    }

    @Test @MainActor
    func completedTimerIsQueuedOnlyOnce() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let timer = try #require(model.canonicalTimer)

        model.completeIfNeeded(timerID: "timer-other", at: timer.anchorAt.addingTimeInterval(60))
        model.completeIfNeeded(timerID: timer.id, at: timer.anchorAt.addingTimeInterval(59))
        #expect(model.pendingCommandCount == 1)

        model.completeIfNeeded(timerID: timer.id, at: timer.anchorAt.addingTimeInterval(60))
        model.completeIfNeeded(timerID: timer.id, at: timer.anchorAt.addingTimeInterval(61))

        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.history.count == 1)
        #expect(model.pendingCommandCount == 2)
    }

    @Test @MainActor
    func cancellingTimerAtomicallyClearsAcrossPersistenceRoundTrip() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.start()
        let timer = try #require(model.canonicalTimer)
        defaults.resetTimerStateWrites()

        model.cancel(at: timer.anchorAt.addingTimeInterval(10))

        let persisted = try persistedState(defaults)
        let cancellation = Array(persisted.pendingCommands.suffix(2))
        #expect(model.canonicalTimer == nil)
        #expect(model.history.count == 1)
        #expect(model.history.first?.status == "cancelled")
        #expect(cancellation.map(\.type) == [.cancel, .clear])
        #expect(cancellation[1].deviceSequence == cancellation[0].deviceSequence + 1)
        #expect(cancellation.map(\.observedElapsedMs) == [10_000, 10_000])
        #expect(cancellation[0].occurredAt == cancellation[1].occurredAt)
        #expect(
            (cancellation[1].hlcWallMs, cancellation[1].hlcCounter)
                > (cancellation[0].hlcWallMs, cancellation[0].hlcCounter)
        )
        let commandIds = try cancellation.map {
            try #require(UUIDv7.payload(from: $0.id))
        }
        #expect(UUIDv7.isLess(commandIds[0], than: commandIds[1]))
        #expect(defaults.timerStateWrites.count == 1)
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.canonicalTimer == nil)
        #expect(restored.history.count == 1)
        #expect(restored.history.first?.status == "cancelled")
        #expect(restored.pendingCommandCount == 3)
    }

    @Test func apiClientBuildsAndDecodesChallengeRequest() async throws {
        let session = TestFixtures.session(for: "challenge-success")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        let challenge = try await client.challenge()

        #expect(challenge.challenge == "challenge-123")
        #expect(challenge.nonce == "nonce-456")
        #expect(challenge.expiresAt == Date(timeIntervalSince1970: 1_784_550_896.789))
    }

    @Test func revisionStreamParsesFiniteSSEAndSendsExactAuthenticatedRequest() async throws {
        let responseBody = """
        : keepalive

        event: revision
        data: {"revision":42}

        data: 43

        event: ignored
        data: 99

        """
        let server = try LoopbackHTTPServer(
            contentType: "text/event-stream; charset=utf-8",
            body: Data(responseBody.utf8)
        )
        let client = APIClient(baseURL: server.baseURL, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())

        let stream = try await client.revisionEvents()
        var revisions: [Int64] = []
        for try await revision in stream {
            revisions.append(revision)
        }

        #expect(revisions == [42, 43])
        let request = server.request
        #expect(request.hasPrefix("GET /api/v1/stream HTTP/1.1\r\n"))
        #expect(request.localizedCaseInsensitiveContains("Accept: text/event-stream\r\n"))
        #expect(request.localizedCaseInsensitiveContains("Authorization: Bearer access-token\r\n"))
        #expect(!request.localizedCaseInsensitiveContains("Content-Type:"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func expiredTokenRefreshesBeforeExactProfileRequestAndSavesTokens() async throws {
        let scenario = "apple-api-coverage-expired-refresh-me"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(tokens: TokenPair(
            accessToken: "expired-access",
            accessTokenExpiresAt: .distantPast,
            refreshToken: "expired-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        let response = try await client.me()

        #expect(response.user == TestFixtures.user)
        #expect(store.operations == [
            .load,
            .save(accessToken: "refreshed-access", refreshToken: "refreshed-refresh")
        ])
        #expect(store.tokens?.accessToken == "refreshed-access")
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.map { $0.path } == [
            "/api/v1/auth/refresh",
            "/api/v1/me"
        ])
        let refresh = try #require(requests.first)
        #expect(refresh.url == "https://pomodorough.egigoka.me/api/v1/auth/refresh")
        #expect(refresh.method == "POST")
        #expect(refresh.accept == "application/json")
        #expect(refresh.contentType == "application/json")
        #expect(refresh.authorization == nil)
        #expect(refresh.body == Data(#"{"refreshToken":"expired-refresh"}"#.utf8))
        let profile = try #require(requests.last)
        #expect(profile.url == "https://pomodorough.egigoka.me/api/v1/me")
        #expect(profile.method == "GET")
        #expect(profile.accept == "application/json")
        #expect(profile.contentType == nil)
        #expect(profile.authorization == "Bearer refreshed-access")
        #expect(profile.body == nil)
    }

    @Test func restoringNewGenerationDiscardsInFlightRefresh() async throws {
        let scenario = "apple-api-coverage-stale-refresh-generation"
        defer { TestFixtures.releaseScenario(scenario) }
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(tokens: TokenPair(
            accessToken: "original-expired-access",
            accessTokenExpiresAt: .distantPast,
            refreshToken: "original-expired-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())
        let staleRequest = Task { try await client.me() }
        let receivedStaleRefresh = await TestFixtures.waitForRequest(
            in: scenario,
            path: "/api/v1/auth/refresh"
        )
        try #require(receivedStaleRefresh, "Timed out waiting for stale refresh request")

        store.replaceTokens(TokenPair(
            accessToken: "replacement-expired-access",
            accessTokenExpiresAt: .distantPast,
            refreshToken: "replacement-expired-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        #expect(try await client.restoreTokens())
        TestFixtures.releaseScenario(scenario)
        switch await staleRequest.result {
        case .success:
            Issue.record("Expected stale request to fail")
        case .failure(let error):
            let isUnauthorized: Bool
            if let appError = error as? AppError, case .unauthorized = appError {
                isUnauthorized = true
            } else {
                isUnauthorized = false
            }
            let isCancelled = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            #expect(
                isUnauthorized || isCancelled,
                "Expected unauthorized or cancellation, got \(error)"
            )
        }

        let response = try await client.me()

        #expect(response.user == TestFixtures.user)
        let requests = TestFixtures.recordedRequests(for: scenario)
        let refreshes = requests.filter {
            $0.path == "/api/v1/auth/refresh"
        }
        #expect(refreshes.count == 2)
        #expect(refreshes.first?.body == Data(
            #"{"refreshToken":"original-expired-refresh"}"#.utf8
        ))
        #expect(refreshes.last?.body == Data(
            #"{"refreshToken":"replacement-expired-refresh"}"#.utf8
        ))
        let profiles = requests.filter { $0.path == "/api/v1/me" }
        #expect(profiles.count == 1)
        #expect(profiles.first?.authorization == "Bearer replacement-access")
        #expect(requests.allSatisfy { $0.authorization != "Bearer stale-access" })
        #expect(!store.operations.contains(
            .save(accessToken: "stale-access", refreshToken: "stale-refresh")
        ))
        #expect(store.operations == [
            .load,
            .load,
            .save(accessToken: "replacement-access", refreshToken: "replacement-refresh")
        ])
        #expect(store.tokens?.accessToken == "replacement-access")
    }

    @Test func concurrentProfileRequestsShareSingleRefresh() async throws {
        let scenario = "apple-api-coverage-concurrent-refresh-single-flight"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(tokens: TokenPair(
            accessToken: "expired-access",
            accessTokenExpiresAt: .distantPast,
            refreshToken: "expired-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        let requests = (0..<8).map { _ in Task { try await client.me() } }
        let receivedRefresh = await TestFixtures.waitForRequest(
            in: scenario,
            path: "/api/v1/auth/refresh"
        )
        try #require(receivedRefresh, "Timed out waiting for concurrent refresh request")
        TestFixtures.releaseScenario(scenario)
        var responses: [MeResponse] = []
        for request in requests {
            responses.append(try await request.value)
        }

        #expect(responses.allSatisfy { $0.user == TestFixtures.user })
        let recorded = TestFixtures.recordedRequests(for: scenario)
        #expect(recorded.count { $0.path == "/api/v1/auth/refresh" } == 1)
        #expect(recorded.count { $0.path == "/api/v1/me" } == 8)
        #expect(store.operations == [
            .load,
            .save(accessToken: "concurrent-access", refreshToken: "concurrent-refresh")
        ])
    }

    @Test func exchangeSendsExactPayloadSavesTokensThenLoadsProfile() async throws {
        let scenario = "apple-api-coverage-exchange-save-me"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore()
        let client = APIClient(session: session, keychain: store)

        let response = try await client.exchange(NativeExchangeRequest(
            idToken: "google-id-token",
            challenge: "challenge-value",
            deviceId: "device-coverage",
            platform: "ios"
        ))

        #expect(response.user == TestFixtures.user)
        #expect(store.operations == [
            .save(accessToken: "exchange-access", refreshToken: "exchange-refresh")
        ])
        let requests = TestFixtures.recordedRequests(for: scenario)
        #expect(requests.map { $0.path } == [
            "/api/v1/auth/google/exchange",
            "/api/v1/me"
        ])
        let exchange = try #require(requests.first)
        #expect(exchange.url == "https://pomodorough.egigoka.me/api/v1/auth/google/exchange")
        #expect(exchange.method == "POST")
        #expect(exchange.accept == "application/json")
        #expect(exchange.contentType == "application/json")
        #expect(exchange.authorization == nil)
        #expect(exchange.body == Data(
            #"{"challenge":"challenge-value","deviceId":"device-coverage","idToken":"google-id-token","platform":"ios"}"#.utf8
        ))
        let profile = try #require(requests.last)
        #expect(profile.authorization == "Bearer exchange-access")
    }

    @Test func logoutDeletesTokensOnlyAfterServerSuccess() async throws {
        let scenario = "apple-api-coverage-logout-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(tokens: TokenPair(
            accessToken: "logout-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "logout-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        try await client.logout()

        #expect(store.operations == [.load, .delete])
        #expect(store.tokens == nil)
        let request = try #require(TestFixtures.recordedRequests(for: scenario).first)
        #expect(request.url == "https://pomodorough.egigoka.me/api/v1/auth/logout")
        #expect(request.method == "POST")
        #expect(request.accept == "application/json")
        #expect(request.contentType == nil)
        #expect(request.authorization == "Bearer logout-access")
        #expect(request.body == nil)
    }

    @Test func accountDeletionSendsExactConfirmationAndDeletesTokensAfterServerSuccess() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(tokens: TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        ))
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        try await client.deleteAccount(confirmation: "DELETE")

        #expect(store.operations == [.load, .delete])
        #expect(store.tokens == nil)
        let request = try #require(TestFixtures.recordedRequests(for: scenario).first)
        #expect(request.url == "https://pomodorough.egigoka.me/api/v1/account")
        #expect(request.method == "DELETE")
        #expect(request.accept == "application/json")
        #expect(request.contentType == "application/json")
        #expect(request.authorization == "Bearer delete-access")
        #expect(request.body == Data(#"{"confirmation":"DELETE"}"#.utf8))
    }

    @Test func accountDeletionRemainsSuccessfulWhenLocalTokenCleanupFails() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let store = RecordingTokenStore(
            tokens: TokenPair(
                accessToken: "delete-access",
                accessTokenExpiresAt: .distantFuture,
                refreshToken: "delete-refresh",
                refreshTokenExpiresAt: .distantFuture
            ),
            failures: [.delete]
        )
        let client = APIClient(session: session, keychain: store)
        #expect(try await client.restoreTokens())

        try await client.deleteAccount(confirmation: "DELETE")

        #expect(store.operations == [.load, .delete])
    }

    @Test @MainActor
    func successfulAccountDeletionClearsLocalAccountWorkspace() async throws {
        let scenario = "apple-api-coverage-account-delete-success"
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Private local task"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        state.history = [TestFixtures.history(
            id: "private-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor,
            taskID: task.id.uuidString
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let tokens = TokenPair(
            accessToken: "delete-access",
            accessTokenExpiresAt: .distantFuture,
            refreshToken: "delete-refresh",
            refreshTokenExpiresAt: .distantFuture
        )
        let identity = RecordingGoogleIdentityProvider()
        let model = AppModel(
            api: APIClient(session: session, keychain: RecordingTokenStore(tokens: tokens)),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: identity
        )
        await model.restore()
        #expect(model.isSignedIn)

        await model.deleteAccount(confirmation: "DELETE")

        #expect(model.sessionState == .localOnly)
        #expect(model.tasks.isEmpty)
        #expect(model.history.isEmpty)
        #expect(model.pendingChangeCount == 0)
        #expect(identity.signOutCount == 1)
        #expect(try persistedState(defaults).cachedUser == nil)
    }

    @Test @MainActor
    func timerControlsUpdateSystemAlarmInOrder() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)
        model.setDurationMinutes(1, for: .focus)

        model.start()
        await model.waitForAlarmOperations()
        let running = try #require(model.canonicalTimer)
        model.pause(at: running.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()
        let paused = try #require(model.canonicalTimer)
        model.resume(at: paused.anchorAt.addingTimeInterval(5))
        await model.waitForAlarmOperations()
        let resumed = try #require(model.canonicalTimer)
        model.finish(at: resumed.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()

        #expect(scheduler.operations == [
            .schedule(timerID: running.id, phase: .focus, duration: 60),
            .pause(timerID: running.id),
            .resume(timerID: running.id, phase: .focus, duration: 50),
            .cancel(timerID: running.id)
        ])
    }

    @Test @MainActor
    func naturalCompletionStopsAlarmAndSchedulesAutomaticBreak() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)
        model.setDurationMinutes(1, for: .focus)
        model.setDurationMinutes(1, for: .shortBreak)
        model.autoStartBreaks = true
        model.start()
        await model.waitForAlarmOperations()
        let focus = try #require(model.canonicalTimer)

        model.completeIfNeeded(timerID: focus.id, at: focus.anchorAt.addingTimeInterval(60))
        await model.waitForAlarmOperations()

        let shortBreak = try #require(model.canonicalTimer)
        #expect(shortBreak.phase == .shortBreak)
        #expect(!model.hasActiveCompletionAlert)
        #expect(scheduler.operations == [
            .schedule(timerID: focus.id, phase: .focus, duration: 60),
            .schedule(timerID: shortBreak.id, phase: .shortBreak, duration: 60),
            .cancel(timerID: focus.id)
        ])
    }

    @Test func apiClientAcceptsStandardRFC3339Date() async throws {
        let session = TestFixtures.session(for: "standard-date")
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)

        let challenge = try await client.challenge()

        #expect(challenge.expiresAt == Date(timeIntervalSince1970: 1_784_550_896))
    }

    @Test func persistedStateBackfillsNewSettingsAndClockFields() throws {
        let json = Data(
            #"{"deviceId":"device-test0001","nextSequence":1,"revision":0,"pendingCommands":[],"canonicalTimer":null,"history":[]}"#.utf8
        )

        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: json)

        #expect(state.settings.focusMinutes == 25)
        #expect(state.hlcWallMs == 0)
        #expect(state.serverTimeOffsetMs == nil)
        #expect(state.serverTimeUncertaintyMs == nil)
        #expect(state.cachedUser == nil)
        #expect(state.pendingTaskOperations.isEmpty)
        #expect(state.pendingDurationOperations.isEmpty)
        #expect(state.pendingSelectedTaskOperations.isEmpty)
        #expect(state.tasks.isEmpty)
        #expect(state.knownTasks.isEmpty)
        #expect(state.selectedTaskID == nil)
        #expect(state.legacyTaskAssignments.isEmpty)
    }

    @Test func persistedLegacyOffsetWithoutContinuityFailsClosedUntilResampled() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(
            PersistedTimerState.fresh()
        )) as? [String: Any])
        object["serverTimeOffsetMs"] = 3_600_000
        object.removeValue(forKey: "serverTimeUncertaintyMs")

        let state = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(state.serverTimeOffsetMs == 3_600_000)
        #expect(state.serverTimeUncertaintyMs == nil)
        #expect(state.serverTimeAnchorMs == nil)
        #expect(!state.hasValidGeneratorState)
        #expect(state.hasValidPendingWireOperationsForResample)
    }

    @Test @MainActor
    func timerDisplayAndAutomaticDeadlineUseMonotonicPhysicalTime() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let wall = LockedTestValue(Date(timeIntervalSince1970: 1_000))
        let uptime = LockedTestValue<TimeInterval>(100)
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { wall.value },
            uptime: { uptime.value }
        )
        model.setDurationMinutes(1, for: .focus)
        model.start()
        let timer = try #require(model.canonicalTimer)

        wall.value = wall.value.addingTimeInterval(3_600)
        uptime.value = 110
        #expect(model.remainingForDisplay(timer) == 50)
        wall.value = wall.value.addingTimeInterval(-7_200)
        uptime.value = 120
        #expect(model.elapsedForDisplay(timer) == 20)
        model.completeIfNeeded(timerID: timer.id)
        #expect(model.canonicalTimer?.status == .running)

        uptime.value = 160
        model.completeIfNeeded(timerID: timer.id)
        #expect(model.canonicalTimer?.status == .completed)
    }

    @Test func persistedTrustedAnchorSurvivesRestartWithoutConsultingWall() throws {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        var state = PersistedTimerState.fresh()
        try state.mergeClock(
            serverWallMs: 2_000_000,
            serverCounter: 0,
            serverTime: serverTime,
            requestWall: serverTime.addingTimeInterval(3_600),
            requestUptime: 100,
            responseUptime: 100
        )
        let persisted = try JSONEncoder.api.encode(state)
        let restored = try JSONDecoder.api.decode(PersistedTimerState.self, from: persisted)

        #expect(try restored.trustedOccurrenceDate(
            for: serverTime.addingTimeInterval(-86_400),
            uptime: 110
        ) == serverTime.addingTimeInterval(10))
    }

    @Test func persistedLegacySentinelRowsNormalizeToEpoch() throws {
        var state = PersistedTimerState.fresh()
        let duration = TestFixtures.durationOperation(
            id: "duration-legacy-real-date",
            phase: .focus,
            durationMs: 60_000,
            wallMs: 0,
            occurredAt: TestFixtures.anchor
        )
        let autoStart = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 0,
            occurredAt: TestFixtures.anchor
        )
        state.pendingDurationOperations = [duration]
        state.pendingAutoStartOperations = [autoStart]
        state.pendingBootstrapResolution = BootstrapResolveRequest(
            requestId: "legacy-sentinel-request",
            deviceId: state.deviceId,
            expectedRevision: 0,
            strategy: .merge,
            commands: [],
            taskOperations: [],
            durationOperations: [duration],
            autoStartOperations: [autoStart]
        )

        let decoded = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: JSONEncoder.api.encode(state)
        )

        #expect(decoded.pendingDurationOperations.first?.occurredAt == Date(timeIntervalSince1970: 0))
        #expect(decoded.pendingAutoStartOperations.first?.occurredAt == Date(timeIntervalSince1970: 0))
        #expect(decoded.pendingBootstrapResolution?.durationOperations.first?.occurredAt == Date(timeIntervalSince1970: 0))
        #expect(decoded.pendingBootstrapResolution?.autoStartOperations?.first?.occurredAt == Date(timeIntervalSince1970: 0))
        #expect(decoded.hasValidPendingWireOperations)
    }

    @Test @MainActor
    func localOnlyHistoryAutomaticallyReplacesRemoteWithCompleteQueues() async throws {
        let scenario = "bootstrap-local-only"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try bootstrapState(hasLocalHistory: true)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let requests = TestFixtures.recordedRequests(for: scenario)
        let syncPaths = requests.filter { $0.path == "/api/v1/bootstrap" || $0.path == "/api/v1/bootstrap/resolve" || $0.path == "/api/v1/sync" }
        #expect(syncPaths.map { "\($0.method) \($0.path)" } == [
            "GET /api/v1/bootstrap",
            "POST /api/v1/bootstrap/resolve",
            "POST /api/v1/sync"
        ])
        let resolve = try #require(requests.first { $0.path == "/api/v1/bootstrap/resolve" })
        let body = try requestJSON(resolve)
        #expect(body["strategy"] as? String == "replace_remote")
        #expect(body["expectedRevision"] as? Int == 5)
        #expect((body["commands"] as? [Any])?.count == 2)
        #expect((body["taskOperations"] as? [Any])?.count == 1)
        #expect((body["durationOperations"] as? [Any])?.count == 1)
        #expect(model.history.map(\.id) == ["local-history"])
        #expect(model.pendingChangeCount == 0)
        #expect(model.historyResolutionState == .none)
        let persisted = try persistedState(defaults)
        #expect(persisted.cachedUser == TestFixtures.user)
        #expect(persisted.bootstrapUser == nil)
        #expect(persisted.pendingBootstrapResolution == nil)
    }

    @Test @MainActor
    func remoteOnlyHistoryAutomaticallyKeepsRemoteWhenLocalStateIsEmpty() async throws {
        let scenario = "bootstrap-remote-only-empty"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = emptyBootstrapState()
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let body = try requestJSON(resolve)
        #expect(body["strategy"] as? String == "keep_remote")
        #expect((body["commands"] as? [Any])?.isEmpty == true)
        #expect((body["taskOperations"] as? [Any])?.isEmpty == true)
        #expect((body["durationOperations"] as? [Any])?.isEmpty == true)
        #expect(model.history.map(\.id) == ["remote-history"])
        #expect(model.canonicalTimer == nil)
        #expect(model.pendingChangeCount == 0)
        #expect(try persistedState(defaults).cachedUser == TestFixtures.user)
    }

    @Test @MainActor
    func remoteHistoryAndLocalQueuedStateRequireExplicitChoice() async throws {
        let scenario = "bootstrap-remote-only"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: false)),
            forKey: "timer-state-v2"
        )
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.localHistoryResolutionCount == 0)
        #expect(model.remoteHistoryResolutionCount == 1)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve" && $0.path != "/api/v1/sync"
        })
    }

    @Test @MainActor
    func localHistoryAndRemoteTaskRequireExplicitChoice() async throws {
        let scenario = "bootstrap-local-history-remote-task"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: true)),
            forKey: "timer-state-v2"
        )
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.localHistoryResolutionCount == 1)
        #expect(model.remoteHistoryResolutionCount == 0)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve" && $0.path != "/api/v1/sync"
        })
    }

    @Test @MainActor
    func bothHistoriesBlockSyncAndMutationsUntilConfirmedAndCancelIsSideEffectFree() async throws {
        let scenario = "bootstrap-both-cancel"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = try bootstrapState(hasLocalHistory: true)
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.localHistoryResolutionCount == 1)
        #expect(model.remoteHistoryResolutionCount == 1)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/sync" && $0.path != "/api/v1/bootstrap/resolve"
        })
        await model.sync(force: true)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
        let persistedBeforeChoice = try #require(defaults.data(forKey: "timer-state-v2"))
        let pendingBefore = model.pendingChangeCount
        model.start()
        model.setDurationMinutes(90, for: .focus)
        #expect(!(await model.addTask("Blocked task")))
        #expect(model.pendingChangeCount == pendingBefore)

        model.requestHistoryResolution(.keepRemote)
        #expect(model.historyResolutionState == .confirming(.keepRemote))
        #expect(try persistedState(defaults).pendingBootstrapResolution == nil)
        model.cancelHistoryResolutionConfirmation()

        #expect(model.historyResolutionState == .choosing)
        model.requestHistoryResolution(.replaceRemote)
        #expect(model.historyResolutionState == .confirming(.replaceRemote))
        model.cancelHistoryResolutionConfirmation()
        #expect(defaults.data(forKey: "timer-state-v2") == persistedBeforeChoice)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
    }

    @Test @MainActor
    func chooserCountsOnlyCompletedHistoryEntries() async throws {
        let scenario = "bootstrap-history-counts"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try bootstrapState(hasLocalHistory: true)
        initial.history = [
            TestFixtures.history(
                id: "local-cancelled",
                status: "cancelled",
                durationMs: 60_000,
                date: TestFixtures.anchor
            ),
            TestFixtures.history(
                id: "local-superseded",
                status: "superseded",
                durationMs: 60_000,
                date: TestFixtures.anchor
            )
        ]
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.historyResolutionState == .choosing)
        #expect(model.history.count == 3)
        #expect(model.localHistoryResolutionCount == 1)
        #expect(model.remoteHistoryResolutionCount == 1)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve" && $0.path != "/api/v1/sync"
        })
    }

    @Test @MainActor
    func keepBothRequiresConfirmationAndInstallsMergedCanonicalHistory() async throws {
        let scenario = "bootstrap-merge"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: true)), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()

        model.requestHistoryResolution(.merge)
        #expect(model.historyResolutionState == .confirming(.merge))
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy {
            $0.path != "/api/v1/bootstrap/resolve"
        })
        await model.confirmHistoryResolution()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let body = try requestJSON(resolve)
        #expect(body["strategy"] as? String == "merge")
        #expect((body["commands"] as? [Any])?.count == 2)
        #expect(Set(model.history.map(\.id)) == ["local-history", "remote-history"])
        #expect(model.historyResolutionState == .none)
    }

    @Test @MainActor
    func transportFailurePreservesLocalDataAndRelaunchRetriesExactResolutionRequest() async throws {
        let scenario = "bootstrap-network-retry"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = try bootstrapState(hasLocalHistory: true)
        initial.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: initial.deviceId,
            enabled: true,
            wallMs: 4
        )]
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
            model.requestHistoryResolution(.merge)
            await model.confirmHistoryResolution()

            #expect(model.historyResolutionState == .retryable(.merge))
            #expect(model.history.map(\.id) == ["local-timer"])
            let pending = try #require(persistedState(defaults).pendingBootstrapResolution)
            #expect(pending.strategy == .merge)
        }

        let firstResolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
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
        #expect(resolves[0].body == firstResolve.body)
        let retriedBody = try requestJSON(resolves[1])
        #expect((retriedBody["autoStartOperations"] as? [Any])?.count == 1)
        #expect(TestFixtures.recordedRequests(for: scenario).count { $0.path == "/api/v1/bootstrap" } == 1)
        #expect(restored.historyResolutionState == .none)
        #expect(Set(restored.history.map(\.id)) == ["local-history", "remote-history"])
        #expect(try persistedState(defaults).pendingBootstrapResolution == nil)
    }

    @Test @MainActor
    func taskSyncEncodesOperationClearsAcknowledgementAndPullsRemoteTasks() async throws {
        let scenario = "task-sync"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        let operation = try taskOperation(title: "Local task")
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

        let sync = try #require(TestFixtures.recordedRequests(for: scenario).first { $0.path == "/api/v1/sync" })
        let body = try requestJSON(sync)
        let taskOperations = try #require(body["taskOperations"] as? [[String: Any]])
        let encoded = try #require(taskOperations.first)
        #expect(Set(body.keys) == [
            "deviceId", "lastRevision", "commands", "taskOperations", "durationOperations",
            "autoStartOperations", "selectedTaskOperations"
        ])
        #expect(encoded["id"] as? String == operation.id)
        #expect(encoded["taskId"] as? String == operation.taskId)
        #expect(encoded["type"] as? String == "upsert")
        #expect(encoded["title"] as? String == "Local task")
        #expect(model.pendingChangeCount == 0)
        #expect(model.tasks.map(\.title) == ["Remote task"])
        #expect(model.history.map(\.id) == ["remote-history"])
    }

    @Test(arguments: [BootstrapResolutionStrategy.keepRemote, .replaceRemote])
    @MainActor
    func chooserAppliesReplacementStrategyAfterConfirmation(
        _ strategy: BootstrapResolutionStrategy
    ) async throws {
        let scenario = "bootstrap-choice-\(strategy.rawValue)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder.api.encode(bootstrapState(hasLocalHistory: true)),
            forKey: "timer-state-v2"
        )
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()
        #expect(model.historyResolutionState == .choosing)
        model.requestHistoryResolution(strategy)
        #expect(model.historyResolutionState == .confirming(strategy))
        await model.confirmHistoryResolution()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        let body = try requestJSON(resolve)
        let includesLocal = strategy == .replaceRemote
        #expect(body["strategy"] as? String == strategy.rawValue)
        #expect((body["commands"] as? [Any])?.count == (includesLocal ? 2 : 0))
        #expect((body["taskOperations"] as? [Any])?.count == (includesLocal ? 1 : 0))
        #expect((body["durationOperations"] as? [Any])?.count == (includesLocal ? 1 : 0))
        #expect(model.history.map(\.id) == [includesLocal ? "local-history" : "remote-history"])
        #expect(model.pendingChangeCount == 0)
        #expect(model.historyResolutionState == .none)
    }

    @Test @MainActor
    func taskDeleteSyncEncodesWireContractAndClearsAcknowledgement() async throws {
        let scenario = "task-sync-delete-wire"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Delete remotely"))
        let operation = TaskOperation(
            id: "task-operation-delete-wire",
            taskId: task.id.uuidString.lowercased(),
            type: .delete,
            title: nil,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002,
            hlcCounter: 0
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
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

        let sync = try #require(TestFixtures.recordedRequests(for: scenario).first { $0.path == "/api/v1/sync" })
        let taskOperations = try #require(try requestJSON(sync)["taskOperations"] as? [[String: Any]])
        let encoded = try #require(taskOperations.first)
        #expect(taskOperations.count == 1)
        #expect(encoded["id"] as? String == operation.id)
        #expect(encoded["taskId"] as? String == operation.taskId)
        #expect(encoded["type"] as? String == "delete")
        #expect(encoded["title"] == nil)
        #expect(model.tasks.isEmpty)
        #expect(model.pendingChangeCount == 0)
        #expect(try persistedState(defaults).pendingTaskOperations.isEmpty)
    }

    @Test @MainActor
    func selectedTaskSyncSendsSelectionAndNilThenInstallsCanonicalPreference() async throws {
        let scenario = "selected-task-sync-wire"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Central selection"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [task]
        state.knownTasks = [task]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        model.selectedTaskID = task.id
        #expect(model.pendingSelectedTaskOperationCount == 1)
        await model.restore()
        #expect(model.selectedTaskID == task.id)
        #expect(model.pendingSelectedTaskOperationCount == 0)

        model.selectedTaskID = nil
        await waitForSyncToDrain(model)

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let operations = try syncs.flatMap { request in
            try #require(try requestJSON(request)["selectedTaskOperations"] as? [[String: Any]])
        }
        #expect(operations.count == 2)
        #expect(operations[0]["taskId"] as? String == task.id.uuidString.lowercased())
        #expect(operations[1]["taskId"] is NSNull)
        #expect(operations.allSatisfy { $0["deviceId"] == nil })
        #expect(model.selectedTaskID == nil)
        #expect(try persistedState(defaults).pendingSelectedTaskOperations.isEmpty)
    }

    @Test @MainActor
    func remoteSelectedTaskSyncPreservesActiveTimerCapturedTask() async throws {
        let scenario = "selected-task-sync-active-timer"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let build = try #require(FocusTask(title: "Captured build"))
        let review = try #require(FocusTask(title: "Next review"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.tasks = [build, review]
        state.knownTasks = [build, review]
        state.selectedTaskID = build.id
        state.canonicalTimer = CanonicalTimer(
            id: "selected-active-timer",
            taskId: build.id.uuidString.lowercased(),
            phase: .focus,
            status: .running,
            plannedDurationMs: 1_500_000,
            elapsedAtAnchorMs: 120_000,
            anchorAt: Date(timeIntervalSince1970: 1_784_620_800),
            lastIntent: nil
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.selectedTaskID == review.id)
        #expect(model.canonicalTimer?.taskId == build.id.uuidString.lowercased())
        #expect(model.task(forTimerID: "selected-active-timer") == build)
        #expect(model.pendingSelectedTaskOperationCount == 0)
    }

    @Test @MainActor
    func remoteTaskPullThenDeletionClearsSelectedTask() async throws {
        let scenario = "task-sync-remote-lifecycle"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        defer {
            model.setSceneActive(false)
            session.invalidateAndCancel()
        }

        await model.restore()
        let remoteTask = try #require(model.tasks.first)
        #expect(model.tasks.map(\.title) == ["Remote task"])
        model.selectedTaskID = remoteTask.id
        #expect(model.selectedTaskID == remoteTask.id)

        await waitForSyncToDrain(model)

        #expect(model.tasks.isEmpty)
        #expect(model.selectedTaskID == nil)
        #expect(try persistedState(defaults).selectedTaskID == nil)
    }

    @Test @MainActor
    func taskAddedDuringSyncRebasesOntoRemoteResponseAndClearsOnFollowUp() async throws {
        let scenario = "task-sync-in-flight-rebase"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        defer {
            model.setSceneActive(false)
            session.invalidateAndCancel()
        }

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/sync" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/sync" })
        #expect(await model.addTask("Added in flight"))

        await restoreTask.value
        try await Task.sleep(for: .milliseconds(50))

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let operationCounts = try syncs.map { request in
            try #require(try requestJSON(request)["taskOperations"] as? [Any]).count
        }
        #expect(syncs.count == 2)
        #expect(operationCounts.first == 0)
        #expect(operationCounts.count { $0 == 1 } == 1)
        #expect(Set(model.tasks.map(\.title)) == ["Remote task", "Added in flight"])
        #expect(model.pendingChangeCount == 0)
    }

    @Test(arguments: [1, 255, 256, 257, 513])
    @MainActor
    func taskSyncCoversProtocolBatchPartitions(operationCount: Int) async throws {
        let expectedBatchSizes = switch operationCount {
        case 1: [1]
        case 255: [255]
        case 256: [256]
        case 257: [256, 1]
        default: [256, 256, 1]
        }
        let scenario = "task-sync-batching-\(operationCount)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tasks = try (0..<operationCount).map { index in
            try #require(FocusTask(title: "Batch task \(index)"))
        }
        let operations = tasks.enumerated().map { index, task in
            TaskOperation(
                id: "task-operation-batch-\(index)",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: TestFixtures.anchor,
                hlcWallMs: 1_000_000 + Int64(index + 1),
                hlcCounter: 0
            )
        }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.knownTasks = tasks
        state.pendingTaskOperations = operations
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let operationCounts = try syncs.map { request in
            try #require(try requestJSON(request)["taskOperations"] as? [Any]).count
        }
        #expect(operationCounts == expectedBatchSizes)
        #expect(model.tasks.count == operationCount)
        #expect(Set(model.tasks) == Set(tasks))
        #expect(model.pendingChangeCount == 0)
    }

    @Test @MainActor
    func normalSyncSurvivesEveryRestartCheckpoint() async throws {
        let scenario = "sync-restart-checkpoints"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Durable restart task"))
        let operation = TaskOperation(
            id: "task-operation-restart-checkpoints",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_001,
            hlcCounter: 0
        )
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.knownTasks = [task]
        state.pendingTaskOperations = [operation]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")

        let beforeHTTP = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(beforeHTTP.pendingChangeCount == 1)

        let interruptedSession = TestFixtures.session(for: scenario)
        var interrupted: AppModel? = AppModel(
            api: APIClient(session: interruptedSession, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            retryDelay: .seconds(30)
        )
        await interrupted?.restore()
        let interruptedSyncs = TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/sync"
        }
        try #require(interruptedSyncs.count == 1)
        interrupted = nil
        interruptedSession.invalidateAndCancel()
        #expect(try persistedState(defaults).pendingTaskOperations == [operation])

        let retrySession = TestFixtures.session(for: scenario, resetsRecorder: false)
        let retried = AppModel(
            api: APIClient(session: retrySession, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await retried.restore()
        retrySession.invalidateAndCancel()

        var syncs = TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/sync"
        }
        try #require(syncs.count == 2)
        #expect(syncs[0].body == syncs[1].body)
        #expect(retried.tasks == [task])
        #expect(try persistedState(defaults).pendingTaskOperations.isEmpty)

        let appliedSession = TestFixtures.session(for: scenario, resetsRecorder: false)
        defer { appliedSession.invalidateAndCancel() }
        let afterApply = AppModel(
            api: APIClient(session: appliedSession, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await afterApply.restore()

        syncs = TestFixtures.recordedRequests(for: scenario).filter {
            $0.path == "/api/v1/sync"
        }
        #expect(syncs.count == 3)
        let afterApplyBody = try requestJSON(try #require(syncs.last))
        #expect(try #require(afterApplyBody["commands"] as? [Any]).isEmpty)
        #expect(try #require(afterApplyBody["taskOperations"] as? [Any]).isEmpty)
        #expect(try #require(afterApplyBody["durationOperations"] as? [Any]).isEmpty)
        #expect(try #require(afterApplyBody["autoStartOperations"] as? [Any]).isEmpty)
        #expect(afterApply.tasks == [task])
        #expect(afterApply.pendingChangeCount == 0)
    }

    @Test @MainActor
    func delayedSyncResponseCannotCrossDestructiveAccountSwitch() async throws {
        let scenario = "sync-account-switch-stale"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            TestFixtures.releaseScenario(scenario)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let oldTask = try #require(FocusTask(title: "Old account task"))
        let oldOperation = TaskOperation(
            id: "task-operation-old-account",
            taskId: oldTask.id.uuidString.lowercased(),
            type: .upsert,
            title: oldTask.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_001,
            hlcCounter: 0
        )
        var oldState = PersistedTimerState.fresh()
        oldState.cachedUser = TestFixtures.user
        oldState.knownTasks = [oldTask]
        oldState.pendingTaskOperations = [oldOperation]
        defaults.set(try JSONEncoder.api.encode(oldState), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        let reachedServer = await TestFixtures.waitForRequest(
            in: scenario,
            path: "/api/v1/sync"
        )
        try #require(reachedServer, "Timed out waiting for stale account response")
        model.signOut()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isWorking)

        let newUser = User(id: "user-b", email: "b@example.com", name: "B", avatarUrl: "")
        let newTask = try #require(FocusTask(title: "New account task"))
        let newOperation = TaskOperation(
            id: "task-operation-new-account",
            taskId: newTask.id.uuidString.lowercased(),
            type: .upsert,
            title: newTask.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2_000_001,
            hlcCounter: 0
        )
        var newState = PersistedTimerState.fresh()
        newState.cachedUser = newUser
        newState.knownTasks = [newTask]
        newState.pendingTaskOperations = [newOperation]
        defaults.set(try JSONEncoder.api.encode(newState), forKey: "timer-state-v2")

        TestFixtures.releaseScenario(scenario)
        await restoreTask.value

        #expect(try persistedState(defaults) == newState)
        let reopened = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(reopened.tasks == [newTask])
        #expect(reopened.pendingChangeCount == 1)
    }

    @Test @MainActor
    func remoteTimerAndHistoryResolveTheirAssociatedTask() async throws {
        let scenario = "task-sync-associations"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let task = try #require(model.tasks.first)
        let timer = try #require(model.canonicalTimer)
        let history = try #require(model.history.first)
        let historyDate = try #require(history.date)
        #expect(model.task(forTimerID: timer.id) == task)
        #expect(model.task(forTimerID: history.timerId) == task)
        let summary = try #require(model.taskSummaries(for: historyDate).first)
        #expect(summary.task == task)
        #expect(summary.finishedPomodoros == 1)
        #expect(summary.timeSpentMs == 1_500_000)
    }

    @Test @MainActor
    func differentEstablishedOwnerRequiresAccountSwitchConfirmationWithoutOfferingHistoryMerge() async throws {
        let scenario = "task-sync-different-owner"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = User(id: "different-user", email: "old@example.com", name: "Old", avatarUrl: "")
        state.history = [TestFixtures.history(
            id: "old-account-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.sessionState == .signedIn(TestFixtures.user))
        #expect(model.historyResolutionState == .none)
        #expect(model.pendingAccountSwitchUser == TestFixtures.user)
        #expect(model.history.map(\.id) == ["old-account-history"])
        #expect(!(await model.addTask("Must remain blocked")))
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/bootstrap" })
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func activeTimerEditsApplyOnlyToNextTimer() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeTask = try #require(FocusTask(title: "Active assignment"))
        let nextTask = try #require(FocusTask(title: "Next assignment"))
        var state = PersistedTimerState.fresh()
        state.tasks = [activeTask, nextTask]
        state.knownTasks = state.tasks
        state.selectedTaskID = activeTask.id
        state.canonicalTimer = TestFixtures.timer(
            status: .paused,
            elapsed: 15_000,
            timerID: "timer-next-settings",
            taskID: activeTask.id.uuidString.lowercased()
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let originalTimer = try #require(model.canonicalTimer)

        model.selectedTaskID = nextTask.id
        model.selectPhase(.longBreak)
        model.setDurationMinutes(42, for: .focus)
        model.autoStartBreaks = true

        #expect(model.canonicalTimer == originalTimer)
        #expect(model.task(forTimerID: originalTimer.id)?.id == activeTask.id)
        #expect(model.selectedTaskID == nextTask.id)
        #expect(model.selectedPhase == .longBreak)
        #expect(model.durationMinutes(for: .focus) == 42)
        #expect(model.autoStartBreaks)
    }

    @Test @MainActor
    func rejectedFinishRollsBackDurableOptimisticPhaseAdvanceAfterRestart() async throws {
        let scenario = "auto-start-finish-rejected-no-previous"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.canonicalTimer = TestFixtures.timer(
            status: .running,
            elapsed: 0,
            timerID: "timer-rejected-finish-phase"
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let offline = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let timer = try #require(offline.canonicalTimer)

        offline.finish(at: timer.anchorAt.addingTimeInterval(timer.plannedDuration))

        #expect(offline.selectedPhase == .shortBreak)
        let optimisticState = try persistedState(defaults)
        let provenance = try #require(optimisticState.provisionalPhaseAdvances.first)
        #expect(provenance.sourceTimerId == timer.id)
        #expect(provenance.previousPhase == .focus)
        #expect(provenance.advancedPhase == .shortBreak)
        #expect(provenance.generation == optimisticState.selectedPhaseGeneration)
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await restored.restore()
        await waitForSyncToDrain(restored)

        #expect(restored.canonicalTimer?.status == .running)
        #expect(restored.selectedPhase == .focus)
    }

    @Test @MainActor
    func rejectedFinishUnwindsDependentPhaseAdvanceProvenance() async throws {
        let scenario = "auto-start-provisional-finish-rejected"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        state.canonicalTimer = TestFixtures.timer(
            status: .running,
            elapsed: 0,
            timerID: "timer-rejected-finish-chain"
        )
        state.localTimerOwners["timer-rejected-finish-chain"] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let offline = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let focus = try #require(offline.canonicalTimer)
        offline.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisionalBreak = try #require(offline.canonicalTimer)
        offline.finish(at: provisionalBreak.anchorAt.addingTimeInterval(provisionalBreak.plannedDuration))
        let provisionalState = try persistedState(defaults)
        #expect(provisionalState.provisionalPhaseAdvances.map(\.sourceTimerId) == [
            focus.id,
            provisionalBreak.id,
        ])

        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await restored.restore()
        await waitForSyncToDrain(restored)

        let reconciled = try persistedState(defaults)
        #expect(reconciled.provisionalPhaseAdvances.isEmpty)
        #expect(restored.selectedPhase == .focus)
    }

    @Test @MainActor
    func rejectedFinishDoesNotOverwriteLaterExplicitPhaseSelection() async throws {
        let scenario = "auto-start-finish-rejected-no-previous"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.canonicalTimer = TestFixtures.timer(
            status: .running,
            elapsed: 0,
            timerID: "timer-rejected-finish-later-selection"
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let offline = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let timer = try #require(offline.canonicalTimer)
        offline.finish(at: timer.anchorAt.addingTimeInterval(timer.plannedDuration))
        offline.selectedPhase = .longBreak

        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await restored.restore()
        await waitForSyncToDrain(restored)

        #expect(restored.selectedPhase == .longBreak)
    }

    @Test @MainActor
    func emptyHistoriesMergeLocalQueuesAndOtherwiseKeepRemote() async throws {
        for (scenario, state, expectedStrategy) in [
            ("bootstrap-empty-merge", try bootstrapState(hasLocalHistory: false), "merge"),
            ("bootstrap-empty-keep", emptyBootstrapState(), "keep_remote")
        ] {
            let suiteName = "PomodoroughTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(session: session, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )

            await model.restore()

            let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
                $0.path == "/api/v1/bootstrap/resolve"
            })
            #expect(try requestJSON(resolve)["strategy"] as? String == expectedStrategy)
            #expect(model.history.isEmpty)
            #expect(model.historyResolutionState == .none)
        }
    }

    @Test @MainActor
    func localAutoStartFalseTogglePersistsWithImmutableOperations() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        model.autoStartBreaks = true
        model.autoStartBreaks = false

        let persisted = try persistedState(defaults)
        #expect(persisted.pendingAutoStartOperations.map(\.enabled) == [true, false])
        #expect(Set(persisted.pendingAutoStartOperations.map(\.id)).count == 2)
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(!restored.autoStartBreaks)
        #expect(restored.pendingAutoStartOperationCount == 2)
    }

    @Test @MainActor
    func legacyUntouchedFalseAutoStartDoesNotCreateOperation() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(
            #"{"deviceId":"device-legacy-false","nextSequence":1,"revision":0,"pendingCommands":[],"pendingTaskOperations":[],"pendingDurationOperations":[],"canonicalTimer":null,"history":[],"settings":{"autoStartBreaks":false}}"#.utf8
        ), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())

        #expect(!model.autoStartBreaks)
        #expect(try persistedState(defaults).pendingAutoStartOperations.isEmpty)
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.pendingAutoStartOperationCount == 0)
    }

    @Test @MainActor
    func legacyExplicitFalseAutoStartMigratesIntoOneOperationOnce() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(
            #"{"deviceId":"device-legacy-explicit-false","nextSequence":1,"revision":0,"pendingCommands":[],"pendingTaskOperations":[],"pendingDurationOperations":[],"canonicalTimer":null,"history":[],"settings":{"autoStartBreaks":false,"autoStartBreaksExplicitlySet":true}}"#.utf8
        ), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        let operation = try #require(try persistedState(defaults).pendingAutoStartOperations.first)

        #expect(!model.autoStartBreaks)
        #expect(operation.deviceId == "device-legacy-explicit-false")
        #expect(!operation.enabled)
        #expect(operation.hlcWallMs > 0)
        let restored = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        #expect(restored.pendingAutoStartOperationCount == 1)
    }

    @Test @MainActor
    func legacyUntouchedFalseUpgradePreservesRemoteTruePreference() async throws {
        let scenario = "auto-start-remote-preference"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacyState = PersistedTimerState.fresh()
        legacyState.cachedUser = TestFixtures.user
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(legacyState)) as? [String: Any]
        )
        object.removeValue(forKey: "pendingAutoStartOperations")
        object.removeValue(forKey: "autoStartBreaks")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(model.pendingAutoStartOperationCount == 0)
        await model.restore()

        let sync = try #require(TestFixtures.recordedRequests(for: scenario).first { $0.path == "/api/v1/sync" })
        #expect((try requestJSON(sync)["autoStartOperations"] as? [Any])?.isEmpty == true)
        #expect(model.autoStartBreaks)
        #expect(try persistedState(defaults).autoStartBreaks)
    }

    @Test(arguments: [true, false])
    @MainActor
    func autoStartSyncSendsTrueAndFalseWireValuesAndClearsExactAcknowledgement(
        _ enabled: Bool
    ) async throws {
        let scenario = "auto-start-wire-\(enabled)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let operation = TestFixtures.autoStartOperation(
            deviceID: "device-auto-wire",
            enabled: enabled,
            wallMs: 10
        )
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-auto-wire"
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = !enabled
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

        let sync = try #require(TestFixtures.recordedRequests(for: scenario).first { $0.path == "/api/v1/sync" })
        let operations = try #require(try requestJSON(sync)["autoStartOperations"] as? [[String: Any]])
        let encoded = try #require(operations.first)
        #expect(operations.count == 1)
        #expect(Set(encoded.keys) == ["id", "enabled", "occurredAt", "hlcWallMs", "hlcCounter"])
        #expect(encoded["enabled"] as? Bool == enabled)
        #expect(encoded["deviceId"] == nil)
        #expect(UUID(uuidString: encoded["id"] as? String ?? "") == operation.id)
        #expect(model.autoStartBreaks == enabled)
        #expect(model.pendingAutoStartOperationCount == 0)
    }

    @Test @MainActor
    func autoStartToggleDuringSyncRebasesAndClearsOnFollowUp() async throws {
        let scenario = "auto-start-in-flight-rebase"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 10
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        for _ in 0..<100 {
            if TestFixtures.recordedRequests(for: scenario).contains(where: { $0.path == "/api/v1/sync" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.autoStartBreaks)
        model.autoStartBreaks = false
        await restoreTask.value
        await waitForSyncToDrain(model)

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let sentValues = try syncs.flatMap { request -> [Bool] in
            let operations = try #require(try requestJSON(request)["autoStartOperations"] as? [[String: Any]])
            return operations.compactMap { $0["enabled"] as? Bool }
        }
        #expect(sentValues == [true, false])
        #expect(!model.autoStartBreaks)
        #expect(model.pendingAutoStartOperationCount == 0)
    }

    @Test @MainActor
    func autoStartSyncBatches257OperationsWithoutDroppingLatestValue() async throws {
        let scenario = "auto-start-batching"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.pendingAutoStartOperations = (0..<257).map { index in
            TestFixtures.autoStartOperation(
                deviceID: state.deviceId,
                enabled: index.isMultiple(of: 2),
                wallMs: Int64(index + 1)
            )
        }
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let counts = try syncs.map { request in
            try #require(try requestJSON(request)["autoStartOperations"] as? [Any]).count
        }
        #expect(counts == [256, 1])
        #expect(model.autoStartBreaks)
        #expect(model.pendingAutoStartOperationCount == 0)
    }

    @Test @MainActor
    func remoteAutoStartPreferenceConvergesWithoutLocalOperation() async throws {
        let scenario = "auto-start-remote-preference"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
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
        #expect(model.pendingAutoStartOperationCount == 0)
        #expect(try persistedState(defaults).autoStartBreaks)
    }

    @Test @MainActor
    func malformedLocalAutoStartRowsFailClosedBeforeCanonicalSync() async throws {
        let scenario = "auto-start-remote-preference"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.pendingAutoStartOperations = [
            TestFixtures.autoStartOperation(
                deviceID: state.deviceId,
                enabled: false,
                wallMs: 0
            ),
            TestFixtures.autoStartOperation(
                deviceID: "device-foreign",
                enabled: false,
                wallMs: 1
            )
        ]
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state)) as? [String: Any]
        )
        var operations = try #require(object["pendingAutoStartOperations"] as? [[String: Any]])
        operations.append(["enabled": false])
        object["pendingAutoStartOperations"] = operations
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        #expect(model.pendingAutoStartOperationCount == 2)
        await model.restore()

        #expect(!model.autoStartBreaks)
        #expect(model.pendingAutoStartOperationCount == 2)
        #expect(model.errorMessage?.contains("local validation") == true)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/sync" })
    }

    @Test @MainActor
    func legacyActiveTimerInfersOwnershipFromLocalCanonicalStartDevice() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.autoStartBreaks = true
        let timer = CanonicalTimer(
            id: "timer-legacy-local-owner",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            lastIntent: TimerIntent(
                type: .start,
                commandId: "command-legacy-local-start",
                occurredAt: TestFixtures.anchor,
                deviceId: state.deviceId
            )
        )
        state.canonicalTimer = timer
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.completeIfNeeded(
            timerID: timer.id,
            at: timer.anchorAt.addingTimeInterval(timer.plannedDuration)
        )

        #expect(model.canonicalTimer?.phase == .shortBreak)
        #expect(model.pendingCommandCount == 2)
        #expect(try persistedState(defaults).localTimerOwners[timer.id] == state.deviceId)
    }

    @Test @MainActor
    func automaticCompletionSoundStopsWhenBreakStarts() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.autoStartBreaks = true
        let focus = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-alert-source")
        state.canonicalTimer = focus
        state.localTimerOwners[focus.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        await model.waitForAlarmOperations()
        let autoStartedBreak = try #require(model.canonicalTimer)

        #expect(autoStartedBreak.phase == .shortBreak)
        #expect(autoStartedBreak.status == .running)
        #expect(!model.hasActiveCompletionAlert)
        #expect(model.canonicalTimer == autoStartedBreak)
        #expect(scheduler.operations.last == .cancel(timerID: focus.id))
    }

    @Test @MainActor
    func startingNextTimerStopsCompletionSound() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        let focus = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-alert-source")
        state.canonicalTimer = focus
        state.localTimerOwners[focus.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        #expect(model.hasActiveCompletionAlert)

        model.start()
        await model.waitForAlarmOperations()

        #expect(model.canonicalTimer?.status == .running)
        #expect(model.canonicalTimer?.id != focus.id)
        #expect(!model.hasActiveCompletionAlert)
        #expect(scheduler.operations.contains(.cancel(timerID: focus.id)))
    }

    @Test @MainActor
    func stoppingCompletionSoundKeepsCompletedTimerUntilDismissed() async throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        let focus = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-stop-sound")
        state.canonicalTimer = focus
        state.localTimerOwners[focus.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(defaults: defaults, alarmScheduler: scheduler)

        model.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        let completed = try #require(model.canonicalTimer)
        #expect(completed.status == .completed)
        #expect(model.hasActiveCompletionAlert)

        model.stopSound()
        await model.waitForAlarmOperations()

        #expect(!model.hasActiveCompletionAlert)
        #expect(model.canonicalTimer == completed)
        #expect(scheduler.operations.last == .cancel(timerID: focus.id))

        model.clear()

        #expect(model.canonicalTimer == nil)
    }

    @Test @MainActor
    func legacyActiveTimerDoesNotInferOwnershipFromRemoteCanonicalStartDevice() throws {
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.autoStartBreaks = true
        let timer = CanonicalTimer(
            id: "timer-legacy-remote-owner",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            lastIntent: TimerIntent(
                type: .start,
                commandId: "command-legacy-remote-start",
                occurredAt: TestFixtures.anchor,
                deviceId: "device-remote"
            )
        )
        state.canonicalTimer = timer
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")

        let model = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        model.completeIfNeeded(
            timerID: timer.id,
            at: timer.anchorAt.addingTimeInterval(timer.plannedDuration)
        )

        #expect(model.canonicalTimer?.id == timer.id)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.pendingCommandCount == 0)
        #expect(try persistedState(defaults).localTimerOwners[timer.id] == nil)
    }

    @Test @MainActor
    func syncedObserverDoesNotAutoCompleteExpiredFocus() async throws {
        let scenario = "auto-start-owner-expiry"
        let originSuite = "PomodoroughTests.\(UUID().uuidString)"
        let observerSuite = "PomodoroughTests.\(UUID().uuidString)"
        let originDefaults = try #require(UserDefaults(suiteName: originSuite))
        let observerDefaults = try #require(UserDefaults(suiteName: observerSuite))
        defer {
            originDefaults.removePersistentDomain(forName: originSuite)
            observerDefaults.removePersistentDomain(forName: observerSuite)
        }
        var originState = PersistedTimerState.fresh()
        originState.cachedUser = TestFixtures.user
        originState.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: originState.deviceId,
            enabled: true,
            wallMs: 1
        )]
        var observerState = PersistedTimerState.fresh()
        observerState.cachedUser = TestFixtures.user
        originDefaults.set(try JSONEncoder.api.encode(originState), forKey: "timer-state-v2")
        observerDefaults.set(try JSONEncoder.api.encode(observerState), forKey: "timer-state-v2")
        let originSession = TestFixtures.session(for: scenario)
        let observerSession = TestFixtures.session(for: scenario, resetsRecorder: false)
        defer {
            originSession.invalidateAndCancel()
            observerSession.invalidateAndCancel()
        }
        do {
            let origin = AppModel(
                api: APIClient(session: originSession, keychain: StaticTokenStore()),
                defaults: originDefaults,
                alarmScheduler: RecordingAlarmScheduler()
            )
            await origin.restore()
            origin.start()
            await waitForSyncToDrain(origin)
        }
        originSession.invalidateAndCancel()

        let observerScheduler = RecordingAlarmScheduler()
        let observer = AppModel(
            api: APIClient(session: observerSession, keychain: StaticTokenStore()),
            defaults: observerDefaults,
            alarmScheduler: observerScheduler
        )
        await observer.restore()
        let focus = try #require(observer.canonicalTimer)
        let syncCount = TestFixtures.recordedRequests(for: scenario).count { $0.path == "/api/v1/sync" }

        observer.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(observer.canonicalTimer == focus)
        #expect(observer.pendingCommandCount == 0)
        #expect(observerScheduler.operations.isEmpty)
        #expect(TestFixtures.recordedRequests(for: scenario).count { $0.path == "/api/v1/sync" } == syncCount)
    }

    @Test @MainActor
    func reopenedOriginStillAutoCompletesItsExpiredFocus() async throws {
        let scenario = "auto-start-owner-expiry"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 1
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let originSession = TestFixtures.session(for: scenario)
        let reopenedSession = TestFixtures.session(for: scenario, resetsRecorder: false)
        defer {
            originSession.invalidateAndCancel()
            reopenedSession.invalidateAndCancel()
        }
        do {
            let origin = AppModel(
                api: APIClient(session: originSession, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )
            await origin.restore()
            origin.start()
            await waitForSyncToDrain(origin)
        }
        originSession.invalidateAndCancel()

        let reopened = AppModel(
            api: APIClient(session: reopenedSession, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await reopened.restore()
        let focus = try #require(reopened.canonicalTimer)
        reopened.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        await waitForSyncToDrain(reopened)

        #expect(reopened.canonicalTimer?.phase == .shortBreak)
        #expect(reopened.canonicalTimer?.status == .running)
        #expect(reopened.completedFocusCount == 1)
        #expect(try persistedState(defaults).provisionalBreaks.isEmpty)
    }

    @Test @MainActor
    func provisionalBreakDependencySurvivesRestartAndReleasesAfterAcceptedFinish() async throws {
        let scenario = "auto-start-dependency-boundary"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        let focus = TestFixtures.timer(status: .running, elapsed: 0, timerID: "timer-owned-restart")
        state.canonicalTimer = focus
        state.localTimerOwners[focus.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let offline = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        offline.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)

        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await restored.restore()
        await waitForSyncToDrain(restored)

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let commandBatches = try syncs.map { try #require(try requestJSON($0)["commands"] as? [[String: Any]]) }
        #expect(commandBatches.count == 2)
        #expect(commandBatches[0].contains { $0["id"] as? String == provisional.finishCommandId })
        #expect(!commandBatches[0].contains { $0["id"] as? String == provisional.startCommandId })
        #expect(commandBatches[1].contains { $0["id"] as? String == provisional.startCommandId })
        #expect(try persistedState(defaults).provisionalBreaks.isEmpty)
    }

    @Test @MainActor
    func acceptedProvisionalBreakAcknowledgementPreservesLaterExplicitPhaseSelection() async throws {
        let scenario = "auto-start-dependency-boundary"
        let suiteName = "PomodoroughTests.ExplicitAcceptedBreak.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        let focus = TestFixtures.timer(
            status: .running,
            elapsed: 0,
            timerID: "timer-explicit-accepted-break"
        )
        state.canonicalTimer = focus
        state.localTimerOwners[focus.id] = state.deviceId
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let offline = AppModel(defaults: defaults, alarmScheduler: RecordingAlarmScheduler())
        offline.completeIfNeeded(
            timerID: focus.id,
            at: focus.anchorAt.addingTimeInterval(focus.plannedDuration)
        )
        offline.selectPhase(.longBreak)
        #expect(try persistedState(defaults).hasExplicitPhaseSelection)

        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let restored = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        await restored.restore()
        await waitForSyncToDrain(restored)

        #expect(restored.canonicalTimer?.phase == .shortBreak)
        #expect(restored.canonicalTimer?.status == .running)
        #expect(restored.selectedPhase == .longBreak)
        #expect(try persistedState(defaults).hasExplicitPhaseSelection)
    }

    @Test @MainActor
    func provisionalBreakBlocksLaterOfflineChainUntilSourceFinishAcceptance() async throws {
        let scenario = "auto-start-owner-expiry"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 1
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        let breakTimer = try #require(model.canonicalTimer)
        model.finish(at: breakTimer.anchorAt.addingTimeInterval(breakTimer.plannedDuration))
        model.selectPhase(.focus)
        model.start()
        let nextFocus = try #require(model.canonicalTimer)

        await model.restore()
        await waitForSyncToDrain(model)

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let commandBatches = try syncs.map { try #require(try requestJSON($0)["commands"] as? [[String: Any]]) }
        #expect(commandBatches.count == 2)
        #expect(commandBatches[0].map { $0["timerId"] as? String } == [focus.id, focus.id])
        #expect(commandBatches[0].last?["id"] as? String == provisional.finishCommandId)
        #expect(commandBatches[1].map { $0["timerId"] as? String } == [nextFocus.id])
        #expect(commandBatches[1].compactMap { $0["type"] as? String } == ["start"])
        #expect(model.canonicalTimer?.id == nextFocus.id)
    }

    @Test @MainActor
    func provisionalChainCoversEveryOutcomePhaseRestartAndResponseLoss() async throws {
        let chains: [[CommandType]] = [
            [.start],
            [.start, .pause],
            [.start, .pause, .resume],
            [.start, .finish],
            [.start, .cancel],
            [.start, .finish, .clear]
        ]
        var caseIndex = 0
        for chain in chains {
            let expectedTypes = chain.flatMap {
                $0 == .cancel ? [CommandType.cancel, .clear] : [$0]
            }.map(\.rawValue)
            for outcome in ["applied", "ignored", "rejected"] {
                for correctsToLong in [false, true] {
                    for restartsBeforeHTTP in [false, true] {
                        for losesResponse in [false, true] {
                            caseIndex += 1
                            let scenario = [
                                "auto-start-matrix",
                                outcome,
                                correctsToLong ? "long" : "short",
                                losesResponse ? "lost" : "delivered",
                                String(caseIndex)
                            ].joined(separator: "-")
                            let label = [
                                chain.map(\.rawValue).joined(separator: ","),
                                outcome,
                                correctsToLong ? "long" : "short",
                                restartsBeforeHTTP ? "restart" : "live",
                                losesResponse ? "lost" : "delivered"
                            ].joined(separator: "/")
                            let suiteName = "PomodoroughTests.\(UUID().uuidString)"
                            let defaults = try #require(UserDefaults(suiteName: suiteName))
                            var state = PersistedTimerState.fresh()
                            state.cachedUser = TestFixtures.user
                            state.autoStartBreaks = true
                            defaults.set(
                                try JSONEncoder.api.encode(state),
                                forKey: "timer-state-v2"
                            )
                            let session = TestFixtures.session(for: scenario)
                            var model: AppModel? = AppModel(
                                api: APIClient(
                                    session: session,
                                    keychain: StaticTokenStore()
                                ),
                                defaults: defaults,
                                alarmScheduler: RecordingAlarmScheduler(),
                                retryDelay: .milliseconds(1)
                            )
                            model?.start()
                            let focus = try #require(model?.canonicalTimer, "\(label): focus")
                            model?.finish(
                                at: focus.anchorAt.addingTimeInterval(
                                    focus.plannedDuration
                                )
                            )
                            let provisional = try #require(
                                persistedState(defaults).provisionalBreaks.first,
                                "\(label): provisional"
                            )
                            for action in chain.dropFirst() {
                                let timer = try #require(
                                    model?.canonicalTimer,
                                    "\(label): dependent timer"
                                )
                                let date = timer.anchorAt.addingTimeInterval(1)
                                switch action {
                                case .start:
                                    Issue.record("\(label): unexpected second start")
                                case .pause:
                                    model?.pause(at: date)
                                case .resume:
                                    model?.resume(at: date)
                                case .finish:
                                    model?.finish(at: date)
                                case .cancel:
                                    model?.cancel(at: date)
                                case .clear:
                                    model?.clear()
                                }
                            }
                            if restartsBeforeHTTP {
                                model = nil
                                model = AppModel(
                                    api: APIClient(
                                        session: session,
                                        keychain: StaticTokenStore()
                                    ),
                                    defaults: defaults,
                                    alarmScheduler: RecordingAlarmScheduler(),
                                    retryDelay: .milliseconds(1)
                                )
                            }
                            await model?.restore()
                            if let model {
                                await waitForSyncToDrain(model)
                            }

                            let breakCommands = try TestFixtures.recordedRequests(
                                for: scenario
                            )
                            .filter { $0.path == "/api/v1/sync" }
                            .flatMap {
                                try #require(
                                    try requestJSON($0)["commands"]
                                        as? [[String: Any]]
                                )
                            }
                            .filter {
                                $0["timerId"] as? String
                                    == provisional.breakTimerId
                            }
                            if outcome == "rejected" {
                                #expect(breakCommands.isEmpty, Comment(rawValue: label))
                            } else {
                                #expect(
                                    breakCommands.compactMap {
                                        $0["type"] as? String
                                    } == expectedTypes,
                                    Comment(rawValue: label)
                                )
                                let expectedPhase = correctsToLong
                                    && !chain.contains(.finish)
                                    ? TimerPhase.longBreak.rawValue
                                    : TimerPhase.shortBreak.rawValue
                                #expect(
                                    breakCommands.allSatisfy {
                                        $0["phase"] as? String == expectedPhase
                                    },
                                    Comment(rawValue: label)
                                )
                            }
                            #expect(
                                try persistedState(defaults).provisionalBreaks.isEmpty,
                                Comment(rawValue: label)
                            )
                            session.invalidateAndCancel()
                            model = nil
                            let reopened = AppModel(
                                defaults: defaults,
                                alarmScheduler: RecordingAlarmScheduler()
                            )
                            #expect(
                                reopened.pendingCommandCount == 0,
                                Comment(rawValue: label)
                            )
                            defaults.removePersistentDomain(forName: suiteName)
                        }
                    }
                }
            }
        }
    }

    @Test @MainActor
    func rejectedFocusFinishDropsProvisionalBreakAndCancelsItsAlarm() async throws {
        let scenario = "auto-start-provisional-finish-rejected"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        await model.restore()
        await model.waitForAlarmOperations()

        let sentCommands = try TestFixtures.recordedRequests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap { try #require(try requestJSON($0)["commands"] as? [[String: Any]]) }
        #expect(!sentCommands.contains { $0["id"] as? String == provisional.startCommandId })
        #expect(model.canonicalTimer?.id == focus.id)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.pendingCommandCount == 0)
        #expect(try persistedState(defaults).provisionalBreaks.isEmpty)
        #expect(Array(scheduler.operations.suffix(2)) == [
            .cancel(timerID: provisional.breakTimerId),
            .schedule(
                timerID: focus.id,
                phase: .focus,
                duration: focus.plannedDuration
            )
        ])
    }

    @Test(arguments: [true, false])
    @MainActor
    func ignoredFinishReleasesProvisionalBreakOnlyWithExactCompletion(
        _ exactCompletion: Bool
    ) async throws {
        let suffix = exactCompletion ? "exact" : "mismatch"
        let scenario = "auto-start-provisional-finish-ignored-\(suffix)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(
            persistedState(defaults).provisionalBreaks.first
        )

        await model.restore()
        await waitForSyncToDrain(model)

        let sentCommands = try TestFixtures.recordedRequests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap {
                try #require(
                    try requestJSON($0)["commands"] as? [[String: Any]]
                )
            }
        #expect(
            sentCommands.contains {
                $0["id"] as? String == provisional.startCommandId
            } == exactCompletion
        )
        #expect(try persistedState(defaults).provisionalBreaks.isEmpty)
        #expect(model.conflictMessage == nil)
        if exactCompletion {
            #expect(model.canonicalTimer?.id == provisional.breakTimerId)
            #expect(model.canonicalTimer?.status == .running)
        } else {
            #expect(model.canonicalTimer?.id == focus.id)
            #expect(model.canonicalTimer?.status == .completed)
            #expect(model.pendingCommandCount == 0)
        }
    }

    @Test @MainActor
    func rejectedFocusFinishDropsWholeProvisionalDependencyChain() async throws {
        let scenario = "auto-start-provisional-finish-rejected"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        let provisionalBreak = try #require(model.canonicalTimer)
        model.pause(at: provisionalBreak.anchorAt.addingTimeInterval(1))
        let pausedBreak = try #require(model.canonicalTimer)
        model.resume(at: pausedBreak.anchorAt.addingTimeInterval(1))
        let resumedBreak = try #require(model.canonicalTimer)
        model.cancel(at: resumedBreak.anchorAt.addingTimeInterval(1))

        await model.restore()
        await model.waitForAlarmOperations()

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let uploadedCommands = try syncs.flatMap {
            try #require(try requestJSON($0)["commands"] as? [[String: Any]])
        }
        #expect(syncs.count == 1)
        #expect(uploadedCommands.map { $0["timerId"] as? String } == [focus.id, focus.id])
        #expect(!uploadedCommands.contains { $0["timerId"] as? String == provisional.breakTimerId })
        #expect(model.canonicalTimer?.id == focus.id)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.pendingCommandCount == 0)
        #expect(try persistedState(defaults).provisionalBreaks.isEmpty)
        #expect(model.conflictMessage == "lost race")
        #expect(scheduler.operations.last == .schedule(
            timerID: focus.id,
            phase: .focus,
            duration: focus.plannedDuration
        ))
    }

    @Test @MainActor
    func rejectedProvisionalStartRebasesAndCancelsItsAlarm() async throws {
        let scenario = "auto-start-provisional-start-rejected"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        await model.restore()
        await model.waitForAlarmOperations()

        #expect(model.canonicalTimer?.id == focus.id)
        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.pendingCommandCount == 0)
        #expect(scheduler.operations.last == .cancel(timerID: provisional.breakTimerId))
    }

    @Test @MainActor
    func canonicalTimerSupersedesProvisionalBreakAndCancelsItsAlarm() async throws {
        let scenario = "auto-start-provisional-superseded"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        await model.restore()
        await model.waitForAlarmOperations()

        let sentCommands = try TestFixtures.recordedRequests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap { try #require(try requestJSON($0)["commands"] as? [[String: Any]]) }
        #expect(!sentCommands.contains { $0["id"] as? String == provisional.startCommandId })
        #expect(model.canonicalTimer?.id == "timer-remote-winner")
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.pendingCommandCount == 0)
        #expect(scheduler.operations.last == .cancel(timerID: provisional.breakTimerId))
    }

    @Test @MainActor
    func canonicalFourthFocusCorrectsProvisionalBreakToLongBeforeUpload() async throws {
        let scenario = "auto-start-stale-fourth"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let scheduler = RecordingAlarmScheduler()
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler
        )
        model.start()
        let focus = try #require(model.canonicalTimer)
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        #expect(model.canonicalTimer?.phase == .shortBreak)
        await model.restore()
        await model.waitForAlarmOperations()

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let commandBatches = try syncs.map { try #require(try requestJSON($0)["commands"] as? [[String: Any]]) }
        let uploadedBreak = try #require(commandBatches.flatMap { $0 }.first {
            $0["id"] as? String == provisional.startCommandId
        })
        #expect(commandBatches.first?.contains { $0["id"] as? String == provisional.startCommandId } == false)
        #expect(uploadedBreak["phase"] as? String == TimerPhase.longBreak.rawValue)
        #expect(model.canonicalTimer?.phase == .longBreak)
        #expect(model.completedFocusCount == 4)
        #expect(scheduler.operations.contains(.cancel(timerID: provisional.breakTimerId)))
        #expect(scheduler.operations.contains {
            if case .schedule(let timerID, let phase, _) = $0 {
                return timerID == provisional.breakTimerId && phase == .longBreak
            }
            return false
        })
    }

    @Test @MainActor
    func provisionalStartPast256BoundaryIsSupersededByNewerFocus() async throws {
        let scenario = "auto-start-dependency-boundary"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.autoStartBreaks = true
        let focus = TestFixtures.timer(
            status: .running,
            elapsed: 0,
            timerID: "timer-boundary-focus",
            durationMs: 300_000
        )
        state.canonicalTimer = focus
        state.localTimerOwners[focus.id] = state.deviceId
        state.pendingCommands = (1...255).map { sequence in
            TestFixtures.command(
                .clear,
                sequence: Int64(sequence),
                elapsed: 0,
                timerID: "timer-old-\(sequence)"
            )
        }
        state.nextSequence = 256
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )
        model.finish(at: focus.anchorAt.addingTimeInterval(focus.plannedDuration))
        let provisional = try #require(persistedState(defaults).provisionalBreaks.first)
        let breakTimer = try #require(model.canonicalTimer)
        model.finish(at: breakTimer.anchorAt.addingTimeInterval(breakTimer.plannedDuration))
        model.selectPhase(.focus)
        model.start()
        let successorFocus = try #require(model.canonicalTimer)
        #expect(model.pendingCommandCount == 260)
        await model.restore()
        await waitForSyncToDrain(model)

        let syncs = TestFixtures.recordedRequests(for: scenario).filter { $0.path == "/api/v1/sync" }
        let commandBatches = try syncs.map { try #require(try requestJSON($0)["commands"] as? [[String: Any]]) }
        #expect(commandBatches.map(\.count) == [256, 1])
        #expect(commandBatches[0].last?["id"] as? String == provisional.finishCommandId)
        #expect(!commandBatches[0].contains { $0["id"] as? String == provisional.startCommandId })
        #expect(!commandBatches[1].contains { $0["id"] as? String == provisional.startCommandId })
        #expect(!commandBatches[0].contains { $0["timerId"] as? String == successorFocus.id })
        #expect(commandBatches[1].first?["timerId"] as? String == successorFocus.id)
        #expect(model.pendingCommandCount == 0)
    }

    @Test @MainActor
    func remoteCompletedFocusNeverAutoStartsLocalBreak() async throws {
        let scenario = "auto-start-remote-completed"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler
        )

        await model.restore()

        #expect(model.autoStartBreaks)
        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.canonicalTimer?.phase == .focus)
        #expect(model.completedFocusCount == 1)
        #expect(model.pendingCommandCount == 0)
        #expect(scheduler.operations.isEmpty)
    }

    @Test @MainActor
    func fourFocusCycleUsesSyncedHistoryCustomDurationsAndLongFourthBreak() async throws {
        let scenario = "timer-cycle"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = try #require(FocusTask(title: "Cycle task"))
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        state.selectedTaskID = task.id
        state.knownTasks = [task]
        state.pendingTaskOperations = [TaskOperation(
            id: "task-operation-cycle",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_001,
            hlcCounter: 0
        )]
        state.pendingDurationOperations = TimerPhase.allCases.enumerated().map { index, phase in
            TestFixtures.durationOperation(
                id: "duration-operation-cycle-\(phase.rawValue)",
                phase: phase,
                durationMs: 60_000,
                wallMs: Int64(index + 2)
            )
        }
        state.settings.durationsMs = DurationValues(focus: 60_000, shortBreak: 60_000, longBreak: 60_000)
        state.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 5
        )]
        state.pendingSelectedTaskOperations = [TestFixtures.selectedTaskOperation(
            deviceID: state.deviceId,
            taskID: task.id,
            wallMs: 6
        )]
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let cycleNow = Date(timeIntervalSince1970: 1_784_620_800)
        let cycleUptime: TimeInterval = 1_000
        let model = AppModel(
            api: APIClient(
                session: session,
                keychain: StaticTokenStore(),
                wallNow: { cycleNow },
                uptime: { cycleUptime }
            ),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { cycleNow },
            uptime: { cycleUptime }
        )
        await model.restore()
        #expect(model.autoStartBreaks)
        #expect(model.selectedTaskID == task.id)

        for focusIndex in 1...4 {
            model.selectPhase(.focus)
            model.start()
            let focus = try #require(model.canonicalTimer)
            #expect(focus.phase == .focus)
            #expect(focus.taskId == task.id.uuidString.lowercased())
            #expect(focus.plannedDurationMs == 60_000)
            model.finish(at: focus.anchorAt.addingTimeInterval(60))

            let expectedBreak: TimerPhase = focusIndex == 4 ? .longBreak : .shortBreak
            let startedBreak = try #require(model.canonicalTimer)
            #expect(model.completedFocusCountToday == focusIndex)
            #expect(startedBreak.phase == expectedBreak)
            #expect(startedBreak.status == .running)
            #expect(startedBreak.taskId == nil)
            #expect(startedBreak.plannedDurationMs == 60_000)
            await waitForSyncToDrain(model)
            #expect(model.completedFocusCount == focusIndex)
            let completedFocuses = model.history.filter { $0.phase == .focus && $0.status == "completed" }
            #expect(completedFocuses.count == focusIndex)
            #expect(completedFocuses.allSatisfy { $0.taskId == task.id.uuidString.lowercased() })

            model.finish(at: startedBreak.anchorAt.addingTimeInterval(60))
            await waitForSyncToDrain(model)
        }

        #expect(model.history.filter { $0.phase == .shortBreak && $0.status == "completed" }.count == 3)
        #expect(model.history.filter { $0.phase == .longBreak && $0.status == "completed" }.count == 1)
        #expect(model.history.filter { $0.phase != .focus }.allSatisfy { $0.taskId == nil })
    }

    @Test @MainActor
    func bootstrapAutoStartKeepReplaceAndMergeHonorPresenceSemantics() async throws {
        for strategy in [
            BootstrapResolutionStrategy.keepRemote,
            .replaceRemote,
            .merge
        ] {
            let scenario = "bootstrap-auto-start-remote-true-\(strategy.rawValue)"
            let suiteName = "PomodoroughTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            var state = try bootstrapState(hasLocalHistory: true)
            if strategy == .merge {
                state.autoStartBreaks = true
                state.pendingAutoStartOperations = [TestFixtures.autoStartOperation(
                    deviceID: state.deviceId,
                    enabled: false,
                    wallMs: 10
                )]
            }
            defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
            let session = TestFixtures.session(for: scenario)
            defer { session.invalidateAndCancel() }
            let model = AppModel(
                api: APIClient(session: session, keychain: StaticTokenStore()),
                defaults: defaults,
                alarmScheduler: RecordingAlarmScheduler()
            )

            await model.restore()
            model.requestHistoryResolution(strategy)
            await model.confirmHistoryResolution()

            let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
                $0.path == "/api/v1/bootstrap/resolve"
            })
            let body = try requestJSON(resolve)
            let operations = try #require(body["autoStartOperations"] as? [[String: Any]])
            #expect(operations.count == (strategy == .merge ? 1 : 0))
            if let operation = operations.first {
                #expect(Set(operation.keys) == ["id", "enabled", "occurredAt", "hlcWallMs", "hlcCounter"])
                #expect(operation["deviceId"] == nil)
            }
            #expect(model.autoStartBreaks == (strategy == .keepRemote))
            #expect(model.pendingAutoStartOperationCount == 0)
        }
    }

    @Test @MainActor
    func legacyBootstrapOmissionPreservesRemoteAutoStartDuringReplace() async throws {
        let scenario = "bootstrap-auto-start-remote-true-legacy-omitted"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let commands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "legacy-local-timer"),
            TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "legacy-local-timer")
        ]
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = commands
        state.pendingBootstrapResolution = BootstrapResolveRequest(
            requestId: "bootstrap-legacy-omitted",
            deviceId: state.deviceId,
            expectedRevision: 8,
            strategy: .replaceRemote,
            commands: commands,
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: nil
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try !requestJSON(resolve).keys.contains("autoStartOperations"))
        #expect(model.autoStartBreaks)
        #expect(model.historyResolutionState == .none)
    }

    @Test @MainActor
    func legacyKeepRemoteOmissionPreservesUnsnapshottedAutoStartQueue() async throws {
        let scenario = "bootstrap-auto-start-remote-true-legacy-keep-omitted"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = PersistedTimerState.fresh()
        let pending = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: false,
            wallMs: 10
        )
        state.bootstrapUser = TestFixtures.user
        state.autoStartBreaks = true
        state.pendingAutoStartOperations = [pending]
        state.pendingBootstrapResolution = BootstrapResolveRequest(
            requestId: "bootstrap-legacy-keep-omitted",
            deviceId: state.deviceId,
            expectedRevision: 8,
            strategy: .keepRemote,
            commands: [],
            taskOperations: [],
            durationOperations: [],
            autoStartOperations: nil
        )
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let resolve = try #require(TestFixtures.recordedRequests(for: scenario).first {
            $0.path == "/api/v1/bootstrap/resolve"
        })
        #expect(try !requestJSON(resolve).keys.contains("autoStartOperations"))
        #expect(!model.autoStartBreaks)
        #expect(model.pendingAutoStartOperationCount == 1)
        let retained = try #require(
            persistedState(defaults).pendingAutoStartOperations.first
        )
        #expect(retained.id == pending.id)
        #expect(retained.deviceId == pending.deviceId)
        #expect(retained.enabled == pending.enabled)
        #expect(
            (retained.hlcWallMs, retained.hlcCounter)
                > (1_784_620_800_000, 4)
        )
        #expect(model.historyResolutionState == .none)
        #expect(model.isOffline)
    }

    @Test(arguments: ["equal", "higher"])
    @MainActor
    func normalSyncAppliesEqualAndHigherRevisionCanonicalSnapshots(_ revisionCase: String) async throws {
        let scenario = "sync-contract-revision-\(revisionCase)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder.api.encode(TestFixtures.syncContractState(includesPendingOperations: false)),
            forKey: "timer-state-v2"
        )
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        let expectedRevision: Int64 = revisionCase == "equal" ? 10 : 11
        let persisted = try persistedState(defaults)
        #expect(persisted.revision == expectedRevision)
        #expect(model.canonicalTimer?.id == "remote-associated-timer")
        #expect(model.history.map(\.id) == ["remote-history"])
        #expect(model.tasks.map(\.title) == ["Remote task"])
        #expect(model.durationMinutes(for: .focus) == 40)
        #expect(model.autoStartBreaks)
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: ["status", "elapsed"])
    @MainActor
    func canonicalStatusOrElapsedCorrectionReconcilesAlarm(
        _ correction: String
    ) async throws {
        let scenario = "sync-contract-alarm-\(correction)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let anchor = Date(timeIntervalSince1970: 1_784_620_800)
        var initial = TestFixtures.syncContractState(
            includesPendingOperations: false
        )
        initial.canonicalTimer = CanonicalTimer(
            id: "alarm-correction-timer",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 10_000,
            anchorAt: anchor,
            lastIntent: nil
        )
        initial.localTimerOwners[initial.canonicalTimer!.id] = initial.deviceId
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: scheduler,
            now: { anchor }
        )

        await model.restore()
        await model.waitForAlarmOperations()

        if correction == "status" {
            #expect(model.canonicalTimer?.status == .paused)
            #expect(scheduler.operations == [
                .cancel(timerID: "alarm-correction-timer")
            ])
        } else {
            #expect(model.canonicalTimer?.status == .running)
            #expect(model.canonicalTimer?.elapsedAtAnchorMs == 20_000)
            #expect(scheduler.operations == [
                .cancel(timerID: "alarm-correction-timer"),
                .schedule(
                    timerID: "alarm-correction-timer",
                    phase: .focus,
                    duration: 40
                )
            ])
        }
    }

    @Test(arguments: ["applied", "ignored", "rejected", "reordered"])
    @MainActor
    func allKnownAcknowledgementOutcomesAreTerminalAndExactReorderingIsAccepted(
        _ outcome: String
    ) async throws {
        let scenario = "sync-contract-ack-\(outcome)"
        let suiteName = "PomodoroughTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder.api.encode(TestFixtures.syncContractState(includesPendingOperations: true)),
            forKey: "timer-state-v2"
        )
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.restore()

        #expect(model.pendingChangeCount == 0)
        #expect(try persistedState(defaults).pendingCommands.isEmpty)
        #expect(try persistedState(defaults).pendingTaskOperations.isEmpty)
        #expect(try persistedState(defaults).pendingDurationOperations.isEmpty)
        #expect(try persistedState(defaults).pendingAutoStartOperations.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(model.conflictMessage == (outcome == "rejected" ? "lost race" : nil))
    }

    private func bootstrapState(hasLocalHistory: Bool) throws -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        state.pendingCommands = hasLocalHistory
            ? [
                TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer"),
                TestFixtures.command(.finish, sequence: 2, elapsed: 60_000, timerID: "local-timer")
            ]
            : [TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "local-timer")]
        state.pendingTaskOperations = [try taskOperation(title: "Local task")]
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-bootstrap",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 3
        )]
        return state
    }

    private func emptyBootstrapState() -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.bootstrapUser = TestFixtures.user
        return state
    }

    private func taskOperation(title: String) throws -> TaskOperation {
        let task = try #require(FocusTask(title: title))
        return TaskOperation(
            id: "task-operation-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002,
            hlcCounter: 0
        )
    }

    private func persistedState(_ defaults: UserDefaults) throws -> PersistedTimerState {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    private func requestJSON(_ request: RecordedRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func authenticatedIrohFrameRoundTripsStrictJSONMessage() throws {
        let secret = Data(0...31)
        let body = Data(#"{"kind":"hello","protocolVersion":1}"#.utf8)

        let received = try IrohFrameCodec.decode(
            try IrohFrameCodec.encode(body: body, roomSecret: secret),
            roomSecret: secret
        )
        let decoded = try StrictJSON.object(from: received)
        let object = try #require(decoded)

        #expect(object["kind"] as? String == "hello")
        #expect(object["protocolVersion"] as? Int == 1)
    }

    @MainActor
    private func waitForSyncToDrain(_ model: AppModel) async {
        for _ in 0..<200 {
            if model.pendingChangeCount == 0, !model.isSyncing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let error = model.errorMessage ?? "nil"
        Issue.record(
            "Sync did not drain queued changes: pending=\(model.pendingChangeCount), timerCommands=\(model.pendingCommandCount), syncing=\(model.isSyncing), offline=\(model.isOffline), error=\(error)"
        )
    }
}
