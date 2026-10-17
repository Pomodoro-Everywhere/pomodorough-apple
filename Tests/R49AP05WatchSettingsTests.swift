import Foundation
import Testing
@testable import Pomodorough

/// R49-AP05 acceptance: the Watch settings entrypoint returns the committed
/// result for `selectPhase` and `setDuration`. Malformed payloads, refused
/// plans, failed writes, and uncertain replacements return `false`.
/// Successful durable commits return `true` with an exact workspace.
/// The corrective-snapshot test pins the payload the receiver pushes on
/// `false` plus the production wiring that triggers it.
@Suite("R49-AP05 Watch settings acceptance", .serialized)
struct R49AP05WatchSettingsAcceptanceTests {
    @Test(arguments: [false, true]) @MainActor
    func malformedSettingsPreserveExactWorkspace(active: Bool) async throws {
        let fixture = try R49AP05AcceptanceFixture()
        defer { fixture.cleanup() }
        if active { try #require(fixture.model.start()) }
        await fixture.settle()
        let before = try fixture.observe()
        let commands = [
            WatchTimerCommand(name: "selectPhase", sentAt: .now),
            .selectPhase("invalid-phase"),
            WatchTimerCommand(name: "setDuration", minutes: 20, sentAt: .now),
            .setDuration(minutes: 20, forPhaseRawValue: "invalid-phase"),
            WatchTimerCommand(name: "setDuration", phase: "focus", sentAt: .now)
        ]
        for command in commands {
            #expect(!fixture.model.applyWatchCommand(command))
            #expect(try fixture.observe() == before)
        }
        #expect(fixture.alarms.operations.isEmpty)
    }

    @Test(arguments: ["selectPhase", "setDuration"]) @MainActor
    func blockedSettingsReturnFalse(name: String) throws {
        var seed = PersistedTimerState.fresh()
        seed.pendingAccountSwitchUser = TestFixtures.user
        let fixture = try R49AP05AcceptanceFixture(seed: seed)
        defer { fixture.cleanup() }
        try #require(fixture.model.isWorkspaceMutationBlocked)
        let before = try fixture.observe()
        #expect(!fixture.model.applyWatchCommand(fixture.command(name)))
        #expect(try fixture.observe() == before)
    }

    @Test(arguments: ["selectPhase", "setDuration"], [false, true]) @MainActor
    func deniedWriteRefusesThenRetryCommitsExactState(name: String, active: Bool) async throws {
        let fixture = try R49AP05AcceptanceFixture()
        defer { fixture.cleanup() }
        if active { try #require(fixture.model.start()) }
        await fixture.settle()
        let before = try fixture.observe()
        try fixture.setWritable(false)
        #expect(!fixture.model.applyWatchCommand(fixture.command(name)))
        await fixture.model.waitForAlarmOperations()
        #expect(try fixture.observe() == before)
        #expect(fixture.alarms.operations.isEmpty)
        try fixture.setWritable(true)
        #expect(fixture.model.applyWatchCommand(fixture.command(name)))
        await fixture.settle()
        let after = try fixture.observe()
        try fixture.expectCommitted(name, before: before, after: after)
        #expect(fixture.reopen().makeWatchSnapshot() == after.snapshot)
    }

    @Test(arguments: [1, 2]) @MainActor
    func coreFaultRefusesDurationWhileLocalPhaseCommits(fault: Int) async throws {
        let fixture = try R49AP05AcceptanceFixture()
        defer { fixture.cleanup() }
        try #require(fixture.model.start())
        await fixture.settle()
        let before = try fixture.observe()
        let calls = fixture.coreCalls.value
        fixture.coreFault.value = fault
        #expect(!fixture.model.applyWatchCommand(fixture.command("setDuration")))
        #expect(fixture.coreCalls.value > calls)
        #expect(try fixture.observe() == before)
        let phaseCalls = fixture.coreCalls.value
        #expect(fixture.model.applyWatchCommand(fixture.command("selectPhase")))
        #expect(fixture.coreCalls.value == phaseCalls)
        try fixture.expectCommitted("selectPhase", before: before, after: fixture.observe())
    }

    @Test(arguments: [1, 2]) @MainActor
    func completedTimerPhaseRequiresCore(fault: Int) async throws {
        let fixture = try R49AP05AcceptanceFixture()
        defer { fixture.cleanup() }
        try #require(fixture.model.start())
        try #require(fixture.model.finish())
        try #require(fixture.model.canonicalTimer?.status == .completed)
        await fixture.settle()
        let before = try fixture.observe()
        fixture.coreFault.value = fault
        #expect(!fixture.model.applyWatchCommand(fixture.command("selectPhase")))
        #expect(try fixture.observe() == before)
        #expect(fixture.alarms.operations.isEmpty)
    }

    @Test(arguments: ["selectPhase", "setDuration"], [false, true]) @MainActor
    func failedReplacementQuarantinesWithExactObservedState(name: String, active: Bool) async throws {
        let fixture = try R49AP05AcceptanceFixture()
        defer { fixture.cleanup() }
        if active { try #require(fixture.model.start()) }
        await fixture.settle()
        let before = try fixture.observe()
        fixture.writeFault.value = true
        #expect(!fixture.model.applyWatchCommand(fixture.command(name)))
        #expect(fixture.model.snapshotLoadFailure != nil)
        #expect(fixture.model.isWorkspaceMutationBlocked)
        let after = try fixture.observe()
        #expect(after.bytes != before.bytes)
        #expect(after.mirror == before.mirror)
        try R49AP05AcceptanceFixture.proposedSettings(name, in: after.bytes)
        #expect(fixture.alarms.operations.isEmpty)
        fixture.writeFault.value = false
        #expect(!fixture.model.applyWatchCommand(fixture.command(name)))
        #expect(try fixture.observe() == after)
    }

    @Test(arguments: ["selectPhase", "setDuration"]) @MainActor
    func frozenDeliveryPreservesClaimAndCommitsExactState(name: String) async throws {
        let fixture = try R49AP05AcceptanceFixture(seed: R49AP05AcceptanceFixture.frozenSeed())
        defer { fixture.cleanup() }
        await fixture.settle()
        let before = try fixture.observe()
        try #require(before.state.outgoingSyncClaim != nil)
        try fixture.setWritable(false)
        #expect(!fixture.model.applyWatchCommand(fixture.command(name)))
        #expect(try fixture.observe() == before)
        try fixture.setWritable(true)
        #expect(fixture.model.applyWatchCommand(fixture.command(name)))
        await fixture.settle()
        let after = try fixture.observe()
        try fixture.expectCommitted(name, before: before, after: after)
        #expect(after.state.outgoingSyncClaim == before.state.outgoingSyncClaim)
        #expect(fixture.reopen().makeWatchSnapshot() == after.snapshot)
    }

    @Test(arguments: ["selectPhase", "setDuration"],
          ["malformed", "blocked", "denied", "uncertain", "core", "success"]) @MainActor
    func correctiveSnapshotMatchesCurrentModel(name: String, reason: String) async throws {
        let fixture = try R49AP05AcceptanceFixture(seed: R49AP05AcceptanceFixture.seed(reason))
        defer { fixture.cleanup() }
        if reason == "denied" { try fixture.setWritable(false) }
        if reason == "core" {
            try #require(fixture.model.start())
            await fixture.settle()
        }
        let before = try fixture.observe()
        R49AP05AcceptanceFixture.configure(reason, on: fixture)
        let command = reason == "malformed"
            ? WatchTimerCommand(name: name, sentAt: .now) : fixture.command(name)
        let accepted = fixture.model.applyWatchCommand(command)
        let commits = reason == "success" || (name == "selectPhase" && reason == "core")
        #expect(accepted == commits)
        let corrective = try JSONDecoder().decode(
            WatchTimerSnapshot.self, from: JSONEncoder().encode(fixture.model.makeWatchSnapshot()))
        #expect(corrective == fixture.model.makeWatchSnapshot())
        if commits {
            try fixture.expectCommitted(name, before: before, after: fixture.observe())
        } else if reason == "uncertain" {
            #expect(fixture.model.isWorkspaceMutationBlocked)
            #expect(corrective != before.snapshot)
        } else {
            #expect(corrective == before.snapshot)
        }
        if reason == "denied" { try fixture.setWritable(true) }
    }

    @Test @MainActor
    func receiverPushesCorrectiveSnapshotOnFalse() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Sources/WatchSyncService.swift"), encoding: .utf8)
        #expect(source.contains("applyWatchCommand(command, isDeferred: isDeferred) == false"))
        #expect(source.contains("push()"))
        let applyRange = try #require(source.range(of: "private func applyIncoming"))
        let tail = String(source[applyRange.lowerBound...])
        let applyIndex = try #require(tail.range(of: "applyWatchCommand"))
        let pushIndex = try #require(tail.range(of: "push()"))
        #expect(applyIndex.lowerBound < pushIndex.lowerBound)
    }
}

@MainActor
private final class R49AP05AcceptanceFixture {
    struct Observation: Equatable {
        let bytes: Data
        let mirror: Data?
        let state: PersistedTimerState
        let snapshot: WatchTimerSnapshot
        let timer: CanonicalTimer?
    }

    static let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)
    let suite = "PomodoroughTests.R49AP05Accept.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let store: AtomicDurableFileStore
    let alarms = RecordingAlarmScheduler()
    let coreFault = LockedTestValue(0)
    let writeFault = LockedTestValue(false)
    let coreCalls = LockedTestValue(0)
    let core: SharedCore
    private(set) lazy var model = reopen()

    init(seed: PersistedTimerState = .fresh()) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AtomicDurableFileStore(fileURL: directory.appendingPathComponent("workspace.json"),
            afterReplacement: { [writeFault] in if writeFault.value { throw POSIXError(.EIO) } })
        core = SharedCore(moduleURL: try SharedCore.bundledModuleURL(), freeResultValidator: { [coreFault, coreCalls] _ in
            coreCalls.value += 1
            if coreFault.value == 1 { throw SharedCoreError.core("AP05 frozen Core") }
            if coreFault.value == 2 { throw CancellationError() }
        })
        let bytes = try JSONEncoder.api.encode(seed)
        try store.write(bytes)
        defaults.set(bytes, forKey: "timer-state-v2")
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        try #require(model.snapshotLoadFailure == nil)
    }

