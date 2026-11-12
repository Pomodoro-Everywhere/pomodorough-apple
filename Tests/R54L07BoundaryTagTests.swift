import Foundation
import Sentry
import Testing
@testable import Pomodorough

// R54-L07: Core, persistence, and alarm failures captured in AppModel and the
// centralized coordinator keep their static boundary through the real SDK
// transport, and admission and bootstrap-install failures keep a finite
// identity. Before this fix those sites reported application.failure and
// OtherError. Every test drives the production call site, except the two
// classification tests at the end, which pin the identity table itself.
@Suite("R54-L07 boundary tags", .serialized)
struct BoundaryTagTests {
    static var coreFailure: SharedCoreError { .core(CoreDiagnosticIdentityTests.payload) }

    @Test @MainActor
    func addTaskCoreFailureKeepsMutationBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("AddTask")
        defer { workspace.remove() }
        let model = workspace.model(sharedCoreProvider: { throw Self.coreFailure })
        try #require(!model.isWorkspaceMutationBlocked)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        #expect(await model.addTask("L04 Secret Task Title") == false)
        // Witness: the failure reached the person as the authored add-task
        // sentence (UX round 2 B4); the Core payload stays off that path.
        #expect(model.errorMessage == "The task was not added. Try again.")
        try expectSingle(captures, operation: "mutation.failure", identity: "SharedCoreError.core", code: 9)
    }

    @Test @MainActor
    func irohCompletionCoreFailureKeepsTimerBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("IrohCompletion")
        defer { workspace.remove() }
        let model = workspace.model(sharedCoreProvider: { throw Self.coreFailure })
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        model.completeIrohTimerIfNeeded(
            TestFixtures.timer(status: .running, elapsed: 1_000), at: TestFixtures.anchor
        )
        #expect(model.errorMessage == "The timer change was not saved. Try again.")
        try expectSingle(captures, operation: "timer.failure", identity: "SharedCoreError.core", code: 9)
    }

    @Test @MainActor
    func nextBreakPhaseCoreFailureKeepsTimerBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("NextBreak")
        defer { workspace.remove() }
        let model = workspace.model(sharedCoreProvider: { throw Self.coreFailure })
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        // The fallback keeps the stored selection.
        #expect(model.nextBreakPhase() == .focus)
        try expectSingle(captures, operation: "timer.failure", identity: "SharedCoreError.core", code: 9)
    }

    @Test @MainActor
    func timerFinishReportersKeepTimerBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("FinishReporters")
        defer { workspace.remove() }
        let model = workspace.model()
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        model.reportFinishPlanFailure(Self.coreFailure)
        model.reportCentralizedBreakFailure(Self.coreFailure)
        model.reportIrohBreakFailure(Self.coreFailure)
        model.reportCompletionDeadlineFailure(Self.coreFailure)
        // Each reporter owns its own captureOnce key, so all four reach the backend.
        try #require(captures.errors.count == 4, "expected four captures, got \(captures.errors.count)")
        for capture in captures.errors {
            let sent = try captureThroughOfflineSDK { $0.capture(error: capture, scope: Scope()) }
            expectEnvelope(sent, operation: "timer.failure", identity: "SharedCoreError.core", code: 9)
        }
    }

    @Test @MainActor
    func roomSecretPurgeFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("Purge")
        defer { workspace.remove() }
        let secrets = MemoryIrohRoomSecretStore(secrets: ["stuck-room-secret": Data(repeating: 3, count: 32)])
        secrets.setDeleteFailure(true, roomID: "stuck-room-secret")
        let roomStore = IrohRoomStore(
            fileURL: workspace.directory.appendingPathComponent("rooms.json"), secretStore: secrets
        )
        let model = workspace.model(roomStore: roomStore)
        workspace.defaults.set(try JSONEncoder().encode([String]()), forKey: "account-deletion-room-ids-v1")
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        await model.finishConfirmedAccountDeletion()
        #expect(model.errorMessage?.contains("room cleanup") == true)
        let witness = URLError(.cannotRemoveFile) as NSError
        try expectSingle(captures, operation: "persistence.failure", identity: witness.domain, code: witness.code)
    }

    @Test @MainActor
    func deletionRoomIDsDecodeFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("RoomIDsDecode")
        defer { workspace.remove() }
        let corrupt = Data("secret-room-corrupt".utf8)
        let witness = try #require(roomIDsDecodeError(corrupt))
        workspace.defaults.set(corrupt, forKey: "account-deletion-room-ids-v1")
        let model = workspace.model()
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        await model.finishConfirmedAccountDeletion()
        #expect(model.errorMessage?.contains("room cleanup") == true)
        try expectSingle(captures, operation: "persistence.failure", identity: witness.domain, code: witness.code)
    }

    @Test @MainActor
    func launchTopologyFailureKeepsPersistenceBoundaryThroughTransport() throws {
        let workspace = try TagWorkspace("LaunchTopology")
        defer { workspace.remove() }
        let journalURL = workspace.directory.appendingPathComponent("account-deletion-v1.json")
        try Data("corrupt-journal".utf8).write(to: journalURL)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        // A corrupt journal makes launch rebuild the prepared topology from the room store.
        let model = workspace.model(
            roomStore: accountListingFailureRoomStore(in: workspace.directory),
            accountDeletionJournal: AccountDeletionJournal(fileURL: journalURL)
        )
        #expect(model.hasPendingAccountDeletionRecovery)
        try expectSingle(captures, operation: "persistence.failure", identity: "NSPOSIXErrorDomain", code: Int(EACCES))
    }

    @Test @MainActor
    func resumeTopologyFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("ResumeTopology")
        defer { workspace.remove() }
        workspace.defaults.set("prepared", forKey: "account-deletion-state-v1")
        let model = workspace.model(roomStore: accountListingFailureRoomStore(in: workspace.directory))
        try #require(model.hasPendingAccountDeletionRecovery)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        await model.restore()
        #expect(model.errorMessage == "Account deletion paused because its recovery state could not be saved.")
        try expectSingle(captures, operation: "persistence.failure", identity: "NSPOSIXErrorDomain", code: Int(EACCES))
    }

    @Test @MainActor
    func deleteAccountTopologyFailureKeepsPersistenceBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("DeleteTopology")
        defer { workspace.remove() }
        let session = TestFixtures.session(for: "apple-api-coverage-account-delete-success")
        defer { session.invalidateAndCancel() }
        var state = PersistedTimerState.fresh()
        state.cachedUser = TestFixtures.user
        workspace.defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        let model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()), defaults: workspace.defaults,
            roomStore: accountListingFailureRoomStore(in: workspace.directory),
            alarmScheduler: RecordingAlarmScheduler()
        )
        await model.restore()
        try #require(model.isSignedIn)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        await model.deleteAccount(confirmation: "DELETE")
        #expect(model.errorMessage == "Account deletion paused because its recovery state could not be saved.")
        // The topology read fails before any recovery state or remote call.
        #expect(!model.hasPendingAccountDeletionRecovery)
        try expectSingle(captures, operation: "persistence.failure", identity: "NSPOSIXErrorDomain", code: Int(EACCES))
    }

    // Each refused key fails one durable write in the offline reset tail.
    @Test(arguments: [
        ("replication-mode-v1", "continue recovery-state cleanup"),
        ("account-deletion-room-ids-v1", "continue room cleanup"),
        ("account-deletion-state-v1", "continue recovery-state cleanup")
    ]) @MainActor
    func offlineResetWriteFailureKeepsPersistenceBoundaryThroughTransport(
        refusedKey: String, message: String
    ) async throws {
        let workspace = try TagWorkspace("OfflineReset") { RefusingDefaults(suiteName: $0) }
        defer { workspace.remove() }
        let defaults = try #require(workspace.defaults as? RefusingDefaults)
        defaults.set(try JSONEncoder().encode([String]()), forKey: "account-deletion-room-ids-v1")
        defaults.set("remote_committed", forKey: "account-deletion-state-v1")
        // Refuse from launch on, so no earlier write can satisfy the read-back.
        defaults.refusedKey = refusedKey
        let model = workspace.model()
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        await model.finishConfirmedAccountDeletion()
        #expect(model.errorMessage?.contains(message) == true)
        // Only the deletion-state row gets past the room-ID clear.
        #expect((defaults.object(forKey: "account-deletion-room-ids-v1") == nil)
            == (refusedKey == "account-deletion-state-v1"))
        // The step error type is private to AppModel; a local struct witnesses its bridged code.
        let witness = DurableWriteWitness() as NSError
        try expectSingle(captures, operation: "persistence.failure", identity: "OtherError", code: witness.code)
    }

    @Test @MainActor
    func alarmAuthorizationFailureKeepsTimerBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("AlarmAuthorization")
        defer { workspace.remove() }
        let alarms = RecordingAlarmScheduler()
        alarms.authorizationError = URLError(.notConnectedToInternet)
        let model = workspace.model(alarmScheduler: alarms)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        await model.allowTimerAlerts()
        #expect(alarms.operations == [.requestAuthorization])
        let witness = URLError(.notConnectedToInternet) as NSError
        try expectSingle(captures, operation: "timer.failure", identity: witness.domain, code: witness.code)
    }

    @Test @MainActor
    func alarmScheduleFailureKeepsTimerBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("AlarmSchedule")
        defer { workspace.remove() }
        let alarms = RecordingAlarmScheduler()
        alarms.schedulingError = URLError(.notConnectedToInternet)
        let model = workspace.model(alarmScheduler: alarms)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        try #require(model.start())
        await model.waitForAlarmOperations()
        // Alarm failures stay silent: the timer keeps running in the app.
        #expect(model.errorMessage == nil)
        let witness = URLError(.notConnectedToInternet) as NSError
        try expectSingle(captures, operation: "timer.failure", identity: witness.domain, code: witness.code)
    }

    @Test @MainActor
    func centralizedCoreSyncFailureKeepsSyncBoundaryThroughTransport() throws {
        let tagWorkspace = try TagWorkspace("CentralizedSync")
        defer { tagWorkspace.remove() }
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        let user = User(id: "l07-user", email: "private@example.test", name: "L07", avatarUrl: "")
        let coordinator = makeCoordinator(.init(sessionState: .signedIn(user)), defaults: tagWorkspace.defaults)
        let lease = CentralizedAccountSessionCoordinator.SyncLease(
            id: UUID(), operation: coordinator.currentOperation, modeGeneration: 0, showsActivity: false
        )
        let workspace = CentralizedAccountSessionCoordinator.Workspace(
            state: .fresh(), replicationMode: .centralized, modeGeneration: 0, isMutationBlocked: false
        )
        let failure = coordinator.syncFailure(Self.coreFailure, lease: lease, workspace: workspace, pendingChangeCount: 3)
        #expect(failure.action == .blocksFollowUp)
        try expectSingle(captures, operation: "sync.failure", identity: "SharedCoreError.core", code: 9)
    }

    @Test @MainActor
    func syncBoundaryFailureKeepsSyncBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("SyncBoundary")
        defer { workspace.remove() }
        let scenario = "r54-l07-sync-boundary-\(UUID().uuidString)"
        R48AP04StubState.shared.configure(scenario: scenario, mode: .succeed)
        let store = AtomicDurableFileStore(fileURL: workspace.directory.appendingPathComponent("workspace.json"))
        try store.write(JSONEncoder.api.encode(deviceMismatchedClaimState()))
        let model = syncBoundaryModel(workspace: workspace, store: store, scenario: scenario)
        await model.restore()
        defer { SentryCapture.resetForTesting() }
        // Restore replays the saved claim once; record only the forced sync.
        let captures = RecordedCaptures()
        #expect(await model.sync(force: true) == false)
        #expect(R48AP04StubState.shared.postCount(for: scenario) == 0)
        let description = try #require(captures.errors.first).localizedDescription
        #expect(description.contains("stage=preSend rollback=notEligible reason=batch"))
        #expect(!description.contains("secret-device-r54-l07"))
        let witness = SyncFailureDiagnostics(
            error: SyncBatchPlanError.invalidResponse("witness"), stage: .preSend,
            rollback: .notEligible, state: .fresh()
        ) as NSError
        try expectSingle(captures, operation: "sync.failure", identity: "Sync.boundary", code: witness.code)
    }

    @Test @MainActor
    func bootstrapInstallFailureKeepsIdentityAndBootstrapBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("BootstrapInstall")
        defer { workspace.remove() }
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        let model = try bootstrapInstallModel(workspace: workspace)
        await model.restore()
        await model.waitForAlarmOperations()
        // The install write fails after its rename, so the install is uncertain.
        #expect(model.snapshotLoadFailure != nil)
        let installs = captures.errors.filter {
            $0.localizedDescription.hasPrefix("bootstrap stage=install outcome=uncertain")
        }
        try #require(installs.count == 1, "expected one install capture, got \(installs.count)")
        let witness = BootstrapInstallDiagnostics(outcome: .uncertain, quarantined: true, pendingOperations: 0)
            as NSError
        let sent = try captureThroughOfflineSDK { $0.capture(error: installs[0], scope: Scope()) }
        expectEnvelope(sent, operation: "bootstrap.failure", identity: "Bootstrap.install", code: witness.code)
    }

    @Test @MainActor
    func legacyReceiptCheckFailureKeepsPersistenceBoundaryThroughTransport() throws {
        let workspace = try TagWorkspace("LegacyReceipt")
        defer { workspace.remove() }
        let fixture = try undecodableReceiptFixture(in: workspace.directory)
        // Witness: the receipt matches its source, but the source bytes are not a
        // task snapshot, so receipt validation fails to decode them.
        let witness = try #require(receiptCheckError(fixture.store, source: fixture.source)) as NSError
        #expect(witness.domain == NSCocoaErrorDomain)
        let coordinator = legacyCoordinator(fixture, state: fixture.stored, defaults: workspace.defaults)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        #expect(coordinator.containsCommittedLegacyRecords(fixture.stored, in: fixture.stored) == false)
        try expectSingle(captures, operation: "persistence.failure", identity: NSCocoaErrorDomain, code: witness.code)
    }

    @Test @MainActor
    func legacyRecordsCheckFailureKeepsPersistenceBoundaryThroughTransport() throws {
        let workspace = try TagWorkspace("LegacyRecords")
        defer { workspace.remove() }
        let fixture = try missingRecordFixture(in: workspace.directory)
        let coordinator = legacyCoordinator(fixture, state: fixture.migrated, defaults: workspace.defaults)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        #expect(coordinator.containsCommittedLegacyRecords(fixture.migrated, in: fixture.stored) == false)
        // The receipt is committed, so the failure is the missing second record.
        let witness = IrohProtocolError.notFound as NSError
        try expectSingle(captures, operation: "persistence.failure", identity: "OtherError", code: witness.code)
    }

    @Test
    func admissionCasesKeepFiniteIdentityAndDropCoreReason() throws {
        let diagnostics = WorkspaceMutationDiagnostics(
            category: .taskUpsert, coreReason: CoreDiagnosticIdentityTests.payload,
            pendingCommands: 1, pendingTasks: 2, pendingDurations: 3, pendingAutoStart: 4,
            pendingSelected: 5, queued: 6, applied: 7, isIgnoredRetarget: false,
            provenance: "core=l04-workspace-canary"
        )
        let cases: [(WorkspaceIntentAdmissionError, String, Int)] = [
            (.coreRejected(diagnostics), "WorkspaceIntent.coreRejected", 0),
            (.invalidCoreResponse(diagnostics), "WorkspaceIntent.invalidCoreResponse", 1),
            (.ignoredRetarget(diagnostics), "WorkspaceIntent.ignoredRetarget", 2)
        ]
        for (error, identity, code) in cases {
            #expect(DiagnosticPrivacy.identities.contains(identity))
            #expect(DiagnosticPrivacy.identity(error) == identity)
            let diagnostic = DiagnosticPrivacy.diagnostic(error, operation: .mutation)
            // The log line and the hook input carry counts and the static category only.
            #expect(diagnostic.localizedDescription
                == "\(identity) category=taskUpsert pending=1/2/3/4/5 queued=6 applied=7")
            assertNoPayload(in: DiagnosticPrivacy.publicSummary(error))
            let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
            expectEnvelope(sent, operation: "mutation.failure", identity: identity, code: code)
            // An automatic event built from the raw error keeps the same identity.
            let raw = try captureThroughOfflineSDK { $0.capture(error: error, scope: Scope()) }
            expectEnvelope(raw, operation: "application.failure", identity: identity, code: code)
        }
    }

    @Test
    func errorDomainsSpellingFixedIdentitiesCollapseToOtherError() throws {
        let spelled = ["SharedCoreError.core", "AppError.server", "Sync.boundary",
                       "WorkspaceIntent.coreRejected", "Bootstrap.install", "SignOut.stage"]
        for domain in spelled {
            let forged = NSError(domain: domain, code: 4, userInfo: [
                NSLocalizedDescriptionKey: CoreDiagnosticIdentityTests.payload
            ])
            #expect(DiagnosticPrivacy.identity(forged) == "OtherError", "\(domain) kept its spelling")
            let sent = try captureThroughOfflineSDK { $0.capture(error: forged, scope: Scope()) }
            expectEnvelope(sent, operation: "application.failure", identity: "OtherError", code: 4)
        }
        // Controls: system domains keep their names, so each forgery fails on the domain allowlist alone.
        for domain in [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, "WCErrorDomain"] {
            let system = NSError(domain: domain, code: 4, userInfo: [
                NSLocalizedDescriptionKey: CoreDiagnosticIdentityTests.payload
            ])
            #expect(DiagnosticPrivacy.identity(system) == domain)
            let sent = try captureThroughOfflineSDK { $0.capture(error: system, scope: Scope()) }
            expectEnvelope(sent, operation: "application.failure", identity: domain, code: 4)
        }
    }
}

