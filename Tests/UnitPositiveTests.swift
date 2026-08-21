import CryptoKit
import Foundation
import Security
import Testing
@testable import Pomodorough

@Suite("Unit Positive")
struct UnitPositiveTests {
    private struct ProtocolFixtureEnvelope: Decodable {
        let formatVersion: Int
        let syncResponse: SyncResponse
    }

    @Test func canonicalShippingFixtureUsesProductionSyncDecoder() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/protocol-fixtures-v1.json")
        let fixture = try JSONDecoder.api.decode(
            ProtocolFixtureEnvelope.self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(fixture.formatVersion == 1)
        #expect(fixture.syncResponse.revision == 5)
        #expect(fixture.syncResponse.canonicalTimer?.id == "01a0219e-0800-7002-8000-000000000002")
        #expect(fixture.syncResponse.tasks.map(\.title) == ["Ship release"])
        #expect(fixture.syncResponse.acknowledgements.count == 1)
        #expect(fixture.syncResponse.taskAcknowledgements.count == 1)
        #expect(fixture.syncResponse.durationAcknowledgements.count == 1)
        #expect(fixture.syncResponse.autoStartAcknowledgements.count == 1)
        #expect(fixture.syncResponse.selectedTaskAcknowledgements.count == 1)
        #expect(fixture.syncResponse.selectedTaskId == nil)
        #expect(fixture.syncResponse.hasValidCanonicalSnapshot)
    }

    @Test func keychainLoadReturnsMissingAndDecodesStoredTokens() throws {
        let missingSecurity = RecordingKeychainSecurity()
        #expect(try KeychainStore(security: missingSecurity).load() == nil)
        let missingQuery = try #require(missingSecurity.copyQueries.first)
        expectKeychainBaseQuery(missingQuery)
        #expect(missingQuery.returnsData == true)
        #expect(missingQuery.matchLimit == kSecMatchLimitOne as String)

        let tokens = keychainTokens
        let storedSecurity = RecordingKeychainSecurity(
            copyStatus: errSecSuccess,
            copyData: try JSONEncoder.api.encode(tokens)
        )
        let loadedTokens = try KeychainStore(security: storedSecurity).load()
        let loaded = try #require(loadedTokens)
        #expect(loaded.accessToken == tokens.accessToken)
        #expect(loaded.accessTokenExpiresAt == tokens.accessTokenExpiresAt)
        #expect(loaded.refreshToken == tokens.refreshToken)
        #expect(loaded.refreshTokenExpiresAt == tokens.refreshTokenExpiresAt)
    }

    @Test func keychainSaveUpdatesExistingItemWithoutAdding() throws {
        let security = RecordingKeychainSecurity(updateStatus: errSecSuccess)
        try KeychainStore(security: security).save(keychainTokens)

        let update = try #require(security.updates.first)
        expectKeychainBaseQuery(update.query)
        let encoded = try #require(update.attributes.valueData)
        let stored = try JSONDecoder.api.decode(TokenPair.self, from: encoded)
        #expect(stored.accessToken == keychainTokens.accessToken)
        #expect(stored.refreshToken == keychainTokens.refreshToken)
        #expect(security.addQueries.isEmpty)
    }

    @Test func keychainSaveAddsMissingItemWithProtectionAttributes() throws {
        let security = RecordingKeychainSecurity(
            updateStatus: errSecItemNotFound,
            addStatus: errSecSuccess
        )
        try KeychainStore(security: security).save(keychainTokens)

        #expect(security.updates.count == 1)
        let add = try #require(security.addQueries.first)
        expectKeychainBaseQuery(add)
        let encoded = try #require(add.valueData)
        let stored = try JSONDecoder.api.decode(TokenPair.self, from: encoded)
        #expect(stored.accessToken == keychainTokens.accessToken)
        #expect(stored.refreshToken == keychainTokens.refreshToken)
    }

    @Test(arguments: [errSecSuccess, errSecItemNotFound])
    func keychainDeleteTreatsSuccessAndMissingAsComplete(status: OSStatus) throws {
        let security = RecordingKeychainSecurity(deleteStatus: status)
        try KeychainStore(security: security).delete()
        let query = try #require(security.deleteQueries.first)
        expectKeychainBaseQuery(query)
    }

    @Test func irohEndpointKeychainStoresStableDeviceOnlySecretSeparately() throws {
        let secret = Data(0...31)
        let saving = RecordingKeychainSecurity(updateStatus: errSecItemNotFound)
        try IrohEndpointKeychainStore(security: saving).save(secret)
        let saved = try #require(saving.addQueries.first)
        #expect(saved.service == "me.egigoka.pomodorough.iroh")
        #expect(saved.account == "endpoint-secret-v1")
        #expect(saved.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(saved.valueData == secret)

        let loading = RecordingKeychainSecurity(copyStatus: errSecSuccess, copyData: secret)
        #expect(try IrohEndpointKeychainStore(security: loading).load() == secret)
    }

    @Test func irohRoomKeychainUsesPerRoomDeviceOnlySecret() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let saving = RecordingKeychainSecurity(updateStatus: errSecItemNotFound)
        try IrohRoomSecretKeychainStore(security: saving).save(secret, roomID: roomID)

