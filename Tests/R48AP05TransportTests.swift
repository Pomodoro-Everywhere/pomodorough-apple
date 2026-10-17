import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP05 durable transport")
struct R48AP05TransportTests {
    @Test @MainActor
    func lostResponseReopenReplaysExactWireAndClearsClaimOnlyAfterCommit() async throws {
        let fixture = try R48AP05TransportFixture()
        defer { fixture.cleanUp() }
        var seed = R48AP05BatchPlanTests().mixedState(count: 3)
        seed.pendingSelectedTaskOperations.removeLast()
        seed.pruneNeverSentProofToPending()
        seed.cachedUser = TestFixtures.user
        try fixture.store.write(JSONEncoder.api.encode(seed))
        let first = fixture.model()
        await first.restore()
        #expect(first.isOffline)
        let saved = try fixture.readState()
        let claim = try #require(saved.outgoingSyncClaim)
        #expect(saved.syncBatchCursor != seed.syncBatchCursor)
        #expect(saved.neverSentCommandIDs.isEmpty)
        #expect(saved.neverSentTaskOperationIDs.isEmpty)
        #expect(saved.neverSentDurationOperationIDs.isEmpty)
        #expect(saved.neverSentAutoStartOperationIDs.isEmpty)
        #expect(saved.neverSentSelectedTaskOperationIDs.isEmpty)
        let reopened = fixture.model()
        await reopened.restore()
        #expect(!reopened.isOffline)
        let bodies = R48AP05TransportProtocol.bodies.value[fixture.scenario] ?? []
        try #require(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
        let wire = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(wire["lastRevision"] as? Int64 == claim.lastRevision)
        for domain in SyncBatchDomain.allCases {
            #expect((wire[domain.rawValue] as? [[String: Any]])?.count == (domain == .selectedTaskOperations ? 2 : 3))
        }
        let installed = try fixture.readState()
        #expect(installed.outgoingSyncClaim == nil)
        #expect(installed.syncBatchCursor == saved.syncBatchCursor)
        #expect(installed.pendingCommands.isEmpty)
        #expect(installed.pendingTaskOperations.isEmpty)
        #expect(installed.pendingDurationOperations.isEmpty)
        #expect(installed.pendingAutoStartOperations.isEmpty)
        #expect(installed.pendingSelectedTaskOperations.isEmpty)
    }

    @Test @MainActor
    func oversizedRecoveryPersistsBeforeReplanningAndKeepsSentProof() async throws {
        let fixture = try R48AP05TransportFixture()
        defer { fixture.cleanUp() }
        var seed = R48AP05BatchPlanTests().mixedState(count: 0)
        seed.cachedUser = TestFixtures.user
        seed.pendingTaskOperations = R48AP05BatchPlanTests().makeTasks(
            count: 257, baseWallMs: 1_710_000_100_000
        )
        seed.outgoingSyncClaim = R48AP05BatchPlanTests().requestForAll(seed)
        try fixture.store.write(JSONEncoder.api.encode(seed))
        let model = fixture.model()
        await model.restore()
        #expect(await model.sync(force: true) == false)
        #expect(model.hasOversizedSavedSyncClaim)
        #expect(R48AP05TransportProtocol.bodies.value[fixture.scenario] == nil)
        #expect(!model.recoverOversizedSavedSyncClaim(confirmed: false))
        #expect(try fixture.readState().outgoingSyncClaim == seed.outgoingSyncClaim)
        #expect(model.recoverOversizedSavedSyncClaim(confirmed: true))
        let reopened = try fixture.readState()
        #expect(reopened.outgoingSyncClaim == nil)
        #expect(reopened.pendingTaskOperations == seed.pendingTaskOperations)
        #expect(reopened.neverSentTaskOperationIDs.isEmpty)
        #expect(reopened.syncBatchCursor == seed.syncBatchCursor)
        let prepared = try R48AP05BatchPlanTests().makeSync().prepareSyncPlan(state: reopened)
        #expect(prepared.plan.batch.taskOperations.count == 256)
        #expect(prepared.retired.neverSentTaskOperationIDs.isEmpty)
    }