// R54-L08 and R54-L09: the renameTask Core catch and the fixed-taxonomy Watch
// captures in AppModel name their own boundary through the real SDK
// transport. Before this fix each sent application.failure, the AppModel file
// default. The Watch refusal cases seed an account-switch fence, so the timer
// control itself refuses after the Watch target checks pass.
@Suite("R54-L08/L09 boundary tags", .serialized)
struct FixedTaxonomyBoundaryTagTests {
    struct WatchRefusal: Sendable, CustomTestStringConvertible {
        let command: String
        let status: CanonicalTimer.Status?
        let identity: String
        var testDescription: String { command }
    }

    static let watchRefusals = [
        WatchRefusal(command: "start", status: nil, identity: "WatchRefusal.start"),
        WatchRefusal(command: "pause", status: .running, identity: "WatchRefusal.pause"),
        WatchRefusal(command: "resume", status: .paused, identity: "WatchRefusal.resume"),
        WatchRefusal(command: "finish", status: .running, identity: "WatchRefusal.finish")
    ]

    @Test @MainActor
    func renameTaskCoreFailureKeepsMutationBoundaryThroughTransport() async throws {
        let workspace = try TagWorkspace("Rename")
        defer { workspace.remove() }
        let model = workspace.model()
        try #require(await model.addTask("L08 Rename Source"))
        let task = try #require(model.tasks.first)
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        // Core rejects a 621-byte title; the title never reaches the envelope.
        let title = "L08-RENAME-CANARY-" + String(repeating: "x", count: 603)
        #expect(await model.renameTask(id: task.id, title: title) == false)
        try expectSingle(captures, operation: "mutation.failure", identity: "SharedCoreError.core", code: 9)
        let sent = try captureThroughOfflineSDK { $0.capture(error: captures.errors[0], scope: Scope()) }
        #expect(!sent.text.contains("L08-RENAME-CANARY"))
    }

