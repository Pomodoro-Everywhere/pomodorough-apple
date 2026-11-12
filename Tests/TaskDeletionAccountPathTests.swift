import Foundation
import Testing
@testable import Pomodorough

/// Sign-out, session expiry and account deletion replace the account
/// workspace. A deletion waiting in its undo window is written to that
/// workspace first, so it is never dropped, never refused by the sign-out
/// fence, and never replayed into the next workspace.
@Suite("Task deletion before an account change")
@MainActor
struct TaskDeletionAccountPathTests {
    @Test func signOutDuringTheWindowCompletesTheDeletionBeforeTheFence() async throws {
        let fixture = try AccountTaskDeletionFixture(scenario: "apple-api-coverage-model-local-signout")
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: fixture.tokens)
        await model.restore()
        try #require(model.isSignedIn)
        let task = try fixture.hideSeededTask(in: model)

        model.signOut()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isSignedIn)
        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(try fixture.accountWriteWithout(task), "the delete is written to the account workspace first")
        #expect(fixture.markers.load() == nil, "nothing is replayed into the signed-out workspace")
        #expect(model.errorMessage == nil, "the sign-out fence must not refuse the delete")
    }

    @Test func sessionExpiryDuringTheWindowCompletesTheDeletionBeforeTheReset() async throws {
        let fixture = try AccountTaskDeletionFixture(scenario: "unauthorized", sharesScenario: true)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: StaticTokenStore())
        let task = try fixture.hideSeededTask(in: model)

        await model.restore()

        #expect(!model.isSignedIn)
        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(try fixture.accountWriteWithout(task))
        #expect(fixture.markers.load() == nil)
    }

    /// A delete that cannot be written stops the sign-out. Its sentence
    /// stays on screen, the task is back, and nothing replays it later.
    @Test func refusedDeleteStopsTheSignOutAndSaysWhy() async throws {
        let fixture = try AccountTaskDeletionFixture(scenario: "apple-api-coverage-model-local-signout")
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: fixture.tokens)
        await model.restore()
        try #require(model.isSignedIn)
        let task = try fixture.hideSeededTask(in: model)
        try fixture.refuseDurableWrites(true)
        defer { try? fixture.refuseDurableWrites(false) }

        model.signOut()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.isSignedIn, "the sign-out waits until the delete can be written")
        #expect(model.errorMessage == Self.refusedSentence(for: task))
        #expect(model.tasks.contains { $0.id == task.id }, "the task is back in the list")
        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(fixture.markers.load() == nil, "a refused delete is never replayed")
    }

    /// The expiry reset clears every message, so a refused delete keeps its
    /// sentence after the expiry sentence.
    @Test func refusedDeleteSentenceOutlastsTheSessionExpiryReset() async throws {
        let fixture = try AccountTaskDeletionFixture(scenario: "unauthorized", sharesScenario: true)
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: StaticTokenStore())
        let task = try fixture.hideSeededTask(in: model)
        try fixture.refuseDurableWrites(true)
        defer { try? fixture.refuseDurableWrites(false) }

        await model.restore()

        #expect(!model.isSignedIn)
        #expect(model.errorMessage == "\(AppError.unauthorized.localizedDescription) \(Self.refusedSentence(for: task))")
        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(fixture.markers.load() == nil, "a refused delete is never replayed")
    }

    /// The acceptance case: an old session's 401 that arrives after a new
    /// sign-in is dropped by the ownership guard, and it must not end the
    /// undo window the new session opened.
    @Test func staleUnauthorizedSyncLeavesTheNewSessionsUndoWindowOpen() async throws {
        let fixture = try AccountTaskDeletionFixture(
            scenario: StubURLProtocol.staleUnauthorizedSyncPrefix,
            mode: .centralized
        )
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: fixture.tokens)
        let oldSession = Task { await model.restore() }
        try #require(await TestFixtures.waitForRequest(in: fixture.scenario, path: "/api/v1/sync"))

        model.signIn()
        for _ in 0..<200 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isSignedIn)
        if model.tasks.isEmpty { #expect(await model.addTask("New session task")) }
        let task = try fixture.hideSeededTask(in: model)

        TestFixtures.releaseScenario(fixture.scenario)
        await oldSession.value

        #expect(TestFixtures.lifecycleEvents(for: fixture.scenario).contains("stale unauthorized sync completed"))
        #expect(model.isSignedIn, "the stale 401 does not end the new session")
        #expect(model.pendingTaskDeletion.entry?.id == task.id, "Undo is still offered")
        #expect(fixture.markers.load()?.taskID == task.id)
        #expect(model.errorMessage == nil)
    }

    private static func refusedSentence(for task: FocusTask) -> String {
        "Could not delete “\(task.title)”. The task is back in your list."
    }

    @Test func accountDeletionCompletesTheDeletionFirst() async throws {
        let fixture = try AccountTaskDeletionFixture(scenario: "apple-api-coverage-model-local-signout")
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: fixture.tokens)
        await model.restore()
        try #require(model.isSignedIn)
        let task = try fixture.hideSeededTask(in: model)

        await model.deleteAccount(confirmation: "DELETE")

        #expect(model.pendingTaskDeletion.entry == nil)
        #expect(try fixture.accountWriteWithout(task))
        #expect(fixture.markers.load() == nil)
    }

    /// The sign-out confirmation ("This will discard N changes") lives on
    /// the Account screen, and opening Account ends the undo window. So the
    /// hidden task's delete is queued before N is read, and N counts it.
    @Test func openingAccountQueuesTheHiddenDeleteSoTheDiscardCountIncludesIt() async throws {
        let fixture = try AccountTaskDeletionFixture(scenario: "apple-api-coverage-model-local-signout")
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(tokens: fixture.tokens)
        await model.restore()
        try #require(model.isSignedIn)
        let before = model.pendingChangeCount
        let task = try fixture.hideSeededTask(in: model)
        #expect(model.pendingChangeCount == before, "the undo window only hides the task")

        model.pendingTaskDeletion.flush() // what opening Account does

        #expect(model.pendingChangeCount == before + 1)
        #expect(try fixture.accountWriteQueuesDelete(of: task))
    }

    /// In Iroh mode the delete is a room record before sign-out completes,
    /// and the room stays active after sign-out, so the delete is not lost.
    @Test func irohSignOutWritesTheHiddenDeleteToTheRoomFirst() async throws {
        try await IrohTaskDeletionFixture.run { fixture in
            let model = try await fixture.restoredRoomModel()
            let before = try #require(fixture.roomStore.roomSnapshot(roomID: fixture.roomID)).operationCount
            try #require(model.requestTaskDeletion(id: fixture.task.id, title: fixture.task.title))
            #expect(fixture.roomStore.roomSnapshot(roomID: fixture.roomID)?.operationCount == before)

            model.signOut()
            for _ in 0..<200 where model.isWorking {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(!model.isSignedIn)
            #expect(model.errorMessage == nil)
            #expect(model.pendingTaskDeletion.entry == nil)
            #expect(model.pendingTaskDeletion.marker == nil)
            #expect(fixture.roomStore.activeRoomID == fixture.roomID, "sign-out keeps the room")
            let saved = fixture.reopenedRoomStore()
            #expect((saved.roomSnapshot(roomID: fixture.roomID)?.operationCount ?? 0) > before,
                    "the delete is a room record on disk")
            #expect(saved.activeRoomState?.tasks.contains { $0.id == fixture.task.id } == false)
        }
    }

    /// Leaving the room replaces the workspace, so the model writes the
    /// hidden delete to the room first, whichever surface asked to leave.
    @Test func leavingTheRoomWritesTheHiddenDeleteToTheRoomFirst() async throws {
        try await IrohTaskDeletionFixture.run { fixture in
            let model = try await fixture.restoredRoomModel()
            let before = try #require(fixture.roomStore.roomSnapshot(roomID: fixture.roomID)).operationCount
            try #require(model.requestTaskDeletion(id: fixture.task.id, title: fixture.task.title))
            model.requestIrohRoomLeave()

            await model.confirmIrohRoomLeave()

            #expect(model.pendingTaskDeletion.entry == nil)
            #expect(model.pendingTaskDeletion.marker == nil)
            let saved = fixture.reopenedRoomStore()
            #expect((saved.roomSnapshot(roomID: fixture.roomID)?.operationCount ?? 0) > before,
                    "the delete is a room record before the room is left")
        }
    }
}