        let saved = try #require(saving.addQueries.first)
        #expect(saved.service == "me.egigoka.pomodorough.iroh-room")
        #expect(saved.account == "room-secret-v1.\(roomID)")
        #expect(saved.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(saved.valueData == secret)
    }

    @Test func wireBoundsAcceptExactSafeIntegerLimits() {
        #expect(WireBounds.containsUnsigned(WireBounds.maxSafeInteger))
        #expect(WireBounds.isValidClock(
            wallMs: WireBounds.maxSafeInteger,
            counter: WireBounds.maxSafeInteger
        ))
    }

    @Test func checkedAllocationsReachExactMaximumWithoutOverflow() throws {
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var sequenceState = PersistedTimerState.fresh()
        sequenceState.nextSequence = WireBounds.maxSafeInteger

        #expect(try sequenceState.reserveDeviceSequence() == WireBounds.maxSafeInteger)
        #expect(sequenceState.nextSequence == WireBounds.maxSafeInteger)
        #expect(sequenceState.sequenceExhausted)

        var clockState = PersistedTimerState.fresh()
        clockState.hlcWallMs = 1_000_000
        clockState.hlcCounter = WireBounds.maxSafeInteger - 1

        try clockState.advanceClock(at: occurrence)

        #expect(clockState.hlcWallMs == 1_000_000)
        #expect(clockState.hlcCounter == WireBounds.maxSafeInteger)
    }

    @Test func portableUuidV7FixtureMatchesRFC9562AndSharedHash() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/uuidv7-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "719bf4601f0e82aa9898e891184edcf8f37b183a05f3ddd6fa211e1ac8dc2f10")

        let fixture = try JSONDecoder().decode(UUIDv7Fixture.self, from: data)
        let expected = try #require(UUID(uuidString: fixture.rfc9562.uuid))
        let entropy: [UInt8] = [
            0x0c, 0xc3, 0x18, 0xc4, 0xdc,
            0x0c, 0x0c, 0x07, 0x39, 0x8f
        ]
        let generated = try UUIDv7.reserve(
            timestampMs: fixture.rfc9562.timestampMs,
            previous: nil,
            entropy: { entropy }
        )[0]
        let parts = try UUIDv7.parts(of: generated)

        #expect(fixture.schemaVersion == 1)
        #expect(fixture.rfc9562.randomValueHex == "330d8c4dc0c0c07398f")
        #expect(generated == expected)
        #expect(parts == UUIDv7.Parts(
            timestampMs: 1_645_557_742_000,
            randomHigh: 0x0cc3,
            randomLow: 0x18c4_dc0c_0c07_398f
        ))
        #expect(try UUIDv7.make(
            timestampMs: parts.timestampMs,
            randomHigh: parts.randomHigh,
            randomLow: parts.randomLow
        ) == expected)
    }

    @Test func uuidV7StaysMonotonicAcrossEqualAndRolledBackTimestamps() throws {
        let firstBatch = try UUIDv7.reserve(
            timestampMs: 2_000,
            count: 2,
            previous: nil,
            entropy: { [UInt8](repeating: 0, count: 10) }
        )
        let afterRollback = try UUIDv7.reserve(
            timestampMs: 1_000,
            previous: firstBatch[1],
            entropy: { Issue.record("Rollback path must not draw entropy"); return [] }
        )[0]
        let parts = try UUIDv7.parts(of: afterRollback)

        #expect(UUIDv7.isLess(firstBatch[0], than: firstBatch[1]))
        #expect(UUIDv7.isLess(firstBatch[1], than: afterRollback))
        #expect(parts.timestampMs == 2_000)
        #expect(parts.randomLow == 2)
    }

    @Test func uuidV7CursorReconstructsAcrossMixedQueuesAndPersists() throws {
        let queuedUuid = try UUIDv7.make(
            timestampMs: 3_000,
            randomHigh: 4,
            randomLow: 5
        )
        let legacyID = "duration-operation-\(UUID().uuidString.lowercased())"
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 3_000
        state.pendingDurationOperations = [
            TestFixtures.durationOperation(
                id: legacyID,
                phase: .focus,
                durationMs: 60_000,
                wallMs: 3_000
            )
        ]
        state.pendingTaskOperations = [TaskOperation(
            id: "task-operation-\(queuedUuid.uuidString.lowercased())",
            taskId: UUID().uuidString.lowercased(),
            type: .delete,
            title: nil,
            occurredAt: Date(timeIntervalSince1970: 3),
            hlcWallMs: 3_000,
            hlcCounter: 0
        )]

        let reserved = try state.reserveUuidV7(
            entropy: { Issue.record("Reconstruction path must not draw entropy"); return [] }
        )[0]
        let restored = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: JSONEncoder.api.encode(state)
        )

        #expect(UUIDv7.isLess(queuedUuid, than: reserved))
        #expect(try UUIDv7.parts(of: reserved).randomLow == 6)
        #expect(state.pendingDurationOperations[0].id == legacyID)
        #expect(restored.lastUuidV7 == reserved)
        #expect(restored.pendingTaskOperations[0].id == state.pendingTaskOperations[0].id)
    }

    @Test func trustedTimeAcceptsExactFiveMinuteFutureBoundary() throws {
        let occurrence = Date(timeIntervalSince1970: 1_000)
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 1_300_000

        try state.advanceClock(at: occurrence)

        #expect(state.hlcWallMs == 1_300_000)
        #expect(state.hlcCounter == 1)
    }

    @Test func serverClockSampleAcceptsDeviceOneHourAheadOrBehind() throws {
        for deviceSkewSeconds in [-3_600, 3_600] {
            let serverTime = Date(timeIntervalSince1970: 1_784_620_800)
            let localTime = serverTime.addingTimeInterval(TimeInterval(deviceSkewSeconds))
            var state = PersistedTimerState.fresh()

            try state.mergeClock(
                serverWallMs: 1_784_620_800_000,
                serverCounter: 7,
                serverTime: serverTime,
                requestWall: localTime,
                requestUptime: 100,
                responseUptime: 100
            )

            #expect(state.serverTimeOffsetMs == Int64(-deviceSkewSeconds * 1_000))
            #expect(state.serverTimeUncertaintyMs == 0)
            #expect(state.hlcWallMs == 1_784_620_800_000)
            #expect(state.hlcCounter == 7)
            #expect(try state.trustedOccurrenceDate(for: localTime, uptime: 100) == serverTime)
        }
    }

    @Test func serverClockSampleUsesRequestMidpointAndPersistsUncertainty() throws {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        let requestWall = serverTime.addingTimeInterval(3_595)
        var state = PersistedTimerState.fresh()

        try state.mergeClock(
            serverWallMs: 2_000_000,
            serverCounter: 3,
            serverTime: serverTime,
            requestWall: requestWall,
            requestUptime: 100,
            responseUptime: 110
        )

        #expect(state.serverTimeOffsetMs == -3_600_000)
        #expect(state.serverTimeUncertaintyMs == 5_000)
        #expect(state.serverTimeAnchorMs == 2_005_000)
        #expect(state.serverTimeAnchorUptime == 110)
        let roundTrip = try JSONDecoder.api.decode(
            PersistedTimerState.self,
            from: JSONEncoder.api.encode(state)
        )
        #expect(roundTrip.serverTimeOffsetMs == -3_600_000)
        #expect(roundTrip.serverTimeUncertaintyMs == 5_000)
        #expect(roundTrip.serverTimeAnchorMs == 2_005_000)
        #expect(roundTrip.serverTimeAnchorUptime == 110)
    }

    @Test func serverClockUncertaintyRoundsHalfRttUp() throws {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        var state = PersistedTimerState.fresh()

        try state.mergeClock(
            serverWallMs: 2_000_000,
            serverCounter: 0,
            serverTime: serverTime,
            requestWall: serverTime,
            requestUptime: 100,
            responseUptime: 100.001
        )

        #expect(state.serverTimeOffsetMs == 0)
        #expect(state.serverTimeUncertaintyMs == 1)
    }

    @Test func retainedOperationsRebaseAfterCanonicalClockWithoutChangingIntent() throws {
        let task = try #require(FocusTask(title: "Retained task"))
        let command = TestFixtures.command(.start, sequence: 1, elapsed: 0)
        let taskOperation = TaskOperation(
            id: "task-operation-retained",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_002,
            hlcCounter: 0
        )
        let durationOperation = TestFixtures.durationOperation(
            id: "duration-operation-retained",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 1_000_003
        )
        let legacyDuration = TestFixtures.durationOperation(
            id: "duration-operation-legacy",
            phase: .shortBreak,
            durationMs: 10 * 60_000,
            wallMs: 0
        )
        let autoStartOperation = TestFixtures.autoStartOperation(
            deviceID: "device-retained",
            enabled: true,
            wallMs: 1_000_004
        )
        var state = PersistedTimerState.fresh()
        state.deviceId = "device-retained"
        state.pendingCommands = [command]
        state.localCommandDates = [command.id: TestFixtures.anchor]
        state.pendingTaskOperations = [taskOperation]
        state.pendingDurationOperations = [durationOperation, legacyDuration]
        state.pendingAutoStartOperations = [autoStartOperation]

        try state.rebasePendingOperations(
            afterServerWallMs: 1_000_100,
            serverCounter: 10,
            serverTime: Date(timeIntervalSince1970: 1_000.1)
        )

        let canonicalClock = (Int64(1_000_100), Int64(10))
        #expect(state.pendingCommands.map(\.id) == [command.id])
        #expect(state.pendingCommands[0].deviceSequence == command.deviceSequence)
        #expect(
            (state.pendingCommands[0].hlcWallMs, state.pendingCommands[0].hlcCounter)
                > canonicalClock
        )
        #expect(state.localCommandDates == [command.id: TestFixtures.anchor])
        #expect(state.pendingTaskOperations.map(\.id) == [taskOperation.id])
        #expect(
            (
                state.pendingTaskOperations[0].hlcWallMs,
                state.pendingTaskOperations[0].hlcCounter
            ) > canonicalClock
        )
        #expect(state.pendingDurationOperations.map(\.id) == [
            durationOperation.id,
            legacyDuration.id
        ])
        #expect(
            (
                state.pendingDurationOperations[0].hlcWallMs,
                state.pendingDurationOperations[0].hlcCounter
            ) > canonicalClock
        )
        #expect(
            (
                state.pendingDurationOperations[1].hlcWallMs,
                state.pendingDurationOperations[1].hlcCounter
            ) == (0, 0)
        )
        #expect(state.pendingAutoStartOperations.map(\.id) == [autoStartOperation.id])
        #expect(
            (
                state.pendingAutoStartOperations[0].hlcWallMs,
                state.pendingAutoStartOperations[0].hlcCounter
            ) > canonicalClock
        )
        #expect((state.hlcWallMs, state.hlcCounter) > canonicalClock)
    }

    @Test func legacySelectionMigrationIncludesPendingTaskUpsert() throws {
        let task = try #require(FocusTask(title: "Pending selected task"))
        var state = PersistedTimerState.fresh()
        state.selectedTaskID = task.id
        state.pendingTaskOperations = [TaskOperation(
            id: "pending-selected-task-upsert",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )]

        #expect(try state.migrateLegacySelectedTask(at: TestFixtures.anchor))
        #expect(state.pendingSelectedTaskOperations.count == 1)
        #expect(state.pendingSelectedTaskOperations[0].taskId == task.id.uuidString.lowercased())
    }

    @Test func newerSampleCannotRegressLastEmittedTrustedTime() throws {
        let serverTime = Date(timeIntervalSince1970: 2_000)
        var state = PersistedTimerState.fresh()
        try state.mergeClock(
            serverWallMs: 2_000_000,
            serverCounter: 0,
            serverTime: serverTime,
            requestWall: serverTime,
            requestUptime: 100,
            responseUptime: 100
        )
        let emitted = try state.trustedOccurrenceDate(for: serverTime, uptime: 110)
        try state.advanceClock(at: emitted)

        try state.mergeClock(
            serverWallMs: 2_000_000,
            serverCounter: 1,
            serverTime: serverTime,
            requestWall: serverTime,
            requestUptime: 110,
            responseUptime: 110
        )

        #expect(state.serverTimeAnchorMs == 2_000_000)
        #expect(try state.trustedOccurrenceDate(for: serverTime, uptime: 110) == emitted.addingTimeInterval(0.001))
    }

    @Test func physicalMillisecondsAcceptsExactBoundsAfterIntegerConversion() {
        #expect(WireBounds.physicalMilliseconds(for: Date(timeIntervalSince1970: 0.001)) == 1)
        #expect(WireBounds.physicalMilliseconds(for: Date(
            timeIntervalSince1970: 8_000_000_000_000
        )) == 8_000_000_000_000_000)
    }

    @Test func portableCanonicalConvergenceFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/convergence-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "a293a679179f7f441a89b04f0260ee77fc0d810abc61e99501f9260a6ea9012e")

        let fixture = try JSONDecoder().decode(ConvergenceFixture.self, from: data)
        #expect(fixture.version == 2)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let epoch = try #require(formatter.date(from: fixture.epoch))

        for fixtureCase in fixture.cases {
            let commands = try fixtureCase.commands.map { command in
                TimerCommand(
                    id: command.id,
                    deviceSequence: command.sequence,
                    timerId: command.timerId,
                    taskId: command.taskId,
                    type: try #require(CommandType(rawValue: command.type)),
                    phase: try #require(TimerPhase(rawValue: command.phase)),
                    plannedDurationMs: command.durationMs,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(command.atMs) / 1_000),
                    hlcWallMs: command.wallMs,
                    hlcCounter: command.counter,
                    observedElapsedMs: command.elapsedMs
                )
            }
            for arrivalOrder in [commands, Array(commands.reversed())] {
                let result = TimerReducer.applying(arrivalOrder, to: nil, history: [])
                #expect(
                    normalizedConvergence(timer: result.timer, history: result.history, epoch: epoch)
                        == fixtureCase.expected,
                    Comment(rawValue: fixtureCase.name)
                )
            }
        }

        for fixtureCase in fixture.projectionCases {
            let taskOperations = try fixtureCase.taskOperations.map { operation in
                TaskOperation(
                    id: operation.id,
                    taskId: operation.taskId,
                    type: try #require(TaskOperationType(rawValue: operation.type)),
                    title: operation.title,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(operation.atMs) / 1_000),
                    hlcWallMs: operation.wallMs,
                    hlcCounter: operation.counter
                )
            }
            for arrivalOrder in TestFixtures.permutations(of: taskOperations) {
                let tasks = TaskReducer.applying(arrivalOrder, to: []).map {
                    ConvergenceTask(id: $0.id.uuidString.lowercased(), title: $0.title)
                }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
                #expect(tasks == fixtureCase.expected.tasks, Comment(rawValue: fixtureCase.name))
            }

            let durationOperations = try fixtureCase.durationOperations.map { operation in
                DurationOperation(
                    id: operation.id,
                    phase: try #require(TimerPhase(rawValue: operation.phase)),
                    durationMs: operation.durationMs,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(operation.atMs) / 1_000),
                    hlcWallMs: operation.wallMs,
                    hlcCounter: operation.counter
                )
            }
            for arrivalOrder in TestFixtures.permutations(of: durationOperations) {
                #expect(
                    DurationReducer.applying(arrivalOrder, to: .defaults)
                        == fixtureCase.expected.durationsMs,
                    Comment(rawValue: fixtureCase.name)
                )
            }

            let autoStartOperations = try fixtureCase.autoStartOperations.map { operation in
                AutoStartOperation(
                    id: try #require(UUID(uuidString: operation.id)),
                    deviceId: operation.deviceId,
                    enabled: operation.enabled,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(operation.atMs) / 1_000),
                    hlcWallMs: operation.wallMs,
                    hlcCounter: operation.counter
                )
            }
            for arrivalOrder in TestFixtures.permutations(of: autoStartOperations) {
                #expect(
                    AutoStartReducer.applying(arrivalOrder, to: false)
                        == fixtureCase.expected.autoStartBreaks,
                    Comment(rawValue: fixtureCase.name)
                )
            }
        }

        for fixtureCase in fixture.responseCases {
            let commands = try fixtureCase.local.commands.map { command in
                TimerCommand(
                    id: command.id,
                    deviceSequence: command.sequence,
                    timerId: command.timerId,
                    taskId: command.taskId,
                    type: try #require(CommandType(rawValue: command.type)),
                    phase: try #require(TimerPhase(rawValue: command.phase)),
                    plannedDurationMs: command.durationMs,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(command.atMs) / 1_000),
                    hlcWallMs: command.wallMs,
                    hlcCounter: command.counter,
                    observedElapsedMs: command.elapsedMs
                )
            }
            let taskOperations = try fixtureCase.local.taskOperations.map { operation in
                TaskOperation(
                    id: operation.id,
                    taskId: operation.taskId,
                    type: try #require(TaskOperationType(rawValue: operation.type)),
                    title: operation.title,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(operation.atMs) / 1_000),
                    hlcWallMs: operation.wallMs,
                    hlcCounter: operation.counter
                )
            }
            let durationOperations = try fixtureCase.local.durationOperations.map { operation in
                DurationOperation(
                    id: operation.id,
                    phase: try #require(TimerPhase(rawValue: operation.phase)),
                    durationMs: operation.durationMs,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(operation.atMs) / 1_000),
                    hlcWallMs: operation.wallMs,
                    hlcCounter: operation.counter
                )
            }
            let autoStartOperations = try fixtureCase.local.autoStartOperations.map { operation in
                AutoStartOperation(
                    id: try #require(UUID(uuidString: operation.id)),
                    deviceId: operation.deviceId,
                    enabled: operation.enabled,
                    occurredAt: epoch.addingTimeInterval(TimeInterval(operation.atMs) / 1_000),
                    hlcWallMs: operation.wallMs,
                    hlcCounter: operation.counter
                )
            }
            let acknowledgementGroups = [
                (fixtureCase.sentIds.commands, fixtureCase.acknowledgements.commands),
                (fixtureCase.sentIds.taskOperations, fixtureCase.acknowledgements.taskOperations),
                (fixtureCase.sentIds.durationOperations, fixtureCase.acknowledgements.durationOperations),
                (fixtureCase.sentIds.autoStartOperations, fixtureCase.acknowledgements.autoStartOperations)
            ]
            for (sent, acknowledgements) in acknowledgementGroups {
                #expect(AcknowledgementSet.exactlyMatches(
                    sent: sent,
                    acknowledged: acknowledgements.map(\.id)
                ))
                #expect(acknowledgements.allSatisfy {
                    AcknowledgementOutcome(rawValue: $0.outcome) != nil
                })
            }

            let retainedCommands = commands.filter {
                !Set(fixtureCase.acknowledgements.commands.map(\.id)).contains($0.id)
            }
            let retainedTasks = taskOperations.filter {
                !Set(fixtureCase.acknowledgements.taskOperations.map(\.id)).contains($0.id)
            }
            let retainedDurations = durationOperations.filter {
                !Set(fixtureCase.acknowledgements.durationOperations.map(\.id)).contains($0.id)
            }
            let retainedAutoStart = autoStartOperations.filter {
                !Set(fixtureCase.acknowledgements.autoStartOperations.map(\.id)).contains($0.id.uuidString.lowercased())
            }
            #expect(retainedCommands.map(\.id) == fixtureCase.expected.commandIds)
            #expect(retainedTasks.map(\.id) == fixtureCase.expected.taskOperationIds)
            #expect(retainedDurations.map(\.id) == fixtureCase.expected.durationOperationIds)
            #expect(
                retainedAutoStart.map { $0.id.uuidString.lowercased() }
                    == fixtureCase.expected.autoStartOperationIds
            )

            let canonicalTimer = try fixtureCase.canonical.timer.map { timer in
                CanonicalTimer(
                    id: timer.id,
                    taskId: timer.taskId,
                    phase: try #require(TimerPhase(rawValue: timer.phase)),
                    status: try #require(CanonicalTimer.Status(rawValue: timer.status)),
                    plannedDurationMs: timer.durationMs,
                    elapsedAtAnchorMs: timer.elapsedMs,
                    anchorAt: epoch.addingTimeInterval(TimeInterval(timer.anchorMs) / 1_000),
                    lastIntent: TimerIntent(
                        type: .start,
                        commandId: timer.lastCommandId,
                        occurredAt: epoch.addingTimeInterval(TimeInterval(timer.anchorMs) / 1_000),
                        deviceId: "device-a"
                    )
                )
            }
            let timerProjection = TimerReducer.applying(
                retainedCommands,
                to: canonicalTimer,
                history: []
            )
            #expect(
                normalizedConvergence(
                    timer: timerProjection.timer,
                    history: timerProjection.history,
                    epoch: epoch
                ) == ConvergenceExpected(
                    timer: fixtureCase.expected.timer,
                    history: fixtureCase.expected.history
                ),
                Comment(rawValue: fixtureCase.name)
            )

            let canonicalTasks = try fixtureCase.canonical.tasks.map { expected in
                let task = try #require(FocusTask(title: expected.title))
                #expect(task.id.uuidString.lowercased() == expected.id)
                return task
            }
            let projectedTasks = TaskReducer.applying(retainedTasks, to: canonicalTasks).map {
                ConvergenceTask(id: $0.id.uuidString.lowercased(), title: $0.title)
            }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
            #expect(projectedTasks == fixtureCase.expected.tasks, Comment(rawValue: fixtureCase.name))
            #expect(
                DurationReducer.applying(retainedDurations, to: fixtureCase.canonical.durationsMs)
                    == fixtureCase.expected.durationsMs,
                Comment(rawValue: fixtureCase.name)
            )
            #expect(
                AutoStartReducer.applying(
                    retainedAutoStart,
                    to: fixtureCase.canonical.autoStartBreaks
                ) == fixtureCase.expected.autoStartBreaks,
                Comment(rawValue: fixtureCase.name)
            )
        }
    }

    @Test func taskIdentityIsStableAfterEdgeCleanupAndUnicodeNormalization() throws {
        let first = try #require(FocusTask(title: "\u{0000}\tCafe\u{0301}\n"))
        let recreated = try #require(FocusTask(title: "Café"))

        #expect(first.title == "Café")
        #expect(first.id == recreated.id)
        #expect(first.id.uuidString.lowercased() == "aaf83054-24b2-8c0e-901f-a974147bfe82")
        #expect(first.id.uuidString[first.id.uuidString.index(first.id.uuidString.startIndex, offsetBy: 14)] == "8")
    }

    @Test func taskIdentityPreservesPrintableSpacesAndStripsNonPrintableSeparators() throws {
        let task = try #require(FocusTask(title: "\u{00a0} Write notes \u{00a0}"))

        #expect(task.title == " Write notes ")
        #expect(task != FocusTask(title: "Write notes"))
    }

    @Test func taskReducerUsesHLCOrderAndAllowsRecreation() throws {
        let task = try #require(FocusTask(title: "Write notes"))
        let taskID = task.id.uuidString.lowercased()
        let staleUpsert = TaskOperation(
            id: "task-operation-a",
            taskId: taskID,
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1,
            hlcCounter: 0
        )
        let deletion = TaskOperation(
            id: "task-operation-b",
            taskId: taskID,
            type: .delete,
            title: nil,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2,
            hlcCounter: 0
        )
        let recreation = TaskOperation(
            id: "task-operation-c",
            taskId: taskID,
            type: .upsert,
            title: task.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 2,
            hlcCounter: 1
        )

        #expect(TaskReducer.applying([deletion, staleUpsert], to: [task]).isEmpty)
        #expect(TaskReducer.applying([recreation, deletion, staleUpsert], to: []) == [task])
    }

    @Test func taskReducerIsPermutationInvariantIndependentAndIdempotent() throws {
        let first = try #require(FocusTask(title: "First"))
        let second = try #require(FocusTask(title: "Second"))
        let operations = [
            TaskOperation(
                id: "task-operation-first-stale-delete",
                taskId: first.id.uuidString.lowercased(),
                type: .delete,
                title: nil,
                occurredAt: TestFixtures.anchor,
                hlcWallMs: 2,
                hlcCounter: 0
            ),
            TaskOperation(
                id: "task-operation-first-tie-delete",
                taskId: first.id.uuidString.lowercased(),
                type: .delete,
                title: nil,
                occurredAt: TestFixtures.anchor,
                hlcWallMs: 2,
                hlcCounter: 1
            ),
            TaskOperation(
                id: "task-operation-first-upsert",
                taskId: first.id.uuidString.lowercased(),
                type: .upsert,
                title: first.title,
                occurredAt: TestFixtures.anchor,
                hlcWallMs: 2,
                hlcCounter: 1
            ),
            TaskOperation(
                id: "task-operation-second-delete",
                taskId: second.id.uuidString.lowercased(),
                type: .delete,
                title: nil,
                occurredAt: TestFixtures.anchor,
                hlcWallMs: 3,
                hlcCounter: 0
            )
        ]
        let expected = [first]

        for permutation in TestFixtures.permutations(of: operations) {
            #expect(TaskReducer.applying(permutation, to: [first, second]) == expected)
        }
        #expect(TaskReducer.applying(operations + operations, to: [first, second]) == expected)
    }

    @Test func timerAlarmIdentityUsesTimerUUID() throws {
        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))

        #expect(TimerAlarmScheduler.alarmID(for: "timer-\(uuid.uuidString.lowercased())") == uuid)
    }

    @Test @MainActor
    func timerAlarmSchedulerPrefersAuthorizedSystemAlarm() async throws {
        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))
        let notifications = RecordingNotificationBackend()
        let alarms = RecordingSystemAlarmBackend()
        alarms.authorizationState = .authorized
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)
        let timerID = "timer-\(uuid.uuidString.lowercased())"

        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 0)
        try await scheduler.pause(timerID: timerID)
        try await scheduler.resume(timerID: timerID, phase: .focus, duration: 30)
        try await scheduler.cancel(timerID: timerID)

        #expect(alarms.operations == [
            .schedule(id: uuid, timerID: timerID, phase: .focus, duration: 0),
            .pause(id: uuid),
            .resume(id: uuid),
            .cancel(id: uuid),
        ])
        #expect(notifications.operations == Array(
            repeating: .remove(identifier: TimerAlarmScheduler.notificationID(for: timerID)),
            count: 4
        ))
    }

    @Test @MainActor
    func timerAlarmSchedulerFallsBackToNotificationContract() async throws {
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        let alarms = RecordingSystemAlarmBackend()
        alarms.authorizationState = .authorized
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)
        let timerID = "remote-timer"

        try await scheduler.schedule(timerID: timerID, phase: .shortBreak, duration: 0)
        try await scheduler.pause(timerID: timerID)
        try await scheduler.resume(timerID: timerID, phase: .longBreak, duration: 12)
        try await scheduler.cancel(timerID: timerID)

        #expect(alarms.operations.isEmpty)
        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: "pomodorough.remote-timer", phase: .shortBreak, duration: 0),
            .remove(identifier: "pomodorough.remote-timer"),
            .canSchedule,
            .schedule(identifier: "pomodorough.remote-timer", phase: .longBreak, duration: 12),
            .remove(identifier: "pomodorough.remote-timer"),
        ])
    }

    @Test @MainActor
    func timerAlarmSchedulerKeepsScheduledBackendAcrossAuthorizationChanges() async throws {
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
        try await scheduler.pause(timerID: timerID)
        try await scheduler.resume(timerID: timerID, phase: .focus, duration: 30)
        try await scheduler.cancel(timerID: timerID)

        #expect(alarms.operations == [
            .schedule(id: uuid, timerID: timerID, phase: .focus, duration: 30),
            .cancel(id: uuid),
        ])
        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: notificationID, phase: .focus, duration: 60),
            .remove(identifier: notificationID),
            .remove(identifier: notificationID),
            .remove(identifier: notificationID),
        ])
    }

    @Test @MainActor
    func timerAlarmSchedulerCleansNotificationWhenSwitchingToSystemAlarm() async throws {
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
        try await scheduler.schedule(timerID: timerID, phase: .shortBreak, duration: 30)
        try await scheduler.cancel(timerID: timerID)

        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: notificationID, phase: .focus, duration: 60),
            .remove(identifier: notificationID),
            .remove(identifier: notificationID),
        ])
        #expect(alarms.operations == [
            .schedule(id: uuid, timerID: timerID, phase: .shortBreak, duration: 30),
            .cancel(id: uuid),
        ])
    }

    @Test @MainActor
    func timerAlarmSchedulerReconcilesBackendAfterRecreation() async throws {
        let uuid = try #require(UUID(uuidString: "83A06D73-1D2D-441E-AFC2-E36DA0518613"))
        let timerID = "timer-\(uuid.uuidString.lowercased())"
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        let alarms = RecordingSystemAlarmBackend()
        alarms.authorizationState = .denied

        try await TimerAlarmScheduler(notifications: notifications, alarms: alarms)
            .schedule(timerID: timerID, phase: .focus, duration: 60)
        alarms.authorizationState = .authorized
        try await TimerAlarmScheduler(notifications: notifications, alarms: alarms)
            .resume(timerID: timerID, phase: .focus, duration: 30)

        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: notificationID, phase: .focus, duration: 60),
            .remove(identifier: notificationID),
        ])
        #expect(alarms.operations == [
            .schedule(id: uuid, timerID: timerID, phase: .focus, duration: 30),
        ])
    }

    @Test @MainActor
    func timerAlarmSchedulerDoesNotResurrectCancelledSuspendedSchedule() async throws {
        let timerID = "remote-timer"
        let notificationID = TimerAlarmScheduler.notificationID(for: timerID)
        let notifications = RecordingNotificationBackend()
        notifications.canScheduleResult = true
        notifications.suspendsScheduling = true
        let alarms = RecordingSystemAlarmBackend()
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        let scheduling = Task {
            try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)
        }
        await notifications.waitUntilSchedulingSuspends()
        let cancelling = Task {
            try await TimerAlarmScheduler(notifications: notifications, alarms: alarms)
                .cancel(timerID: timerID)
        }
        notifications.releaseScheduling()
        try await scheduling.value
        try await cancelling.value

        #expect(notifications.operations == [
            .canSchedule,
            .schedule(identifier: notificationID, phase: .focus, duration: 60),
            .remove(identifier: notificationID),
        ])
    }

    @Test @MainActor
    func timerAlarmAuthorizationSucceedsWhenEitherBackendAuthorizes() async throws {
        let notifications = RecordingNotificationBackend()
        let alarms = RecordingSystemAlarmBackend()
        let scheduler = TimerAlarmScheduler(notifications: notifications, alarms: alarms)

        notifications.authorizationResult = true
        try await scheduler.requestAuthorization()

        notifications.authorizationResult = false
        alarms.authorizationState = .notDetermined
        alarms.authorizationResult = true
        try await scheduler.requestAuthorization()

        #expect(notifications.operations == [.requestAuthorization, .requestAuthorization])
        #expect(alarms.operations == [.requestAuthorization])
    }

    @Test func timerAlarmNotificationIdentityAndTitlesAreDeterministic() {
        #expect(TimerAlarmScheduler.notificationID(for: "timer-1") == "pomodorough.timer-1")
        #expect(TimerAlarmScheduler.title(for: .focus) == "Focus complete")
        #expect(TimerAlarmScheduler.title(for: .shortBreak) == "Short break complete")
        #expect(TimerAlarmScheduler.title(for: .longBreak) == "Long break complete")
        #expect(TimerAlarmScheduler.stopSoundTitle == "Stop sound")
    }

    @Test func runningTimerClampsAtPlannedDuration() {
        let timer = TestFixtures.timer(status: .running, elapsed: 50_000)

        #expect(timer.elapsed(at: TestFixtures.anchor.addingTimeInterval(20)) == 60)
        #expect(timer.remaining(at: TestFixtures.anchor.addingTimeInterval(20)) == 0)
    }

    @Test func pausedTimerDoesNotAdvance() {
        let timer = TestFixtures.timer(status: .paused, elapsed: 15_000)

        #expect(timer.elapsed(at: TestFixtures.anchor.addingTimeInterval(20)) == 15)
    }

    @Test func runningTimerDoesNotRunBackwardBeforeAnchor() {
        let timer = TestFixtures.timer(status: .running, elapsed: 15_000)

        #expect(timer.elapsed(at: TestFixtures.anchor.addingTimeInterval(-20)) == 15)
        #expect(timer.remaining(at: TestFixtures.anchor.addingTimeInterval(-20)) == 45)
    }

    @Test func timerPhasesExposeExpectedPresentationAndDefaults() {
        #expect(TimerPhase.allCases.map(\.id) == ["focus", "short_break", "long_break"])
        #expect(TimerPhase.allCases.map(\.title) == ["Focus", "Short break", "Long break"])
        #expect(TimerPhase.allCases.map(\.routeLabel) == ["Work", "Reset", "Recover"])
        #expect(TimerPhase.allCases.map(\.abbreviation) == ["F", "SB", "LB"])
        #expect(TimerPhase.allCases.map(\.defaultMinutes) == [25, 5, 15])
    }

    @Test func syncRequestEncodesExactDurationOperationContract() throws {
        let operation = TestFixtures.durationOperation(
            id: "duration-operation-test",
            phase: .shortBreak,
            durationMs: 420_000,
            wallMs: 1_234,
            counter: 2
        )
        let request = SyncRequest(
            deviceId: "device-test",
            lastRevision: 3,
            commands: [],
            taskOperations: [],
            durationOperations: [operation],
            autoStartOperations: []
        )

        let data = try JSONEncoder.api.encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let operations = try #require(json["durationOperations"] as? [[String: Any]])
        let encoded = try #require(operations.first)

        #expect(Set(encoded.keys) == Set(["id", "phase", "durationMs", "occurredAt", "hlcWallMs", "hlcCounter"]))
        #expect(encoded["id"] as? String == operation.id)
        #expect(encoded["phase"] as? String == "short_break")
        #expect(encoded["durationMs"] as? Int == 420_000)
        #expect(json["commands"] is [Any])
        #expect(json["taskOperations"] is [Any])
    }

    @Test func syncResponseDecodesFixedDurationContract() throws {
        let json = Data(
            #"{"acknowledgements":[],"durationAcknowledgements":[{"operationId":"duration-operation-test","outcome":"applied","reason":""}],"autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[],"selectedTaskId":null,"durationsMs":{"focus":1500000,"short_break":300000,"long_break":900000},"autoStartBreaks":false,"revision":0,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":7}"#.utf8
        )

        let response = try JSONDecoder.api.decode(SyncResponse.self, from: json)

        #expect(response.durationAcknowledgements == [DurationAcknowledgement(
            operationId: "duration-operation-test",
            outcome: .applied,
            reason: ""
        )])
        #expect(response.durationsMs == .defaults)
        #expect(response.serverHlcWallMs == 1_784_620_800_000)
        #expect(response.serverHlcCounter == 7)
    }

    @Test func persistedAutoStartOperationRetainsDeviceIdentity() throws {
        let operationID = try #require(UUID(uuidString: "2ddbd077-3814-4a1f-bbd7-41c4ef26432a"))
        let operation = TestFixtures.autoStartOperation(
            id: operationID,
            deviceID: "device-wire",
            enabled: true,
            wallMs: 1_234,
            counter: 2
        )
        let data = try JSONEncoder.api.encode(operation)
        let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(encoded.keys) == ["id", "deviceId", "enabled", "occurredAt", "hlcWallMs", "hlcCounter"])
        #expect(UUID(uuidString: encoded["id"] as? String ?? "") == operationID)
        #expect(encoded["deviceId"] as? String == "device-wire")
        #expect(encoded["enabled"] as? Bool == true)
        #expect(encoded["hlcWallMs"] as? Int == 1_234)
        #expect(encoded["hlcCounter"] as? Int == 2)
        #expect(encoded["occurredAt"] as? String == "1970-01-01T00:00:01.000Z")
    }

    @Test func persistedSelectedTaskOperationRetainsDeviceIdentityAndNullableTask() throws {
        let operation = TestFixtures.selectedTaskOperation(
            deviceID: "device-selection-wire",
            taskID: nil,
            wallMs: 1_234,
            counter: 2
        )
        let data = try JSONEncoder.api.encode(operation)
        let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(encoded.keys) == ["id", "deviceId", "occurredAt", "hlcWallMs", "hlcCounter"])
        #expect(encoded["deviceId"] as? String == "device-selection-wire")
        #expect(encoded["taskId"] == nil)
        #expect(encoded["hlcWallMs"] as? Int == 1_234)
        #expect(encoded["hlcCounter"] as? Int == 2)
    }

    @Test func selectedTaskReducerUsesHLCDeviceAndOperationOrdering() throws {
        let firstTask = try #require(FocusTask(title: "First selection"))
        let secondTask = try #require(FocusTask(title: "Second selection"))
        let firstID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let first = TestFixtures.selectedTaskOperation(
            id: firstID,
            deviceID: "device-a",
            taskID: firstTask.id,
            wallMs: 10,
            counter: 2
        )
        let second = TestFixtures.selectedTaskOperation(
            id: secondID,
            deviceID: "device-b",
            taskID: secondTask.id,
            wallMs: 10,
            counter: 2
        )

        #expect(SelectedTaskReducer.applying([second, first], to: nil) == secondTask.id)
    }

    @Test func bootstrapAutoStartPresenceDistinguishesLegacyOmissionFromExplicitDefault() throws {
        func encoded(_ operations: [AutoStartOperation]?) throws -> [String: Any] {
            let request = BootstrapResolveRequest(
                requestId: "bootstrap-presence",
                deviceId: "device-presence",
                expectedRevision: 1,
                strategy: .replaceRemote,
                commands: [],
                taskOperations: [],
                durationOperations: [],
                autoStartOperations: operations
            )
            return try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(request)) as? [String: Any])
        }

        #expect(try !encoded(nil).keys.contains("autoStartOperations"))
        #expect(try (encoded([])["autoStartOperations"] as? [Any])?.isEmpty == true)
    }

    @Test func autoStartReducerUsesHLCDeviceAndOperationOrdering() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let first = TestFixtures.autoStartOperation(
            id: firstID,
            deviceID: "device-a",
            enabled: false,
            wallMs: 10,
            counter: 2
        )
        let second = TestFixtures.autoStartOperation(
            id: secondID,
            deviceID: "device-b",
            enabled: true,
            wallMs: 10,
            counter: 2
        )

        #expect(AutoStartReducer.applying([second, first], to: false))
    }

    @Test func autoStartReducerAcceptsValidOperationFromRemoteDevice() {
        let remote = TestFixtures.autoStartOperation(
            deviceID: "device-remote",
            enabled: true,
            wallMs: 10
        )

        #expect(AutoStartReducer.applying([remote], to: false))
    }

    @Test func durationReducerIsPermutationInvariantPerPhaseAndIdempotent() {
        let operations = [
            TestFixtures.durationOperation(
                id: "duration-focus-wall-stale",
                phase: .focus,
                durationMs: 15 * 60_000,
                wallMs: 9,
                counter: 9
            ),
            TestFixtures.durationOperation(
                id: "duration-focus-counter-stale",
                phase: .focus,
                durationMs: 20 * 60_000,
                wallMs: 10,
                counter: 1
            ),
            TestFixtures.durationOperation(
                id: "duration-focus-tie-a",
                phase: .focus,
                durationMs: 25 * 60_000,
                wallMs: 10,
                counter: 2
            ),
            TestFixtures.durationOperation(
                id: "duration-focus-tie-z",
                phase: .focus,
                durationMs: 30 * 60_000,
                wallMs: 10,
                counter: 2
            ),
            TestFixtures.durationOperation(
                id: "duration-break-winner",
                phase: .shortBreak,
                durationMs: 10 * 60_000,
                wallMs: 9
            )
        ]
        var expected = DurationValues.defaults
        expected.focus = 30 * 60_000
        expected.shortBreak = 10 * 60_000

        for permutation in TestFixtures.permutations(of: operations) {
            #expect(DurationReducer.applying(permutation, to: .defaults) == expected)
        }
        #expect(DurationReducer.applying(operations + operations, to: .defaults) == expected)
    }

    @Test func autoStartReducerIsPermutationInvariantAcrossEveryTieBreakerAndIdempotent() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let operations = [
            TestFixtures.autoStartOperation(
                id: secondID,
                deviceID: "device-z",
                enabled: true,
                wallMs: 9,
                counter: 9
            ),
            TestFixtures.autoStartOperation(
                id: firstID,
                deviceID: "device-a",
                enabled: false,
                wallMs: 10,
                counter: 1
            ),
            TestFixtures.autoStartOperation(
                id: secondID,
                deviceID: "device-a",
                enabled: false,
                wallMs: 10,
                counter: 2
            ),
            TestFixtures.autoStartOperation(
                id: firstID,
                deviceID: "device-b",
                enabled: false,
                wallMs: 10,
                counter: 2
            ),
            TestFixtures.autoStartOperation(
                id: secondID,
                deviceID: "device-b",
                enabled: true,
                wallMs: 10,
                counter: 2
            )
        ]

        for permutation in TestFixtures.permutations(of: operations) {
            #expect(AutoStartReducer.applying(permutation, to: false))
        }
        #expect(AutoStartReducer.applying(operations + operations, to: false))
    }

    @Test func syncHelpersAcceptReorderedExactAcknowledgementsAndRetireAllKnownOutcomes() throws {
        let sentIDs = ["first", "second", "third"]
        #expect(AcknowledgementSet.exactlyMatches(sent: sentIDs, acknowledged: Array(sentIDs.reversed())))

        var durationState = PersistedTimerState.fresh()
        let durations = [
            TestFixtures.durationOperation(
                id: "duration-first",
                phase: .focus,
                durationMs: 30 * 60_000,
                wallMs: 1
            ),
            TestFixtures.durationOperation(
                id: "duration-second",
                phase: .shortBreak,
                durationMs: 10 * 60_000,
                wallMs: 2
            ),
            TestFixtures.durationOperation(
                id: "duration-third",
                phase: .longBreak,
                durationMs: 20 * 60_000,
                wallMs: 3
            )
        ]
        durationState.pendingDurationOperations = durations
        try durationState.applyDurationSync(
            canonicalDurations: .defaults,
            sentOperations: durations,
            acknowledgements: [
                DurationAcknowledgement(operationId: durations[2].id, outcome: .rejected, reason: "lost race"),
                DurationAcknowledgement(operationId: durations[0].id, outcome: .applied, reason: ""),
                DurationAcknowledgement(operationId: durations[1].id, outcome: .ignored, reason: "stale")
            ]
        )
        #expect(durationState.pendingDurationOperations.isEmpty)

        var autoStartState = PersistedTimerState.fresh()
        let autoStartOperations = [
            TestFixtures.autoStartOperation(deviceID: autoStartState.deviceId, enabled: true, wallMs: 1),
            TestFixtures.autoStartOperation(deviceID: autoStartState.deviceId, enabled: false, wallMs: 2),
            TestFixtures.autoStartOperation(deviceID: autoStartState.deviceId, enabled: true, wallMs: 3)
        ]
        autoStartState.pendingAutoStartOperations = autoStartOperations
        try autoStartState.applyAutoStartSync(
            canonicalValue: true,
            sentOperations: autoStartOperations,
            acknowledgements: [
                AutoStartAcknowledgement(operationId: autoStartOperations[1].id, outcome: .ignored, reason: "stale"),
                AutoStartAcknowledgement(operationId: autoStartOperations[2].id, outcome: .rejected, reason: "lost race"),
                AutoStartAcknowledgement(operationId: autoStartOperations[0].id, outcome: .applied, reason: "")
            ]
        )
        #expect(autoStartState.pendingAutoStartOperations.isEmpty)
        #expect(autoStartState.autoStartBreaks)
    }

    @Test func autoStartSyncRebasesNewerPendingToggleOntoCanonicalResponse() throws {
        var state = PersistedTimerState.fresh()
        let sent = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: true,
            wallMs: 1
        )
        let newer = TestFixtures.autoStartOperation(
            deviceID: state.deviceId,
            enabled: false,
            wallMs: 2
        )
        state.pendingAutoStartOperations = [sent, newer]

        try state.applyAutoStartSync(
            canonicalValue: true,
            sentOperations: [sent],
            acknowledgements: [AutoStartAcknowledgement(
                operationId: sent.id,
                outcome: .applied,
                reason: ""
            )]
        )

        #expect(state.autoStartBreaks)
        #expect(state.pendingAutoStartOperations == [newer])
        #expect(!AutoStartReducer.applying(state.pendingAutoStartOperations, to: state.autoStartBreaks))
    }

    @Test func durationSyncReplaysNewerPendingEditAfterInFlightAcknowledgement() throws {
        var state = PersistedTimerState.fresh()
        state.settings.selectedPhase = .longBreak
        state.autoStartBreaks = true
        let sent = TestFixtures.durationOperation(
            id: "duration-operation-sent",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 1
        )
        let newer = TestFixtures.durationOperation(
            id: "duration-operation-newer",
            phase: .focus,
            durationMs: 45 * 60_000,
            wallMs: 2
        )
        state.pendingDurationOperations = [newer]
        state.settings.setMinutes(45, for: .focus)

        try state.applyDurationSync(
            canonicalDurations: DurationValues(
                focus: sent.durationMs,
                shortBreak: 8 * 60_000,
                longBreak: 20 * 60_000
            ),
            sentOperations: [sent],
            acknowledgements: [DurationAcknowledgement(
                operationId: sent.id,
                outcome: .applied,
                reason: ""
            )]
        )

        #expect(state.pendingDurationOperations == [newer])
        #expect(state.settings.durationMs(for: .focus) == newer.durationMs)
        #expect(state.settings.durationMs(for: .shortBreak) == 8 * 60_000)
        #expect(state.settings.durationMs(for: .longBreak) == 20 * 60_000)
        #expect(state.settings.selectedPhase == .longBreak)
        #expect(state.autoStartBreaks)
    }

    @Test func legacyDurationBootstrapUsesSentinelWithoutAdvancingClock() {
        var state = PersistedTimerState.fresh()
        state.hlcWallMs = 123_456
        state.hlcCounter = 7
        state.settings.setMinutes(30, for: .focus)
        state.settings.setMinutes(20, for: .longBreak)

        state.migrateLegacyDurationSettings()

        #expect(state.hlcWallMs == 123_456)
        #expect(state.hlcCounter == 7)
        #expect(state.pendingDurationOperations.count == 2)
        #expect(state.pendingDurationOperations.allSatisfy {
            $0.hlcWallMs == 0
                && $0.hlcCounter == 0
                && $0.occurredAt == Date(timeIntervalSince1970: 0)
                && $0.isValid
        })
    }

    @Test func historyUsesBestDateAndRoundsMinutesUp() {
        let completed = HistoryItem(
            id: "history-completed",
            timerId: "timer-completed",
            commandId: "command-completed",
            taskId: nil,
            phase: .focus,
            status: "completed",
            plannedDurationMs: 60_001,
            completedAt: TestFixtures.anchor,
            endedAt: TestFixtures.anchor.addingTimeInterval(10)
        )
        let cancelled = HistoryItem(
            id: "history-cancelled",
            timerId: "timer-cancelled",
            commandId: "command-cancelled",
            taskId: nil,
            phase: .shortBreak,
            status: "cancelled",
            plannedDurationMs: 0,
            completedAt: nil,
            endedAt: TestFixtures.anchor
        )

        #expect(completed.date == TestFixtures.anchor)
        #expect(completed.minutes == 2)
        #expect(cancelled.date == TestFixtures.anchor)
        #expect(cancelled.minutes == 1)
    }

    @Test func completedFocusAnalyticsGroupsTimeByTaskAndExcludesOtherArrivals() throws {
        let writing = try #require(FocusTask(title: "Writing"))
        let review = try #require(FocusTask(title: "Review"))
        let deletedTaskID = "11111111-2222-3333-4444-555555555555"
        let otherDeletedTaskID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
        let history = [
            TestFixtures.history(
                id: "writing-25",
                durationMs: 25 * 60_000,
                date: TestFixtures.anchor,
                taskID: writing.id.uuidString
            ),
            TestFixtures.history(
                id: "writing-10",
                durationMs: 10 * 60_000,
                date: TestFixtures.anchor,
                taskID: writing.id.uuidString
            ),
            TestFixtures.history(
                id: "review-30",
                durationMs: 30 * 60_000,
                date: TestFixtures.anchor,
                taskID: review.id.uuidString
            ),
            TestFixtures.history(
                id: "unassigned-15",
                durationMs: 15 * 60_000,
                date: TestFixtures.anchor
            ),
            TestFixtures.history(
                id: "deleted-20",
                durationMs: 20 * 60_000,
                date: TestFixtures.anchor,
                taskID: deletedTaskID
            ),
            TestFixtures.history(
                id: "other-deleted-20",
                durationMs: 20 * 60_000,
                date: TestFixtures.anchor,
                taskID: otherDeletedTaskID
            ),
            TestFixtures.history(
                id: "cancelled-focus",
                status: "cancelled",
                durationMs: 90 * 60_000,
                date: TestFixtures.anchor,
                taskID: writing.id.uuidString
            ),
            TestFixtures.history(
                id: "completed-break",
                phase: .shortBreak,
                durationMs: 60 * 60_000,
                date: TestFixtures.anchor,
                taskID: writing.id.uuidString
            )
        ]
        let tasks = Dictionary(uniqueKeysWithValues: [writing, review].map { ($0.id, $0) })

        let summaries = HistoryAnalytics.completedFocusSummaries(from: history) { item in
            item.taskId.flatMap(UUID.init(uuidString:)).flatMap { tasks[$0] }
        }

        #expect(summaries == [
            CompletedFocusSummary(
                id: writing.id.uuidString.lowercased(),
                taskTitle: "Writing",
                completedPomodoros: 2,
                timeSpentMs: 35 * 60_000
            ),
            CompletedFocusSummary(
                id: review.id.uuidString.lowercased(),
                taskTitle: "Review",
                completedPomodoros: 1,
                timeSpentMs: 30 * 60_000
            ),
            CompletedFocusSummary(
                id: "task:\(deletedTaskID)",
                taskTitle: "Deleted task",
                completedPomodoros: 1,
                timeSpentMs: 20 * 60_000
            ),
            CompletedFocusSummary(
                id: "task:\(otherDeletedTaskID)",
                taskTitle: "Deleted task",
                completedPomodoros: 1,
                timeSpentMs: 20 * 60_000
            ),
            CompletedFocusSummary(
                id: "unassigned",
                taskTitle: "Unassigned",
                completedPomodoros: 1,
                timeSpentMs: 15 * 60_000
            )
        ])
    }

    @Test func historyTaskContextDistinguishesResolvedDeletedAndUnassignedTasks() throws {
        let retainedTask = try #require(FocusTask(title: "Retained title"))
        let retained = TestFixtures.history(
            id: "retained-task-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor,
            taskID: retainedTask.id.uuidString
        )
        let deleted = TestFixtures.history(
            id: "deleted-task-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor,
            taskID: "11111111-2222-3333-4444-555555555555"
        )
        let unassigned = TestFixtures.history(
            id: "unassigned-task-history",
            durationMs: 25 * 60_000,
            date: TestFixtures.anchor
        )

        #expect(HistoryAnalytics.taskContext(for: retained) { _ in retainedTask } == "Retained title")
        #expect(HistoryAnalytics.taskContext(for: deleted) { _ in nil } == "Deleted task")
        #expect(HistoryAnalytics.taskContext(for: unassigned) { _ in nil } == "Unassigned")
    }

    @Test func reducerAppliesCommandsInDeviceSequenceOrder() {
        let start = TestFixtures.command(.start, sequence: 1, elapsed: 0)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: 12_000)
        let finish = TestFixtures.command(.finish, sequence: 3, elapsed: 12_000)

        let result = TimerReducer.applying([finish, start, pause], to: nil, history: [])

        #expect(result.timer?.status == .completed)
        #expect(result.timer?.elapsedAtAnchorMs == 60_000)
        #expect(result.history.count == 1)
        #expect(result.history.first?.status == "completed")
    }

    @Test func localTimerReducerIsPermutationInvariantAndIdempotentByDeviceSequence() {
        let commands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0),
            TestFixtures.command(.pause, sequence: 2, elapsed: 12_000),
            TestFixtures.command(.resume, sequence: 3, elapsed: 12_000),
            TestFixtures.command(.finish, sequence: 4, elapsed: 12_000)
        ]
        let expected = TimerReducer.applying(commands, to: nil, history: [])

        for permutation in TestFixtures.permutations(of: commands) {
            let result = TimerReducer.applying(permutation, to: nil, history: [])
            #expect(result.timer == expected.timer)
            #expect(result.history == expected.history)
        }
        let duplicated = TimerReducer.applying(commands + commands, to: nil, history: [])
        #expect(duplicated.timer == expected.timer)
        #expect(duplicated.history == expected.history)
    }

    @Test func localTimerReducerResumesSupersededTimerAndSupersedesReplacement() {
        let commands = [
            TestFixtures.command(.start, sequence: 1, elapsed: 0, timerID: "timer-a"),
            TestFixtures.command(.start, sequence: 2, elapsed: 0, timerID: "timer-b"),
            TestFixtures.command(.resume, sequence: 3, elapsed: 12_000, timerID: "timer-a")
        ]

        let result = TimerReducer.applying(commands, to: nil, history: [])

        #expect(result.timer?.id == "timer-a")
        #expect(result.timer?.status == .running)
        #expect(result.timer?.elapsedAtAnchorMs == 12_000)
        #expect(result.history.map(\.timerId) == ["timer-b"])
        #expect(result.history.map(\.status) == [CanonicalTimer.Status.superseded.rawValue])
    }

    @Test func localTimerReducerNeverRestartsTimerAlreadyInHistory() {
        let completed = TestFixtures.history(
            id: "timer-existing",
            durationMs: 60_000,
            date: TestFixtures.anchor
        )
        let start = TestFixtures.command(.start, sequence: 2, elapsed: 0, timerID: completed.timerId)

        let result = TimerReducer.apply(start, to: nil, history: [completed])

        #expect(result.0 == nil)
        #expect(result.1 == [completed])
    }

    @Test func localTimerReducerCoversEveryStateCommandAndTargetMatrix() {
        let statuses: [CanonicalTimer.Status?] = [
            nil, .running, .paused, .completed, .cancelled, .superseded
        ]
        let commandTypes: [CommandType] = [.start, .pause, .resume, .finish, .cancel, .clear]

        for status in statuses {
            for commandType in commandTypes {
                for usesSameID in [true, false] {
                    let elapsed: Int64 = status == .completed ? 60_000 : 10_000
                    let base = status.map {
                        TestFixtures.timer(
                            status: $0 == .superseded ? .running : $0,
                            elapsed: elapsed,
                            timerID: $0 == .superseded ? "timer-current" : "timer-test0001"
                        )
                    }
                    let baseHistory = status == .superseded
                        ? [TestFixtures.history(
                            id: "timer-test0001",
                            status: CanonicalTimer.Status.superseded.rawValue,
                            durationMs: 60_000,
                            date: TestFixtures.anchor
                        )]
                        : []
                    let timerID = usesSameID ? "timer-test0001" : "timer-foreign"
                    let command = TestFixtures.command(
                        commandType,
                        sequence: 2,
                        elapsed: 10_000,
                        timerID: timerID
                    )
                    let result = TimerReducer.apply(command, to: base, history: baseHistory)
                    let isActive = status == .running || status == .paused

                    if status == .superseded {
                        switch commandType {
                        case .start where !usesSameID:
                            #expect(result.0?.id == timerID)
                            #expect(result.0?.status == .running)
                            #expect(result.1.map(\.timerId) == ["timer-current", "timer-test0001"])
                        case .resume where usesSameID:
                            #expect(result.0?.id == "timer-test0001")
                            #expect(result.0?.status == .running)
                            #expect(result.1.map(\.timerId) == ["timer-current"])
                        default:
                            #expect(result.0 == base)
                            #expect(result.1 == baseHistory)
                        }
                        continue
                    }

                    switch commandType {
                    case .start where base == nil || !usesSameID:
                        #expect(result.0?.id == timerID)
                        #expect(result.0?.status == .running)
                        #expect(result.1.count == (isActive ? 1 : 0))
                        if isActive {
                            #expect(result.1.first?.status == CanonicalTimer.Status.superseded.rawValue)
                            #expect(result.1.first?.timerId == base?.id)
                        }
                    case .pause where usesSameID && status == .running:
                        #expect(result.0?.status == .paused)
                        #expect(result.0?.elapsedAtAnchorMs == 10_000)
                        #expect(result.1.isEmpty)
                    case .resume where usesSameID && status == .paused:
                        #expect(result.0?.status == .running)
                        #expect(result.0?.elapsedAtAnchorMs == 10_000)
                        #expect(result.1.isEmpty)
                    case .finish where usesSameID && isActive:
                        #expect(result.0?.status == .completed)
                        #expect(result.0?.elapsedAtAnchorMs == 60_000)
                        #expect(result.1.map(\.status) == [CanonicalTimer.Status.completed.rawValue])
                    case .cancel where usesSameID && isActive:
                        #expect(result.0?.status == .cancelled)
                        #expect(result.0?.elapsedAtAnchorMs == 10_000)
                        #expect(result.1.map(\.status) == [CanonicalTimer.Status.cancelled.rawValue])
                    case .clear where usesSameID && (status == .completed || status == .cancelled):
                        #expect(result.0 == nil)
                        #expect(result.1.isEmpty)
                    default:
                        #expect(result.0 == base)
                        #expect(result.1.isEmpty)
                    }
                }
            }
        }
    }

    @Test func localTimerReducerAutoCompletesAtDeadlineBeforeLaterCommands() throws {
        let running = TestFixtures.timer(
            status: .running,
            elapsed: 30_000,
            phase: .shortBreak,
            taskID: "task-source"
        )
        let latePause = TestFixtures.command(.pause, sequence: 31, elapsed: 40_000)
        let result = TimerReducer.apply(latePause, to: running, history: [])
        let completed = try #require(result.0)
        let completion = try #require(result.1.first)

        #expect(completed.status == .completed)
        #expect(completed.elapsedAtAnchorMs == 60_000)
        #expect(completed.anchorAt == TestFixtures.anchor.addingTimeInterval(30))
        #expect(completed.lastIntent == nil)
        #expect(completion.id == running.id)
        #expect(completion.commandId == nil)
        #expect(completion.phase == running.phase)
        #expect(completion.plannedDurationMs == running.plannedDurationMs)
        #expect(completion.taskId == running.taskId)
        #expect(completion.completedAt == completed.anchorAt)
        #expect(completion.endedAt == completed.anchorAt)
    }

    @Test func localTimerReducerLateFinishClaimsDeadlineCompletion() throws {
        let running = TestFixtures.timer(status: .running, elapsed: 30_000, phase: .longBreak)
        let finish = TestFixtures.command(.finish, sequence: 31, elapsed: 60_000)
        let result = TimerReducer.apply(finish, to: running, history: [])
        let completed = try #require(result.0)
        let completion = try #require(result.1.first)

        #expect(completed.status == .completed)
        #expect(completed.anchorAt == TestFixtures.anchor.addingTimeInterval(30))
        #expect(completed.lastIntent?.commandId == finish.id)
        #expect(completion.commandId == finish.id)
        #expect(completion.phase == running.phase)
        #expect(completion.completedAt == completed.anchorAt)
        #expect(completion.endedAt == completed.anchorAt)
    }

    @Test func localTimerReducerStartAfterDeadlineKeepsAutomaticCompletion() {
        let running = TestFixtures.timer(status: .running, elapsed: 30_000)
        let replacement = TestFixtures.command(
            .start,
            sequence: 31,
            elapsed: 0,
            timerID: "timer-replacement"
        )
        let result = TimerReducer.apply(replacement, to: running, history: [])

        #expect(result.0?.id == replacement.timerId)
        #expect(result.0?.status == .running)
        #expect(result.1.map(\.status) == [CanonicalTimer.Status.completed.rawValue])
        #expect(result.1.first?.timerId == running.id)
        #expect(result.1.first?.commandId == nil)
    }

    @Test func localTimerReducerTerminalHistoryUsesStartedTimerMetadata() throws {
        let running = TestFixtures.timer(
            status: .running,
            elapsed: 5_000,
            phase: .shortBreak,
            taskID: "task-source"
        )
        let finish = TestFixtures.command(.finish, sequence: 2, elapsed: 5_000)
        let result = TimerReducer.apply(finish, to: running, history: [])
        let completion = try #require(result.1.first)

        #expect(completion.phase == running.phase)
        #expect(completion.plannedDurationMs == running.plannedDurationMs)
        #expect(completion.taskId == running.taskId)
        #expect(completion.completedAt == finish.occurredAt)
        #expect(completion.endedAt == finish.occurredAt)
    }

    @Test func timerReducerKeepsTaskFromStartThroughCompletion() throws {
        let taskID = "aaf83054-24b2-8c0e-901f-a974147bfe82"
        let start = TestFixtures.command(.start, sequence: 1, elapsed: 0, taskID: taskID)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: 12_000, taskID: "different-task")
        let finish = TestFixtures.command(.finish, sequence: 3, elapsed: 12_000)

        let result = TimerReducer.applying([finish, pause, start], to: nil, history: [])

        #expect(result.timer?.taskId == taskID)
        #expect(try #require(result.history.first).taskId == taskID)
    }

    @Test func accountChangeKeepsLocalPreferencesAndResetsSyncedDurations() {
        var state = PersistedTimerState.fresh()
        let deviceID = state.deviceId
        state.settings.focusMinutes = 42
        state.settings.selectedPhase = .longBreak
        state.autoStartBreaks = true
        state.cachedUser = User(id: String(repeating: "a", count: 32), email: "a@example.com", name: "A", avatarUrl: "")
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.pendingTaskOperations = [TaskOperation(
            id: "task-operation-test",
            taskId: "aaf83054-24b2-8c0e-901f-a974147bfe82",
            type: .delete,
            title: nil,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1,
            hlcCounter: 0
        )]
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-operation-test",
            phase: .focus,
            durationMs: 42 * 60_000,
            wallMs: 2
        )]
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        let newUser = User(id: String(repeating: "b", count: 32), email: "b@example.com", name: "B", avatarUrl: "")

        state.prepare(for: newUser)

        #expect(state.deviceId == deviceID)
        #expect(state.settings.durationsMs == .defaults)
        #expect(state.settings.selectedPhase == .longBreak)
        #expect(!state.autoStartBreaks)
        #expect(state.cachedUser == newUser)
        #expect(state.pendingCommands.isEmpty)
        #expect(state.pendingTaskOperations.isEmpty)
        #expect(state.pendingDurationOperations.isEmpty)
        #expect(state.pendingAutoStartOperations.isEmpty)
        #expect(state.canonicalTimer == nil)
    }

    @Test func sameAccountRetainsLocalAccountData() {
        var state = PersistedTimerState.fresh()
        let user = User(id: "user-a", email: "a@example.com", name: "A", avatarUrl: "")
        state.cachedUser = user
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)
        let original = state

        state.prepare(for: user)

        #expect(state == original)
    }

    @Test func firstAccountClaimsLocalTimerData() {
        var state = PersistedTimerState.fresh()
        let user = User(id: "user-a", email: "a@example.com", name: "A", avatarUrl: "")
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 0)

        state.prepare(for: user)

        #expect(state.cachedUser == user)
        #expect(state.pendingCommands.count == 1)
        #expect(state.canonicalTimer?.status == .running)
    }

    @Test func cancelAddsOptimisticHistory() {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let cancel = TestFixtures.command(.cancel, sequence: 2, elapsed: 5_000)

        let result = TimerReducer.apply(cancel, to: running, history: [])

        #expect(result.0?.status == .cancelled)
        #expect(result.1.count == 1)
        #expect(result.1.first?.status == "cancelled")
        #expect(result.1.first?.endedAt == cancel.occurredAt)
    }

    @Test func clearRemovesInactiveTimerWithoutChangingHistory() {
        let completed = TestFixtures.timer(status: .completed, elapsed: 60_000)
        let clear = TestFixtures.command(.clear, sequence: 2, elapsed: 60_000)
        let history = [HistoryItem(
            id: "history-test0001",
            timerId: completed.id,
            commandId: "command-finish",
            taskId: nil,
            phase: .focus,
            status: "completed",
            plannedDurationMs: 60_000,
            completedAt: TestFixtures.anchor,
            endedAt: nil
        )]

        let result = TimerReducer.apply(clear, to: completed, history: history)

        #expect(result.0 == nil)
        #expect(result.1 == history)
    }

    @Test func reducerClampsObservedElapsedAtBothBounds() throws {
        let running = TestFixtures.timer(status: .running, elapsed: 5_000)
        let pause = TestFixtures.command(.pause, sequence: 2, elapsed: -1_000)
        let paused = try #require(TimerReducer.apply(pause, to: running, history: []).0)
        let resume = TestFixtures.command(.resume, sequence: 3, elapsed: 120_000)
        let resumed = try #require(TimerReducer.apply(resume, to: paused, history: []).0)

        #expect(paused.status == .paused)
        #expect(paused.elapsedAtAnchorMs == 0)
        #expect(resumed.status == .running)
        #expect(resumed.elapsedAtAnchorMs == 60_000)
    }

    @Test func longBreakFollowsEveryFourthCompletedFocus() {
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 3) == .shortBreak)
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 4) == .longBreak)
        #expect(TimerReducer.breakPhase(afterCompletedFocusCount: 8) == .longBreak)
    }

    @Test func parserEmitsNamedJSONAndPlainRevisionEvents() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: "event: revision") == nil)
        #expect(parser.consume(line: "data: {\"revision\":42}") == nil)
        #expect(parser.consume(line: "") == 42)
        #expect(parser.consume(line: "data: 17") == nil)
        #expect(parser.consume(line: "") == 17)
    }

    @Test func parserCombinesMultilineEventData() {
        var parser = SSERevisionParser()

        #expect(parser.consume(line: "data: {\"revision\":") == nil)
        #expect(parser.consume(line: "data: 42}") == nil)
        #expect(parser.consume(line: "") == 42)
    }

    @Test func revisionHintDuringSyncIsCoalescedForFollowUp() {
        var hints = RevisionHintCoalescer()

        #expect(hints.receive(12, localRevision: 10, isSyncing: true) == false)
        #expect(hints.consumeFollowUp(localRevision: 10) == true)
        #expect(hints.consumeFollowUp(localRevision: 12) == false)
    }

    @Test func activeStreamLifecycleOwnsCurrentTask() throws {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)

        let startedStreamID = lifecycle.begin()
        let streamID = try #require(startedStreamID)

        #expect(lifecycle.owns(streamID))
        lifecycle.end(streamID)
        #expect(lifecycle.begin() != nil)
    }

    @Test func activeStreamLifecyclePreventsConcurrentStreams() throws {
        var lifecycle = RevisionStreamLifecycle()
        lifecycle.setActive(true)
        let startedStreamID = lifecycle.begin()
        let streamID = try #require(startedStreamID)

        #expect(lifecycle.begin() == nil)
        lifecycle.end(UUID())
        #expect(lifecycle.owns(streamID))
        lifecycle.cancelCurrent()
        #expect(!lifecycle.owns(streamID))
        #expect(lifecycle.begin() != nil)
    }

    @Test func syncOwnershipRequestsFollowUpForNewerGeneration() throws {
        var ownership = SyncOwnership()
        let startedOwner = ownership.begin(generation: 1)
        let owner = try #require(startedOwner)

        #expect(ownership.begin(generation: 2) == nil)
        #expect(ownership.finish(owner, currentGeneration: 2) == true)
    }

    @Test func verifiedSessionAllowsMatchingGeneration() {
        var verification = SessionVerification()

        verification.markVerified(generation: 7)

        #expect(verification.allows(generation: 7))
    }

    @Test func appErrorsProvideActionableDescriptions() {
        #expect(AppError.configuration.errorDescription == "Google Sign-In is not configured for this build.")
        #expect(AppError.missingPresentationAnchor.errorDescription == "No window is available for Google Sign-In.")
        #expect(AppError.missingIDToken.errorDescription == "Google did not return an identity token.")
        #expect(AppError.unauthorized.errorDescription == "Session expired. Sign in again.")
        #expect(AppError.server("Try later.").errorDescription == "Try later.")
        #expect(AppError.invalidResponse.errorDescription == "Server returned an invalid response.")
    }

    @Test func validStreamResponseAcceptsSSEMediaTypeParameters() {
        #expect(RevisionStreamResponse.isValid(statusCode: 200, contentType: "text/event-stream; charset=utf-8"))
    }

    @Test func foregroundPollingIsFasterForActiveTimers() {
        #expect(RemotePolling.interval(isTimerActive: true) == 2)
        #expect(RemotePolling.interval(isTimerActive: false) == 5)
    }
}