    @Test @MainActor
    func recoveryWriteFailurePreservesExactSavedClaim() async throws {
        let fixture = try R48AP05TransportFixture()
        defer { fixture.cleanUp() }
        var seed = R48AP05BatchPlanTests().mixedState(count: 0)
        seed.pendingTaskOperations = R48AP05BatchPlanTests().makeTasks(
            count: 257, baseWallMs: 1_710_000_100_000
        )
        seed.outgoingSyncClaim = R48AP05BatchPlanTests().requestForAll(seed)
        try fixture.store.write(JSONEncoder.api.encode(seed))
        let model = fixture.model()
        let before = try fixture.store.read()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
        #expect(!model.recoverOversizedSavedSyncClaim(confirmed: true))
        #expect(try fixture.store.read() == before)
        #expect(try fixture.readState().outgoingSyncClaim == seed.outgoingSyncClaim)
    }
}

@MainActor
private struct R48AP05TransportFixture {
    let scenario = UUID().uuidString
    let suite = "R48AP05.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let session: URLSession
    var store: AtomicDurableFileStore { AtomicDurableFileStore(fileURL: directory.appendingPathComponent("workspace.json")) }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R48AP05TransportProtocol.self]
        configuration.httpAdditionalHeaders = ["X-R48AP05": scenario]
        session = URLSession(configuration: configuration)
    }

    func model() -> AppModel {
        AppModel(api: APIClient(session: session, keychain: StaticTokenStore()), defaults: defaults,
                 durableLocalStore: store, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
                 alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
                 now: { Date(timeIntervalSince1970: 1_710_100_000) }, uptime: { 100 })
    }

    func readState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: #require(try store.read()))
    }

    func cleanUp() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class R48AP05TransportProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = LockedTestValue<[String: [Data]]>([:])
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-R48AP05") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        if request.url?.path == "/api/v1/me" {
            respond(R48AP04StubProtocol.meBody)
            return
        }
        guard request.url?.path == "/api/v1/sync", let body = Self.body(request),
              let scenario = request.value(forHTTPHeaderField: "X-R48AP05") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let count = Self.lock.withLock {
            var recorded = Self.bodies.value
            recorded[scenario, default: []].append(body)
            Self.bodies.value = recorded
            return recorded[scenario]?.count ?? 0
        }
        if count == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        do { respond(try Self.response(body)) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func respond(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return body }
            body.append(buffer, count: count)
        }
    }

    private static func response(_ body: Data) throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var response: [String: Any] = [
            "revision": 1, "canonicalTimer": NSNull(), "history": [], "tasks": [],
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false, "selectedTaskId": NSNull(),
            "serverTime": "2026-07-21T08:00:00.000Z", "serverHlcWallMs": 1_784_620_800_000,
            "serverHlcCounter": 4
        ]
        let keys = ["acknowledgements", "taskAcknowledgements", "durationAcknowledgements",
                    "autoStartAcknowledgements", "selectedTaskAcknowledgements"]
        for (domain, key) in zip(SyncBatchDomain.allCases, keys) {
            response[key] = (request[domain.rawValue] as? [[String: Any]] ?? []).map {
                [domain == .commands ? "commandId" : "operationId": $0["id"]!,
                 "outcome": "applied", "reason": ""]
            }
        }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

