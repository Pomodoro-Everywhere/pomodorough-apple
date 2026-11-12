import Foundation
import Sentry
import Testing
@testable import Pomodorough

// R54-L04: each tagged capture site keeps its static operation through the
// real SDK transport. Every test drives the production call site, so a site
// that loses or swaps its tag, or a SentryCapture entry point that drops the
// operation on the way to the hook, changes the transported envelope.
@Suite("R54-L04 tagged boundary sites", .serialized)
struct BoundarySiteTests {
    @Test
    func admissionFailuresKeepMutationBoundaryThroughTransport() async throws {
        let run = try await admissionFailures()
        // Witness: the rejected admission reached the person as the authored
        // sentence (UX round 2 B4); the Core reason stays on the log path.
        #expect(run.rejectedMessage == "The change was not saved. Try again.")
        // The ignored-retarget branch captures without replacing the user message.
        #expect(run.retargetMessage == nil)
        try #require(run.rejected.count == 1 && run.retarget.count == 1)
        // R54-L07: the hook input keeps the case name, category, and counts, never the Core reason.
        #expect(run.rejected[0].localizedDescription.hasPrefix("WorkspaceIntent.coreRejected category="))
        assertNoPayload(in: run.rejected[0].localizedDescription)
        assertNoPayload(in: run.retarget[0].localizedDescription)
        let rejected = try captureThroughOfflineSDK { $0.capture(error: run.rejected[0], scope: Scope()) }
        expectEnvelope(rejected, operation: "mutation.failure", identity: "WorkspaceIntent.coreRejected", code: 0)
        let retarget = try captureThroughOfflineSDK { $0.capture(error: run.retarget[0], scope: Scope()) }
        expectEnvelope(retarget, operation: "mutation.failure", identity: "WorkspaceIntent.ignoredRetarget", code: 2)
    }

    @Test
    func launchJournalLoadFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let run = try await launchJournalLoadFailure()
        #expect(String(describing: run.witness).contains("l04-workspace-canary"))
        try #require(run.captures.count == 1, "expected one capture, got \(run.captures.count)")
        let sent = try captureThroughOfflineSDK { $0.capture(error: run.captures[0], scope: Scope()) }
        expectEnvelope(sent, operation: "persistence.failure", identity: run.witness.domain, code: run.witness.code)
    }

    @Test
    func journalSaveFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let run = try await deletionJournalFailure(.save)
        try #require(run.captures.count == 1, "expected one capture, got \(run.captures.count)")
        let sent = try captureThroughOfflineSDK { $0.capture(error: run.captures[0], scope: Scope()) }
        expectEnvelope(sent, operation: "persistence.failure", identity: "NSCocoaErrorDomain", code: 512)
    }

    @Test
    func journalPriorLoadFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let run = try await deletionJournalFailure(.priorLoad)
        let witness = try #require(run.witness)
        #expect(String(describing: witness).contains("l04-workspace-canary"))
        try #require(run.captures.count == 1, "expected one capture, got \(run.captures.count)")
        let sent = try captureThroughOfflineSDK { $0.capture(error: run.captures[0], scope: Scope()) }
        expectEnvelope(sent, operation: "persistence.failure", identity: witness.domain, code: witness.code)
    }

    @Test
    func journalVerifyLoadFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let run = try await deletionJournalFailure(.verifyLoad)
        let witness = try #require(run.witness)
        #expect(String(describing: witness).contains("l04-workspace-canary"))
        // The replacement cannot land on a directory, so the save capture comes first.
        try #require(run.captures.count == 2, "expected two captures, got \(run.captures.count)")
        let save = try captureThroughOfflineSDK { $0.capture(error: run.captures[0], scope: Scope()) }
        expectEnvelope(save, operation: "persistence.failure", identity: "NSPOSIXErrorDomain", code: Int(EISDIR))
        let verify = try captureThroughOfflineSDK { $0.capture(error: run.captures[1], scope: Scope()) }
        expectEnvelope(verify, operation: "persistence.failure", identity: witness.domain, code: witness.code)
    }

    @Test
    func recurringBatchPlanCaptureKeepsBootstrapBoundaryThroughTransport() async throws {
        let captures = try await batchPlanFailures(attempts: 4)
        try #require(captures.count == 3, "captureRecurring limit is 3, got \(captures.count)")
        for capture in captures {
            let sent = try captureThroughOfflineSDK { $0.capture(error: capture, scope: Scope()) }
            expectEnvelope(sent, operation: "bootstrap.failure", identity: "Bootstrap.batchPlan", code: 1)
        }
    }

    @Test
    func didNotWinFinishKeepsMutationBoundaryThroughTransport() async throws {
        let run = try await didNotWinFinish()
        // Witness: the historical throw reaches the user as the authored
        // workspace sentence, never as its internal text. The envelope
        // below pins the throw itself by identity and code.
        let historical = SharedCoreError.invalidResponse("new synchronized mutation did not win Core projection")
        #expect(run.message == UserFacingFailure.sentence(for: historical, during: .changeWorkspace))
        #expect(run.message?.contains("did not win") == false)
        try #require(run.captures.count == 1, "expected one capture, got \(run.captures.count)")
        let sent = try captureThroughOfflineSDK { $0.capture(error: run.captures[0], scope: Scope()) }
        expectEnvelope(sent, operation: "mutation.failure", identity: "SharedCoreError.invalidResponse", code: 10)
    }
}

