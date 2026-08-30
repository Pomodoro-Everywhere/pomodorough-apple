import Foundation
import IrohLib
import Testing
@testable import Pomodorough

@Suite("Retained room rejoin")
struct RetainedRoomRejoinTests {
    @Test(arguments: [false, true])
    func rejoinPreservesRoomAndReturnsCurrentLocalWorkspace(restart: Bool) throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let original = try fixture.workspace(fixture.roomA)
        let other = try fixture.workspace(fixture.roomB)
        #expect(fixture.store.preferredRoomID == fixture.roomB)
        var local = fixture.local
        local.pendingCommands = [fixture.command(id: "local-pending001", sequence: 7)]
        local.nextSequence = 8
        local.selectedPhaseGeneration = 12
        local.settings.selectedPhase = .longBreak
        let preparation = try fixture.prepare(returnState: local)
        #expect(!preparation.alreadyActive)
        let prepared = try fixture.workspace(fixture.roomA)
        #expect(prepared.records == original.records)
        #expect(prepared.roomState == original.roomState)
        #expect(prepared.returnState == original.returnState)
        #expect(prepared.createdAt == original.createdAt)
        #expect(prepared.roomName == original.roomName)
        #expect(prepared.peers.first?.endpointTicket == "ticket-refreshed01")
        #expect(prepared.peers.first?.deviceID == "peer-device0001")
        if restart { fixture.restart() }
        let joined = try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: local)
        #expect(joined.history == original.roomState.history)
        #expect(joined.tasks == original.roomState.tasks)
        #expect(joined.deviceId == original.roomState.deviceId)
        #expect(joined.nextSequence == original.roomState.nextSequence)
        #expect(joined.pendingCommands.isEmpty)
        fixture.restart()
        #expect(fixture.store.activeRoomID == fixture.roomA)
        #expect(try fixture.workspace(fixture.roomA).records == original.records)
        #expect(try fixture.workspace(fixture.roomB) == other)
        #expect(fixture.store.activeReturnState == local)
        #expect(try fixture.store.captureAndSuspendActiveRoom(from: joined) == local)
        fixture.restart()
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.store.roomIDs == [fixture.roomA, fixture.roomB].sorted())
    }

    @Test func alreadyActiveCallsDoNotReplaceReturnWorkspaceOrWrite() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        _ = try fixture.prepare()
        let joined = try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: fixture.local)
        let before = try Data(contentsOf: fixture.fileURL)
        let writes = fixture.vault.saves
        let preparation = try fixture.prepare(returnState: joined)
        #expect(preparation.alreadyActive)
        #expect(try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: joined) == joined)
        #expect(try fixture.store.activateExistingRoom(roomID: fixture.roomA, returnState: joined) == joined)
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.saves == writes)
        #expect(try fixture.store.captureAndSuspendActiveRoom(from: joined) == fixture.local)
    }

    @Test func failedResumeRestoresExactWorkspaceAndKeepsSecret() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        let preparation = try fixture.prepare()
        try fixture.store.insertRemoteRecords([fixture.record(id: "remote-rejoin001", sequence: 3)], roomID: fixture.roomA)
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.secrets[fixture.roomA] == fixture.secretA)
        #expect(fixture.vault.deletes == 0)
        fixture.restart()
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.store.roomIDs.count == 2)
    }

    @Test func legacyCleanupCannotDeleteRetainedGenesis() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        try fixture.store.discardUnconflictedInactiveRoom(roomID: fixture.roomA)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.deletes == 0)
    }

    @Test func wrongSecretAndConflictingVaultFailWithoutMutation() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        #expect(throws: IrohProtocolError.self) { try fixture.prepare(secret: fixture.secretB) }
        fixture.vault.secrets[fixture.roomA] = fixture.secretB
        #expect(throws: IrohProtocolError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.vault.secrets[fixture.roomA] == fixture.secretB)
        #expect(fixture.vault.deletes == 0)
    }

    @Test func conflictDuringResumeSurvivesRollbackAndRestart() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try fixture.workspace(fixture.roomA)
        let preparation = try fixture.prepare()
        #expect(throws: IrohProtocolError.self) {
            try fixture.store.insertRemoteRecords(
                [fixture.record(id: "command-retained01", sequence: 1, elapsed: 1)], roomID: fixture.roomA)
        }
        try fixture.store.rollbackJoinedRoom(preparation)
        let conflicted = try fixture.workspace(fixture.roomA)
        #expect(conflicted.records == before.records)
        #expect(conflicted.peers == before.peers)
        #expect(conflicted.returnState == before.returnState)
        #expect(conflicted.conflict?.id == "command-retained01")
        fixture.restart()
        let bytes = try Data(contentsOf: fixture.fileURL)
        #expect(throws: IrohProtocolError.self) { try fixture.prepare() }
        #expect(throws: IrohProtocolError.self) {
            try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: fixture.local)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == bytes)
    }

    @Test(arguments: [false, true])
    func prepareDatabaseFailureRollsBackAndCompensatesNewSecret(missingSecret: Bool) throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        if missingSecret { fixture.vault.secrets[fixture.roomA] = nil }
        let before = try fixture.workspace(fixture.roomA)
        try fixture.withBlockedWrites { () throws in
            #expect(throws: (any Error).self) { try fixture.prepare() }
            #expect(fixture.store.activeRoomID == nil)
            #expect(try fixture.store.peers(roomID: fixture.roomA) == before.peers)
        }
        #expect(try fixture.workspace(fixture.roomA) == before)
        #expect(fixture.vault.secrets[fixture.roomA] == (missingSecret ? nil : fixture.secretA))
        #expect(fixture.vault.deletes == (missingSecret ? 1 : 0))
    }

    @Test func activationDatabaseFailureKeepsOriginalReturnAndAllowsRollback() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        let preparation = try fixture.prepare()
        try fixture.withBlockedWrites {
            #expect(throws: (any Error).self) {
                try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: .fresh())
            }
            #expect(fixture.store.activeRoomID == nil)
        }
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        fixture.restart()
        #expect(fixture.store.activeRoomID == nil)
    }

    @Test func rollbackDatabaseFailureKeepsPreparedWorkspaceAndCanRetry() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let original = try Data(contentsOf: fixture.fileURL)
        let preparation = try fixture.prepare()
        let preparedPeers = try fixture.store.peers(roomID: fixture.roomA)
        try fixture.withBlockedWrites { () throws in
            #expect(throws: (any Error).self) { try fixture.store.rollbackJoinedRoom(preparation) }
            #expect(try fixture.store.peers(roomID: fixture.roomA) == preparedPeers)
            #expect(fixture.vault.deletes == 0)
        }
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test(arguments: [false, true])
    func secretSaveFailureIncludingPartialWriteIsCompensated(partialWrite: Bool) throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        fixture.vault.secrets[fixture.roomA] = nil
        fixture.vault.failSave = true
        fixture.vault.writeBeforeSaveFailure = partialWrite
        #expect(throws: RejoinVaultFailure.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.secrets[fixture.roomA] == nil)
        #expect(fixture.vault.deletes == 1)
    }

    @Test func secretLoadFailureLeavesStoreUntouched() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        fixture.vault.failLoad = true
        #expect(throws: RejoinVaultFailure.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.deletes == 0)
    }

    @Test func secretCompensationFailureIsReportedWithoutDeletingRoom() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        fixture.vault.secrets[fixture.roomA] = nil
        fixture.vault.failSave = true
        fixture.vault.writeBeforeSaveFailure = true
        fixture.vault.failDelete = true
        do {
            _ = try fixture.prepare()
            Issue.record("Secret compensation failure was hidden")
        } catch {
            #expect(error.localizedDescription.contains("Room secret cleanup failed"))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.secrets[fixture.roomA] == fixture.secretA)
    }

    @Test func incompleteJoinPreservesRecordsAndRequiresGenesis() throws {
        let fixture = try RetainedRejoinFixture()
        let preparation = try fixture.prepare()
        try fixture.store.insertRemoteRecords([fixture.record(id: "command-partial01", sequence: 1)], roomID: fixture.roomA)
        fixture.restart()
        let original = try fixture.workspace(fixture.roomA)
        let retry = try fixture.prepare()
        #expect(try fixture.workspace(fixture.roomA).records == original.records)
        #expect(throws: IrohProtocolError.self) {
            try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: fixture.local)
        }
        try fixture.store.rollbackJoinedRoom(retry)
        #expect(try fixture.workspace(fixture.roomA) == original)
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(fixture.store.roomIDs.isEmpty)
        #expect(fixture.vault.secrets[fixture.roomA] == nil)
    }

    @Test(arguments: [false, true])
    func rollbackSecretFailureIsVisibleAndCanRetry(retained: Bool) throws {
        let fixture = try RetainedRejoinFixture()
        if retained { try fixture.retainRooms() }
        fixture.vault.secrets[fixture.roomA] = nil
        let preparation = try fixture.prepare()
        fixture.vault.failDelete = true
        #expect(throws: RejoinVaultFailure.self) { try fixture.store.rollbackJoinedRoom(preparation) }
        #expect(fixture.store.roomIDs.contains(fixture.roomA) == retained)
        #expect(fixture.vault.secrets[fixture.roomA] == fixture.secretA)
        fixture.vault.failDelete = false
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(fixture.vault.secrets[fixture.roomA] == nil)
    }

    @Test func activationCannotReplaceRoomActivatedDuringPreparation() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let preparation = try fixture.prepare()
        _ = try fixture.store.activateExistingRoom(roomID: fixture.roomB, returnState: fixture.local)
        let before = try Data(contentsOf: fixture.fileURL)
        #expect(throws: IrohProtocolError.self) {
            try fixture.store.activateJoinedRoom(roomID: fixture.roomA, returnState: fixture.local)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        try fixture.store.rollbackJoinedRoom(preparation)
        #expect(fixture.store.activeRoomID == fixture.roomB)
        #expect(fixture.store.activeReturnState == fixture.local)
    }

    @Test func corruptedGenesisFailsClosedAcrossRestart() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        var persisted = try fixture.persisted()
        let index = try #require(persisted.rooms.firstIndex(where: { $0.roomID == fixture.roomA }))
        let invalid = IrohGenesis(canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
            autoStartBreaks: false, hlcWallMs: -1, hlcCounter: 0)
        let record = IrohOperationRecord(domain: .genesis, deviceId: fixture.local.deviceId, payload: .genesis(invalid))
        #expect(!record.isValid)
        persisted.rooms[index].records[0] = try IrohStoredRecord(
            record: record, digest: record.digest(), canonicalData: record.canonicalBytes())
        let corrupt = try JSONEncoder.api.encode(persisted)
        try corrupt.write(to: fixture.fileURL)
        fixture.restart()
        #expect(throws: IrohProtocolError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.fileURL) == corrupt)
        #expect(fixture.store.activeRoomID == nil)
    }

    @Test func anotherActiveRoomCannotBeSilentlyReplaced() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        _ = try fixture.store.activateExistingRoom(roomID: fixture.roomB, returnState: fixture.local)
        let before = try Data(contentsOf: fixture.fileURL)
        #expect(throws: IrohProtocolError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.store.activeRoomID == fixture.roomB)
    }

    @Test func oversizedPeerCannotMutateRetainedRoom() throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        #expect(throws: IrohProtocolError.self) {
            try fixture.prepare(ticket: String(repeating: "x", count: IrohProtocolV1.maxEndpointTicketBytes + 1))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
    }

    @Test @MainActor
    func controllerCapturesReturnBeforeTransportAndLeavesCorrectWorkspace() async throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let harness = try RetainedRejoinControllerFixture(fixture)
        let original = harness.state
        harness.service.onStart = { harness.state.settings.selectedPhase = .longBreak }
        let result = await harness.controller.joinRoom(inviteText: try harness.invite(), environment: harness.environment)
        guard case .roomJoined(let joined) = result else {
            Issue.record("Expected retained room join, got \(result)")
            return
        }
        #expect(harness.snapshots == 1)
        #expect(fixture.store.activeReturnState == original)
        #expect(fixture.store.activeRoomID == fixture.roomA)
        harness.state = joined
        let returned = await harness.controller.leaveRoom(environment: harness.environment)
        #expect(returned == .roomLeft(original))
        fixture.restart()
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.store.roomIDs.count == 2)
        harness.service.onStart = nil
    }

    @Test(arguments: [false, true]) @MainActor
    func controllerTransportFailureRollsBackRetainedRoom(failStart: Bool) async throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let before = try Data(contentsOf: fixture.fileURL)
        let harness = try RetainedRejoinControllerFixture(fixture)
        if failStart {
            harness.service.onStart = { throw RejoinVaultFailure.load }
        } else {
            harness.service.onJoin = {
                try fixture.store.insertRemoteRecords(
                    [fixture.record(id: "command-transport01", sequence: 3)], roomID: fixture.roomA)
                throw RejoinVaultFailure.load
            }
        }
        let result = await harness.controller.joinRoom(inviteText: try harness.invite(), environment: harness.environment)
        guard case .failed = result else {
            Issue.record("Expected transport failure, got \(result)")
            return
        }
        #expect(harness.service.stops == 1)
        #expect(harness.service.joins == (failStart ? 0 : 1))
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(fixture.vault.deletes == 0)
        fixture.restart()
        #expect(fixture.store.activeRoomID == nil)
        #expect(fixture.store.roomIDs.count == 2)
    }

    @Test @MainActor
    func controllerActiveRejoinIsNoOpWithoutTransportOrReturnReplacement() async throws {
        let fixture = try RetainedRejoinFixture()
        try fixture.retainRooms()
        let joined = try fixture.store.activateExistingRoom(roomID: fixture.roomA, returnState: fixture.local)
        let harness = try RetainedRejoinControllerFixture(fixture, mode: .iroh)
        harness.state = joined
        let before = try Data(contentsOf: fixture.fileURL)
        let result = await harness.controller.joinRoom(inviteText: try harness.invite(), environment: harness.environment)
        #expect(result == .unchanged)
        #expect(harness.service.starts == 0)
        #expect(harness.service.joins == 0)
        #expect(harness.service.stops == 0)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(await harness.controller.leaveRoom(environment: harness.environment) == .roomLeft(fixture.local))
    }
}