/// Signed-in offline workspace seeded on disk, with stubbed network and
/// in-memory credential, revocation, endpoint-key and room-secret stores.
@MainActor
private final class AccountTaskDeletionFixture {
    let scenario: String
    let sharesScenario: Bool
    let directory: URL
    let defaults: RecordingUserDefaults
    let session: URLSession
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "deletion-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "deletion-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let suiteName: String
    var markers: TaskDeletionMarkerStore { TaskDeletionMarkerStore(defaults: defaults) }

    /// `sharesScenario` marks a fixed stub scenario that other suites use
    /// too; its recorder is then left in place. `mode` is the saved
    /// replication mode; centralized lets the restore start a sync.
    init(scenario base: String, sharesScenario: Bool = false, mode: ReplicationMode = .offline) throws {
        let id = UUID().uuidString
        scenario = sharesScenario ? base : "\(base)-task-deletion-\(id)"
        self.sharesScenario = sharesScenario
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskDeletionAccountPath-\(id)", isDirectory: true)
        suiteName = "TaskDeletionAccountPath.\(id)"
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        session = TestFixtures.session(for: scenario, resetsRecorder: !sharesScenario)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(mode.rawValue, forKey: "replication-mode-v1")
        let bytes = try JSONEncoder.api.encode(TestFixtures.syncContractState(includesPendingOperations: false))
        try AtomicDurableFileStore(fileURL: stateURL).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        defaults.resetTimerStateWrites()
    }

