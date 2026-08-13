import Foundation
import Security
import Testing
@testable import Pomodorough

@Suite("Unit Negative")
struct UnitNegativeTests {
    @Test func keychainLoadRejectsSecurityFailureMissingDataAndMalformedData() throws {
        let failedSecurity = RecordingKeychainSecurity(copyStatus: errSecAuthFailed)
        do {
            _ = try KeychainStore(security: failedSecurity).load()
            Issue.record("Expected keychain load failure")
        } catch let error as KeychainError {
            #expect(error.operation == "load")
            #expect(error.status == errSecAuthFailed)
            #expect(error.message == "test status \(errSecAuthFailed)")
        }

        #expect(throws: KeychainError.self) {
            _ = try KeychainStore(security: RecordingKeychainSecurity(
                copyStatus: errSecSuccess,
                copyData: nil
            )).load()
        }
        #expect(throws: DecodingError.self) {
            _ = try KeychainStore(security: RecordingKeychainSecurity(
                copyStatus: errSecSuccess,
                copyData: Data("not-json".utf8)
            )).load()
        }
    }

    @Test func keychainSaveSurfacesUpdateAndAddFailuresWithoutFallbackWrites() {
        let updateFailure = RecordingKeychainSecurity(updateStatus: errSecInteractionNotAllowed)
        do {
            try KeychainStore(security: updateFailure).save(keychainFailureTokens)
            Issue.record("Expected keychain update failure")
        } catch let error as KeychainError {
            #expect(error.operation == "save (update)")
            #expect(error.status == errSecInteractionNotAllowed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(updateFailure.addQueries.isEmpty)

        let addFailure = RecordingKeychainSecurity(
            updateStatus: errSecItemNotFound,
            addStatus: errSecAuthFailed
        )
        do {
            try KeychainStore(security: addFailure).save(keychainFailureTokens)
            Issue.record("Expected keychain add failure")
        } catch let error as KeychainError {
            #expect(error.operation == "save (add)")
            #expect(error.status == errSecAuthFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(addFailure.updates.count == 1)
        #expect(addFailure.addQueries.count == 1)
    }

    @Test func keychainDeleteSurfacesSecurityFailure() {
        let security = RecordingKeychainSecurity(deleteStatus: errSecInteractionNotAllowed)
        do {
            try KeychainStore(security: security).delete()
            Issue.record("Expected keychain delete failure")
        } catch let error as KeychainError {
            #expect(error.operation == "delete")
            #expect(error.status == errSecInteractionNotAllowed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(security.deleteQueries.count == 1)
    }

    @Test func checkedSequenceAndCounterOverflowRejectWithoutMutation() {
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var sequenceState = PersistedTimerState.fresh()
        sequenceState.nextSequence = WireBounds.maxSafeInteger
        sequenceState.sequenceExhausted = true
        let originalSequenceState = sequenceState

        #expect(throws: AppError.self) {
            try sequenceState.reserveDeviceSequence()
        }
        #expect(sequenceState == originalSequenceState)

        var clockState = PersistedTimerState.fresh()
        clockState.hlcWallMs = 1_000_000
        clockState.hlcCounter = WireBounds.maxSafeInteger
        let originalClockState = clockState

        #expect(throws: AppError.self) {
            try clockState.advanceClock(at: occurrence)
        }
        #expect(clockState == originalClockState)
    }

    @Test func uuidV7RejectsMalformedPersistedCursorWithoutMutation() {
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 1_000
        state.lastUuidV7 = UUID()
        let original = state

        #expect(throws: AppError.self) {
            try state.reserveUuidV7()
        }
        #expect(state == original)
    }

    @Test func uuidV7RejectsStalePersistedCursorWithoutMutation() throws {
        let stored = try UUIDv7.make(timestampMs: 1_000, randomHigh: 0, randomLow: 1)
        let queued = try UUIDv7.make(timestampMs: 1_000, randomHigh: 0, randomLow: 2)
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 1_000
        state.lastUuidV7 = stored
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-\(queued.uuidString.lowercased())",
            phase: .focus,
            durationMs: 60_000,
            wallMs: 1_000
        )]
        let original = state

        #expect(throws: AppError.self) {
            try state.reserveUuidV7()
        }
        #expect(state == original)
    }

    @Test func uuidV7RejectsTimestampAndTailOverflowWithoutMutation() throws {
        var unsafeTimestamp = PersistedTimerState.fresh()
        unsafeTimestamp.hlcWallMs = UUIDv7.maxTimestampMs + 1
        let originalTimestamp = unsafeTimestamp

        #expect(throws: AppError.self) {
            try unsafeTimestamp.reserveUuidV7()
        }
        #expect(unsafeTimestamp == originalTimestamp)

        var exhaustedTail = PersistedTimerState.fresh()
        exhaustedTail.hlcWallMs = 1_000
        exhaustedTail.lastUuidV7 = try UUIDv7.make(
            timestampMs: 1_000,
            randomHigh: UUIDv7.maxRandomHigh,
            randomLow: UUIDv7.maxRandomLow
        )
        let originalTail = exhaustedTail

        #expect(throws: AppError.self) {
            try exhaustedTail.reserveUuidV7()
        }
        #expect(exhaustedTail == originalTail)
    }

    @Test func trustedTimeRejectsMoreThanFiveMinutesSkewWithoutMutation() {
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 1_300_001
        let original = state

        #expect(throws: AppError.self) {
            try state.advanceClock(at: occurrence)
        }
        #expect(state == original)
    }

    @Test func normalOperationsRejectZeroClockAndLegacySentinelRequiresEpoch() {
        let nonEpoch = Date(timeIntervalSince1970: 1)
        let task = TaskOperation(
            id: "task-zero-clock",
            taskId: "aaf83054-24b2-8c0e-901f-a974147bfe82",
            type: .delete,
            title: nil,
            occurredAt: nonEpoch,
            hlcWallMs: 0,
            hlcCounter: 0
        )
        let duration = TestFixtures.durationOperation(
            id: "duration-zero-clock-non-epoch",
            phase: .focus,
            durationMs: 60_000,
            wallMs: 0,
            occurredAt: nonEpoch
        )
        let autoStart = TestFixtures.autoStartOperation(
            enabled: true,
            wallMs: 0,
            occurredAt: nonEpoch
        )

        #expect(!task.isValid)
        #expect(!duration.isValid)
        #expect(!autoStart.isValid)
    }

    @Test func serverClockSampleRejectsHLCOutsideServerTimeSkewWithoutMutation() {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        var state = PersistedTimerState.fresh()
        let original = state

        #expect(throws: AppError.self) {
            try state.mergeClock(
                serverWallMs: 2_300_001,
                serverCounter: 0,
                serverTime: serverTime,
                requestWall: serverTime.addingTimeInterval(3_600),
                requestUptime: 100,
                responseUptime: 100
            )
        }
        #expect(state == original)
    }

    @Test func serverClockSampleRejectsExcessiveUncertaintyWithoutMutation() {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        var state = PersistedTimerState.fresh()
        state.serverTimeOffsetMs = 123
        state.serverTimeUncertaintyMs = 10
        let original = state

        #expect(throws: AppError.self) {
            try state.mergeClock(
                serverWallMs: 2_000_000,
                serverCounter: 0,
                serverTime: serverTime,
                requestWall: serverTime,
                requestUptime: 100,
                responseUptime: 160.002
            )
        }
        #expect(state == original)
    }

    @Test func retainedOperationWithoutCanonicalHeadroomRejectsWithoutMutation() throws {
        let task = try #require(FocusTask(title: "Future retained task"))
        let operation = TaskOperation(
            id: "task-operation-future",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: Date(timeIntervalSince1970: 1_000.101),
            hlcWallMs: 1_000_101,
            hlcCounter: 0
        )
        var state = PersistedTimerState.fresh()
        state.pendingTaskOperations = [operation]
        let original = state

        #expect(throws: AppError.self) {
            try state.rebasePendingOperations(
                afterServerWallMs: 1_300_100,
                serverCounter: WireBounds.maxSafeInteger,
                serverTime: Date(timeIntervalSince1970: 1_000.1)
            )
        }
        #expect(state == original)
    }

    @Test func serverClockSampleRejectsReversedOrUnsafeWallArithmeticWithoutMutation() {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        for (requestWall, requestUptime, responseUptime) in [
            (serverTime, 101.0, 100.0),
            (Date(timeIntervalSince1970: .infinity), 100.0, 100.0)
        ] {
            var state = PersistedTimerState.fresh()
            let original = state

            #expect(throws: AppError.self) {
                try state.mergeClock(
                    serverWallMs: 2_000_000,
                    serverCounter: 0,
                    serverTime: serverTime,
                    requestWall: requestWall,
                    requestUptime: requestUptime,
                    responseUptime: responseUptime
                )
            }
            #expect(state == original)
        }
    }

    @Test func persistedHalfSampleFailsClosed() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(
            PersistedTimerState.fresh()
        )) as? [String: Any])
        object["serverTimeUncertaintyMs"] = 1

        let state = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(state.serverTimeOffsetMs == nil)
        #expect(state.serverTimeUncertaintyMs == 1)
        #expect(!state.hasValidGeneratorState)
        #expect(throws: AppError.self) {
            try state.trustedOccurrenceDate(for: TestFixtures.anchor, uptime: 100)
        }
    }

    @Test func physicalMillisecondsRejectsUnsafeDoubleBoundaryAndSubMillisecondEpoch() {
        #expect(WireBounds.physicalMilliseconds(for: Date(
            timeIntervalSince1970: 9_007_199_254_740_992.0 / 1_000
        )) == nil)
        #expect(WireBounds.physicalMilliseconds(for: Date(timeIntervalSince1970: 0.0009)) == nil)
    }

    @Test func resamplePreflightRejectsCorruptLastTrustedTimestamp() {
        var state = PersistedTimerState.fresh()
        state.lastTrustedTimeMs = WireBounds.maxSafeInteger + 1

        #expect(!state.hasValidPendingWireOperationsForResample)
    }

    @Test func taskRejectsTitleContainingOnlyInvisibleEdges() {
        #expect(FocusTask(title: "\u{0000}\t\n") == nil)
    }

    @Test func malformedTaskUpsertDoesNotDeleteExistingTask() throws {
        let task = try #require(FocusTask(title: "Existing"))
        let malformed = TaskOperation(
            id: "task-operation-malformed",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: "Different identity",
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1,
            hlcCounter: 0
        )

        #expect(TaskReducer.applying([malformed], to: [task]) == [task])
    }

    @Test func timerAlarmIdentityRejectsMalformedTimerIDs() {
        #expect(TimerAlarmScheduler.alarmID(for: "remote-timer") == nil)
        #expect(TimerAlarmScheduler.alarmID(for: "timer-not-a-uuid") == nil)
    }

    @Test @MainActor
    func timerAlarmSchedulerRejectsDeniedAuthorizationAndNotificationFallback() async {
        let notifications = RecordingNotificationBackend()
        let alarms = RecordingSystemAlarmBackend()
        alarms.authorizationState = .denied
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        await #expect(throws: TimerAlarmError.self) {
            try await scheduler.requestAuthorization()
        }
        await #expect(throws: TimerAlarmError.self) {
            try await scheduler.schedule(timerID: "remote-timer", phase: .focus, duration: 60)
        }
        #expect(notifications.operations == [.requestAuthorization, .canSchedule])
        #expect(alarms.operations.isEmpty)
    }

    @Test @MainActor
    func timerAlarmSchedulerPropagatesSelectedBackendFailures() async throws {
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        notifications.schedulingError = AppError.invalidResponse
        let alarms = RecordingSystemAlarmBackend()
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        await #expect(throws: AppError.self) {
            try await scheduler.schedule(timerID: "remote-timer", phase: .focus, duration: 60)
        }

        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))
        alarms.authorizationState = .authorized
        try await alarms.schedule(id: uuid, timerID: "timer-\(uuid.uuidString.lowercased())", phase: .focus, duration: 60)
        alarms.operationError = AppError.invalidResponse
        await #expect(throws: AppError.self) {
            try await scheduler.pause(timerID: "timer-\(uuid.uuidString.lowercased())")
        }
    }

    @Test @MainActor
    func timerAlarmSchedulerKeepsExistingNotificationWhenAlarmReplacementFails() async throws {
        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))
        let timerID = "timer-\(uuid.uuidString.lowercased())"
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        let alarms = RecordingSystemAlarmBackend()
        alarms.authorizationState = .denied
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)
        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)

        alarms.authorizationState = .authorized
        alarms.operationError = AppError.invalidResponse
        await #expect(throws: AppError.self) {
            try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 30)
        }

        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: notificationID, phase: .focus, duration: 60),
        ])
    }

    @Test func settingsClampDurationsOutsideAPIContract() {
        var settings = TimerSettings()

        settings.setMinutes(0, for: .focus)
        settings.setMinutes(999, for: .longBreak)

        #expect(settings.minutes(for: .focus) == 1)
        #expect(settings.minutes(for: .longBreak) == 180)
    }

    @Test func legacyMinuteDecodingClampsBeforeIntegerConversion() throws {
        let json = Data(
            "{\"focusMinutes\":\(Int.max),\"shortBreakMinutes\":\(Int.min),\"longBreakMinutes\":15}".utf8
        )

        let settings = try JSONDecoder.api.decode(TimerSettings.self, from: json)

        #expect(settings.durationMs(for: .focus) == DurationValues.validRange.upperBound)
        #expect(settings.durationMs(for: .shortBreak) == DurationValues.validRange.lowerBound)
    }

    @Test func persistedMillisecondDurationsNormalizeToDisplayedMinutes() throws {
        let json = Data(
            #"{"focusDurationMs":90000,"shortBreakDurationMs":300000,"longBreakDurationMs":900000}"#.utf8
        )

        let settings = try JSONDecoder.api.decode(TimerSettings.self, from: json)

        #expect(settings.minutes(for: .focus) == 2)
        #expect(settings.durationMs(for: .focus) == 120_000)
    }

    @Test func canonicalAndOperationValidationRejectSubMinuteValues() {
        let durations = DurationValues(
            focus: 60_001,
            shortBreak: DurationValues.defaults.shortBreak,
            longBreak: DurationValues.defaults.longBreak
        )
        let operation = TestFixtures.durationOperation(
            id: "duration-operation-subminute",
            phase: .focus,
            durationMs: 60_001,
            wallMs: 1
        )

        #expect(!durations.isValid)
        #expect(!operation.isValid)
    }

    @Test func persistedPendingDurationsRetainMalformedHLCForFailClosedPreflight() throws {
        var state = PersistedTimerState.fresh()
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-malformed",
            phase: .focus,
            durationMs: 60_000,
            wallMs: 0,
            counter: 1
        )]
        let data = try JSONEncoder.api.encode(state)

        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: data)

        #expect(decoded.pendingDurationOperations == state.pendingDurationOperations)
        #expect(!decoded.hasValidPendingWireOperations)
    }

    @Test func persistedPendingAutoStartRetainsDecodableCorruptionForFailClosedPreflight() throws {
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-local"
        state.autoStartBreaks = true
        let valid = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: false,
            wallMs: 1
        )
        let zeroWall = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 0
        )
        let negativeWall = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: -1
        )
        let foreign = TestFixtures.autoStartOperation(
            deviceID: "device-foreign",
            enabled: true,
            wallMs: 2
        )
        state.pendingAutoStartOperations = [valid, zeroWall, negativeWall, foreign, valid]
        let data = try JSONEncoder.api.encode(state)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var operations = try #require(object["pendingAutoStartOperations"] as? [[String: Any]])
        operations.append(["enabled": true, "hlcWallMs": 3])
        object["pendingAutoStartOperations"] = operations
        let malformedData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.api.decode(PersistedTimerState.self, from: malformedData)

        #expect(zeroWall.isValid)
        #expect(!negativeWall.isValid)
        #expect(decoded.pendingAutoStartOperations == [valid, zeroWall, negativeWall, foreign, valid])
        #expect(decoded.hasCorruptPendingOperations)
        #expect(!decoded.hasValidPendingWireOperations)
        #expect(decoded.autoStartBreaks)
    }

    @Test func syncResponseRequiresFixedDurationFields() {
        let json = Data(
            #"{"acknowledgements":[],"revision":0,"canonicalTimer":null,"history":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(SyncResponse.self, from: json)
        }
    }

    @Test func syncResponseRequiresCanonicalTasksField() {
        let json = Data(
            #"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"autoStartAcknowledgements":[],"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"autoStartBreaks":false,"revision":1,"canonicalTimer":null,"history":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(SyncResponse.self, from: json)
        }
    }

    @Test(
        arguments: [
            "acknowledgements",
            "taskAcknowledgements",
            "durationAcknowledgements",
            "autoStartAcknowledgements",
            "selectedTaskAcknowledgements",
            "durationsMs",
            "autoStartBreaks",
            "selectedTaskId",
            "revision",
            "canonicalTimer",
            "history",
            "tasks",
            "serverTime",
            "serverHlcWallMs",
            "serverHlcCounter"
        ]
    )
    func bootstrapResponseRequiresEveryCanonicalField(_ missingKey: String) throws {
        let complete = Data(
            #"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[],"selectedTaskId":null,"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"autoStartBreaks":false,"revision":1,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )
        var object = try #require(JSONSerialization.jsonObject(with: complete) as? [String: Any])
        object.removeValue(forKey: missingKey)
        let incomplete = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(BootstrapResponse.self, from: incomplete)
        }
    }

    @Test func bootstrapResponseRejectsMalformedCanonicalTimer() throws {
        let json = Data(
            #"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[],"selectedTaskId":null,"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"autoStartBreaks":false,"revision":1,"canonicalTimer":"invalid","history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(BootstrapResponse.self, from: json)
        }
    }

    @Test func durationSyncRejectsDuplicateAcknowledgementsWithoutMutatingState() {
        var state = PersistedTimerState.fresh()
        let operation = TestFixtures.durationOperation(
            id: "duration-operation-test",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 1
        )
        state.pendingDurationOperations = [operation]
        state.settings.setMinutes(30, for: .focus)
        let original = state
        let acknowledgement = DurationAcknowledgement(
            operationId: operation.id,
            outcome: .applied,
            reason: ""
        )

        #expect(throws: AppError.self) {
            try state.applyDurationSync(
                canonicalDurations: .defaults,
                sentOperations: [operation],
                acknowledgements: [acknowledgement, acknowledgement]
            )
        }
        #expect(state == original)
    }

    @Test func autoStartSyncRejectsDuplicateAcknowledgementsWithoutMutatingState() {
        var state = PersistedTimerState.fresh()
        let operation = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 1
        )
        let acknowledgement = AutoStartAcknowledgement(
            operationId: operation.id,
            outcome: .applied,
            reason: ""
        )
        state.pendingAutoStartOperations = [operation]
        let original = state

        #expect(throws: AppError.self) {
            try state.applyAutoStartSync(
                canonicalValue: true,
                sentOperations: [operation],
                acknowledgements: [acknowledgement, acknowledgement]
            )
        }
        #expect(state == original)
    }

    @Test func autoStartSyncRejectsForeignLocalOperationWithoutMutatingState() {
        let operation = TestFixtures.autoStartOperation(
            deviceID: "device-foreign",
            enabled: true,
            wallMs: 1
        )
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-local"
        state.pendingAutoStartOperations = [operation]
        let original = state

        #expect(throws: AppError.self) {
            try state.applyAutoStartSync(
                canonicalValue: true,
                sentOperations: [operation],
                acknowledgements: [AutoStartAcknowledgement(
                    operationId: operation.id,
                    outcome: .applied,
                    reason: ""
                )]
            )
        }
        #expect(state == original)
    }

    @Test func selectedTaskSyncRejectsDuplicateAcknowledgementsWithoutMutatingState() throws {
        let task = try #require(FocusTask(title: "Selection validation"))
        var state = PersistedTimerState.fresh()
        let operation = TestFixtures.selectedTaskOperation(
            deviceID: state.deviceId,
            taskID: task.id,
            wallMs: 1
        )
        let acknowledgement = SelectedTaskAcknowledgement(
            operationId: operation.id,
            outcome: .applied,
            reason: ""
        )
        state.pendingSelectedTaskOperations = [operation]
        let original = state

        #expect(throws: AppError.self) {
            try state.applySelectedTaskSync(
                canonicalTaskId: task.id.uuidString.lowercased(),
                canonicalTasks: [task],
                sentOperations: [operation],
                acknowledgements: [acknowledgement, acknowledgement]
            )
        }
        #expect(state == original)
    }

    @Test func selectedTaskSyncRejectsCanonicalSelectionMissingFromTasks() throws {
        let task = try #require(FocusTask(title: "Missing canonical selection"))
        var state = PersistedTimerState.fresh()
        let original = state

        #expect(throws: AppError.self) {
            try state.applySelectedTaskSync(
                canonicalTaskId: task.id.uuidString.lowercased(),
                canonicalTasks: [],
                sentOperations: [],
                acknowledgements: []
            )
        }
        #expect(state == original)
    }

    @Test func syncResponseRejectsUnknownAutoStartAcknowledgementOutcome() {
        let operationID = UUID().uuidString.lowercased()
        let json = Data(
            #"{"acknowledgements":[],"durationAcknowledgements":[],"autoStartAcknowledgements":[{"operationId":"\#(operationID)","outcome":"unknown","reason":""}],"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"autoStartBreaks":true,"revision":0,"canonicalTimer":null,"history":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":0}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(SyncResponse.self, from: json)
        }
    }

    @Test(arguments: ["acknowledgements", "taskAcknowledgements", "durationAcknowledgements", "selectedTaskAcknowledgements"])
    func syncResponseRejectsUnknownStringAcknowledgementOutcomes(_ key: String) throws {
        var object: [String: Any] = [
            "acknowledgements": [],
            "taskAcknowledgements": [],
            "durationAcknowledgements": [],
            "autoStartAcknowledgements": [],
            "selectedTaskAcknowledgements": [],
            "selectedTaskId": NSNull(),
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false,
            "revision": 1,
            "canonicalTimer": NSNull(),
            "history": [],
            "tasks": [],
            "serverTime": "2026-07-21T08:00:00.000Z",
            "serverHlcWallMs": 1_784_620_800_000,
            "serverHlcCounter": 0
        ]
        let idKey = key == "acknowledgements" ? "commandId" : "operationId"
        object[key] = [[idKey: "unknown-outcome", "outcome": "unknown", "reason": ""]]
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(SyncResponse.self, from: data)
        }
    }

    @Test func durationSyncRejectsOutOfBoundsCanonicalValuesWithoutMutatingState() {
        var state = PersistedTimerState.fresh()
        let original = state

        #expect(throws: AppError.self) {
            try state.applyDurationSync(
                canonicalDurations: DurationValues(
                    focus: DurationValues.validRange.lowerBound - 1,
                    shortBreak: DurationValues.defaults.shortBreak,
                    longBreak: DurationValues.defaults.longBreak
                ),
                sentOperations: [],
                acknowledgements: []
            )
        }
        #expect(state == original)
    }

    @Test func reducerRejectsInvalidStateTransitions() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let resume = TestFixtures.command(.resume, sequence: 2, elapsed: 10_000)
        let wrongTimerFinish = TestFixtures.command(.finish, sequence: 3, elapsed: 10_000, timerID: "timer-other0001")
        let clear = TestFixtures.command(.clear, sequence: 4, elapsed: 10_000)

        #expect(TimerReducer.apply(resume, to: running, history: []).0 == running)
        #expect(TimerReducer.apply(wrongTimerFinish, to: running, history: []).0 == running)
        #expect(TimerReducer.apply(clear, to: running, history: []).0 == running)
    }

    @Test func duplicateFinishDoesNotDuplicateHistory() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let finish = TestFixtures.command(.finish, sequence: 2, elapsed: 5_000)
        let firstResult = TimerReducer.apply(finish, to: running, history: [])

        let duplicateResult = TimerReducer.apply(finish, to: running, history: firstResult.1)

        #expect(duplicateResult.1.count == 1)
    }

    @Test func duplicateCancelDoesNotDuplicateHistory() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let cancel = TestFixtures.command(.cancel, sequence: 2, elapsed: 5_000)
        let firstResult = TimerReducer.apply(cancel, to: running, history: [])

        let duplicateResult = TimerReducer.apply(cancel, to: running, history: firstResult.1)

        #expect(duplicateResult.0?.status == .cancelled)
        #expect(duplicateResult.1.count == 1)
    }

    @Test func reducerRejectsPauseAndCancelFromInactiveStates() {
        let paused = TestFixtures.timer(status: .paused, elapsed: 5_000)
        let completed = TestFixtures.timer(status: .completed, elapsed: 60_000)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: 10_000)
        let cancel = TestFixtures.command(.cancel, sequence: 3, elapsed: 10_000)

        #expect(TimerReducer.apply(pause, to: paused, history: []).0 == paused)
        #expect(TimerReducer.apply(cancel, to: completed, history: []).0 == completed)
    }

    @Test func parserIgnoresKeepaliveUnknownEventsAndMalformedData() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: ": keepalive") == nil)
        #expect(parser.consume(line: "event: unrelated") == nil)
        #expect(parser.consume(line: "data: 23") == nil)
        #expect(parser.consume(line: "") == nil)
        #expect(parser.consume(line: "data: not-a-revision") == nil)
        #expect(parser.consume(line: "") == nil)
    }

    @Test func currentOrOlderRevisionDoesNotTriggerSync() {
        var hints = RevisionHintCoalescer()

        #expect(hints.receive(9, localRevision: 10, isSyncing: false) == false)
        #expect(hints.receive(10, localRevision: 10, isSyncing: false) == false)
        #expect(hints.receive(11, localRevision: 10, isSyncing: false) == true)
    }

    @Test func suspendedStreamCannotBeReclaimedByStaleTask() throws {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)
        let startedStaleID = lifecycle.begin()
        let staleID = try #require(startedStaleID)

        lifecycle.setActive(false)

        #expect(lifecycle.owns(staleID) == false)
        #expect(lifecycle.begin() == nil)
        lifecycle.setActive(true)
        let startedCurrentID = lifecycle.begin()
        let currentID = try #require(startedCurrentID)
        #expect(currentID != staleID)
        #expect(lifecycle.owns(staleID) == false)
        #expect(lifecycle.owns(currentID))
    }

    @Test(
        arguments: [
            (204, "text/event-stream" as String?),
            (200, "application/json" as String?),
            (200, "application/text/event-stream+json" as String?),
            (200, "text/event-stream-invalid" as String?),
            (200, nil as String?)
        ]
    )
    func invalidStreamResponseIsRejected(statusCode: Int, contentType: String?) {
        #expect(!RevisionStreamResponse.isValid(statusCode: statusCode, contentType: contentType))
    }

    @Test func staleSyncCannotClearNewSessionOwnership() throws {
        var ownership = SyncOwnership()
        let startedOldSync = ownership.begin(generation: 1)
        let oldSync = try #require(startedOldSync)
        ownership.invalidate()
        let startedNewSync = ownership.begin(generation: 2)
        let newSync = try #require(startedNewSync)

        #expect(ownership.finish(oldSync, currentGeneration: 2) == nil)
        #expect(ownership.isOwned(by: newSync))
        #expect(ownership.begin(generation: 2) == nil)
        #expect(ownership.finish(newSync, currentGeneration: 2) == true)
    }

    @Test func sessionVerificationRejectsWrongAndInvalidatedGenerations() {
        var verification = SessionVerification()

        #expect(!verification.allows(generation: 1))
        verification.markVerified(generation: 1)
        #expect(!verification.allows(generation: 2))
        verification.invalidate()
        #expect(!verification.allows(generation: 1))
    }

    @Test func syncOwnershipSkipsFollowUpForDifferentRequestedGeneration() throws {
        var ownership = SyncOwnership()
        let startedOwner = ownership.begin(generation: 1)
        let owner = try #require(startedOwner)

        #expect(ownership.begin(generation: 3) == nil)
        #expect(ownership.finish(owner, currentGeneration: 2) == false)
    }

    @Test func decoderRejectsInvalidAPIDate() {
        let json = Data(#"{"challenge":"challenge","nonce":"nonce","expiresAt":"not-a-date"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(NativeChallenge.self, from: json)
        }
    }
}

private let keychainFailureTokens = TokenPair(
    accessToken: "access",
    accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
    refreshToken: "refresh",
    refreshTokenExpiresAt: Date(timeIntervalSince1970: 3_000)
)