private let keychainTokens = TokenPair(
    accessToken: "keychain-access",
    accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
    refreshToken: "keychain-refresh",
    refreshTokenExpiresAt: Date(timeIntervalSince1970: 3_000)
)

private func expectKeychainBaseQuery(_ query: KeychainQuerySnapshot) {
    #expect(query.itemClass == kSecClassGenericPassword as String)
    #expect(query.service == "me.egigoka.pomodorough.native-auth")
    #expect(query.account == "token-pair")
    #expect(query.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
}

private struct UUIDv7Fixture: Decodable {
    let schemaVersion: Int
    let rfc9562: RFC9562Fixture
}

private struct RFC9562Fixture: Decodable {
    let timestampMs: Int64
    let randomValueHex: String
    let uuid: String
}

private struct ConvergenceFixture: Decodable {
    let version: Int
    let epoch: String
    let cases: [ConvergenceCase]
    let projectionCases: [ConvergenceProjectionCase]
    let responseCases: [ConvergenceResponseCase]
}

private struct ConvergenceCase: Decodable {
    let name: String
    let nowMs: Int64
    let commands: [ConvergenceCommand]
    let expected: ConvergenceExpected
}

private struct ConvergenceCommand: Decodable {
    let id: String
    let sequence: Int64
    let deviceId: String
    let timerId: String
    let taskId: String?
    let type: String
    let phase: String
    let durationMs: Int64
    let atMs: Int64
    let wallMs: Int64
    let counter: Int64
    let elapsedMs: Int64
}

