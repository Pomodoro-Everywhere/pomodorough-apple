import Foundation
import CryptoKit
import IrohLib
import Testing
@testable import Pomodorough

@Suite("Iroh Replication")
struct IrohReplicationTests {
    private struct CoreTimerInput: Encodable, Sendable {
        let canonicalTimer: CanonicalTimer?
        let history: [HistoryItem]
        let commands: [TimerCommand]
        let now: Date
    }

    private struct CoreTimerProjection: Decodable, Sendable {
        let canonicalTimer: CanonicalTimer?
        let history: [HistoryItem]
    }

    @Test @MainActor
    func cancellingRequestedRoomLeavePreservesActiveRoomWorkspace() throws {
        let suiteName = "PomodoroughTests.IrohLeaveCancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        let store = temporaryStore()
        let returnTask = try #require(FocusTask(title: "Previous workspace"))
        var returnState = PersistedTimerState.fresh()
        returnState.tasks = [returnTask]
        returnState.knownTasks = [returnTask]
        let roomTask = try #require(FocusTask(title: "Room workspace"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Leave confirmation",
            returnState: returnState,
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [roomTask],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )

        model.requestIrohRoomLeave()
        #expect(model.isIrohRoomLeaveConfirmationPresented)
        model.cancelIrohRoomLeave()