@Suite("R49-AP01 sync failure durability")
struct R49AP01SyncFailureTests {
    @Test(arguments: R49AP01Edit.allCases, R49AP01Failure.allCases) @MainActor
    func concurrentDurableEditsSurvivePossibleDelivery(
        edit: R49AP01Edit, failure: R49AP01Failure
    ) async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let restoration = Task { await model.restore() }
        defer { restoration.cancel() }
        try await fixture.waitForDelivery()
        let retired = try fixture.readState()
        let claim = try #require(retired.outgoingSyncClaim)
        let wire = try #require(R49AP01Protocol.deliveries.value[fixture.scenario]?.requestBody())
        #expect(try JSONDecoder.api.decode(SyncRequest.self, from: wire) == claim)
        #expect(claim.durationOperations == fixture.seed.pendingDurationOperations)
        #expect(retired.neverSentDurationOperationIDs.isEmpty)
        try await fixture.apply(edit, to: model)
        let during = try fixture.readState()
        let bytes = try #require(try fixture.store.read())
        let watch = model.makeWatchSnapshot()
        #expect(during != retired)
        #expect(during.outgoingSyncClaim == claim)
        #expect(during.syncBatchCursor == retired.syncBatchCursor)
        #expect(during.pendingDurationOperations.first == fixture.seed.pendingDurationOperations.first)
        #expect(!during.neverSentDurationOperationIDs.contains(claim.durationOperations[0].id))
        fixture.finish(failure)
        await restoration.value
        #expect(try fixture.store.read() == bytes)
        #expect(try fixture.readState() == during)
        #expect(model.pendingChangeCount == fixture.pendingCount(during))
        #expect(model.makeWatchSnapshot() == watch)
        let reopened = fixture.model()
        #expect(reopened.pendingChangeCount == model.pendingChangeCount)
        #expect(reopened.durationMinutes(for: .focus) == model.durationMinutes(for: .focus))
        #expect(try fixture.readState() == during)
        let replay = try R48AP05BatchPlanTests().makeSync().prepareSyncPlan(state: during)
        #expect(replay.plan.isSavedReplay)
        #expect(replay.plan.request == claim)
        #expect(replay.retired == during)
    }

    @Test @MainActor
    func invalidResponseWithoutConcurrentEditCannotResurrectNeverSentProof() async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let restoration = Task { await model.restore() }
        defer { restoration.cancel() }
        try await fixture.waitForDelivery()
        let retired = try fixture.readState()
        let bytes = try fixture.store.read()
        fixture.finish(.invalidRevision)
        await restoration.value
        #expect(try fixture.store.read() == bytes)
        #expect(try fixture.readState() == retired)
        #expect(retired.neverSentDurationOperationIDs.isEmpty)
        #expect(retired.outgoingSyncClaim != nil)
    }

    @Test @MainActor
    func cancellationOfOutstandingSyncPreservesConcurrentMixedGroup() async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let restoration = Task { await model.restore() }
        defer { restoration.cancel() }
        try await fixture.waitForDelivery()
        try await fixture.apply(.mixed, to: model)
        let during = try fixture.readState()
        let bytes = try fixture.store.read()
        restoration.cancel()
        await restoration.value
        #expect(try fixture.store.read() == bytes)
        #expect(try fixture.readState() == during)
        #expect(model.pendingChangeCount == fixture.pendingCount(during))
    }

    @Test @MainActor
    func reopenedModelResendsExactClaimWithoutSendingConcurrentGroup() async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.model()
        let initialRestore = Task { await first.restore() }
        defer { initialRestore.cancel() }
        try await fixture.waitForDelivery()
        let firstBody = try #require(R49AP01Protocol.deliveries.value[fixture.scenario]?.requestBody())
        try await fixture.apply(.mixed, to: first)
        let during = try fixture.readState()
        fixture.finish(.invalidRevision)
        await initialRestore.value
        R49AP01Protocol.remove(fixture.scenario)
        let reopened = fixture.model()
        let retry = Task { await reopened.restore() }
        defer { retry.cancel() }
        try await fixture.waitForDelivery()
        #expect(R49AP01Protocol.deliveries.value[fixture.scenario]?.requestBody() == firstBody)
        #expect(try fixture.readState() == during)
        fixture.finish(.invalidDecode)
        await retry.value
        #expect(try fixture.readState() == during)
        #expect(reopened.pendingChangeCount == fixture.pendingCount(during))
    }

    @Test @MainActor
    func commitWriteFailureKeepsCurrentClaimAndConcurrentEdits() async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let restoration = Task { await model.restore() }
        defer { restoration.cancel() }
        try await fixture.waitForDelivery()
        try await fixture.apply(.mixed, to: model)
        let during = try fixture.readState()
        let bytes = try fixture.store.read()
        try fixture.permissions(0o555)
        defer { try? fixture.permissions(0o700) }
        fixture.finish(.valid)
        await restoration.value
        #expect(try fixture.store.read() == bytes)
        #expect(try fixture.readState() == during)
        #expect(model.pendingChangeCount == fixture.pendingCount(during))
        #expect(model.conflictMessage != nil)
    }

    @Test @MainActor
    func successfulCommitClearsClaimAndInstallsCanonicalDuration() async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let restoration = Task { await model.restore() }
        defer { restoration.cancel() }
        try await fixture.waitForDelivery()
        fixture.finish(.valid)
        await restoration.value
        let installed = try fixture.readState()
        #expect(installed.revision == 1)
        #expect(installed.outgoingSyncClaim == nil)
        #expect(installed.pendingDurationOperations.isEmpty)
        #expect(installed.neverSentDurationOperationIDs.isEmpty)
        #expect(model.durationMinutes(for: .focus) == 30)
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: R49AP01PreSendFault.allCases) @MainActor
    func preSendRollbackRequiresExactSnapshotAndSuccessfulPersistence(fault: R49AP01PreSendFault) async throws {
        let fixture = try R49AP01Fixture()
        defer { fixture.cleanUp() }
        let validation = R49AP01ValidationFault()
        let model = fixture.model(validation: validation)
        var retired: PersistedTimerState?
        var concurrent: PersistedTimerState?
        validation.action = {
            retired = try fixture.readState()
            switch fault {
            case .unchanged: break
            case .concurrent:
                model.setDurationMinutes(35, for: .focus)
                concurrent = try fixture.readState()
                fixture.coreFailure.value = true
            case .writeDenied: try fixture.permissions(0o555)
            case .replacementUncertain: fixture.replacementFailure.value = true
            }
        }
        defer { try? fixture.permissions(0o700) }
        await model.restore()
        #expect(R49AP01Protocol.deliveries.value[fixture.scenario] == nil)
        let retiredState = try #require(retired)
        #expect(retiredState.outgoingSyncClaim != nil)
        #expect(retiredState.neverSentDurationOperationIDs.isEmpty)
        switch fault {
        case .unchanged:
            #expect(try fixture.readState() == fixture.seed)
            #expect(model.snapshotLoadFailure == nil)
        case .concurrent:
            #expect(try fixture.readState() == concurrent)
            #expect(model.durationMinutes(for: .focus) == 35)
        case .writeDenied:
            #expect(try fixture.readState() == retiredState)
            #expect(model.snapshotLoadFailure == nil)
        case .replacementUncertain:
            #expect(try fixture.readState() == fixture.seed)
            #expect(model.snapshotLoadFailure != nil)
        }
        await Task.yield()
    }

    @Test
    func deliveryDiagnosticsHaveBoundedReasonsAndNoUserContent() {
        var budget = SyncFailureDiagnostics.Budget()
        var state = R48AP05BatchPlanTests().mixedState(count: 1)
        state.deviceId = "private-device"
        let diagnostic = SyncFailureDiagnostics(
            error: SharedCoreError.invalidResponse("private-payload-token"),
            stage: .reconciliation, rollback: .deliveryPossible, state: state
        )
        #expect(diagnostic.reason == .core)
        #expect(diagnostic.warrantsCapture)
        #expect(diagnostic.pending == [1, 1, 1, 1, 1])
        #expect(!diagnostic.localizedDescription.contains("private"))
        #expect(!diagnostic.localizedDescription.contains(state.pendingTaskOperations[0].title!))
        #expect(diagnostic.localizedDescription.contains("stage=reconciliation rollback=deliveryPossible"))
        #expect(diagnostic.localizedDescription.utf8.count < 400)
        let reported = (0..<20).filter { _ in budget.record(diagnostic) }.count
        #expect(reported == 3)
        let other = SyncFailureDiagnostics(error: AppError.invalidResponse, stage: .preSend,
                                          rollback: .snapshotChanged, state: state)
        let recordedOther = budget.record(other)
        #expect(recordedOther)
        for error: Error in [CancellationError(), URLError(.networkConnectionLost), AppError.invalidLocalClock,
                             AppError.server("private-server-message")] {
            let expected = SyncFailureDiagnostics(error: error, stage: .possibleDelivery,
                                                  rollback: .deliveryPossible, state: state)
            #expect(!expected.warrantsCapture)
            #expect(!expected.localizedDescription.contains("private"))
        }
    }
}