private enum RejoinVaultFailure: Error { case load, save, delete }

private final class RejoinVault: IrohRoomSecretStoring, @unchecked Sendable {
    var secrets: [String: Data] = [:]
    var failLoad = false
    var failSave = false
    var writeBeforeSaveFailure = false
    var failDelete = false
    var saves = 0
    var deletes = 0

    func load(roomID: String) throws -> Data? {
        if failLoad { throw RejoinVaultFailure.load }
        return secrets[roomID]
    }

    func save(_ secret: Data, roomID: String) throws {
        saves += 1
        if !failSave || writeBeforeSaveFailure { secrets[roomID] = secret }
        if failSave { throw RejoinVaultFailure.save }
    }

    func delete(roomID: String) throws {
        deletes += 1
        if failDelete { throw RejoinVaultFailure.delete }
        secrets[roomID] = nil
    }

    func accountDeletionAccounts() throws -> [String] { [] }
    func deleteAccount(named account: String) throws { throw RejoinVaultFailure.delete }
}

private final class RetainedRejoinFixture {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    let directory: URL
    let fileURL: URL
    let vault: RejoinVault
    let secretA = Data(repeating: 31, count: 32)
    let secretB = Data(repeating: 32, count: 32)
    let roomA: String
    let roomB: String
    var local: PersistedTimerState
    var store: IrohRoomStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetainedRejoin-\(UUID())")
        fileURL = directory.appendingPathComponent("rooms.json")
        vault = RejoinVault()
        roomA = try IrohProtocolV1.roomID(for: secretA)
        roomB = try IrohProtocolV1.roomID(for: secretB)
        local = .fresh()
        local.deviceId = "device-return0001"
        local.tasks = [try #require(FocusTask(title: "Local workspace"))]
        local.knownTasks = local.tasks
        local.selectedTaskID = local.tasks[0].id
        store = IrohRoomStore(fileURL: fileURL, secretStore: vault, now: { Self.date })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func restart() {
        store = IrohRoomStore(fileURL: fileURL, secretStore: vault, now: { Self.date })
    }

    func retainRooms() throws {
        for (offset, secret) in [secretA, secretB].enumerated() {
            let roomID = try IrohProtocolV1.roomID(for: secret)
            var room = try store.createRoom(roomID: roomID, roomSecret: secret, name: "Original \(offset)",
                returnState: local, genesis: genesis(offset), now: Self.date.addingTimeInterval(Double(offset)))
            room.pendingCommands = [command(id: "command-retained01", sequence: 1)]
            room.nextSequence = 2
            room = try store.captureLocalOperations(from: room)
            try store.upsertPeer(IrohPeer(endpointID: "endpoint-retained01", endpointTicket: "ticket-original01",
                deviceID: "peer-device0001", displayName: "Known peer", lastSeenAt: Self.date), roomID: roomID)
            #expect(try store.captureAndSuspendActiveRoom(from: room) == local)
        }
    }

    func genesis(_ offset: Int) throws -> IrohGenesis {
        let task = try #require(FocusTask(title: "Room task \(offset)"))
        let history = HistoryItem(id: "history-retained01", timerId: "timer-finished001", commandId: nil,
            taskId: task.id.uuidString.lowercased(), phase: .focus, status: "completed", plannedDurationMs: 60_000,
            completedAt: Self.date.addingTimeInterval(-120), endedAt: Self.date.addingTimeInterval(-120))
        return IrohGenesis(canonicalTimer: nil, history: [history], tasks: [task], durationsMs: .defaults,
            autoStartBreaks: false, selectedTaskId: task.id.uuidString.lowercased(), hlcWallMs: 0, hlcCounter: 0)
    }

    func command(id: String, sequence: Int64, elapsed: Int64 = 0) -> TimerCommand {
        TimerCommand(id: id, deviceSequence: sequence, timerId: "timer-retained001", taskId: nil,
            type: .start, phase: .focus, plannedDurationMs: 60_000, occurredAt: Self.date,
            hlcWallMs: 1_700_000_000_000, hlcCounter: 0, observedElapsedMs: elapsed)
    }

    func record(id: String, sequence: Int64, elapsed: Int64 = 0) -> IrohOperationRecord {
        IrohOperationRecord(domain: .timer, deviceId: local.deviceId,
            payload: .timer(command(id: id, sequence: sequence, elapsed: elapsed)))
    }

    @discardableResult
    func prepare(returnState: PersistedTimerState? = nil, secret: Data? = nil,
                 ticket: String = "ticket-refreshed01") throws -> IrohRoomStore.JoinPreparation {
        try store.prepareJoinedRoom(roomID: roomA, roomSecret: secret ?? secretA, name: "Invite rename ignored",
            returnState: returnState ?? local, initialPeer: IrohPeer(endpointID: "endpoint-retained01",
                endpointTicket: ticket, deviceID: nil, displayName: nil, lastSeenAt: nil), now: Self.date)
    }

    func persisted() throws -> IrohReplicationState {
        try JSONDecoder.api.decode(IrohReplicationState.self, from: Data(contentsOf: fileURL))
    }

    func workspace(_ roomID: String) throws -> IrohRoomWorkspace {
        try #require(persisted().rooms.first(where: { $0.roomID == roomID }))
    }

    func withBlockedWrites(_ action: () throws -> Void) throws {
        let original = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        do {
            try action()
        } catch {
            try FileManager.default.removeItem(at: fileURL)
            try original.write(to: fileURL)
            throw error
        }
        try FileManager.default.removeItem(at: fileURL)
        try original.write(to: fileURL)
    }
}

@MainActor
private final class RetainedRejoinService: RoomReplicationServing {
    var starts = 0
    var joins = 0
    var stops = 0
    var onStart: (() throws -> Void)?
    var onJoin: (() throws -> Void)?