private struct ConvergenceExpected: Decodable, Equatable {
    let timer: ConvergenceTimer?
    let history: [ConvergenceHistory]
}

private struct ConvergenceTimer: Decodable, Equatable {
    let id: String
    let status: String
    let phase: String
    let durationMs: Int64
    let elapsedMs: Int64
    let anchorMs: Int64
    let lastCommandId: String
    let taskId: String?
}

private struct ConvergenceHistory: Decodable, Equatable {
    let timerId: String
    let status: String
    let phase: String
    let durationMs: Int64
    let commandId: String?
    let endedMs: Int64
    let taskId: String?
}

private struct ConvergenceProjectionCase: Decodable {
    let name: String
    let taskOperations: [ConvergenceTaskOperation]
    let durationOperations: [ConvergenceDurationOperation]
    let autoStartOperations: [ConvergenceAutoStartOperation]
    let expected: ConvergenceProjectionExpected
}

private struct ConvergenceTaskOperation: Decodable {
    let id: String
    let deviceId: String
    let taskId: String
    let type: String
    let title: String?
    let atMs: Int64
    let wallMs: Int64
    let counter: Int64
}

private struct ConvergenceDurationOperation: Decodable {
    let id: String
    let deviceId: String
    let phase: String
    let durationMs: Int64
    let atMs: Int64
    let wallMs: Int64
    let counter: Int64
}