        #expect(!model.isIrohRoomLeaveConfirmationPresented)
        #expect(model.replicationMode == .iroh)
        #expect(model.tasks == [roomTask])
        #expect(model.activeRoom?.roomID == roomID)
        #expect(store.roomSnapshot(roomID: roomID) != nil)
    }

    @Test @MainActor
    func confirmedRoomLeaveRestoresPreviousWorkspaceAndRetainsRoomLog() async throws {
        let suiteName = "PomodoroughTests.IrohLeaveConfirm.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        let store = temporaryStore()
        let returnTask = try #require(FocusTask(title: "Previous workspace"))
        var returnState = PersistedTimerState.fresh()
        returnState.tasks = [returnTask]
        returnState.knownTasks = [returnTask]
        let roomTask = try #require(FocusTask(title: "Room workspace"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Retained room log",
            returnState: returnState,
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [roomTask],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )
        model.requestIrohRoomLeave()

        await model.confirmIrohRoomLeave()
        await model.confirmIrohRoomLeave()

        #expect(!model.isIrohRoomLeaveConfirmationPresented)
        #expect(!model.isLeavingIrohRoom)
        #expect(model.replicationMode == .offline)
        #expect(model.tasks == [returnTask])
        #expect(model.activeRoom == nil)
        let retainedRoom = try #require(store.roomSnapshot(roomID: roomID))
        #expect(retainedRoom.roomName == "Retained room log")
        #expect(retainedRoom.operationCount > 0)
    }

    @Test @MainActor
    func replicationModePersistsOutsideSynchronizedTimerState() async throws {
        let suiteName = "PomodoroughTests.IrohMode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = temporaryStore()
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )

        await model.setReplicationMode(.offline)

        let restored = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )
        #expect(restored.replicationMode == .offline)
        #expect(defaults.string(forKey: "replication-mode-v1") == ReplicationMode.offline.rawValue)
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["replicationMode"] == nil)
    }

    @Test @MainActor
    func delayedCentralSyncCannotOverwriteActivatedIrohWorkspace() async throws {
        let suiteName = "PomodoroughTests.IrohStaleSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = temporaryStore()
        let releaseSync = DispatchSemaphore(value: 0)
        defer {
            releaseSync.signal()
            defaults.removePersistentDomain(forName: suiteName)
        }
        let centralTask = try #require(FocusTask(title: "Central task"))
        var centralState = PersistedTimerState.fresh()
        centralState.cachedUser = TestFixtures.user
        centralState.knownTasks = [centralTask]
        centralState.pendingTaskOperations = [TaskOperation(
            id: "task-operation-central-stale",
            taskId: centralTask.id.uuidString.lowercased(),
            type: .upsert,
            title: centralTask.title,
            occurredAt: TestFixtures.anchor,
            hlcWallMs: 1_000_001,
            hlcCounter: 0
        )]
        defaults.set(try JSONEncoder.api.encode(centralState), forKey: "timer-state-v2")

        let roomTask = try #require(FocusTask(title: "Room task"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Stale response test",
            returnState: centralState,
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [roomTask],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let centralTaskJSON = [
            "id": centralTask.id.uuidString.lowercased(),
            "title": centralTask.title
        ]
        let server = try LoopbackHTTPServer { request in
            let requestText = String(decoding: request, as: UTF8.self)
            if requestText.hasPrefix("GET /api/v1/me ") {
                return LoopbackHTTPResponse(body: Data(
                    #"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8
                ))
            }
            if requestText.hasPrefix("POST /api/v1/sync ") {
                releaseSync.wait()
                let response: [String: Any] = [
                    "acknowledgements": [],
                    "taskAcknowledgements": [[
                        "operationId": "task-operation-central-stale",
                        "outcome": "applied",
                        "reason": ""
                    ]],
                    "durationAcknowledgements": [],
                    "autoStartAcknowledgements": [],
                    "selectedTaskAcknowledgements": [],
                    "selectedTaskId": NSNull(),
                    "durationsMs": [
                        "focus": 1_500_000,
                        "short_break": 300_000,
                        "long_break": 900_000
                    ],
                    "autoStartBreaks": false,
                    "revision": 1,
                    "canonicalTimer": NSNull(),
                    "history": [],
                    "tasks": [centralTaskJSON],
                    "serverTime": "2026-07-21T08:00:00.000Z",
                    "serverHlcWallMs": 1_784_620_800_000,
                    "serverHlcCounter": 0
                ]
                return LoopbackHTTPResponse(body: try! JSONSerialization.data(withJSONObject: response))
            }
            return LoopbackHTTPResponse(statusCode: 404, body: Data())
        }
        let model = AppModel(
            api: APIClient(baseURL: server.baseURL, keychain: StaticTokenStore()),
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )

        let restoreTask = Task { await model.restore() }
        var reachedServer = false
        for _ in 0..<500 {
            if server.request.contains("POST /api/v1/sync ") {
                reachedServer = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(reachedServer, "Timed out waiting for central sync")
        let modeTask = Task { await model.setReplicationMode(.iroh) }
        var activatedRoom = false
        for _ in 0..<500 {
            if model.replicationMode == .iroh, model.tasks == [roomTask] {
                activatedRoom = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(activatedRoom, "Timed out activating Iroh workspace")

        releaseSync.signal()
        await restoreTask.value
        await modeTask.value

        #expect(model.replicationMode == .iroh)
        #expect(model.tasks == [roomTask])
        #expect(store.activeRoomState?.tasks == [roomTask])
    }

    @Test @MainActor
    func signInOutsideCentralizedModePreflightsWhenCloudIsSelected() async throws {
        let scenario = "bootstrap-offline-sign-in"
        let suiteName = "PomodoroughTests.IrohOfflineSignIn.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = TestFixtures.session(for: scenario)
        defer { session.invalidateAndCancel() }
        let identity = RecordingGoogleIdentityProvider()
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
        #expect(model.isSignedIn)
        #expect(!model.isHistoryResolutionBlocking)
        #expect(TestFixtures.recordedRequests(for: scenario).allSatisfy { $0.path != "/api/v1/bootstrap" })

        await model.setReplicationMode(.centralized)

        #expect(TestFixtures.recordedRequests(for: scenario).contains { $0.path == "/api/v1/bootstrap" })
    }

    @Test func roomProjectionReplaysClearThenPauseAsOneTimerBatchAndSurvivesRestart() async throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        func command(
            _ type: CommandType,
            id: String,
            wallMs: Int64
        ) -> TimerCommand {
            TimerCommand(
                id: id,
                deviceSequence: 1,
                timerId: "timer-clear-pause",
                taskId: nil,
                type: type,
                phase: .focus,
                plannedDurationMs: 60_000,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1_000),
                hlcWallMs: wallMs,
                hlcCounter: 0,
                observedElapsedMs: type == .pause ? 10_000 : 0
            )
        }
        let records = [
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-c-pause",
                payload: .timer(command(.pause, id: "command-c-pause", wallMs: 1_002_000))
            ),
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-b-clear",
                payload: .timer(command(.clear, id: "command-b-clear", wallMs: 1_001_000))
            ),
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-a-start",
                payload: .timer(command(.start, id: "command-a-start", wallMs: 1_000_000))
            ),
        ]

        let projected = try store.insertRemoteRecords(records, roomID: roomID)

        #expect(projected.canonicalTimer?.id == "timer-clear-pause")
        #expect(projected.canonicalTimer?.status == .paused)
        #expect(projected.canonicalTimer?.startedByDeviceId == "device-a-start")
        let projectedLastIntentDeviceID = projected.canonicalTimer?.lastIntent?.deviceId
        #expect(projectedLastIntentDeviceID == "device-c-pause")

        let orderedRecords = records.sorted {
            guard case .timer(let left) = $0.payload,
                  case .timer(let right) = $1.payload else { return false }
            if left.hlcWallMs != right.hlcWallMs { return left.hlcWallMs < right.hlcWallMs }
            if left.hlcCounter != right.hlcCounter { return left.hlcCounter < right.hlcCounter }
            if $0.deviceId != $1.deviceId { return $0.deviceId < $1.deviceId }
            return left.id < right.id
        }
        let wireCommands = try orderedRecords.map { record -> [String: Any] in
            guard case .timer(let timerCommand) = record.payload,
                  var object = try JSONSerialization.jsonObject(
                    with: JSONEncoder.api.encode(timerCommand)
                  ) as? [String: Any] else {
                throw IrohProtocolError.invalidMessage("timer fixture encoding failed")
            }
            object["deviceId"] = record.deviceId
            return object
        }
        let input = try JSONSerialization.data(withJSONObject: [
            "canonicalTimer": NSNull(),
            "history": [],
            "commands": wireCommands,
            "now": "1970-01-01T00:16:43Z",
        ])
        let core = try SharedCore.bundled()
        let coreProjection = try await core.dispatch(
            "timer.reduce.v1",
            inputJSON: input,
            as: CoreTimerProjection.self
        )
        let projectedForCore = projected.canonicalTimer.map { timer in
            CanonicalTimer(
                id: timer.id,
                taskId: timer.taskId,
                phase: timer.phase,
                status: timer.status,
                plannedDurationMs: timer.plannedDurationMs,
                elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                anchorAt: timer.anchorAt,
                startedByDeviceId: timer.startedByDeviceId,
                lastIntent: timer.lastIntent.map {
                    TimerIntent(
                        type: $0.type,
                        commandId: $0.commandId,
                        occurredAt: $0.occurredAt,
                        deviceId: nil
                    )
                }
            )
        }
        #expect(coreProjection.canonicalTimer == projectedForCore)
        #expect(coreProjection.history == projected.history)

        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.canonicalTimer == projected.canonicalTimer)
        #expect(restarted.activeRoomState?.history == projected.history)

        for first in records.indices {
            for second in records.indices where second != first {
                let third = records.indices.first { $0 != first && $0 != second }!
                let permutationURL = temporaryURL()
                let permutationSecrets = MemoryIrohRoomSecretStore()
                let permutationStore = IrohRoomStore(
                    fileURL: permutationURL,
                    secretStore: permutationSecrets
                )
                _ = try permutationStore.createRoom(
                    roomID: roomID,
                    roomSecret: secret,
                    name: nil,
                    returnState: .fresh(),
                    genesis: emptyGenesis()
                )
                let permutationProjection = try permutationStore.insertRemoteRecords(
                    [records[first], records[second], records[third]],
                    roomID: roomID
                )
                #expect(permutationProjection.canonicalTimer == projected.canonicalTimer)
                #expect(permutationProjection.history == projected.history)
                let permutationRestart = IrohRoomStore(
                    fileURL: permutationURL,
                    secretStore: permutationSecrets
                )
                #expect(permutationRestart.activeRoomState?.canonicalTimer == projected.canonicalTimer)
                #expect(permutationRestart.activeRoomState?.history == projected.history)
            }
        }
    }

    @Test func roomProjectionPreservesHistoricalIdentityAcrossReactivationAndSwitch() throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let historical = HistoryItem(
            id: "history-custom",
            timerId: "timer-a0001",
            commandId: "finish-a",
            taskId: nil,
            phase: .focus,
            status: CanonicalTimer.Status.completed.rawValue,
            plannedDurationMs: 60_000,
            completedAt: Date(timeIntervalSince1970: 900),
            endedAt: Date(timeIntervalSince1970: 900)
        )
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [historical],
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 900_000,
                hlcCounter: 0
            )
        )
        func command(
            _ type: CommandType,
            id: String,
            timerID: String,
            wallMs: Int64
        ) -> TimerCommand {
            TimerCommand(
                id: id,
                deviceSequence: 1,
                timerId: timerID,
                taskId: nil,
                type: type,
                phase: .focus,
                plannedDurationMs: 60_000,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1_000),
                hlcWallMs: wallMs,
                hlcCounter: 0,
                observedElapsedMs: 10_000
            )
        }
        let projected = try store.insertRemoteRecords([
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-b-switch",
                payload: .timer(command(
                    .start,
                    id: "command-b-switch",
                    timerID: "timer-b0001",
                    wallMs: 1_001_000
                ))
            ),
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-a-reactivate",
                payload: .timer(command(
                    .pause,
                    id: "command-a-reactivate",
                    timerID: "timer-a0001",
                    wallMs: 1_000_000
                ))
            ),
        ], roomID: roomID)

        #expect(projected.canonicalTimer?.id == "timer-b0001")
        #expect(projected.history.first(where: { $0.timerId == "timer-a0001" })?.id == "history-custom")
        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.canonicalTimer == projected.canonicalTimer)
        #expect(restarted.activeRoomState?.history == projected.history)
    }

    @Test func canonicalProtocolFixtureDecodesIrohSelectedTaskRecords() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/protocol-fixtures-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "544fa8a8f33361e80421e1f8395223c6a1e1ff243f9583b6baee6d2a1f1112d0")
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        func decodeRecord(_ record: [String: Any]) throws -> IrohOperationRecord {
            let message = try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 1,
                "roomId": roomID,
                "requestId": requestID,
                "kind": "operationsResult",
                "records": [record],
            ])
            guard case .operationsResult(let result) = try IrohMessageCodec.decode(message),
                  let decoded = result.records.first else {
                throw IrohProtocolError.invalidMessage("fixture record did not decode")
            }
            return decoded
        }

        let genesisRecord = try #require(fixture["irohGenesisRecord"] as? [String: Any])
        let genesis = try decodeRecord(genesisRecord)
        guard case .genesis(let genesisValue) = genesis.payload else {
            Issue.record("Expected canonical fixture genesis")
            return
        }
        #expect(genesisValue.selectedTaskId == nil)
        #expect(genesis.isValid)
        var legacyGenesisRecord = genesisRecord
        var legacyGenesisOperation = try #require(legacyGenesisRecord["operation"] as? [String: Any])
        legacyGenesisOperation.removeValue(forKey: "selectedTaskId")
        legacyGenesisRecord["operation"] = legacyGenesisOperation
        guard case .genesis(let legacyGenesis) = try decodeRecord(legacyGenesisRecord).payload else {
            Issue.record("Expected pre-selected-task genesis compatibility")
            return
        }
        #expect(legacyGenesis.selectedTaskId == nil)

        let selectedRecord = try #require(fixture["irohSelectedTaskRecord"] as? [String: Any])
        let selected = try decodeRecord(selectedRecord)
        guard case .selectedTask(let selectedValue) = selected.payload else {
            Issue.record("Expected canonical fixture selected-task operation")
            return
        }
        #expect(selectedValue.id == "01a0219e-0800-7006-8000-000000000006")
        #expect(selectedValue.taskId == nil)
        #expect(selected.isValid)
        #expect(try selected.canonicalBytes() == JSONCanonicalizer.encodeJSONObject(
            fixture["irohSelectedTaskRecord"] as Any
        ))
    }

    @Test func selectedTaskWireRequiresNullableTaskIdentityAndRejectsUnknownFields() throws {
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        func message(operation: String) -> Data {
            Data("""
            {"protocolVersion":1,"roomId":"\(roomID)","requestId":"\(requestID)","kind":"operationsResult","records":[{"domain":"selectedTask","deviceId":"device-test0001","operation":\(operation)}]}
            """.utf8)
        }
        let valid = #"{"id":"selected-task-operation-peer0001","taskId":null,"occurredAt":"1970-01-01T00:16:40Z","hlcWallMs":1000000,"hlcCounter":0}"#
        guard case .operationsResult(let decoded) = try IrohMessageCodec.decode(message(operation: valid)),
              case .selectedTask(let operation) = decoded.records.first?.payload else {
            Issue.record("Expected strict selected-task record")
            return
        }
        #expect(operation.taskId == nil)
        let localClear = IrohOperationRecord(
            domain: .selectedTask,
            deviceId: "device-test0001",
            payload: .selectedTask(IrohSelectedTaskOperation(
                id: "selected-task-operation-local-clear",
                taskId: nil,
                occurredAt: Date(timeIntervalSince1970: 1_000),
                hlcWallMs: 1_000_000,
                hlcCounter: 0
            ))
        )
        let encodedClear = try #require(
            (JSONSerialization.jsonObject(with: JSONEncoder.api.encode(localClear)) as? [String: Any])?["operation"]
                as? [String: Any]
        )
        #expect(encodedClear["taskId"] is NSNull)
        #expect(throws: IrohProtocolError.self) {
            try IrohMessageCodec.decode(message(operation: #"{"id":"selected-task-operation-peer0001","occurredAt":"1970-01-01T00:16:40Z","hlcWallMs":1000000,"hlcCounter":0}"#))
        }
        #expect(throws: IrohProtocolError.self) {
            try IrohMessageCodec.decode(message(operation: #"{"id":"selected-task-operation-peer0001","taskId":null,"occurredAt":"1970-01-01T00:16:40Z","hlcWallMs":1000000,"hlcCounter":0,"extra":true}"#))
        }
    }

    @Test func roomProjectionReducesSelectedTaskByHLCDeviceAndOperationAndSurvivesRestart() throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let first = try #require(FocusTask(title: "First selected task"))
        let second = try #require(FocusTask(title: "Second selected task"))
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [first, second],
                durationsMs: .defaults,
                autoStartBreaks: false,
                selectedTaskId: first.id.uuidString.lowercased(),
                hlcWallMs: 1_000_000,
                hlcCounter: 0
            )
        )
        let lowerDeviceLaterID = IrohOperationRecord(
            domain: .selectedTask,
            deviceId: "device-a0001",
            payload: .selectedTask(IrohSelectedTaskOperation(
                id: "selected-task-operation-z",
                taskId: nil,
                occurredAt: Date(timeIntervalSince1970: 1_001),
                hlcWallMs: 1_001_000,
                hlcCounter: 0
            ))
        )
        let higherDeviceEarlierID = IrohOperationRecord(
            domain: .selectedTask,
            deviceId: "device-z0001",
            payload: .selectedTask(IrohSelectedTaskOperation(
                id: "selected-task-operation-a",
                taskId: second.id.uuidString.lowercased(),
                occurredAt: Date(timeIntervalSince1970: 1_001),
                hlcWallMs: 1_001_000,
                hlcCounter: 0
            ))
        )
        let deletion = TaskOperation(
            id: "task-operation-delete-selected",
            taskId: second.id.uuidString.lowercased(),
            type: .delete,
            title: nil,
            occurredAt: Date(timeIntervalSince1970: 1_002),
            hlcWallMs: 1_002_000,
            hlcCounter: 0
        )

        let projected = try store.insertRemoteRecords([
            higherDeviceEarlierID,
            lowerDeviceLaterID,
            IrohOperationRecord(domain: .task, deviceId: "device-a0001", payload: .task(deletion)),
        ], roomID: roomID)

        #expect(projected.selectedTaskID == nil)
        #expect(!projected.tasks.contains(second))
        #expect(projected.knownTasks.contains(second))
        #expect(projected.hlcWallMs == 1_002_000)
        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.selectedTaskID == nil)
        #expect(restarted.activeRoomState?.knownTasks.contains(second) == true)
    }

    @Test func roomCaptureDurablyStoresSelectedTaskOperationsIncludingClear() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        let task = try #require(FocusTask(title: "Durable selection"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.knownTasks = [task]
        state = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: state,
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [task],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        state.pendingSelectedTaskOperations = [SelectedTaskOperation(
            id: try #require(UUID(uuidString: "01a0219e-0800-7006-8000-000000000006")),
            deviceId: state.deviceId,
            taskId: task.id.uuidString.lowercased(),
            occurredAt: Date(timeIntervalSince1970: 1_000),
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )]

        let selected = try store.captureLocalOperations(from: state)
        #expect(selected.selectedTaskID == task.id)
        #expect(selected.pendingSelectedTaskOperations.isEmpty)
        let records = try store.operations(
            roomID: roomID,
            references: [IrohInventoryReference(
                domain: .selectedTask,
                id: "01a0219e-0800-7006-8000-000000000006"
            )]
        )
        guard case .selectedTask(let captured) = records.first?.payload else {
            Issue.record("Expected captured selected-task operation")
            return
        }
        #expect(captured.taskId == task.id.uuidString.lowercased())
    }

    @Test @MainActor
    func appModelSelectionAndDeletionCaptureRestoreAcrossIrohRestart() throws {
        let suiteName = "PomodoroughTests.IrohSelectionRestart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        let store = temporaryStore()
        let task = try #require(FocusTask(title: "Restarted room selection"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [task],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )

        model.selectedTaskID = task.id
        #expect(model.selectedTaskID == task.id)
        #expect(store.activeRoomState?.selectedTaskID == task.id)
        #expect(store.activeRoomState?.pendingSelectedTaskOperations.isEmpty == true)

        let restarted = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )
        #expect(restarted.selectedTaskID == task.id)
        restarted.deleteTask(id: task.id)
        #expect(restarted.selectedTaskID == nil)
        #expect(restarted.tasks.isEmpty)
        #expect(store.activeRoomState?.selectedTaskID == nil)
        let selectedEntries = try store.inventory(roomID: roomID, after: nil, limit: 20).entries
            .filter { $0.domain == .selectedTask }
        #expect(selectedEntries.count == 2)
    }

    @Test @MainActor
    func irohSignOutClearsAccountWithoutDiscardingRoomOrLocalReturnSelection() throws {
        let suiteName = "PomodoroughTests.IrohAccountClear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        let store = temporaryStore()
        let returnTask = try #require(FocusTask(title: "Local return selection"))
        var returnState = PersistedTimerState.fresh()
        returnState.tasks = [returnTask]
        returnState.knownTasks = [returnTask]
        returnState.selectedTaskID = returnTask.id
        let roomTask = try #require(FocusTask(title: "Room selection"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: returnState,
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [],
                tasks: [roomTask],
                durationsMs: .defaults,
                autoStartBreaks: false,
                selectedTaskId: roomTask.id.uuidString.lowercased(),
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler()
        )

        model.signOut()

        #expect(model.replicationMode == .iroh)
        #expect(model.selectedTaskID == roomTask.id)
        #expect(model.tasks == [roomTask])
        #expect(store.activeRoomState?.cachedUser == nil)
        #expect(store.activeReturnState?.selectedTaskID == returnTask.id)
        #expect(store.activeReturnState?.tasks == [returnTask])
    }

    @Test func roomIDMatchesProtocolVector() throws {
        let secret = Data(0...31)
        #expect(try IrohProtocolV1.roomID(for: secret) == "Z_qLtnvZQsi-d2Giw1lvj7yy1x20hyE4jUgODkFsQBs")
    }

    @Test func inviteRejectsUnknownFieldsAndMalformedBase64() throws {
        let unknownFieldJSON = Data(#"{"v":1,"roomId":"Z_qLtnvZQsi-d2Giw1lvj7yy1x20hyE4jUgODkFsQBs","endpointTicket":"endpoint","roomSecret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","extra":true}"#.utf8) // gitleaks:allow -- deterministic public protocol vector
        let invite = IrohProtocolV1.invitePrefix + Base64URL.encode(unknownFieldJSON)

        #expect(throws: IrohProtocolError.self) { try IrohRoomInvite.decode(invite) }
        #expect(throws: IrohProtocolError.self) {
            try IrohRoomInvite.decode(IrohProtocolV1.invitePrefix + "not+base64")
        }
    }

    @Test func strictJSONRejectsInvalidUTF8AndDuplicateKeysRecursively() throws {
        #expect(throws: IrohProtocolError.self) {
            try StrictJSON.object(from: Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d]))
        }
        #expect(throws: IrohProtocolError.self) {
            try StrictJSON.object(from: Data(#"{"kind":"hello","kind":"inventory"}"#.utf8))
        }
        #expect(throws: IrohProtocolError.self) {
            try StrictJSON.object(from: Data(#"{"outer":{"key":1,"\u006bey":2}}"#.utf8))
        }
        #expect(throws: IrohProtocolError.self) {
            try StrictJSON.object(from: Data(#"{"é":1,"e\u0301":2}"#.utf8))
        }
    }

    @Test func authenticatedFrameRoundTripsAndRejectsTampering() throws {
        let secret = Data(0...31)
        let body = Data(#"{"kind":"hello"}"#.utf8)
        let frame = try IrohFrameCodec.encode(body: body, roomSecret: secret)

        #expect(try IrohFrameCodec.decode(frame, roomSecret: secret) == body)

        var tamperedBody = frame
        tamperedBody[tamperedBody.index(before: tamperedBody.endIndex)] ^= 1
        #expect(throws: IrohProtocolError.self) {
            try IrohFrameCodec.decode(tamperedBody, roomSecret: secret)
        }

        var tamperedMAC = frame
        tamperedMAC[4] ^= 1
        #expect(throws: IrohProtocolError.self) {
            try IrohFrameCodec.decode(tamperedMAC, roomSecret: secret)
        }
    }

    @Test func frameAndCanonicalDigestMatchCrossClientVectors() throws {
        let secret = Data(0...31)
        let frame = try IrohFrameCodec.encode(
            body: Data(#"{"kind":"hello"}"#.utf8),
            roomSecret: secret
        )
        #expect(frame.map { String(format: "%02x", $0) }.joined() ==
            "00000010d9f01510c6ce30066f8318494a013c47657387a9bc3bbb81625b3cd74569d8377b226b696e64223a2268656c6c6f227d")

        let recordJSON = Data(#"{"domain":"autoStart","deviceId":"device-test0001","operation":{"id":"auto-start-operation-peer0001","enabled":true,"occurredAt":"1970-01-01T00:16:40Z","hlcWallMs":1000000,"hlcCounter":0}}"#.utf8)
        let record = try JSONSerialization.jsonObject(with: recordJSON)
        let digest = Base64URL.encode(Data(SHA256.hash(
            data: try JSONCanonicalizer.encodeJSONObject(record)
        )))
        #expect(digest == "ViRTrF---kkCpXCRyxUvXbeZSas4Iyal_dtSbi4TTzE")
    }

    @Test func timerOperationUsesCentralizedProtocolBounds() {
        let command = validStartCommand(
            id: "command-fourhours",
            elapsed: -1,
            plannedDurationMs: 14_400_000
        )
        let record = IrohOperationRecord(
            domain: .timer,
            deviceId: "device-test0001",
            payload: .timer(command)
        )

        #expect(!command.isValid)
        #expect(record.isValid)
    }

    @Test func autoStartRecordUsesWrapperOriginOnly() throws {
        let operation = TestFixtures.autoStartOperation(
            deviceID: "device-test0001",
            enabled: true,
            wallMs: 1_000_000
        )
        let record = IrohOperationRecord(
            domain: .autoStart,
            deviceId: operation.deviceId,
            payload: .autoStart(IrohAutoStartOperation(operation))
        )

        let data = try JSONEncoder.api.encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedOperation = try #require(object["operation"] as? [String: Any])
        #expect(object["deviceId"] as? String == operation.deviceId)
        #expect(encodedOperation["deviceId"] == nil)
        #expect(try JSONDecoder.api.decode(IrohOperationRecord.self, from: data) == record)
    }

    @Test func autoStartRecordAcceptsNonUUIDProtocolIdentifier() throws {
        let operation = IrohAutoStartOperation(
            id: "auto-start-operation-peer0001",
            enabled: true,
            occurredAt: Date(timeIntervalSince1970: 1_000),
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )
        let record = IrohOperationRecord(
            domain: .autoStart,
            deviceId: "device-test0001",
            payload: .autoStart(operation)
        )

        #expect(record.isValid)
        #expect(try JSONDecoder.api.decode(
            IrohOperationRecord.self,
            from: JSONEncoder.api.encode(record)
        ) == record)
    }

    @Test func operationDigestPreservesPeerDateSpelling() throws {
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        let json = Data("""
        {"protocolVersion":1,"roomId":"\(roomID)","requestId":"\(requestID)","kind":"operationsResult","records":[{"domain":"autoStart","deviceId":"device-test0001","operation":{"id":"auto-start-operation-peer0001","enabled":true,"occurredAt":"1970-01-01T00:16:40Z","hlcWallMs":1000000,"hlcCounter":0}}]}
        """.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rawRecord = try #require((object["records"] as? [Any])?.first)
        let expectedDigest = Base64URL.encode(Data(SHA256.hash(
            data: try JSONCanonicalizer.encodeJSONObject(rawRecord)
        )))

        let decoded = try IrohMessageCodec.decode(json)
        guard case .operationsResult(let result) = decoded else {
            Issue.record("Expected operations result")
            return
        }
        #expect(try result.records[0].digest() == expectedDigest)

        let reencoded = try decoded.encoded()
        let reencodedObject = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let reencodedRecord = try #require((reencodedObject["records"] as? [[String: Any]])?.first)
        let operation = try #require(reencodedRecord["operation"] as? [String: Any])
        #expect(operation["occurredAt"] as? String == "1970-01-01T00:16:40Z")
    }

    @Test func inventoryMessagesEncodeRequiredNullCursors() throws {
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        let request = IrohRPCMessage.inventory(IrohInventoryRequest(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "inventory",
            after: nil,
            limit: 1_024
        ))
        let result = IrohRPCMessage.inventoryResult(IrohInventoryResult(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "inventoryResult",
            entries: [],
            next: nil
        ))

        let requestObject = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        let resultObject = try #require(JSONSerialization.jsonObject(with: result.encoded()) as? [String: Any])
        #expect(requestObject["after"] is NSNull)
        #expect(resultObject["next"] is NSNull)
        #expect(try IrohMessageCodec.decode(request.encoded()) == request)
        #expect(try IrohMessageCodec.decode(result.encoded()) == result)
    }

    @Test func helloAcceptsWindowsPeer() throws {
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        let hello = Data("""
        {"protocolVersion":1,"roomId":"\(roomID)","requestId":"\(requestID)","kind":"hello","deviceId":"device-windows01","endpointTicket":"endpoint-ticket","platform":"windows"}
        """.utf8)

        guard case .hello(let decoded) = try IrohMessageCodec.decode(hello) else {
            Issue.record("Expected hello")
            return
        }
        #expect(decoded.platform == "windows")
    }

    @Test func endpointBindsListensDialsNegotiatesALPNAndCloses() async throws {
        let server = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            alpns: [IrohProtocolV1.alpn],
            relayMode: RelayMode.disabled()
        ))
        let client = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            relayMode: RelayMode.disabled()
        ))
        let accepting = Task {
            let incoming = try #require(await server.acceptNext())
            let connection = try await incoming.accept().connect()
            #expect(connection.alpn() == IrohProtocolV1.alpn)
            let stream = try await connection.acceptBi()
            let body = try await stream.recv().readToEnd(sizeLimit: 64)
            try await stream.send().writeAll(buf: body)
            try await stream.send().finish()
            _ = await connection.closed()
        }

        let connection = try await client.connect(addr: server.addr(), alpn: IrohProtocolV1.alpn)
        #expect(connection.remoteId() == server.id())
        let stream = try await connection.openBi()
        try await stream.send().writeAll(buf: Data("pomodorough".utf8))
        try await stream.send().finish()
        #expect(try await stream.recv().readToEnd(sizeLimit: 64) == Data("pomodorough".utf8))
        try connection.close(errorCode: 0, reason: Data("test complete".utf8))
        try await accepting.value
        try await client.close()
        try await server.close()
        #expect(client.isClosed())
        #expect(server.isClosed())
    }

    #if os(macOS)
    @Test @MainActor
    func pythonPeerNegotiatesALPNAndDecodesSwiftFrame() async throws {
        let appleRepository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryURL = ProcessInfo.processInfo.environment["POMODOROUGH_IROH_PYTHON_REPO"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? appleRepository.deletingLastPathComponent().appending(path: "pomodorough-linux")
        let peerScript = repositoryURL.appending(path: "tests/iroh_interop_peer.py")
        guard FileManager.default.fileExists(atPath: peerScript.path) else { return }
        let ticketFile = FileManager.default.temporaryDirectory
            .appending(path: "pomodorough-iroh-interop-\(UUID().uuidString).ticket")
        let environment = ProcessInfo.processInfo.environment
        let uvCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "uv").path }
            + ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        guard let uvPath = environment["POMODOROUGH_UV"]
            ?? uvCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            Issue.record("uv is required for Swift-Python Iroh interoperability testing")
            return
        }
        let standardError = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = [
            "run", "--extra", "iroh", "python", peerScript.path,
            "--ticket-file", ticketFile.path
        ]
        process.currentDirectoryURL = repositoryURL
        process.standardError = standardError
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: ticketFile)
        }

        var ticketValue: String?
        for _ in 0..<300 {
            if let data = try? Data(contentsOf: ticketFile),
               let value = String(data: data, encoding: .utf8), !value.isEmpty {
                ticketValue = value
                break
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let ticketValue else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let errors = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errors, encoding: .utf8) ?? ""
            Issue.record("Python peer did not publish its endpoint ticket: \(errorText)")
            return
        }
        let ticket = try EndpointTicket.fromString(str: ticketValue)
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let client = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            relayMode: RelayMode.disabled()
        ))
        let clientTicket = try EndpointTicket.fromAddr(addr: client.addr()).description
        let connection = try await client.connect(
            addr: ticket.endpointAddr(),
            alpn: IrohProtocolV1.alpn
        )
        #expect(connection.alpn() == IrohProtocolV1.alpn)
        #expect(connection.remoteId() == ticket.endpointAddr().id())
        let stream = try await connection.openBi()
        let requestID = try IrohProtocolV1.makeRequestID()
        try await writeTestMessage(
            .hello(IrohHello(
                protocolVersion: IrohProtocolV1.version,
                roomId: roomID,
                requestId: requestID,
                kind: "hello",
                deviceId: "device-swift001",
                endpointTicket: clientTicket,
                platform: "macos",
                displayName: nil
            )),
            to: stream.send(),
            secret: secret
        )
        guard case .hello(let response) = try await readTestMessage(
            from: stream.recv(),
            secret: secret
        ) else {
            Issue.record("Expected Python hello")
            return
        }
        #expect(response.requestId == requestID)
        #expect(response.roomId == roomID)
        #expect(response.platform == "linux")
        #expect(response.deviceId == "device-python01")
        try connection.close(errorCode: 0, reason: Data("interop complete".utf8))
        try await client.close()

        for _ in 0..<100 where process.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "Python peer failed: \(errorText)")
    }
    #endif

    @Test func dialingServiceServesPeerRequestsAfterHello() async throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let service = IrohReplicationService(
            store: store,
            keyStore: StaticIrohEndpointKeyStore(),
            statusHandler: { _ in },
            projectionHandler: { _, _ in }
        )
        _ = try await service.start(IrohServiceContext(
            roomID: roomID,
            roomSecret: secret,
            deviceID: "device-client01",
            displayName: nil,
            platform: "ios"
        ))
        defer { Task { await service.stop() } }

        let peer = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            alpns: [IrohProtocolV1.alpn],
            relayMode: RelayMode.disabled()
        ))
        defer { Task { try? await peer.close() } }
        let peerTicket = try EndpointTicket.fromAddr(addr: peer.addr()).description
        let invite = try IrohRoomInvite(
            roomID: roomID,
            roomName: nil,
            endpointTicket: peerTicket,
            roomSecret: secret
        )

        let peerTask = Task { () -> Error? in
            do {
                let incoming = try #require(await peer.acceptNext())
                let connection = try await incoming.accept().connect()
                let helloStream = try await connection.acceptBi()
                let hello = try await readTestMessage(from: helloStream.recv(), secret: secret)
                guard case .hello(let request) = hello else {
                    Issue.record("Expected hello")
                    return nil
                }
                try await writeTestMessage(
                    .hello(IrohHello(
                        protocolVersion: IrohProtocolV1.version,
                        roomId: roomID,
                        requestId: request.requestId,
                        kind: "hello",
                        deviceId: "device-peer0001",
                        endpointTicket: peerTicket,
                        platform: "linux",
                        displayName: nil
                    )),
                    to: helloStream.send(),
                    secret: secret
                )

                let clientRequestStream = try await connection.acceptBi()
                let clientRequest = try await readTestMessage(from: clientRequestStream.recv(), secret: secret)
                guard case .inventory(let inventoryRequest) = clientRequest else {
                    Issue.record("Expected client inventory request")
                    return nil
                }

                let reverseRequestID = try IrohProtocolV1.makeRequestID()
                let reverseStream = try await connection.openBi()
                try await writeTestMessage(
                    .inventory(IrohInventoryRequest(
                        protocolVersion: IrohProtocolV1.version,
                        roomId: roomID,
                        requestId: reverseRequestID,
                        kind: "inventory",
                        after: nil,
                        limit: IrohProtocolV1.maxInventoryEntries
                    )),
                    to: reverseStream.send(),
                    secret: secret
                )
                let reverseResponse = try await readTestMessage(from: reverseStream.recv(), secret: secret)
                guard case .inventoryResult(let inventory) = reverseResponse else {
                    Issue.record("Expected reverse inventory response")
                    return nil
                }
                #expect(inventory.requestId == reverseRequestID)
                #expect(inventory.entries.contains { $0.domain == .genesis && $0.id == "genesis" })

                try await writeTestMessage(
                    .inventoryResult(IrohInventoryResult(
                        protocolVersion: IrohProtocolV1.version,
                        roomId: roomID,
                        requestId: inventoryRequest.requestId,
                        kind: "inventoryResult",
                        entries: [],
                        next: nil
                    )),
                    to: clientRequestStream.send(),
                    secret: secret
                )
                _ = await connection.closed()
                return nil
            } catch {
                return error
            }
        }

        do {
            try await service.join(invite: invite)
        } catch {
            Issue.record("Service join failed: \(error)")
        }
        if let error = await peerTask.value {
            Issue.record("Peer RPC failed: \(error)")
        }
        await service.stop()
        try? await peer.close()
    }

    @Test func roomStoreIsIdempotentAndPersistsImmutableConflict() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        let genesis = emptyGenesis()
        let local = PersistedTimerState.fresh()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: "Test room",
            returnState: local,
            genesis: genesis,
            now: TestFixtures.anchor
        )
        let firstCommand = validStartCommand(id: "command-test0001", elapsed: 0)
        let first = IrohOperationRecord(
            domain: .timer,
            deviceId: "device-test0001",
            payload: .timer(firstCommand)
        )

        _ = try store.insertRemoteRecords([first], roomID: roomID)
        _ = try store.insertRemoteRecords([first], roomID: roomID)

        #expect(store.activeSnapshot?.operationCount == 2)
        let conflicting = IrohOperationRecord(
            domain: .timer,
            deviceId: "device-test0001",
            payload: .timer(validStartCommand(id: firstCommand.id, elapsed: 1))
        )
        #expect(throws: IrohProtocolError.self) {
            try store.insertRemoteRecords([conflicting], roomID: roomID)
        }
        let conflict = try #require(store.activeSnapshot?.conflict)
        #expect(conflict.domain == .timer)
        #expect(conflict.id == firstCommand.id)
        #expect(conflict.localDigest != conflict.receivedDigest)
        #expect(store.activeSnapshot?.operationCount == 2)
    }

    @Test func failedJoinCleanupPreservesImmutableConflictEvidence() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        try store.prepareJoinedRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            initialPeer: IrohPeer(
                endpointID: "endpoint-test0001",
                endpointTicket: "endpoint-ticket-test0001",
                deviceID: nil,
                displayName: nil,
                lastSeenAt: nil
            )
        )
        let first = IrohOperationRecord(
            domain: .timer,
            deviceId: "device-test0001",
            payload: .timer(validStartCommand(id: "command-conflict01", elapsed: 0))
        )
        let conflicting = IrohOperationRecord(
            domain: .timer,
            deviceId: "device-test0001",
            payload: .timer(validStartCommand(id: "command-conflict01", elapsed: 1))
        )
        _ = try store.insertRemoteRecords([first], roomID: roomID)
        #expect(throws: IrohProtocolError.self) {
            try store.insertRemoteRecords([conflicting], roomID: roomID)
        }

        try store.discardUnconflictedInactiveRoom(roomID: roomID)

        let conflicted = try #require(store.roomSnapshot(roomID: roomID))
        #expect(conflicted.conflict?.id == first.id)
        #expect(conflicted.operationCount == 1)

        let cleanSecret = Data(repeating: 42, count: 32)
        let cleanRoomID = try IrohProtocolV1.roomID(for: cleanSecret)
        try store.prepareJoinedRoom(
            roomID: cleanRoomID,
            roomSecret: cleanSecret,
            name: nil,
            returnState: .fresh(),
            initialPeer: IrohPeer(
                endpointID: "endpoint-test0002",
                endpointTicket: "endpoint-ticket-test0002",
                deviceID: nil,
                displayName: nil,
                lastSeenAt: nil
            )
        )
        try store.discardUnconflictedInactiveRoom(roomID: cleanRoomID)
        #expect(store.roomSnapshot(roomID: cleanRoomID) == nil)
    }

    @Test func roomSwitchRestoresIndependentWorkspaceWithoutDrainingCentralQueue() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        var local = PersistedTimerState.fresh()
        let pending = validStartCommand(id: "command-central0001", elapsed: 0)
        local.pendingCommands = [pending]
        local.localCommandDates = [pending.id: pending.occurredAt]
        let genesis = IrohGenesis(
            canonicalTimer: nil,
            history: [],
            tasks: [],
            durationsMs: .defaults,
            autoStartBreaks: false,
            hlcWallMs: 0,
            hlcCounter: 0
        )

        let roomState = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: local,
            genesis: genesis
        )
        #expect(roomState.pendingCommands.isEmpty)

        let restored = try store.captureAndSuspendActiveRoom(from: roomState)
        #expect(restored.pendingCommands == [pending])
        #expect(restored.localCommandDates == [pending.id: pending.occurredAt])
    }

    @Test func roomSuspensionAtomicallyCapturesPendingLocalMutation() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        var returnState = PersistedTimerState.fresh()
        let central = validStartCommand(id: "command-central-return", elapsed: 0)
        returnState.pendingCommands = [central]
        let roomState = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: returnState,
            genesis: emptyGenesis()
        )
        var mutatedRoomState = roomState
        let local = validStartCommand(
            id: "command-room-pending",
            timerID: "timer-room-pending"
        )
        mutatedRoomState.pendingCommands = [local]
        mutatedRoomState.localCommandDates[local.id] = local.occurredAt

        let restored = try store.captureAndSuspendActiveRoom(from: mutatedRoomState)

        #expect(restored.pendingCommands == [central])
        #expect(store.activeRoomID == nil)
        let roomRecords = try store.operations(
            roomID: roomID,
            references: [IrohInventoryReference(domain: .timer, id: local.id)]
        )
        #expect(roomRecords.count == 1)
        #expect(roomRecords[0].id == local.id)
        #expect(store.roomSnapshot(roomID: roomID)?.operationCount == 2)
    }

    @Test func roomProjectionUsesHLCDeviceAndIDInsteadOfDeviceSequence() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let laterSequenceEarlierClock = validStartCommand(
            id: "command-earlier1",
            sequence: 99,
            timerID: "timer-earlier001",
            wallMs: 1_000_000
        )
        let earlierSequenceLaterClock = validStartCommand(
            id: "command-later001",
            sequence: 1,
            timerID: "timer-later0001",
            wallMs: 1_000_001
        )
        let projected = try store.insertRemoteRecords([
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-z0001",
                payload: .timer(laterSequenceEarlierClock)
            ),
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-a0001",
                payload: .timer(earlierSequenceLaterClock)
            ),
        ], roomID: roomID)

        #expect(projected.canonicalTimer?.id == earlierSequenceLaterClock.timerId)
        let projectedLastIntentDeviceID = projected.canonicalTimer?.lastIntent?.deviceId
        #expect(projectedLastIntentDeviceID == "device-a0001")
    }

    @Test func roomProjectionPersistsStartAndFinish() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let start = validStartCommand(id: "command-start001", sequence: 1)
        let finish = TimerCommand(
            id: "command-finish01",
            deviceSequence: 2,
            timerId: start.timerId,
            taskId: nil,
            type: .finish,
            phase: .focus,
            plannedDurationMs: start.plannedDurationMs,
            occurredAt: Date(timeIntervalSince1970: 1_001),
            hlcWallMs: 1_001_000,
            hlcCounter: 0,
            observedElapsedMs: start.plannedDurationMs
        )

        let projected = try store.insertRemoteRecords([
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(start)),
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(finish)),
        ], roomID: roomID)

        #expect(projected.canonicalTimer?.status == .completed)
        #expect(projected.history.first?.completedAt == finish.occurredAt)
        #expect(projected.history.first?.endedAt == finish.occurredAt)
    }

    @Test(arguments: [CommandType.cancel, .finish])
    func roomCreationDoesNotRestoreClearedTerminalHistoryAfterRestart(
        _ terminalType: CommandType
    ) throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let endedAt = Date(timeIntervalSince1970: 1_001)
        let timerID = "timer-genesis-cleared-\(terminalType.rawValue)"
        let terminalCommandID = "command-genesis-terminal-\(terminalType.rawValue)"
        let history = HistoryItem(
            id: "history-genesis-cleared-\(terminalType.rawValue)",
            timerId: timerID,
            commandId: terminalCommandID,
            taskId: nil,
            phase: .focus,
            status: terminalType == .finish ? "completed" : "cancelled",
            plannedDurationMs: 60_000,
            completedAt: terminalType == .finish ? endedAt : nil,
            endedAt: endedAt
        )
        let genesis = IrohGenesis(
            canonicalTimer: nil,
            history: [history],
            tasks: [],
            durationsMs: .defaults,
            autoStartBreaks: false,
            hlcWallMs: 0,
            hlcCounter: 0
        )
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)

        let projected = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: genesis
        )

        #expect(projected.canonicalTimer == nil)
        #expect(projected.history == [history])

        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.canonicalTimer == nil)
        #expect(restarted.activeRoomState?.history == [history])
    }

    @Test(arguments: [CommandType.cancel, .finish])
    func roomCreationRetainsExplicitTerminalGenesisAfterRestart(
        _ terminalType: CommandType
    ) throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let endedAt = Date(timeIntervalSince1970: 1_001)
        let timerID = "timer-genesis-terminal-\(terminalType.rawValue)"
        let terminalCommandID = "command-genesis-terminal-\(terminalType.rawValue)"
        let status: CanonicalTimer.Status = terminalType == .finish ? .completed : .cancelled
        let terminal = CanonicalTimer(
            id: timerID,
            taskId: nil,
            phase: .focus,
            status: status,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: terminalType == .finish ? 60_000 : 10_000,
            anchorAt: endedAt,
            startedByDeviceId: "device-test0001",
            lastIntent: TimerIntent(
                type: terminalType,
                commandId: terminalCommandID,
                occurredAt: endedAt,
                deviceId: nil
            )
        )
        let history = HistoryItem(
            id: "history-genesis-terminal-\(terminalType.rawValue)",
            timerId: timerID,
            commandId: terminalCommandID,
            taskId: nil,
            phase: .focus,
            status: status.rawValue,
            plannedDurationMs: 60_000,
            completedAt: terminalType == .finish ? endedAt : nil,
            endedAt: endedAt
        )
        let genesis = IrohGenesis(
            canonicalTimer: terminal,
            history: [history],
            tasks: [],
            durationsMs: .defaults,
            autoStartBreaks: false,
            hlcWallMs: 0,
            hlcCounter: 0
        )
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)

        let projected = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: genesis
        )

        #expect(projected.canonicalTimer == terminal)
        #expect(projected.history == [history])

        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.canonicalTimer == terminal)
        #expect(restarted.activeRoomState?.history == [history])
    }

    @Test(arguments: [CommandType.cancel, .finish])
    func roomProjectionDoesNotRestoreFinalClearedTerminalTimerAfterRestart(
        _ terminalType: CommandType
    ) throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let timerID = "timer-cleared-\(terminalType.rawValue)"
        let start = validStartCommand(
            id: "command-start-\(terminalType.rawValue)",
            sequence: 1,
            timerID: timerID
        )
        let terminalElapsedMs: Int64 = terminalType == .finish ? 60_000 : 10_000
        let terminal = TimerCommand(
            id: "command-terminal-\(terminalType.rawValue)",
            deviceSequence: 2,
            timerId: timerID,
            taskId: nil,
            type: terminalType,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: Date(timeIntervalSince1970: 1_001),
            hlcWallMs: 1_001_000,
            hlcCounter: 0,
            observedElapsedMs: terminalElapsedMs
        )
        let clear = TimerCommand(
            id: "command-clear-\(terminalType.rawValue)",
            deviceSequence: 3,
            timerId: timerID,
            taskId: nil,
            type: .clear,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: Date(timeIntervalSince1970: 1_002),
            hlcWallMs: 1_002_000,
            hlcCounter: 0,
            observedElapsedMs: terminalElapsedMs
        )

        let projected = try store.insertRemoteRecords([
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(start)),
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(terminal)),
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(clear)),
        ], roomID: roomID)

        #expect(projected.canonicalTimer == nil)
        #expect(projected.history.count == 1)
        #expect(projected.history.first?.commandId == terminal.id)
        #expect(projected.history.first?.status == (terminalType == .finish ? "completed" : "cancelled"))

        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.canonicalTimer == nil)
        #expect(restarted.activeRoomState?.history == projected.history)
    }

    @Test(arguments: [false, true])
    func roomProjectionUsesLastAppliedTimerCommandUnderClockSkew(
        _ clearsNewestTimer: Bool
    ) throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore(now: { Date(timeIntervalSince1970: 1_300) })
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let olderStart = validStartCommand(
            id: "command-skew-start-older",
            sequence: 1,
            timerID: "timer-skew-older",
            wallMs: 1_000_000
        )
        let olderFinish = TimerCommand(
            id: "command-skew-finish-older",
            deviceSequence: 2,
            timerId: olderStart.timerId,
            taskId: nil,
            type: .finish,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: Date(timeIntervalSince1970: 1_250),
            hlcWallMs: 1_001_000,
            hlcCounter: 0,
            observedElapsedMs: 60_000
        )
        let newestStart = validStartCommand(
            id: "command-skew-start-newest",
            sequence: 3,
            timerID: "timer-skew-newest",
            wallMs: 1_002_000
        )
        let newestFinish = TimerCommand(
            id: "command-skew-finish-newest",
            deviceSequence: 4,
            timerId: newestStart.timerId,
            taskId: nil,
            type: .finish,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: Date(timeIntervalSince1970: 1_003),
            hlcWallMs: 1_003_000,
            hlcCounter: 0,
            observedElapsedMs: 60_000
        )
        let clear = TimerCommand(
            id: "command-skew-clear-newest",
            deviceSequence: 5,
            timerId: newestStart.timerId,
            taskId: nil,
            type: .clear,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: Date(timeIntervalSince1970: 1_004),
            hlcWallMs: 1_004_000,
            hlcCounter: 0,
            observedElapsedMs: 60_000
        )
        var records = [olderStart, olderFinish, newestStart, newestFinish].map {
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer($0))
        }
        if clearsNewestTimer {
            records.append(
                IrohOperationRecord(
                    domain: .timer,
                    deviceId: "device-test0001",
                    payload: .timer(clear)
                )
            )
        }

        let projected = try store.insertRemoteRecords(records, roomID: roomID)

        if clearsNewestTimer {
            #expect(projected.canonicalTimer == nil)
        } else {
            #expect(projected.canonicalTimer?.id == newestStart.timerId)
            #expect(projected.canonicalTimer?.lastIntent?.commandId == newestFinish.id)
        }
    }

    @Test(arguments: [CommandType.cancel, .finish])
    func roomProjectionRetainsNonClearedTerminalTimerAfterRestart(
        _ terminalType: CommandType
    ) throws {
        let url = temporaryURL()
        let secretStore = MemoryIrohRoomSecretStore()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let timerID = "timer-terminal-\(terminalType.rawValue)"
        let start = validStartCommand(
            id: "command-start-only-\(terminalType.rawValue)",
            sequence: 1,
            timerID: timerID
        )
        let terminal = TimerCommand(
            id: "command-terminal-only-\(terminalType.rawValue)",
            deviceSequence: 2,
            timerId: timerID,
            taskId: nil,
            type: terminalType,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: Date(timeIntervalSince1970: 1_001),
            hlcWallMs: 1_001_000,
            hlcCounter: 0,
            observedElapsedMs: terminalType == .finish ? 60_000 : 10_000
        )

        let projected = try store.insertRemoteRecords([
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(start)),
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(terminal)),
        ], roomID: roomID)
        let expectedStatus: CanonicalTimer.Status = terminalType == .finish ? .completed : .cancelled

        #expect(projected.canonicalTimer?.id == timerID)
        #expect(projected.canonicalTimer?.status == expectedStatus)
        #expect(projected.canonicalTimer?.lastIntent?.commandId == terminal.id)
        #expect(projected.history.first?.commandId == terminal.id)

        let restarted = IrohRoomStore(fileURL: url, secretStore: secretStore)
        #expect(restarted.activeRoomState?.canonicalTimer == projected.canonicalTimer)
        #expect(restarted.activeRoomState?.history == projected.history)
    }

    @Test @MainActor
    func incomingPeerFirstFocusCompletionAdvancesDefaultSelectionToShortBreak() throws {
        let fixture = try incomingPeerCompletionFixture(
            phase: .focus,
            priorCompletedFocusCount: 0,
            selectedPhase: .focus,
            hasExplicitPhaseSelection: false
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        #expect(fixture.model.canonicalTimer?.status == .completed)
        #expect(fixture.model.selectedPhase == .shortBreak)
    }

    @Test @MainActor
    func incomingPeerFourthFocusCompletionAdvancesDefaultSelectionToLongBreak() throws {
        let fixture = try incomingPeerCompletionFixture(
            phase: .focus,
            priorCompletedFocusCount: 3,
            selectedPhase: .focus,
            hasExplicitPhaseSelection: false
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        #expect(fixture.model.canonicalTimer?.status == .completed)
        #expect(fixture.model.selectedPhase == .longBreak)
    }

    @Test @MainActor
    func incomingPeerBreakCompletionAdvancesDefaultSelectionToFocus() throws {
        let fixture = try incomingPeerCompletionFixture(
            phase: .shortBreak,
            priorCompletedFocusCount: 1,
            selectedPhase: .shortBreak,
            hasExplicitPhaseSelection: false
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        #expect(fixture.model.canonicalTimer?.status == .completed)
        #expect(fixture.model.selectedPhase == .focus)
    }

    @Test @MainActor
    func incomingPeerCompletionPreservesExplicitPhaseSelection() throws {
        let fixture = try incomingPeerCompletionFixture(
            phase: .focus,
            priorCompletedFocusCount: 0,
            selectedPhase: .longBreak,
            hasExplicitPhaseSelection: true
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        #expect(fixture.model.canonicalTimer?.status == .completed)
        #expect(fixture.model.selectedPhase == .longBreak)
    }

    @Test @MainActor
    func irohDeadlineProjectsCompletionAndAtomicallyStartsOwnedBreak() async throws {
        let suiteName = "PomodoroughTests.IrohDeadline.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        let state = PersistedTimerState.fresh()
        let deadline = TestFixtures.anchor.addingTimeInterval(60)
        var currentDate = TestFixtures.anchor.addingTimeInterval(30)
        var currentUptime: TimeInterval = 100
        let timer = CanonicalTimer(
            id: "timer-iroh-owned",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            startedByDeviceId: state.deviceId,
            lastIntent: TimerIntent(
                type: .start,
                commandId: "command-iroh-owned-start",
                occurredAt: TestFixtures.anchor,
                deviceId: state.deviceId
            )
        )
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore(now: { currentDate })
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: state,
            genesis: IrohGenesis(
                canonicalTimer: timer,
                history: [],
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: true,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let scheduler = RecordingAlarmScheduler()
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: scheduler,
            now: { currentDate },
            uptime: { currentUptime }
        )

        model.selectPhase(.longBreak)
        currentDate = deadline
        currentUptime = 130
        model.completeIfNeeded(timerID: timer.id, at: deadline)
        await model.waitForAlarmOperations()

        let inventory = try store.inventory(roomID: roomID, after: nil, limit: 10).entries
        let timerReferences = inventory.filter { $0.domain == .timer }.map(\.reference)
        let records = try store.operations(roomID: roomID, references: timerReferences)
        #expect(records.count == 1)
        guard case .timer(let breakStart) = records.first?.payload else {
            Issue.record("Expected one break start record")
            return
        }
        #expect(breakStart.type == .start)
        #expect(breakStart.phase == .shortBreak)
        #expect(model.selectedPhase == .longBreak)
        #expect(model.canonicalTimer?.id == breakStart.timerId)
        #expect(model.canonicalTimer?.status == .running)
        #expect(model.history.first?.timerId == timer.id)
        #expect(model.history.first?.commandId == nil)
        #expect(scheduler.operations.contains {
            if case .schedule(let timerID, let phase, _) = $0 {
                return timerID == breakStart.timerId && phase == .shortBreak
            }
            return false
        })
    }

    @Test @MainActor
    func irohDeadlineWithoutAutoBreakCreatesNoSharedTimerRecord() throws {
        let suiteName = "PomodoroughTests.IrohLocalDeadline.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        let state = PersistedTimerState.fresh()
        let deadline = TestFixtures.anchor.addingTimeInterval(60)
        let timer = CanonicalTimer(
            id: "timer-iroh-local",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: TestFixtures.anchor,
            startedByDeviceId: state.deviceId,
            lastIntent: nil
        )
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: state,
            genesis: IrohGenesis(
                canonicalTimer: timer,
                history: [],
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { deadline },
            uptime: { 100 }
        )

        model.completeIfNeeded(timerID: timer.id, at: deadline)

        #expect(model.canonicalTimer?.status == .completed)
        #expect(model.history.first?.timerId == timer.id)
        #expect(try store.inventory(roomID: roomID, after: nil, limit: 10).entries.allSatisfy {
            $0.domain != .timer
        })
    }

    @Test func roomProjectionAcceptsFourHourTimerOperation() throws {
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )
        let start = validStartCommand(
            id: "command-fourhours",
            plannedDurationMs: 14_400_000
        )

        let projected = try store.insertRemoteRecords([
            IrohOperationRecord(domain: .timer, deviceId: "device-test0001", payload: .timer(start)),
        ], roomID: roomID)

        #expect(projected.canonicalTimer?.plannedDurationMs == 14_400_000)
    }

    @Test func roomProjectionUsesServerTaskAndHistoryOrdering() throws {
        let earlier = TestFixtures.anchor
        let later = earlier.addingTimeInterval(60)
        let zTask = try #require(FocusTask(title: "zeta"))
        let accentedTask = try #require(FocusTask(title: "éclair"))
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        let projected = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: IrohGenesis(
                canonicalTimer: nil,
                history: [
                    HistoryItem(
                        id: "history-later-z",
                        timerId: "timer-z-later",
                        commandId: nil,
                        taskId: nil,
                        phase: .focus,
                        status: CanonicalTimer.Status.completed.rawValue,
                        plannedDurationMs: 60_000,
                        completedAt: later,
                        endedAt: later
                    ),
                    HistoryItem(
                        id: "history-earlier",
                        timerId: "timer-earlier",
                        commandId: nil,
                        taskId: nil,
                        phase: .focus,
                        status: CanonicalTimer.Status.completed.rawValue,
                        plannedDurationMs: 60_000,
                        completedAt: earlier,
                        endedAt: earlier
                    ),
                    HistoryItem(
                        id: "history-later-a",
                        timerId: "timer-a-later",
                        commandId: nil,
                        taskId: nil,
                        phase: .focus,
                        status: CanonicalTimer.Status.completed.rawValue,
                        plannedDurationMs: 60_000,
                        completedAt: later,
                        endedAt: later
                    ),
                ],
                tasks: [accentedTask, zTask],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )

        #expect(projected.tasks == [zTask, accentedTask])
        #expect(projected.history.map(\.timerId) == [
            "timer-a-later", "timer-z-later", "timer-earlier",
        ])
    }

    @Test func failedRoomPersistenceRollsBackInMemoryState() throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughIrohParent-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let store = IrohRoomStore(
            fileURL: parentFile.appendingPathComponent("rooms.json"),
            secretStore: MemoryIrohRoomSecretStore()
        )
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)

        #expect(throws: Error.self) {
            try store.createRoom(
                roomID: roomID,
                roomSecret: secret,
                name: nil,
                returnState: .fresh(),
                genesis: emptyGenesis()
            )
        }
        #expect(store.activeRoomID == nil)
        #expect(store.roomSnapshot(roomID: roomID) == nil)
    }

    @Test func roomSecretPersistsOnlyInKeychainAndLegacyJSONMigrates() throws {
        let url = temporaryURL()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let secretStore = MemoryIrohRoomSecretStore()
        let store = IrohRoomStore(fileURL: url, secretStore: secretStore)
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rooms = try #require(object["rooms"] as? [[String: Any]])
        #expect(rooms[0]["roomSecret"] == nil)
        #expect(try secretStore.load(roomID: roomID) == secret)

        rooms[0]["roomSecret"] = secret.base64EncodedString()
        object["rooms"] = rooms
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        let migrationStore = MemoryIrohRoomSecretStore()
        let migrated = IrohRoomStore(fileURL: url, secretStore: migrationStore)

        #expect(migrated.activeRoomSecret == secret)
        #expect(try migrationStore.load(roomID: roomID) == secret)
        let migratedObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let migratedRooms = try #require(migratedObject["rooms"] as? [[String: Any]])
        #expect(migratedRooms[0]["roomSecret"] == nil)
    }

    @Test func roomStoreFailsClosedWhenKeychainSecretIsMissing() throws {
        let url = temporaryURL()
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = IrohRoomStore(fileURL: url, secretStore: MemoryIrohRoomSecretStore())
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: .fresh(),
            genesis: emptyGenesis()
        )

        let unavailable = IrohRoomStore(fileURL: url, secretStore: MemoryIrohRoomSecretStore())

        #expect(unavailable.activeRoomID == nil)
        #expect(unavailable.activeRoomSecret == nil)
        #expect(throws: IrohProtocolError.self) {
            try unavailable.createRoom(
                roomID: try IrohProtocolV1.roomID(for: Data(repeating: 42, count: 32)),
                roomSecret: Data(repeating: 42, count: 32),
                name: nil,
                returnState: .fresh(),
                genesis: emptyGenesis()
            )
        }
    }

    @Test func endpointLifecycleInvalidatesSuspendedOwnerAndAllocatesNewGeneration() {
        var lifecycle = IrohEndpointLifecycle()
        let first = lifecycle.setActive(true)
        #expect(lifecycle.owns(first))

        let stopped = lifecycle.setActive(false)
        #expect(stopped != first)
        #expect(!lifecycle.owns(first))

        let second = lifecycle.setActive(true)
        #expect(second != first)
        #expect(lifecycle.owns(second))
    }

    @Test func retryJitterNeverExceedsProtocolCap() {
        #expect(IrohReplicationService.retryDelaySeconds(base: 2, jitterUnit: 0) == 2)
        #expect(IrohReplicationService.retryDelaySeconds(base: 30, jitterUnit: 1) == 36)
        #expect(IrohReplicationService.retryDelaySeconds(base: 60, jitterUnit: 1) == 60)
        #expect(IrohReplicationService.retryDelaySeconds(base: 120, jitterUnit: 1) == 60)
    }

    private struct IncomingPeerCompletionFixture {
        let model: AppModel
        let defaults: UserDefaults
        let suiteName: String
    }

    @MainActor
    private func incomingPeerCompletionFixture(
        phase: TimerPhase,
        priorCompletedFocusCount: Int,
        selectedPhase: TimerPhase,
        hasExplicitPhaseSelection: Bool
    ) throws -> IncomingPeerCompletionFixture {
        let suiteName = "PomodoroughTests.IrohPeerCompletion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        var state = PersistedTimerState.fresh()
        state.settings.selectedPhase = selectedPhase
        state.hasExplicitPhaseSelection = hasExplicitPhaseSelection
        let timerID = "timer-peer-completion"
        let timer = TestFixtures.timer(
            status: .running,
            elapsed: 0,
            phase: phase,
            timerID: timerID
        )
        let priorHistory = (0..<priorCompletedFocusCount).map { index in
            TestFixtures.history(
                id: "peer-prior-focus-\(index)",
                durationMs: 60_000,
                date: TestFixtures.anchor.addingTimeInterval(-Double(index + 1))
            )
        }
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let store = temporaryStore()
        _ = try store.createRoom(
            roomID: roomID,
            roomSecret: secret,
            name: nil,
            returnState: state,
            genesis: IrohGenesis(
                canonicalTimer: timer,
                history: priorHistory,
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            )
        )
        let finish = TimerCommand(
            id: "command-peer-finish",
            deviceSequence: 1,
            timerId: timerID,
            taskId: nil,
            type: .finish,
            phase: phase,
            plannedDurationMs: 60_000,
            occurredAt: TestFixtures.anchor.addingTimeInterval(60),
            hlcWallMs: 1_060_000,
            hlcCounter: 0,
            observedElapsedMs: 60_000
        )
        _ = try store.insertRemoteRecords([
            IrohOperationRecord(
                domain: .timer,
                deviceId: "device-peer0001",
                payload: .timer(finish)
            )
        ], roomID: roomID)
        let model = AppModel(
            defaults: defaults,
            roomStore: store,
            alarmScheduler: RecordingAlarmScheduler(),
            now: { TestFixtures.anchor.addingTimeInterval(60) },
            uptime: { 100 }
        )
        return IncomingPeerCompletionFixture(
            model: model,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func temporaryURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PomodoroughTests", isDirectory: true)
            .appendingPathComponent("Iroh-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rooms.json")
    }

    private func temporaryStore(now: @escaping () -> Date = { .now }) -> IrohRoomStore {
        IrohRoomStore(
            fileURL: temporaryURL(),
            secretStore: MemoryIrohRoomSecretStore(),
            now: now
        )
    }

    private func emptyGenesis() -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: nil,
            history: [],
            tasks: [],
            durationsMs: .defaults,
            autoStartBreaks: false,
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private func validStartCommand(
        id: String,
        sequence: Int64 = 1,
        timerID: String = "timer-test0001",
        elapsed: Int64 = 0,
        wallMs: Int64 = 1_000_000,
        plannedDurationMs: Int64 = 60_000
    ) -> TimerCommand {
        TimerCommand(
            id: id,
            deviceSequence: sequence,
            timerId: timerID,
            taskId: nil,
            type: .start,
            phase: .focus,
            plannedDurationMs: plannedDurationMs,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1_000),
            hlcWallMs: wallMs,
            hlcCounter: 0,
            observedElapsedMs: elapsed
        )
    }

    private func readTestMessage(from stream: RecvStream, secret: Data) async throws -> IrohRPCMessage {
        let header = try await stream.readExact(size: 36)
        let length = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = try await stream.readExact(size: length)
        var frame = header
        frame.append(body)
        return try IrohMessageCodec.decode(IrohFrameCodec.decode(frame, roomSecret: secret))
    }

    private func writeTestMessage(
        _ message: IrohRPCMessage,
        to stream: SendStream,
        secret: Data
    ) async throws {
        try await stream.writeAll(buf: IrohFrameCodec.encode(body: try message.encoded(), roomSecret: secret))
        try await stream.finish()
    }
}

private struct StaticIrohEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { Data(repeating: 7, count: 32) }
    func save(_ secret: Data) throws {}
}