    func start(_ context: IrohServiceContext) async throws -> String {
        starts += 1
        try onStart?()
        return "fake-transport-ticket"
    }

    func join(invite: IrohRoomInvite) async throws {
        joins += 1
        try onJoin?()
    }

    func stop() async { stops += 1 }
    func currentEndpointTicket() async throws -> String { "fake-transport-ticket" }
    func syncNow() async {}
    func markConflict(roomID: String?) async {}
}

@MainActor
private final class RetainedRejoinControllerFixture {
    let fixture: RetainedRejoinFixture
    let service = RetainedRejoinService()
    let genesis: IrohGenesis
    let mode: ReplicationMode
    var state: PersistedTimerState
    var snapshots = 0

    init(_ fixture: RetainedRejoinFixture, mode: ReplicationMode = .offline) throws {
        self.fixture = fixture
        self.mode = mode
        state = fixture.local
        genesis = try fixture.genesis(0)
    }

    var environment: RoomReplicationEnvironment {
        .init(deviceID: state.deviceId, displayName: nil, platform: "macos")
    }

    lazy var controller = RoomReplicationController(mode: mode, dependencies: .init(
        roomStore: fixture.store, retryDelay: .seconds(1),
        centralizedState: {
            .init(sessionGeneration: 0, isSignedIn: false, isWorkspaceMutationBlocked: false,
                isSessionVerified: false, localRevision: 0, isSyncing: false,
                isTimerActive: false, isHistoryResolutionBlocking: false)
        },
        workspaceSnapshot: { [unowned self] in
            snapshots += 1
            return .init(state: state, genesis: genesis)
        },
        revisionEvents: { throw RejoinVaultFailure.load },
        sleep: { _ in throw CancellationError() },
        secureRandomBytes: { Data(repeating: 0, count: $0) },
        encodeInvite: { _, _, _, _ in throw RejoinVaultFailure.load },
        makeService: { [service] _ in service }
    ), eventHandler: { _ in }, operationHandler: { _ in })

    func invite() throws -> String {
        let identity = try SecretKey.fromBytes(bytes: Data(repeating: 41, count: 32))
        let address = EndpointAddr(id: identity.public(), relayUrl: nil, addresses: [])
        let ticket = try EndpointTicket.fromAddr(addr: address).description
        return try IrohRoomInvite(roomID: fixture.roomA, roomName: "Rejoin invite",
            endpointTicket: ticket, roomSecret: fixture.secretA).encoded()
    }
}