enum R49AP01Edit: CaseIterable, Sendable {
    case timer, task, duration, autoStart, selectedTask, mixed
}

enum R49AP01Failure: Sendable {
    case invalidRevision, invalidDecode, core, responseLoss, cancellation, valid
    static let allCases: [Self] = [.invalidRevision, .invalidDecode, .core, .responseLoss, .cancellation]
}

enum R49AP01PreSendFault: CaseIterable, Sendable {
    case unchanged, concurrent, writeDenied, replacementUncertain
}

@MainActor
private final class R49AP01ValidationFault {
    var action: (() throws -> Void)?
    func invoke() throws {
        guard let action else { return }
        self.action = nil
        try action()
        throw SharedCoreError.resourceMissing
    }
}

@MainActor
private struct R49AP01Fixture {
    let scenario = UUID().uuidString
    let suite = "R49AP01.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let session: URLSession
    let seed: PersistedTimerState
    let coreFailure = LockedTestValue(false)
    let replacementFailure = LockedTestValue(false)
    nonisolated static let date = Date(timeIntervalSince1970: 1_784_620_800)
    var store: AtomicDurableFileStore {
        let fail = replacementFailure
        return AtomicDurableFileStore(fileURL: directory.appendingPathComponent("workspace.json"), afterReplacement: {
            if fail.value { throw POSIXError(.EIO) }
        })
    }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R49AP01Protocol.self]
        configuration.httpAdditionalHeaders = ["X-R49AP01": scenario]
        session = URLSession(configuration: configuration)
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        let task = try #require(FocusTask(title: "Private selected task"))
        state.tasks = [task]
        state.knownTasks = [task]
        state.canonicalHeadWallMs = Int64(Self.date.timeIntervalSince1970 * 1_000) - 1_000
        state.canonicalHeadCounter = 0
        state.canonicalDurationsMs = .defaults
        state.pendingDurationOperations = [TestFixtures.durationOperation(
            id: "duration-already-claimed", phase: .focus, durationMs: 1_800_000,
            wallMs: state.canonicalHeadWallMs! + 1
        )]
        state.neverSentDurationOperationIDs = ["duration-already-claimed"]
        state.settings.focusMinutes = 30
        seed = state
        try store.write(JSONEncoder.api.encode(state))
    }

    func model(validation: R49AP01ValidationFault? = nil) -> AppModel {
        let fail = coreFailure
        let store = store
        return AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore(),
                           logoutRevocationStore: TestLogoutRevocationStore(),
                           wallNow: { Self.date }, uptime: { 100 }),
            defaults: defaults, durableLocalStore: store,
            roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
            now: { Self.date }, uptime: { 100 },
            sharedCoreProvider: {
                SharedCore(moduleURL: try SharedCore.bundledModuleURL(), freeResultValidator: { _ in
                    if fail.value { throw SharedCoreError.resourceMissing }
                    if let validation, let bytes = try store.read(),
                       try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes).outgoingSyncClaim != nil {
                        try MainActor.assumeIsolated { try validation.invoke() }
                    }
                })
            }
        )
    }

    func readState() throws -> PersistedTimerState {
        try JSONDecoder.api.decode(PersistedTimerState.self, from: #require(try store.read()))
    }

    func waitForDelivery() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while R49AP01Protocol.deliveries.value[scenario] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(R49AP01Protocol.deliveries.value[scenario])
    }

    func apply(_ edit: R49AP01Edit, to model: AppModel) async throws {
        switch edit {
        case .timer: model.start()
        case .task: #expect(await model.addTask("Private concurrent task"))
        case .duration: model.setDurationMinutes(35, for: .focus)
        case .autoStart: model.autoStartBreaks = true
        case .selectedTask: model.selectedTaskID = seed.tasks[0].id
        case .mixed:
            #expect(await model.addTask("Private concurrent task"))
            model.setDurationMinutes(35, for: .focus)
            model.autoStartBreaks = true
            model.start()
            model.selectedTaskID = seed.tasks[0].id
        }
        let current = try readState()
        #expect(current.neverSentCommandIDs == Set(current.pendingCommands.map(\.id)))
        #expect(current.neverSentTaskOperationIDs == Set(current.pendingTaskOperations.map(\.id)))
        #expect(current.neverSentDurationOperationIDs == Set(current.pendingDurationOperations.dropFirst().map(\.id)))
        #expect(current.neverSentAutoStartOperationIDs == Set(current.pendingAutoStartOperations.map { $0.id.uuidString.lowercased() }))
        #expect(current.neverSentSelectedTaskOperationIDs == Set(current.pendingSelectedTaskOperations.map { $0.id.uuidString.lowercased() }))
        #expect(current.lastUuidV7 != nil)
        #expect(current.nextSequence == seed.nextSequence + Int64(current.pendingCommands.count))
        switch edit {
        case .timer: #expect(current.pendingCommands.count == 1)
        case .task: #expect(current.pendingTaskOperations.count == 1)
        case .duration: #expect(current.pendingDurationOperations.count == 2)
        case .autoStart: #expect(current.pendingAutoStartOperations.count == 1)
        case .selectedTask: #expect(current.pendingSelectedTaskOperations.count == 1)
        case .mixed:
            #expect(current.pendingCommands.count == 2)
            #expect(current.pendingTaskOperations.count == 1)
            #expect(current.pendingDurationOperations.count == 2)
            #expect(current.pendingAutoStartOperations.count == 1)
            #expect(current.pendingSelectedTaskOperations.count == 1)
        }
    }

    func finish(_ failure: R49AP01Failure) {
        coreFailure.value = failure == .core
        R49AP01Protocol.deliveries.value[scenario]?.finish(failure)
    }

    func pendingCount(_ state: PersistedTimerState) -> Int {
        state.pendingCommands.count + state.pendingTaskOperations.count
            + state.pendingDurationOperations.count + state.pendingAutoStartOperations.count
            + state.pendingSelectedTaskOperations.count
    }

    func permissions(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        R49AP01Protocol.remove(scenario)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class R49AP01Protocol: URLProtocol, @unchecked Sendable {
    static let deliveries = LockedTestValue<[String: R49AP01Protocol]>([:])
    private static let registryLock = NSLock()
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var body: Data?

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-R49AP01") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.withLock { stopped = true } }

    override func startLoading() {
        if request.url?.path == "/api/v1/me" { respond(R48AP04StubProtocol.meBody); return }
        guard request.url?.path == "/api/v1/sync",
              let scenario = request.value(forHTTPHeaderField: "X-R49AP01") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        lock.withLock { body = Self.body(request) }
        Self.registryLock.withLock {
            var deliveries = Self.deliveries.value
            deliveries[scenario] = self
            Self.deliveries.value = deliveries
        }
    }

    func requestBody() -> Data? { lock.withLock { body } }

    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return body }
            body.append(buffer, count: count)
        }
    }

    static func remove(_ scenario: String) {
        registryLock.withLock {
            var current = deliveries.value
            current.removeValue(forKey: scenario)
            deliveries.value = current
        }
    }

    func finish(_ failure: R49AP01Failure) {
        lock.withLock {
            guard !stopped else { return }
            switch failure {
            case .responseLoss: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .cancellation: client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            case .invalidDecode: respond(Data("{}".utf8))
            case .invalidRevision, .core, .valid:
                var response = try! JSONSerialization.jsonObject(with: R48AP04StubProtocol.pausedResponse(revision: 1)) as! [String: Any]
                response["canonicalTimer"] = NSNull()
                response["revision"] = failure == .invalidRevision ? -1 : 1
                if failure == .valid {
                    let claim = try! JSONDecoder.api.decode(SyncRequest.self, from: body!)
                    response["durationAcknowledgements"] = claim.durationOperations.map {
                        ["operationId": $0.id, "outcome": "applied", "reason": ""]
                    }
                    response["durationsMs"] = ["focus": 1_800_000, "short_break": 300_000, "long_break": 900_000]
                }
                respond(try! JSONSerialization.data(withJSONObject: response))
            }
        }
    }

    private func respond(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