    @Test @MainActor
    func unknownWatchCommandKeepsWatchBoundaryThroughTransport() throws {
        let workspace = try TagWorkspace("WatchUnknown")
        defer { workspace.remove() }
        let model = workspace.model()
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        var unknown = WatchTimerCommand.start()
        unknown.name = "l09-unknown-command"
        #expect(model.applyWatchCommand(unknown) == false)
        try expectSingle(captures, operation: "watch.failure", identity: "WatchCommand.unknown", code: 1)
    }

    @Test @MainActor
    func staleWatchWorkspaceKeepsWatchBoundaryThroughTransport() throws {
        let workspace = try TagWorkspace("WatchStale")
        defer { workspace.remove() }
        let model = workspace.model()
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        let stale = WatchTimerCommand(
            workspaceGeneration: UUID(), name: "selectPhase",
            phase: TimerPhase.shortBreak.rawValue, sentAt: TestFixtures.anchor
        )
        #expect(model.applyWatchCommand(stale) == false)
        try expectSingle(captures, operation: "watch.failure", identity: "WatchCommand.staleWorkspace", code: 1)
    }

    @Test(arguments: FixedTaxonomyBoundaryTagTests.watchRefusals) @MainActor
    func refusedWatchCommandKeepsWatchBoundaryThroughTransport(_ refusal: WatchRefusal) throws {
        let workspace = try TagWorkspace("WatchRefusal\(refusal.command)")
        defer { workspace.remove() }
        let model = try fencedModel(workspace, status: refusal.status)
        let revision = model.makeWatchSnapshot().timerRevision
        try #require((revision == nil) == (refusal.status == nil))
        let command = WatchTimerCommand(
            timerId: revision?.timerId, expectedTimerRevision: revision,
            name: refusal.command, sentAt: TestFixtures.anchor
        )
        defer { SentryCapture.resetForTesting() }
        let captures = RecordedCaptures()
        #expect(model.applyWatchCommand(command) == false)
        #expect(model.canonicalTimer?.status == refusal.status)
        try expectSingle(captures, operation: "watch.failure", identity: refusal.identity, code: 1)
    }