    private var stateURL: URL { directory.appendingPathComponent("workspace.json") }

    func makeModel(tokens: any TokenStoring & LogoutRevocationStoring) -> AppModel {
        AppModel(
            api: APIClient(session: session, keychain: tokens, logoutRevocationStore: tokens),
            defaults: defaults,
            durableLocalStore: AtomicDurableFileStore(fileURL: stateURL),
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            endpointKeyStore: PreviewEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        )
    }

    func hideSeededTask(in model: AppModel) throws -> FocusTask {
        let task = try #require(model.tasks.first)
        model.requestTaskDeletion(id: task.id, title: task.title)
        try #require(markers.load()?.workspace.owner == "account:\(TestFixtures.user.id)")
        return task
    }

    /// Makes the workspace folder read-only, so the next durable write of
    /// the delete fails the way a full or locked disk would.
    func refuseDurableWrites(_ refused: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: refused ? 0o500 : 0o700],
            ofItemAtPath: directory.path
        )
    }

    /// Whether some saved account snapshot already deletes `task`: either
    /// the task is gone, or a queued delete for it waits for the server.
    func accountWriteWithout(_ task: FocusTask) throws -> Bool {
        try defaults.timerStateWrites.contains { bytes in
            let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
            guard state.cachedUser != nil else { return false }
            let queuesDelete = state.pendingTaskOperations.contains {
                $0.type == .delete && UUID(uuidString: $0.taskId) == task.id
            }
            return queuesDelete || !state.tasks.contains { $0.id == task.id }
        }
    }

    /// Whether the last saved account snapshot queues a delete for `task`.
    func accountWriteQueuesDelete(of task: FocusTask) throws -> Bool {
        guard let bytes = defaults.timerStateWrites.last else { return false }
        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
        return state.cachedUser != nil && state.pendingTaskOperations.contains {
            $0.type == .delete && UUID(uuidString: $0.taskId) == task.id
        }
    }

    func cleanUp() {
        if !sharesScenario {
            TestFixtures.releaseScenario(scenario)
            session.invalidateAndCancel()
        }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Signed-in account with an active Iroh room whose genesis holds one task.
/// Network, credentials, endpoint keys and room secrets are fakes; the room
/// service has no peers. Teardown drains the logout revocation before it
/// invalidates the stub session.
@MainActor
private final class IrohTaskDeletionFixture {
    let suiteName = "TaskDeletionIrohSignOut.\(UUID().uuidString)"
    let directory: URL
    let defaults: RecordingUserDefaults
    let tokens = RecordingTokenStore(tokens: TokenPair(
        accessToken: "room-deletion-access", accessTokenExpiresAt: .distantFuture,
        refreshToken: "room-deletion-refresh", refreshTokenExpiresAt: .distantFuture
    ))
    let secrets = MemoryIrohRoomSecretStore()
    let logout: LogoutDrainingSession
    let task: FocusTask
    let roomStore: IrohRoomStore
    private(set) var roomID = ""

    private init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
        logout = LogoutDrainingSession(
            scenario: "apple-api-coverage-model-local-signout-room-deletion-\(UUID().uuidString)",
            obligations: tokens
        )
        task = try #require(FocusTask(title: "Room task"))
        roomStore = IrohRoomStore(fileURL: directory.appendingPathComponent("iroh-rooms.json"), secretStore: secrets)
    }

    static func run(_ body: @MainActor (IrohTaskDeletionFixture) async throws -> Void) async throws {
        let fixture = try IrohTaskDeletionFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try await fixture.logout.run { try await body(fixture) }
    }

    func reopenedRoomStore() -> IrohRoomStore {
        IrohRoomStore(fileURL: directory.appendingPathComponent("iroh-rooms.json"), secretStore: secrets)
    }

    /// Seeds the account and its room, then restores a model into the room.
    func restoredRoomModel() async throws -> AppModel {
        let account = TestFixtures.syncContractState(includesPendingOperations: false)
        let bytes = try JSONEncoder.api.encode(account)
        let stateURL = directory.appendingPathComponent("workspace.json")
        try AtomicDurableFileStore(fileURL: stateURL).write(bytes)
        defaults.set(bytes, forKey: PersistedStateLoader.storageKey)
        let secret = Data(0...31)
        roomID = try IrohProtocolV1.roomID(for: secret)
        _ = try roomStore.createRoom(
            roomID: roomID, roomSecret: secret, name: nil, returnState: account,
            genesis: IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [task], durationsMs: .defaults,
                autoStartBreaks: false, selectedTaskId: nil, hlcWallMs: 0, hlcCounter: 0
            ),
            now: TestFixtures.anchor
        )
        let model = logout.track(AppModel(
            api: APIClient(session: logout.session, keychain: tokens, logoutRevocationStore: tokens),
            defaults: defaults, durableLocalStore: AtomicDurableFileStore(fileURL: stateURL),
            roomStore: roomStore, endpointKeyStore: PreviewEndpointKeyStore(),
            roomServiceFactory: { _ in NoPeerRoomService() },
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { TestFixtures.anchor.addingTimeInterval(5) }, uptime: { 100 }
        ))
        await model.restore()
        try #require(model.isSignedIn)
        try #require(model.replicationMode == .iroh)
        try #require(model.tasks.contains { $0.id == task.id })
        return model
    }
}

/// Iroh service stand-in with no peers: every call succeeds at once.
private actor NoPeerRoomService: RoomReplicationServing {
    func start(_ context: IrohServiceContext) async throws -> String { "endpoint-ticket" }
    func stop() async {}
    func currentEndpointTicket() async throws -> String { "endpoint-ticket" }
    func syncNow() async {}
    func markConflict(roomID: String?) async {}
    func join(invite: IrohRoomInvite) async throws {}
}