private struct ConvergenceAutoStartOperation: Decodable {
    let id: String
    let deviceId: String
    let enabled: Bool
    let atMs: Int64
    let wallMs: Int64
    let counter: Int64
}

private struct ConvergenceProjectionExpected: Decodable {
    let tasks: [ConvergenceTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
}

private struct ConvergenceTask: Decodable, Equatable {
    let id: String
    let title: String
}

private struct ConvergenceResponseCase: Decodable {
    let name: String
    let local: ConvergenceResponseLocal
    let sentIds: ConvergenceResponseIDs
    let acknowledgements: ConvergenceResponseAcknowledgements
    let canonical: ConvergenceResponseCanonical
    let expected: ConvergenceResponseExpected
}

private struct ConvergenceResponseLocal: Decodable {
    let commands: [ConvergenceCommand]
    let taskOperations: [ConvergenceTaskOperation]
    let durationOperations: [ConvergenceDurationOperation]
    let autoStartOperations: [ConvergenceAutoStartOperation]
}

private struct ConvergenceResponseIDs: Decodable {
    let commands: [String]
    let taskOperations: [String]
    let durationOperations: [String]
    let autoStartOperations: [String]
}

private struct ConvergenceResponseAcknowledgements: Decodable {
    let commands: [ConvergenceResponseAcknowledgement]
    let taskOperations: [ConvergenceResponseAcknowledgement]
    let durationOperations: [ConvergenceResponseAcknowledgement]
    let autoStartOperations: [ConvergenceResponseAcknowledgement]
}

private struct ConvergenceResponseAcknowledgement: Decodable {
    let id: String
    let outcome: String
    let reason: String
}

private struct ConvergenceResponseCanonical: Decodable {
    let timer: ConvergenceTimer?
    let history: [ConvergenceHistory]
    let tasks: [ConvergenceTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
}

private struct ConvergenceResponseExpected: Decodable {
    let commandIds: [String]
    let taskOperationIds: [String]
    let durationOperationIds: [String]
    let autoStartOperationIds: [String]
    let timer: ConvergenceTimer?
    let history: [ConvergenceHistory]
    let tasks: [ConvergenceTask]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
}

private func normalizedConvergence(
    timer: CanonicalTimer?,
    history: [HistoryItem],
    epoch: Date
) -> ConvergenceExpected {
    let normalizedTimer = timer.map {
        ConvergenceTimer(
            id: $0.id,
            status: $0.status.rawValue,
            phase: $0.phase.rawValue,
            durationMs: $0.plannedDurationMs,
            elapsedMs: $0.elapsedAtAnchorMs,
            anchorMs: Int64(($0.anchorAt.timeIntervalSince(epoch) * 1_000).rounded()),
            lastCommandId: $0.lastIntent?.commandId ?? "",
            taskId: $0.taskId
        )
    }
    let normalizedHistory = history.map {
        ConvergenceHistory(
            timerId: $0.timerId,
            status: $0.status,
            phase: $0.phase.rawValue,
            durationMs: $0.plannedDurationMs,
            commandId: $0.commandId,
            endedMs: Int64((($0.endedAt ?? $0.completedAt ?? epoch).timeIntervalSince(epoch) * 1_000).rounded()),
            taskId: $0.taskId
        )
    }
    return ConvergenceExpected(timer: normalizedTimer, history: normalizedHistory)
}