    // Pins the identity, the allowlist entry, and the public summary. Since
    // R54-AP07 a failed room create leaves the controller centralized, so the
    // retained call site has no model-level route; R54AP07CreateRoomInviteOrderTests
    // pins that the failed create releases the foreground gate instead.
    @Test
    func irohForegroundRefreshKeepsFiniteIdentityThroughTransport() throws {
        let diagnostic = IrohForegroundRefreshDiagnostics(outcome: .retained)
        #expect(DiagnosticPrivacy.identities.contains("Iroh.foregroundRefresh"))
        #expect(DiagnosticPrivacy.publicSummary(diagnostic) == "foreground backend=iroh outcome=retained")
        let sent = try captureThroughOfflineSDK {
            $0.capture(error: DiagnosticPrivacy.diagnostic(diagnostic, operation: .room), scope: Scope())
        }
        expectEnvelope(sent, operation: "room.failure", identity: "Iroh.foregroundRefresh", code: 1)
    }

    @MainActor
    private func fencedModel(_ workspace: TagWorkspace, status: CanonicalTimer.Status?) throws -> AppModel {
        var seed = PersistedTimerState.fresh()
        if let status {
            let timer = TestFixtures.timer(status: status, elapsed: 0, timerID: "timer-l09-\(status.rawValue)")
            seed.canonicalTimer = timer
            seed.localTimerOwners[timer.id] = seed.deviceId
        }
        seed.pendingAccountSwitchUser = TestFixtures.user
        workspace.defaults.set(try JSONEncoder.api.encode(seed), forKey: PersistedStateLoader.storageKey)
        let model = workspace.model()
        try #require(model.isWorkspaceMutationBlocked)
        return model
    }
}