    func reopen() -> AppModel {
        AppModel(api: APIClient(keychain: EmptyTokenStore()), defaults: defaults,
            durableLocalStore: store, roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
            alarmScheduler: alarms, now: { Self.fixedNow }, uptime: { 100 },
            sharedCoreProvider: { [core] in core })
    }

    func observe() throws -> Observation {
        let bytes = try #require(try store.read())
        return try Observation(bytes: bytes, mirror: defaults.data(forKey: "timer-state-v2"),
            state: JSONDecoder.api.decode(PersistedTimerState.self, from: bytes),
            snapshot: model.makeWatchSnapshot(), timer: model.canonicalTimer)
    }

    func command(_ name: String) -> WatchTimerCommand {
        name == "selectPhase" ? .selectPhase("long_break") : .setDuration(minutes: 20, forPhaseRawValue: "focus")
    }

    func settle() async {
        await model.waitForAlarmOperations()
        alarms.operations.removeAll()
    }

    func setWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o555], ofItemAtPath: directory.path)
    }

    func cleanup() {
        try? setWritable(true)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    static func seed(_ reason: String) -> PersistedTimerState {
        var seed = PersistedTimerState.fresh()
        if reason == "blocked" { seed.pendingAccountSwitchUser = TestFixtures.user }
        return seed
    }

    static func configure(_ reason: String, on fixture: R49AP05AcceptanceFixture) {
        if reason == "core" { fixture.coreFault.value = 1 }
        if reason == "uncertain" { fixture.writeFault.value = true }
    }

    static func frozenSeed() throws -> PersistedTimerState {
        let producer = try R49AP05AcceptanceFixture()
        defer { producer.cleanup() }
        try #require(producer.model.setDurationMinutes(30, for: .focus))
        let sync = AccountSynchronization(api: APIClient(keychain: EmptyTokenStore()),
            sharedCoreProvider: { producer.core })
        let prepared = try sync.prepareSyncPlan(state: producer.observe().state)
        let seed = prepared.retired
        try #require(seed.outgoingSyncClaim == prepared.plan.request)
        try #require(seed.safeProjectionDurationOperations().isEmpty)
        return seed
    }

    static func proposedSettings(_ name: String, in bytes: Data) throws {
        let observed = try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
        if name == "selectPhase" {
            #expect(observed.settings.selectedPhase == .longBreak)
        } else {
            #expect(observed.settings.minutes(for: .focus) == 20)
        }
    }

    func expectCommitted(_ name: String, before: Observation, after: Observation) throws {
        #expect(after.bytes != before.bytes)
        #expect(try JSONDecoder.api.decode(PersistedTimerState.self, from: #require(after.mirror)) == after.state)
        var expected = before.state
        if name == "selectPhase" {
            expected.settings.selectedPhase = .longBreak
            expected.selectedPhaseGeneration = TimerSessionController.nextPhaseGeneration(after: expected.selectedPhaseGeneration)
            expected.hasExplicitPhaseSelection = true
        } else {
            try expectDurationCommit(before: before, after: after, expected: &expected)
        }
        #expect(after.state == expected)
        #expect(after.timer == before.timer)
        #expect(after.snapshot.timerRevision == before.snapshot.timerRevision)
        #expect(after.snapshot.selectedPhase == expected.settings.selectedPhase.rawValue)
        #expect(after.snapshot.focusDurationMs == expected.settings.durationsMs.focus)
        #expect(after.snapshot.shortBreakDurationMs == expected.settings.durationsMs.shortBreak)
        #expect(after.snapshot.longBreakDurationMs == expected.settings.durationsMs.longBreak)
    }

    private func expectDurationCommit(before: Observation, after: Observation, expected: inout PersistedTimerState) throws {
        if !before.state.pendingDurationOperations.isEmpty,
           before.state.safeProjectionDurationOperations().isEmpty {
            expected.captureCanonicalSelectedTaskIfNeeded()
        }
        let operation = try #require(after.state.pendingDurationOperations.last)
        #expect(operation.phase == .focus)
        #expect(operation.durationMs == 1_200_000)
        #expect(operation.occurredAt == Self.fixedNow)
        let input = CoreHLCTickInput(local: CoreHLC(wallMs: before.state.hlcWallMs, counter: before.state.hlcCounter),
            remote: nil, physicalNowMs: Int64(Self.fixedNow.timeIntervalSince1970 * 1_000))
        let official = try SharedCore.bundled().tickHLC(input).validated(for: input)
        #expect(operation.hlcWallMs == official.wallMs)
        #expect(operation.hlcCounter == official.counter)
        #expect(after.state.hlcWallMs == official.wallMs)
        #expect(after.state.hlcCounter == official.counter)
        #expect(operation.isValid)
        let uuid = try #require(after.state.lastUuidV7)
        _ = try UUIDv7.parts(of: uuid)
        if let previousUuid = before.state.lastUuidV7 { #expect(UUIDv7.isLess(previousUuid, than: uuid)) }
        #expect(operation.id == "duration-operation-\(uuid.uuidString.lowercased())")
        let discarded = expected.pendingDurationOperations.filter {
            $0.phase == .focus && expected.neverSentDurationOperationIDs.contains($0.id)
        }
        expected.pendingDurationOperations.removeAll { candidate in discarded.contains { $0.id == candidate.id } }
        expected.neverSentDurationOperationIDs.subtract(discarded.map(\.id))
        expected.pendingDurationOperations.append(operation)
        expected.neverSentDurationOperationIDs.insert(operation.id)
        expected.settings.setMinutes(20, for: .focus)
        expected.hlcWallMs = after.state.hlcWallMs
        expected.hlcCounter = after.state.hlcCounter
        expected.lastUuidV7 = uuid
    }
}
