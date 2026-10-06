import Foundation
import Testing
@testable import Pomodorough

@Suite("Persisted State Compatibility")
struct PersistedStateCompatibilityTests {
    @Test
    func deterministicStateKeepsFlatPersistenceShape() throws {
        let encoded = try JSONEncoder.api.encode(Self.deterministicState())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(Set(object.keys) == Self.currentTopLevelKeys)
        #expect(object["deviceId"] as? String == "device-compatibility")
        #expect((object["pendingCommands"] as? [Any])?.isEmpty == true)
        #expect(object["serverTimeOffsetMs"] as? Int == 125)
        #expect(
            encoded == Data(#"{"autoStartBreaks":false,"deviceId":"device-compatibility","hasCorruptPendingOperations":false,"hasExplicitPhaseSelection":false,"history":[],"hlcCounter":0,"hlcWallMs":0,"knownTasks":[],"lastTrustedTimeMs":2000000,"legacyTaskAssignments":{},"legacyTimerDependencyUpgrade":false,"legacyUnresolvedCommandIDs":[],"localCommandDates":{},"localTimerOwners":{},"neverSentAutoStartOperationIDs":[],"neverSentCommandIDs":[],"neverSentDurationOperationIDs":[],"neverSentSelectedTaskOperationIDs":[],"neverSentTaskOperationIDs":[],"nextSequence":1,"pendingAutoStartOperations":[],"pendingCommands":[],"pendingDurationOperations":[],"pendingSelectedTaskOperations":[],"pendingTaskOperations":[],"pendingTimerDependencies":[],"provisionalBreaks":[],"provisionalPhaseAdvances":[],"revision":0,"selectedPhaseGeneration":0,"sequenceExhausted":false,"serverTimeAnchorMs":2000000,"serverTimeAnchorUptime":100,"serverTimeOffsetMs":125,"serverTimeUncertaintyMs":25,"settings":{"autoStartBreaks":false,"focusDurationMs":1500000,"longBreakDurationMs":900000,"selectedPhase":"focus","shortBreakDurationMs":300000},"tasks":[]}"#.utf8)
        )
    }

    @Test
    func legacyPayloadDecodesAdditiveDefaultsWithoutRenamingFields() throws {
        let encoded = try JSONEncoder.api.encode(Self.deterministicState())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in [
            "sequenceExhausted",
            "hlcWallMs",
            "hlcCounter",
            "serverTimeOffsetMs",
            "serverTimeUncertaintyMs",
            "serverTimeAnchorMs",
            "serverTimeAnchorUptime",
            "lastTrustedTimeMs",
            "lastUuidV7",
            "localCommandDates",
            "pendingTaskOperations",
            "pendingDurationOperations",
            "pendingAutoStartOperations",
            "pendingSelectedTaskOperations",
            "pendingTimerDependencies",
            "legacyTimerDependencyUpgrade",
            "legacyUnresolvedCommandIDs",
            "autoStartBreaks",
            "localTimerOwners",
            "provisionalBreaks",
            "provisionalPhaseAdvances",
            "selectedPhaseGeneration",
            "hasExplicitPhaseSelection",
            "tasks",
            "knownTasks",
            "selectedTaskID",
            "legacyTaskAssignments",
            "hasCorruptPendingOperations",
            "neverSentCommandIDs",
            "neverSentTaskOperationIDs",
            "neverSentDurationOperationIDs",
            "neverSentAutoStartOperationIDs",
            "neverSentSelectedTaskOperationIDs",
            "canonicalHeadWallMs",
            "canonicalHeadCounter"
        ] {
            object.removeValue(forKey: key)
        }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: legacyData)