// Collects what SentryCapture hands SentrySDK.capture(error:).
private final class RecordedCaptures: Sendable {
    private let recorded = LockedTestValue<[any Error]>([])

    init() {
        SentryCapture.resetForTesting()
        let recorded = recorded
        SentryCapture.setTestBackend { recorded.value = recorded.value + [$0] }
    }

    var errors: [any Error] { recorded.value }
}

@MainActor
private struct TemporaryWorkspace {
    nonisolated static let launchDate = Date(timeIntervalSince1970: 1_710_000_001)
    let directory: URL
    let suite = "PomodoroughTests.R54L04Sites.\(UUID().uuidString)"
    let defaults: UserDefaults
    var store: AtomicDurableFileStore { .init(fileURL: directory.appendingPathComponent("workspace.json")) }
    var journalURL: URL { directory.appendingPathComponent("deletion.json") }

    // The directory name is a path canary: system file errors carry it.
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("R54L04Sites-l04-workspace-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func seed(_ state: PersistedTimerState) throws {
        try store.write(JSONEncoder.api.encode(state))
    }

    // The clock runs `elapsed` seconds past the seeded snapshots.
    func model(
        elapsed: TimeInterval,
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore = { try SharedCore.bundled() }
    ) -> AppModel {
        AppModel(api: APIClient(keychain: EmptyTokenStore()), defaults: defaults, durableLocalStore: store,
                 roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
                 alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
                 now: { Self.launchDate.addingTimeInterval(elapsed) }, uptime: { 100 + elapsed },
                 sharedCoreProvider: sharedCoreProvider)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func siteController() -> SynchronizedWorkspaceMutationController {
    SynchronizedWorkspaceMutationController(
        timerSessionController: TimerSessionController { try SharedCore.bundled() },
        timerIDProvider: { "timer-r54-l04-sites" }
    )
}

private func siteSnapshot(_ state: PersistedTimerState) -> SynchronizedWorkspaceMutationController.Snapshot {
    SynchronizedWorkspaceMutationController.Snapshot(
        state: state, canonicalTimer: state.canonicalTimer, tasks: state.tasks,
        projectedAutoStartBreaks: state.autoStartBreaks, projectedSelectedTaskID: state.selectedTaskID,
        replicationMode: .centralized, localDate: TemporaryWorkspace.launchDate,
        trustedClockUptime: 100, isWorkspaceMutationBlocked: false
    )
}

// Claims the queued operations for upload, as a sync in flight leaves them.
@MainActor
private func claimedForUpload(_ state: PersistedTimerState) throws -> PersistedTimerState {
    let sync = AccountSynchronization(api: APIClient(keychain: EmptyTokenStore()),
        sharedCoreProvider: { try SharedCore.bundled() })
    let result = try sync.prepareSyncPlan(state: state)
    try #require(!result.plan.batch.isEmpty)
    return result.retired
}

// A duration change and a selection are in flight, so new edits of either
// queue behind them and reach durable admission instead of winning projection.
@MainActor
private func admissionFailures() throws
    -> (rejected: [any Error], rejectedMessage: String?, retarget: [any Error], retargetMessage: String?) {
    let workspace = try TemporaryWorkspace()
    defer { workspace.remove() }
    let tasks = [try #require(FocusTask(title: "L04 Secret Task Title A")),
                 try #require(FocusTask(title: "L04 Secret Task Title B"))]
    var state = PersistedTimerState.fresh()
    state.tasks = tasks
    state.knownTasks = tasks
    let controller = siteController()
    state = try #require(try controller.plan(.setDurationMinutes(30, for: .focus), from: siteSnapshot(state))).state
    state = try #require(try controller.plan(.selectTask(tasks[1].id), from: siteSnapshot(state))).state
    try workspace.seed(try claimedForUpload(state))
    // Each entry answers one provider call: nil is a healthy Core, a reason is
    // a Core whose buffer release fails with that reason.
    let script = LockedTestValue<[String?]>([])
    let model = workspace.model(elapsed: 10, sharedCoreProvider: {
        guard let next = script.value.first else { return try SharedCore.bundled() }
        script.value = Array(script.value.dropFirst())
        guard let reason = next else { return try SharedCore.bundled() }
        return SharedCore(moduleURL: try SharedCore.bundledModuleURL(), freeResultValidator: { _ in
            throw SharedCoreError.core(reason)
        })
    })
    // Load the projection Core first; admission asks the provider on every plan.
    #expect(model.rebuildOptimisticState())
    model.errorMessage = nil
    defer { SentryCapture.resetForTesting() }
    // Request building ticks the clock on its own Core before the intent dispatch.
    let rejected = RecordedCaptures()
    script.value = [nil, CoreDiagnosticIdentityTests.payload]
    #expect(model.setDurationMinutes(35, for: .focus) == false)
    #expect(script.value.isEmpty)
    let rejectedMessage = model.errorMessage
    model.errorMessage = nil
    let retarget = RecordedCaptures()
    script.value = [nil, "workspace group failed retained-ledger admission \(CoreDiagnosticIdentityTests.payload)"]
    model.selectedTaskID = tasks[0].id
    #expect(script.value.isEmpty)
    return (rejected.errors, rejectedMessage, retarget.errors, model.errorMessage)
}

// The deletion journal path is a directory, so the launch-time load throws.
@MainActor
private func launchJournalLoadFailure() throws -> (captures: [any Error], witness: NSError) {
    let workspace = try TemporaryWorkspace()
    defer { workspace.remove() }
    try FileManager.default.createDirectory(at: workspace.journalURL, withIntermediateDirectories: false)
    let journal = AccountDeletionJournal(fileURL: workspace.journalURL)
    let witness = try #require(journalLoadError(journal))
    defer { SentryCapture.resetForTesting() }
    let captures = RecordedCaptures()
    let model = AppModel(
        api: APIClient(keychain: EmptyTokenStore()), defaults: workspace.defaults,
        accountDeletionJournal: journal,
        roomStore: TestFixtures.emptyIrohRoomStore(in: workspace.directory),
        alarmScheduler: RecordingAlarmScheduler()
    )
    // An unreadable journal recovers as a prepared deletion.
    #expect(model.hasPendingAccountDeletionRecovery)
    return (captures.errors, witness)
}

private func journalLoadError(_ journal: AccountDeletionJournal) -> NSError? {
    do {
        _ = try journal.load()
        return nil
    } catch {
        return error as NSError
    }
}

private enum JournalFailure {
    case save, priorLoad, verifyLoad
}

// Drives deleteAccount into reconcileJournalSave with one failing step.
@MainActor
private func deletionJournalFailure(_ failure: JournalFailure) async throws
    -> (captures: [any Error], witness: NSError?) {
    let workspace = try TemporaryWorkspace()
    defer { workspace.remove() }
    let session = TestFixtures.session(for: "apple-api-coverage-account-delete-success")
    defer { session.invalidateAndCancel() }
    var state = PersistedTimerState.fresh()
    state.cachedUser = TestFixtures.user
    workspace.defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
    let journalURL = workspace.journalURL
    let journal = AccountDeletionJournal(fileURL: journalURL, beforeSave: { _ in
        switch failure {
        case .save:
            throw NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [
                NSLocalizedDescriptionKey: CoreDiagnosticIdentityTests.payload,
                NSFilePathErrorKey: journalURL.path
            ])
        case .verifyLoad:
            try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        case .priorLoad:
            break
        }
    })
    let model = AppModel(
        api: APIClient(session: session, keychain: StaticTokenStore()), defaults: workspace.defaults,
        accountDeletionJournal: journal, durableLocalStore: workspace.store,
        roomStore: TestFixtures.emptyIrohRoomStore(in: workspace.directory),
        alarmScheduler: RecordingAlarmScheduler()
    )
    await model.restore()
    if failure == .priorLoad {
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
    }
    defer { SentryCapture.resetForTesting() }
    let captures = RecordedCaptures()
    await model.deleteAccount(confirmation: "DELETE")
    #expect(model.errorMessage == "Account deletion paused because its recovery state could not be saved.")
    // The load witness is the system error a later load still throws.
    return (captures.errors, journalLoadError(journal))
}

@MainActor
private func batchPlanFailures(attempts: Int) throws -> [any Error] {
    defer { SentryCapture.resetForTesting() }
    let captures = RecordedCaptures()
    let lifecycle = AccountLifecycleController(api: APIClient(),
        googleIdentityProvider: RecordingGoogleIdentityProvider())
    for _ in 0..<attempts {
        let failure = SyncBatchPlanError.invalidResponse(CoreDiagnosticIdentityTests.payload)
        let transition = lifecycle.bootstrapFailure(failure, stage: .preflight)
        #expect(transition.historyResolutionState == .retryable(nil))
    }
    return captures.errors
}

// The server already shows the timer running while its start is still in
// flight. A finish queued behind the sent start does not win projection, and
// the commit path has no durable admission kind, so the historical throw
// reaches performWorkspaceMutation's catch-all.
@MainActor
private func didNotWinFinish() throws -> (captures: [any Error], message: String?) {
    let workspace = try TemporaryWorkspace()
    defer { workspace.remove() }
    let started = try #require(try siteController().plan(.startTimer, from: siteSnapshot(.fresh())))
    var state = try claimedForUpload(started.state)
    state.canonicalTimer = try #require(started.projection?.canonicalTimer)
    try workspace.seed(state)
    let model = workspace.model(elapsed: 60)
    try #require(model.canonicalTimer?.status == .running, "seeded start must project as running")
    model.errorMessage = nil
    defer { SentryCapture.resetForTesting() }
    let captures = RecordedCaptures()
    #expect(model.finish() == false)
    return (captures.errors, model.errorMessage)
}