// Records the diagnostics SentryCapture hands its backend. Internal so the
// sign-out and account-switch boundary suites, whose fixtures are private to
// their own files, can use it. RecordedCaptures above stays private because
// R54L04BoundarySiteTests declares its own.
final class BoundaryCaptureLog: Sendable {
    private let recorded = LockedTestValue<[any Error]>([])

    init() {
        SentryCapture.resetForTesting()
        let recorded = recorded
        SentryCapture.setTestBackend { recorded.value = recorded.value + [$0] }
    }

    var errors: [NSError] { recorded.value.map { $0 as NSError } }

    var summary: [String] {
        errors.map { "\($0.userInfo["operation"] as? String ?? "nil")|\($0.userInfo["identity"] as? String ?? "nil")" }
    }

    func errors(identity: String) -> [NSError] {
        errors.filter { $0.userInfo["identity"] as? String == identity }
    }
}

// Sends a recorded diagnostic through the offline SDK and checks its tags.
// A nil identity keeps the one the diagnostic already carries.
func expectTransportedBoundary(_ error: any Error, operation: String, identity: String? = nil) throws {
    let diagnostic = error as NSError
    let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
    let expected = identity ?? diagnostic.userInfo["identity"] as? String ?? ""
    expectEnvelope(sent, operation: operation, identity: expected, code: diagnostic.code)
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

private func expectSingle(_ captures: RecordedCaptures, operation: String, identity: String, code: Int) throws {
    try #require(captures.errors.count == 1, "expected one capture, got \(captures.errors.count)")
    let sent = try captureThroughOfflineSDK { $0.capture(error: captures.errors[0], scope: Scope()) }
    expectEnvelope(sent, operation: operation, identity: identity, code: code)
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54L07\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private struct TagWorkspace {
    let directory: URL
    let suite: String
    let defaults: UserDefaults

    init(_ name: String, defaults make: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) throws {
        suite = "PomodoroughTests.R54L07\(name).\(UUID().uuidString)"
        directory = try temporaryDirectory(name)
        defaults = try #require(make(suite))
    }

    func model(
        roomStore: IrohRoomStore? = nil,
        accountDeletionJournal: AccountDeletionJournal? = nil,
        alarmScheduler: RecordingAlarmScheduler = RecordingAlarmScheduler(),
        sharedCoreProvider: @escaping @MainActor () throws -> SharedCore = { try SharedCore.bundled() }
    ) -> AppModel {
        AppModel(
            api: APIClient(keychain: EmptyTokenStore()), defaults: defaults,
            accountDeletionJournal: accountDeletionJournal,
            roomStore: roomStore ?? TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: alarmScheduler, sharedCoreProvider: sharedCoreProvider
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// Drops writes and removals for one key, so a durable read-back check fails.
private final class RefusingDefaults: UserDefaults {
    var refusedKey = ""

    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != refusedKey else { return }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard defaultName != refusedKey else { return }
        super.removeObject(forKey: defaultName)
    }
}

private struct DurableWriteWitness: Error {}

// Keychain listing denied: the only failure accountDeletionTopology() can raise.
private struct AccountListingFailureSecretStore: IrohRoomSecretStoring {
    func load(roomID: String) throws -> Data? { nil }
    func save(_ secret: Data, roomID: String) throws {}
    func delete(roomID: String) throws {}
    func accountDeletionAccounts() throws -> [String] { throw POSIXError(.EACCES) }
    func deleteAccount(named account: String) throws {}
}

private func accountListingFailureRoomStore(in directory: URL) -> IrohRoomStore {
    IrohRoomStore(
        fileURL: directory.appendingPathComponent("iroh-rooms.json"),
        secretStore: AccountListingFailureSecretStore()
    )
}

private func roomIDsDecodeError(_ data: Data) -> NSError? {
    do {
        _ = try JSONDecoder().decode([String].self, from: data)
        return nil
    } catch {
        return error as NSError
    }
}

// Commands, tasks, and durations carry no device identity, so the mismatched
// claim device passes the beginSync gate and reaches the saved-plan validator.
@MainActor
private func deviceMismatchedClaimState() -> PersistedTimerState {
    let batch = R48AP05BatchPlanTests()
    var seed = PersistedTimerState.fresh()
    seed.cachedUser = TestFixtures.user
    seed.pendingCommands = batch.makeCommands(count: 1, baseWallMs: 1_710_000_000_000)
    seed.pendingTaskOperations = batch.makeTasks(count: 1, baseWallMs: 1_710_001_000_000)
    seed.pendingDurationOperations = batch.makeDurations(count: 1, baseWallMs: 1_710_002_000_000)
    seed.outgoingSyncClaim = batch.requestForAll(seed)
    seed.deviceId = "secret-device-r54-l07"
    return seed
}

@MainActor
private func syncBoundaryModel(workspace: TagWorkspace, store: AtomicDurableFileStore, scenario: String) -> AppModel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [R48AP04StubProtocol.self]
    configuration.httpAdditionalHeaders = ["X-R48AP04-Scenario": scenario]
    return AppModel(
        api: APIClient(session: URLSession(configuration: configuration), keychain: StaticTokenStore()),
        defaults: workspace.defaults, durableLocalStore: store,
        roomStore: TestFixtures.emptyIrohRoomStore(in: workspace.directory),
        alarmScheduler: RecordingAlarmScheduler(), retryDelay: .seconds(3600),
        now: { Date(timeIntervalSince1970: 1_710_100_000) }, uptime: { 100 }
    )
}

// R50-AP02 uncertain replacement: the remote bootstrap installs, and the
// second durable write throws after its rename.
@MainActor
private func bootstrapInstallModel(workspace: TagWorkspace) throws -> AppModel {
    var initial = PersistedTimerState.fresh()
    initial.bootstrapUser = TestFixtures.user
    let storeURL = workspace.directory.appendingPathComponent("workspace.json")
    let bytes = try JSONEncoder.api.encode(initial)
    try AtomicDurableFileStore(fileURL: storeURL).write(bytes)
    workspace.defaults.set(bytes, forKey: "timer-state-v2")
    // Only the install records the signed-in user, so only its replacement fails.
    let store = AtomicDurableFileStore(fileURL: storeURL, afterReplacement: {
        let replaced = try? JSONDecoder.api.decode(PersistedTimerState.self, from: Data(contentsOf: storeURL))
        if replaced?.cachedUser != nil { throw POSIXError(.EIO) }
    })
    return AppModel(
        api: APIClient(session: TestFixtures.session(for: "bootstrap-legacy-ownership-remote"),
            keychain: StaticTokenStore()),
        defaults: workspace.defaults, durableLocalStore: store,
        roomStore: TestFixtures.emptyIrohRoomStore(in: workspace.directory),
        alarmScheduler: RecordingAlarmScheduler()
    )
}

private struct LegacyFixture {
    let store: IrohRoomStore
    let stored: PersistedTimerState
    let migrated: PersistedTimerState
    let source: Data
    let roomID: String
}

private func emptyGenesis() -> IrohGenesis {
    IrohGenesis(canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
        autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0)
}

// createRoom clears the receipt, so the receipt with undecodable source bytes
// is staged through the persisted room file instead.
private func undecodableReceiptFixture(in directory: URL) throws -> LegacyFixture {
    let secret = Data(repeating: 5, count: 32)
    let roomID = try IrohProtocolV1.roomID(for: secret)
    let secrets = MemoryIrohRoomSecretStore()
    let fileURL = directory.appendingPathComponent("rooms.json")
    _ = try IrohRoomStore(fileURL: fileURL, secretStore: secrets).createRoom(
        roomID: roomID, roomSecret: secret, name: "Secret Room",
        returnState: .fresh(), genesis: emptyGenesis()
    )
    let undecodableSource = Data("receipt-source-not-json".utf8)
    var saved = try JSONDecoder.api.decode(IrohReplicationState.self, from: Data(contentsOf: fileURL))
    var roomState = saved.rooms[0].roomState
    roomState.irohLegacyTaskMigration = IrohLegacyTaskMigration(roomID: roomID, source: undecodableSource, state: roomState)
    saved.rooms[0].roomState = roomState
    try JSONEncoder.api.encode(saved).write(to: fileURL, options: .atomic)
    let store = IrohRoomStore(fileURL: fileURL, secretStore: secrets)
    let stored = try #require(store.activeRoomState)
    return LegacyFixture(store: store, stored: stored, migrated: stored, source: undecodableSource, roomID: roomID)
}

private func receiptCheckError(_ store: IrohRoomStore, source: Data) -> (any Error)? {
    do {
        _ = try store.committedLegacyTaskMigration(source: source)
        return nil
    } catch {
        return error
    }
}

// The receipt and the first task operation are committed to the room; the
// migrated state adds a second operation the room never received.
private func missingRecordFixture(in directory: URL) throws -> LegacyFixture {
    let secret = Data(repeating: 5, count: 32)
    let roomID = try IrohProtocolV1.roomID(for: secret)
    let source = try JSONEncoder.api.encode(LocalTaskState(tasks: [], selectedTaskID: nil, assignments: [:]))
    let committed = try #require(FocusTask(title: "Secret Committed Task"))
    let missing = try #require(FocusTask(title: "Secret Missing Task"))
    var base = PersistedTimerState.fresh()
    base.deviceId = "device-r54-l07"
    base.tasks = [committed]
    base.knownTasks = [committed]
    base.pendingTaskOperations = [legacyUpsert(committed, id: "r54-l07-op-1")]
    base.irohLegacyTaskMigration = IrohLegacyTaskMigration(roomID: roomID, source: source, state: base)
    let store = IrohRoomStore(fileURL: directory.appendingPathComponent("rooms.json"),
        secretStore: MemoryIrohRoomSecretStore())
    _ = try store.createRoom(roomID: roomID, roomSecret: secret, name: "Secret Room",
        returnState: base, genesis: emptyGenesis())
    _ = try store.captureLocalOperations(from: base)
    let stored = try #require(store.activeRoomState)
    try #require(stored.irohLegacyTaskMigration == base.irohLegacyTaskMigration)
    var migrated = stored
    migrated.pendingTaskOperations.append(legacyUpsert(missing, id: "r54-l07-op-2"))
    migrated.tasks.append(missing)
    migrated.knownTasks.append(missing)
    return LegacyFixture(store: store, stored: stored, migrated: migrated, source: source, roomID: roomID)
}

private func legacyUpsert(_ task: FocusTask, id: String) -> TaskOperation {
    TaskOperation(id: id, taskId: task.id.uuidString.lowercased(), type: .upsert, title: task.title,
        occurredAt: TestFixtures.anchor, hlcWallMs: 1_000_000, hlcCounter: 0)
}

// Suite defaults back the persistence coordinator, never the standard domain.
@MainActor
private func makeCoordinator(
    _ publication: CentralizedAccountSessionCoordinator.PublicationSnapshot,
    defaults: UserDefaults, roomStore: IrohRoomStore? = nil
) -> CentralizedAccountSessionCoordinator {
    let api = APIClient(keychain: EmptyTokenStore())
    return CentralizedAccountSessionCoordinator(
        lifecycle: AccountLifecycleController(api: api, googleIdentityProvider: RecordingGoogleIdentityProvider()),
        synchronization: AccountSynchronization(api: api, sharedCoreProvider: { try SharedCore.bundled() }),
        initialPublication: publication,
        persistence: AppStatePersistenceCoordinator(defaults: defaults), roomStore: roomStore
    )
}

@MainActor
private func legacyCoordinator(
    _ fixture: LegacyFixture, state: PersistedTimerState, defaults: UserDefaults
) -> CentralizedAccountSessionCoordinator {
    let coordinator = makeCoordinator(.init(sessionState: .localOnly), defaults: defaults, roomStore: fixture.store)
    let transition = AppStatePersistenceCoordinator.LoadTransition(
        replicationMode: .iroh, state: state, removesLegacyTasksAfterProjection: false,
        shouldPersistAfterProjection: false, shouldReportInvalidLocalClock: false,
        snapshotLoadFailure: nil, legacyTaskSource: fixture.source
    )
    coordinator.setLegacyMigrationForTesting(transition: transition, roomID: fixture.roomID)
    return coordinator
}