        #expect(!decoded.sequenceExhausted)
        #expect(decoded.hlcWallMs == 0)
        #expect(decoded.hlcCounter == 0)
        #expect(decoded.serverTimeOffsetMs == nil)
        #expect(decoded.pendingTaskOperations.isEmpty)
        #expect(decoded.pendingDurationOperations.isEmpty)
        #expect(decoded.pendingAutoStartOperations.isEmpty)
        #expect(decoded.pendingSelectedTaskOperations.isEmpty)
        #expect(decoded.pendingTimerDependencies.isEmpty)
        #expect(!decoded.legacyTimerDependencyUpgrade)
        #expect(decoded.legacyUnresolvedCommandIDs.isEmpty)
        let upgraded = try JSONDecoder.api.decode(PersistedTimerState.self,
                                                  from: JSONEncoder.api.encode(decoded))
        #expect(!upgraded.legacyTimerDependencyUpgrade)
        #expect(decoded.tasks.isEmpty)
        #expect(decoded.knownTasks.isEmpty)
        #expect(!decoded.hasCorruptPendingOperations)
        #expect(decoded.neverSentCommandIDs.isEmpty)
        #expect(decoded.canonicalHeadWallMs == nil)
    }

    @Test
    func oldEmptyQueueRetiresUpgradeMarkerBeforeNewTimerWork() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.api.encode(Self.deterministicState())
        ) as? [String: Any])
        object.removeValue(forKey: "pendingTimerDependencies")
        object.removeValue(forKey: "legacyTimerDependencyUpgrade")
        object.removeValue(forKey: "legacyUnresolvedCommandIDs")
        let restored = try JSONDecoder.api.decode(PersistedTimerState.self, from:
            JSONSerialization.data(withJSONObject: object))

        #expect(restored.pendingCommands.isEmpty)
        #expect(!restored.legacyTimerDependencyUpgrade)
        var next = restored
        next.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        let restarted = try JSONDecoder.api.decode(PersistedTimerState.self,
                                                  from: JSONEncoder.api.encode(next))
        #expect(!restarted.legacyTimerDependencyUpgrade)
    }

    @Test
    func oldEmptyQueueWithPersistedMarkerRetiresOnDecode() throws {
        var state = Self.deterministicState()
        state.legacyTimerDependencyUpgrade = true
        let restored = try JSONDecoder.api.decode(PersistedTimerState.self,
                                                  from: JSONEncoder.api.encode(state))
        #expect(!restored.legacyTimerDependencyUpgrade)
        #expect(restored.pendingCommands.isEmpty)
    }

    @Test
    func oldPendingQueueKeepsMarkerAcrossUnrelatedOperationAndRestart() throws {
        var state = Self.deterministicState()
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.api.encode(state)
        ) as? [String: Any])
        object.removeValue(forKey: "pendingTimerDependencies")
        object.removeValue(forKey: "legacyTimerDependencyUpgrade")
        object.removeValue(forKey: "legacyUnresolvedCommandIDs")
        var old = try JSONDecoder.api.decode(PersistedTimerState.self, from:
            JSONSerialization.data(withJSONObject: object))
        old.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "unrelated-duration", phase: .focus, durationMs: 1_500_000, wallMs: 1_001_000
        )]
        let restarted = try JSONDecoder.api.decode(PersistedTimerState.self,
                                                  from: JSONEncoder.api.encode(old))

        #expect(restarted.legacyTimerDependencyUpgrade)
        #expect(restarted.legacyUnresolvedCommandIDs == Set(state.pendingCommands.map(\.id)))
        #expect(restarted.pendingCommands == state.pendingCommands)
        #expect(restarted.pendingDurationOperations == old.pendingDurationOperations)
    }

    @Test
    func previousBooleanOnlyUpgradeCapturesIDsOnce() throws {
        var state = Self.deterministicState()
        let old = TestFixtures.command(.finish, sequence: 1, elapsed: 60_000)
        state.pendingCommands = [old]
        state.legacyTimerDependencyUpgrade = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(state)) as? [String: Any])
        object.removeValue(forKey: "legacyUnresolvedCommandIDs")
        var upgraded = try JSONDecoder.api.decode(PersistedTimerState.self, from:
            JSONSerialization.data(withJSONObject: object))
        #expect(upgraded.legacyUnresolvedCommandIDs == [old.id])
        let new = TestFixtures.command(.start, sequence: 2, elapsed: 0, timerID: "new-focus")
        upgraded.pendingCommands.append(new)
        let restarted = try JSONDecoder.api.decode(PersistedTimerState.self,
                                                  from: JSONEncoder.api.encode(upgraded))
        #expect(restarted.legacyUnresolvedCommandIDs == [old.id])
        #expect(restarted.pendingCommands.map(\.id) == [old.id, new.id])
    }

    @Test(arguments: [false, true])
    func malformedLegacyIDSetCannotDefaultToUnquarantinedQueue(nullValue: Bool) throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.api.encode(Self.deterministicState())
        ) as? [String: Any])
        if nullValue {
            object["legacyUnresolvedCommandIDs"] = NSNull()
        } else {
            object["legacyUnresolvedCommandIDs"] = "invalid-id-set"
        }
        let encoded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.api.decode(PersistedTimerState.self, from: encoded)
        }
    }

    @Test
    func legacyIdentityWithoutRetainedPayloadFailsClosed() throws {
        var state = Self.deterministicState()
        state.legacyTimerDependencyUpgrade = true
        state.legacyUnresolvedCommandIDs = ["missing-old-command"]
        let encoded = try JSONEncoder.api.encode(state)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.api.decode(PersistedTimerState.self, from: encoded)
        }
    }

    @Test
    func accountChangeClearsOldMarkerAndEdgesOnlyWithItsQueue() throws {
        var state = Self.deterministicState()
        let owner = TestFixtures.user
        state.cachedUser = owner
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.pendingTimerDependencies = [CoreTimerDependency(
            operationId: "dependent", dependsOnOperationId: state.pendingCommands[0].id
        )]
        state.legacyTimerDependencyUpgrade = true
        state.legacyUnresolvedCommandIDs = Set(state.pendingCommands.map(\.id))
        var sameOwner = state
        sameOwner.prepare(for: owner)
        #expect(sameOwner == state)

        state.prepare(for: User(id: "another-user", email: "other@example.com", name: "Other", avatarUrl: ""))
        #expect(state.pendingCommands.isEmpty)
        #expect(state.pendingTimerDependencies.isEmpty)
        #expect(state.legacyUnresolvedCommandIDs.isEmpty)
        #expect(!state.legacyTimerDependencyUpgrade)
        let restarted = try JSONDecoder.api.decode(PersistedTimerState.self,
                                                  from: JSONEncoder.api.encode(state))
        #expect(!restarted.legacyTimerDependencyUpgrade)
    }

    @Test
    func retainedCoreTimerEdgeRoundTripsAndDoesNotCrossAccountOwnership() throws {
        var state = Self.deterministicState()
        state.cachedUser = TestFixtures.user
        state.pendingTimerDependencies = [CoreTimerDependency(
            operationId: "child-finish", dependsOnOperationId: "generated-start"
        )]
        let encoded = try JSONEncoder.api.encode(state)
        let restored = try JSONDecoder.api.decode(PersistedTimerState.self, from: encoded)
        #expect(restored.pendingTimerDependencies == state.pendingTimerDependencies)
        #expect(!restored.legacyTimerDependencyUpgrade)

        var switched = restored
        switched.prepare(for: User(id: "another-user", email: "other@example.com", name: "Other", avatarUrl: ""))
        #expect(switched.pendingTimerDependencies.isEmpty)
        #expect(!switched.legacyTimerDependencyUpgrade)
        #expect(switched.deviceId == state.deviceId)
    }

    @Test
    func stableDomainModelsKeepWireNamesAndBytes() throws {
        #expect(try JSONEncoder.api.encode(TimerPhase.shortBreak) == Data(#""short_break""#.utf8))
        #expect(
            try JSONEncoder.api.encode(DurationValues(
                focus: 1_500_000,
                shortBreak: 300_000,
                longBreak: 900_000
            )) == Data(#"{"focus":1500000,"long_break":900000,"short_break":300000}"#.utf8)
        )

        var settings = TimerSettings()
        settings.selectedPhase = .longBreak
        settings.autoStartBreaks = true
        #expect(
            try JSONEncoder.api.encode(settings)
                == Data(#"{"autoStartBreaks":true,"focusDurationMs":1500000,"longBreakDurationMs":900000,"selectedPhase":"long_break","shortBreakDurationMs":300000}"#.utf8)
        )
    }

    @Test @MainActor
    func appModelKeepsInjectedClockAndCoreProviderSeams() throws {
        let suiteName = "PersistedStateCompatibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            retryDelay: .milliseconds(25),
            now: { now },
            uptime: { 100 },
            sharedCoreProvider: { throw CompatibilityError.unavailable }
        )

        #expect(model.sessionState == .restoring)
        #expect(model.selectedPhase == .focus)
        #expect(model.durationMinutes(for: .focus) == 25)
        #expect(model.pendingChangeCount == 0)
        #expect(!model.isWorkspaceMutationBlocked)
    }

    @Test
    func loaderPrefersCurrentStateOverLegacyState() throws {
        let suiteName = "PersistedStateCompatibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var current = Self.deterministicState()
        current.deviceId = "current"
        var legacy = Self.deterministicState()
        legacy.deviceId = "legacy"
        defaults.set(try JSONEncoder.api.encode(current), forKey: PersistedStateLoader.storageKey)
        defaults.set(try JSONEncoder.api.encode(legacy), forKey: PersistedStateLoader.legacyStorageKey)

        let load = PersistedStateLoader(defaults: defaults).load()

        #expect(load.decodedState?.deviceId == "current")
        #expect(load.localState.deviceId == "current")
    }

    @Test
    func loaderReturnsTypedLegacyMigrationTransition() throws {
        let suiteName = "PersistedStateCompatibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let encoded = try JSONEncoder.api.encode(Self.deterministicState())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pendingDurationOperations")
        object.removeValue(forKey: "pendingAutoStartOperations")
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: PersistedStateLoader.storageKey
        )
        let loader = PersistedStateLoader(defaults: defaults)
        let load = loader.load()

        let transition = loader.migrating(
            load.localState,
            from: load,
            replicationMode: .centralized,
            wallDate: Date(timeIntervalSince1970: 2_000),
            uptime: 100
        )

        #expect(transition.migrations.contains(.durationSettings))
        #expect(transition.migrations.contains(.autoStartBreaks))
        #expect(!transition.migrationFailed)
        #expect(transition.stagedStateWasValid)
        #expect(transition.shouldPersist(projectionSucceeded: true))
        #expect(!transition.shouldPersist(projectionSucceeded: false))
    }

    @Test
    func trustedClockReturnsTypedMonotonicTransitionAndResample() throws {
        let clock = TrustedClockState(
            offsetMs: 125,
            uncertaintyMs: 25,
            anchorMs: 2_000_000,
            anchorUptime: 100,
            lastEmittedMs: 2_000_500
        )

        let occurrence = try clock.occurrenceTransition(
            for: Date(timeIntervalSince1970: 0),
            uptime: 100
        )
        #expect(occurrence.trustedDate == Date(timeIntervalSince1970: 2_000.501))
        #expect(occurrence.state == clock)

        let resample = try clock.resampled(
            serverTimeMs: 3_000_000,
            requestWallMs: 2_900_000,
            requestUptime: 10,
            responseUptime: 12
        )
        #expect(resample.state.offsetMs == 99_000)
        #expect(resample.state.uncertaintyMs == 1_000)
        #expect(resample.state.anchorMs == 3_001_000)
        #expect(resample.state.anchorUptime == 12)
        #expect(resample.state.lastEmittedMs == clock.lastEmittedMs)
    }

    private enum CompatibilityError: Error {
        case unavailable
    }

    private static func deterministicState() -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-compatibility"
        state.serverTimeOffsetMs = 125
        state.serverTimeUncertaintyMs = 25
        state.serverTimeAnchorMs = 2_000_000
        state.serverTimeAnchorUptime = 100
        state.lastTrustedTimeMs = 2_000_000
        return state
    }

    private static let currentTopLevelKeys: Set<String> = [
        "autoStartBreaks",
        "deviceId",
        "hasCorruptPendingOperations",
        "hasExplicitPhaseSelection",
        "history",
        "hlcCounter",
        "hlcWallMs",
        "knownTasks",
        "legacyTaskAssignments",
        "localCommandDates",
        "localTimerOwners",
        "neverSentAutoStartOperationIDs",
        "neverSentCommandIDs",
        "neverSentDurationOperationIDs",
        "neverSentSelectedTaskOperationIDs",
        "neverSentTaskOperationIDs",
        "nextSequence",
        "pendingAutoStartOperations",
        "pendingCommands",
        "pendingDurationOperations",
        "pendingSelectedTaskOperations",
        "pendingTaskOperations",
        "pendingTimerDependencies",
        "legacyTimerDependencyUpgrade",
        "legacyUnresolvedCommandIDs",
        "provisionalBreaks",
        "provisionalPhaseAdvances",
        "revision",
        "selectedPhaseGeneration",
        "sequenceExhausted",
        "serverTimeAnchorMs",
        "serverTimeAnchorUptime",
        "serverTimeOffsetMs",
        "serverTimeUncertaintyMs",
        "lastTrustedTimeMs",
        "settings",
        "tasks"
    ]
}
