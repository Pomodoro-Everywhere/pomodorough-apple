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
            encoded == Data(#"{"autoStartBreaks":false,"deviceId":"device-compatibility","hasCorruptPendingOperations":false,"hasExplicitPhaseSelection":false,"history":[],"hlcCounter":0,"hlcWallMs":0,"knownTasks":[],"lastTrustedTimeMs":2000000,"legacyTaskAssignments":{},"localCommandDates":{},"localTimerOwners":{},"nextSequence":1,"pendingAutoStartOperations":[],"pendingCommands":[],"pendingDurationOperations":[],"pendingSelectedTaskOperations":[],"pendingTaskOperations":[],"provisionalBreaks":[],"provisionalPhaseAdvances":[],"revision":0,"selectedPhaseGeneration":0,"sequenceExhausted":false,"serverTimeAnchorMs":2000000,"serverTimeAnchorUptime":100,"serverTimeOffsetMs":125,"serverTimeUncertaintyMs":25,"settings":{"autoStartBreaks":false,"focusDurationMs":1500000,"longBreakDurationMs":900000,"selectedPhase":"focus","shortBreakDurationMs":300000},"tasks":[]}"#.utf8)
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
            "hasCorruptPendingOperations"
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
        #expect(decoded.tasks.isEmpty)
        #expect(decoded.knownTasks.isEmpty)
        #expect(!decoded.hasCorruptPendingOperations)
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
        "nextSequence",
        "pendingAutoStartOperations",
        "pendingCommands",
        "pendingDurationOperations",
        "pendingSelectedTaskOperations",
        "pendingTaskOperations",
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
