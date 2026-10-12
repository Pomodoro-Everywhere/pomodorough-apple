import Foundation
import Testing
@testable import Pomodorough

@Suite("R48-AP05 Core batch planning")
struct R48AP05BatchPlanTests {
    @Test @MainActor
    func sync512BoundarySelectsAll() throws {
        let sync = makeSync()
        var state = PersistedTimerState.fresh()
        state.pendingCommands = makeCommands(count: 256, baseWallMs: 1_710_000_000_000)
        state.pendingTaskOperations = makeTasks(count: 256, baseWallMs: 1_710_000_100_000)
        for operation in state.pendingCommands { state.recordNeverSentCommand(id: operation.id) }
        for operation in state.pendingTaskOperations { state.recordNeverSentTaskOperation(id: operation.id) }
        let prepared = try sync.prepareSyncPlan(state: state)
        #expect(prepared.plan.coreStatus == "planned")
        #expect(!prepared.plan.isSavedReplay)
        #expect(prepared.plan.batch.commands.count == 256)
        #expect(prepared.plan.batch.taskOperations.count == 256)
        #expect(prepared.plan.request.commands.count + prepared.plan.request.taskOperations.count == 512)
        #expect(prepared.retired.outgoingSyncClaim == prepared.plan.request)
        #expect(prepared.retired.syncBatchCursor == prepared.plan.nextCursor)
        #expect(prepared.retired.neverSentCommandIDs.isEmpty)
    }

    @Test @MainActor
    func sync513FairnessCapsAt512() throws {
        let sync = makeSync()
        var state = PersistedTimerState.fresh()
        state.pendingCommands = makeCommands(count: 256, baseWallMs: 1_710_000_000_000)
        state.pendingTaskOperations = makeTasks(count: 256, baseWallMs: 1_710_000_100_000)
        state.pendingDurationOperations = makeDurations(count: 1, baseWallMs: 1_710_000_200_000)
        let prepared = try sync.prepareSyncPlan(state: state)
        #expect(prepared.plan.coreStatus == "planned")
        let total = prepared.plan.batch.commands.count
            + prepared.plan.batch.taskOperations.count
            + prepared.plan.batch.durationOperations.count
        #expect(total == 512)
        #expect(prepared.plan.batch.commands.count <= 256)
        #expect(prepared.plan.batch.taskOperations.count <= 256)
        #expect(prepared.plan.batch.durationOperations.count <= 1)
        #expect(exactBodies(request: prepared.plan.request, state: state))
    }

    @Test @MainActor
    func mixedFiveDomainDrainsWithoutStarvation() throws {
        let sync = makeSync()
        var working = mixedState(count: 300)
        let original = working
        var selected = Set<String>()
        var drained = 0
        var rounds = 0
        while drained < 1500, rounds < 10 {
            let prepared = try sync.prepareSyncPlan(state: working)
            #expect(prepared.plan.coreStatus == "planned")
            let counts = domainCounts(prepared.plan.request)
            let batchTotal = counts.reduce(0, +)
            #expect(batchTotal > 0 && batchTotal <= 512)
            #expect(counts.allSatisfy { $0 > 0 && $0 <= 256 })
            #expect(exactBodies(request: prepared.plan.request, state: original))
            let ids = allIDs(prepared.plan.request)
            #expect(selected.isDisjoint(with: ids))
            selected.formUnion(ids)
            drained += batchTotal
            working = try reopen(removingSent(prepared.plan.request, from: prepared.retired))
            #expect(working.syncBatchCursor == prepared.plan.nextCursor)
            rounds += 1
        }
        #expect(drained == 1500)
        #expect(selected.count == 1500)
        #expect(rounds == 3)
    }

    @Test @MainActor
    func dependencyBarrierHoldsChild() throws {
        let sync = makeSync()
        var state = PersistedTimerState.fresh()
        let parent = makeCommands(count: 1, baseWallMs: 1_710_000_000_000)[0]
        var child = makeCommands(count: 1, baseWallMs: 1_710_000_001_000)[0]
        child = TimerCommand(
            id: "command-barrier-child", deviceSequence: 2, timerId: child.timerId,
            taskId: nil, type: .pause, phase: .focus, plannedDurationMs: 60_000,
            occurredAt: child.occurredAt, hlcWallMs: child.hlcWallMs,
            hlcCounter: child.hlcCounter, observedElapsedMs: 0
        )
        var later = makeCommands(count: 1, baseWallMs: 1_710_000_002_000)[0]
        later = TimerCommand(
            id: "command-barrier-later", deviceSequence: 3, timerId: later.timerId,
            taskId: nil, type: .pause, phase: .focus, plannedDurationMs: 60_000,
            occurredAt: later.occurredAt, hlcWallMs: later.hlcWallMs,
            hlcCounter: later.hlcCounter, observedElapsedMs: 0
        )
        let start = TimerCommand(
            id: parent.id, deviceSequence: 1, timerId: parent.timerId,
            taskId: nil, type: parent.type, phase: parent.phase,
            plannedDurationMs: parent.plannedDurationMs, occurredAt: parent.occurredAt,
            hlcWallMs: parent.hlcWallMs, hlcCounter: parent.hlcCounter,
            observedElapsedMs: parent.observedElapsedMs
        )
        state.pendingCommands = [start, child, later]
        state.pendingTimerDependencies = [CoreTimerDependency(
            operationId: child.id, dependsOnOperationId: start.id
        )]
        let prepared = try sync.prepareSyncPlan(state: state)
        #expect(prepared.plan.coreStatus == "planned")
        #expect(prepared.plan.batch.commands.map(\.id) == [start.id])
        #expect(prepared.plan.heldTimerOperationId == child.id)
        #expect(!prepared.plan.batch.commands.contains(where: { $0.id == child.id }))
    }

    @Test @MainActor
    func savedClaimLossReplaysExactBodies() throws {
        let sync = makeSync()
        let state = mixedState(count: 3)
        let prepared = try sync.prepareSyncPlan(state: state)
        let retired = prepared.retired
        #expect(retired.outgoingSyncClaim == prepared.plan.request)
        var changed = retired
        changed.pendingTaskOperations = []
        changed.pendingCommands.reverse()
        changed.revision = 99
        let replay = try sync.makeSyncPlan(state: changed)
        #expect(replay.isSavedReplay)
        #expect(replay.request == prepared.plan.request)
        #expect(replay.batch.commands == prepared.plan.batch.commands)
        #expect(replay.batch.taskOperations == prepared.plan.batch.taskOperations)
        #expect(replay.nextCursor == retired.syncBatchCursor)
        let second = try sync.prepareSyncPlan(state: retired)
        #expect(second.plan.request == prepared.plan.request)
        #expect(second.retired.outgoingSyncClaim == prepared.plan.request)
    }

    @Test @MainActor
    func reopenPreservesClaimCursorAndProof() throws {
        let sync = makeSync()
        let state = mixedState(count: 2)
        let prepared = try sync.prepareSyncPlan(state: state)
        let reopened = try reopen(prepared.retired)
        #expect(reopened == prepared.retired)
        #expect(reopened.outgoingSyncClaim == prepared.plan.request)
        #expect(reopened.syncBatchCursor == prepared.plan.nextCursor)
        let replay = try sync.makeSyncPlan(state: reopened)
        #expect(replay.isSavedReplay)
        #expect(replay.request == prepared.plan.request)
        #expect(try JSONEncoder.api.encode(replay.request) == JSONEncoder.api.encode(prepared.plan.request))
    }

    @Test @MainActor
    func oversizedSavedBlocksAndRequiresConfirmation() throws {
        let sync = makeSync()
        var state = PersistedTimerState.fresh()
        state.pendingTaskOperations = makeTasks(count: 257, baseWallMs: 1_710_000_100_000)
        var claimed = state
        claimed.outgoingSyncClaim = SyncRequest(
            deviceId: state.deviceId, lastRevision: state.revision,
            commands: [], taskOperations: state.pendingTaskOperations,
            durationOperations: [], autoStartOperations: [], selectedTaskOperations: []
        )
        do {
            _ = try sync.makeSyncPlan(state: claimed)
            Issue.record("oversized saved claim must block")
        } catch let error as SyncBatchPlanError {
            #expect(error == .oversizedSaved)
        }
        do {
            _ = try sync.discardSavedSyncClaim(confirmed: false, state: claimed)
            Issue.record("discard requires confirmation")
        } catch let error as SyncBatchPlanError {
            #expect(error == .oversizedSaved)
        }
        let cleared = try sync.discardSavedSyncClaim(confirmed: true, state: claimed)
        #expect(cleared.outgoingSyncClaim == nil)
        #expect(cleared.pendingTaskOperations == state.pendingTaskOperations)
    }

    @Test @MainActor
    func bootstrapAtomicCaps() throws {
        let core = try SharedCore.bundled()
        let planner = SyncBatchPlanner(core: core)
        var state = PersistedTimerState.fresh()
        state.pendingTaskOperations = makeTasks(count: 4096, baseWallMs: 1_710_000_100_000)
        let fitting = try planner.planBootstrap(
            commands: [], tasks: state.pendingTaskOperations, durations: [],
            autoStarts: [], selectedTasks: [], deviceId: state.deviceId,
            dependencies: [], strategy: .merge
        )
        #expect(fitting.status == "planned")
        #expect(fitting.selected.taskOperations.count == 4096)
        state.pendingTaskOperations = makeTasks(count: 4097, baseWallMs: 1_710_000_100_000)
        let oversized = try planner.planBootstrap(
            commands: [], tasks: state.pendingTaskOperations, durations: [],
            autoStarts: [], selectedTasks: [], deviceId: state.deviceId,
            dependencies: [], strategy: .merge
        )
        #expect(oversized.status == "oversized")
        #expect(oversized.selected.total() == 0)
    }

    @Test @MainActor
    func completeQueuesAreSortedBeforePerDomainCap() throws {
        let sync = makeSync()
        var state = mixedState(count: 300)
        state.pendingCommands.reverse()
        state.pendingTaskOperations.reverse()
        state.pendingDurationOperations.reverse()
        state.pendingAutoStartOperations.reverse()
        state.pendingSelectedTaskOperations.reverse()
        let plan = try sync.makeSyncPlan(state: state)
        #expect(plan.batch.commands.first?.id == "batch-command-00000")
        #expect(plan.batch.taskOperations.first?.id == "batch-task-op-00000")
        #expect(plan.batch.durationOperations.first?.id == "batch-duration-00000")
        #expect(plan.batch.autoStartOperations.first?.hlcWallMs == 1_710_003_000_000)
        #expect(plan.batch.selectedTaskOperations.first?.hlcWallMs == 1_710_004_000_000)
        #expect(domainCounts(plan.request).reduce(0, +) == 512)
    }

    @Test @MainActor
    func saved512ReplaysAndSaved513CannotBeTruncated() throws {
        let sync = makeSync()
        var state = mixedState(count: 0)
        state.pendingCommands = makeCommands(count: 256, baseWallMs: 1_710_000_000_000)
        state.pendingTaskOperations = makeTasks(count: 256, baseWallMs: 1_710_001_000_000)
        state.outgoingSyncClaim = requestForAll(state)
        #expect(try sync.makeSyncPlan(state: state).request == state.outgoingSyncClaim)
        state.pendingDurationOperations = makeDurations(count: 1, baseWallMs: 1_710_002_000_000)
        state.outgoingSyncClaim = requestForAll(state)
        #expect(throws: SyncBatchPlanError.oversizedSaved) { try sync.makeSyncPlan(state: state) }
        let recovered = try reopen(sync.discardSavedSyncClaim(confirmed: true, state: state))
        #expect(recovered.outgoingSyncClaim == nil)
        #expect(recovered.neverSentProof() == state.neverSentProof())
        #expect(domainCounts(try sync.makeSyncPlan(state: recovered).request).reduce(0, +) == 512)
    }

    @Test @MainActor
    func validSavedClaimCannotBeDiscarded() throws {
        let sync = makeSync()
        let prepared = try sync.prepareSyncPlan(state: mixedState(count: 2))
        #expect(throws: SyncBatchPlanError.invalidResponse("saved claim must replay exactly")) {
            try sync.discardSavedSyncClaim(confirmed: true, state: prepared.retired)
        }
    }

    @Test @MainActor
    func malformedSavedClaimFailsClosedOnReopen() throws {
        let state = mixedState(count: 1)
        let bytes = try JSONEncoder.api.encode(state)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["outgoingSyncClaim"] = ["commands": []]
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(PersistedTimerState.self, from: corrupt)
        }
    }

    @Test @MainActor
    func dependencyBeyondOldPrefixStillHoldsEveryLaterCommand() throws {
        let sync = makeSync()
        var state = mixedState(count: 300)
        let child = state.pendingCommands[1]
        state.pendingTimerDependencies = [CoreTimerDependency(
            operationId: child.id, dependsOnOperationId: state.pendingCommands[0].id
        )]
        state.pendingCommands.reverse()
        let prepared = try sync.prepareSyncPlan(state: state)
        #expect(prepared.plan.batch.commands.map(\.id) == ["batch-command-00000"])
        #expect(prepared.plan.heldTimerOperationId == child.id)
        #expect(prepared.retired.neverSentCommandIDs.count == 299)
        #expect(!prepared.plan.batch.autoStartOperations.isEmpty)
        #expect(!prepared.plan.batch.selectedTaskOperations.isEmpty)
    }

    @Test @MainActor
    func bootstrap8192BoundaryAnd8193RemainAtomic() throws {
        let planner = SyncBatchPlanner(core: try SharedCore.bundled())
        let state = mixedState(count: 0)
        let commands = makeCommands(count: 4096, baseWallMs: 1_710_000_000_000)
        let tasks = makeTasks(count: 4096, baseWallMs: 1_710_100_000_000)
        let fitting = try planner.planBootstrap(
            commands: commands, tasks: tasks, durations: [], autoStarts: [], selectedTasks: [],
            deviceId: state.deviceId, dependencies: [], strategy: .replaceRemote
        )
        #expect(fitting.selected.total() == 8192)
        let oversized = try planner.planBootstrap(
            commands: commands, tasks: tasks,
            durations: makeDurations(count: 1, baseWallMs: 1_710_200_000_000),
            autoStarts: [], selectedTasks: [], deviceId: state.deviceId,
            dependencies: [], strategy: .replaceRemote
        )
        #expect(oversized.status == "oversized")
        #expect(oversized.selected.total() == 0)
    }

    @Test @MainActor
    func durableCursorStartsNextFairRoundAfterContinuousTimerBacklog() throws {
        let sync = makeSync()
        var state = mixedState(count: 300)
        state.syncBatchCursor = "selectedTaskOperations"
        let first = try sync.prepareSyncPlan(state: state)
        #expect(domainCounts(first.plan.request) == [103, 102, 102, 102, 103])
        #expect(first.plan.nextCursor == "taskOperations")
        let reopened = try reopen(removingSent(first.plan.request, from: first.retired))
        let second = try sync.prepareSyncPlan(state: reopened)
        #expect(domainCounts(second.plan.request) == [102, 103, 103, 102, 102])
        #expect(second.plan.nextCursor == "autoStartOperations")
        #expect(second.retired.pendingCommands.count == reopened.pendingCommands.count)
        #expect(second.retired.outgoingSyncClaim == second.plan.request)
    }

    @Test @MainActor
    func savedMissingAutoStartStaysMissingAndInvalidDeviceBlocks() throws {
        let sync = makeSync()
        var state = mixedState(count: 0)
        state.outgoingSyncClaim = SyncRequest(
            deviceId: state.deviceId, lastRevision: 7, commands: [], taskOperations: [],
            durationOperations: [], autoStartOperations: nil, selectedTaskOperations: []
        )
        let reopened = try reopen(state)
        let replay = try sync.makeSyncPlan(state: reopened)
        #expect(replay.request.autoStartOperations == nil)
        #expect(replay.request.lastRevision == 7)
        #expect(replay.request == state.outgoingSyncClaim)
        state.deviceId = "other-device"
        #expect(throws: SyncBatchPlanError.invalidResponse("saved claim device mismatch")) {
            try sync.makeSyncPlan(state: state)
        }
    }

    @Test @MainActor
    func invalidCompleteQueueFailsBeforeAnyClaimOrProofRetirement() throws {
        let sync = makeSync()
        var state = mixedState(count: 300)
        state.pendingTaskOperations.append(state.pendingTaskOperations[0])
        #expect(throws: SharedCoreError.self) { try sync.prepareSyncPlan(state: state) }
        #expect(state.outgoingSyncClaim == nil)
        #expect(state.neverSentTaskOperationIDs.count == 300)
        #expect(state.syncBatchCursor == "commands")
    }
}

extension R48AP05BatchPlanTests {
    @MainActor
    func makeSync() -> AccountSynchronization {
        AccountSynchronization(
            api: APIClient(keychain: EmptyTokenStore()),
            sharedCoreProvider: { try SharedCore.bundled() }
        )
    }

    func reopen(_ state: PersistedTimerState) throws -> PersistedTimerState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        try AtomicDurableFileStore(fileURL: url).write(JSONEncoder.api.encode(state))
        let data = try #require(try AtomicDurableFileStore(fileURL: url).read())
        return try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
    }

    func exactBodies(request: SyncRequest, state: PersistedTimerState) -> Bool {
        let commandIndex = Dictionary(uniqueKeysWithValues: state.pendingCommands.map { ($0.id, $0) })
        let taskIndex = Dictionary(uniqueKeysWithValues: state.pendingTaskOperations.map { ($0.id, $0) })
        let durationIndex = Dictionary(uniqueKeysWithValues: state.pendingDurationOperations.map { ($0.id, $0) })
        let autoIndex = Dictionary(uniqueKeysWithValues: state.pendingAutoStartOperations.map { ($0.id, $0) })
        let selectedIndex = Dictionary(uniqueKeysWithValues: state.pendingSelectedTaskOperations.map { ($0.id, $0) })
        return request.commands.allSatisfy { $0 == commandIndex[$0.id] }
            && request.taskOperations.allSatisfy { $0 == taskIndex[$0.id] }
            && request.durationOperations.allSatisfy { $0 == durationIndex[$0.id] }
            && (request.autoStartOperations ?? []).allSatisfy { $0 == autoIndex[$0.id] }
            && request.selectedTaskOperations.allSatisfy { $0 == selectedIndex[$0.id] }
    }

    func mixedState(count: Int) -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.pendingCommands = makeCommands(count: count, baseWallMs: 1_710_000_000_000)
        state.pendingTaskOperations = makeTasks(count: count, baseWallMs: 1_710_001_000_000)
        state.pendingDurationOperations = makeDurations(count: count, baseWallMs: 1_710_002_000_000)
        state.pendingAutoStartOperations = (0..<count).map {
            TestFixtures.autoStartOperation(deviceID: state.deviceId, enabled: $0.isMultiple(of: 2),
                                            wallMs: 1_710_003_000_000 + Int64($0))
        }
        state.pendingSelectedTaskOperations = (0..<count).map {
            TestFixtures.selectedTaskOperation(deviceID: state.deviceId, taskID: nil,
                                               wallMs: 1_710_004_000_000 + Int64($0))
        }
        state.neverSentCommandIDs = Set(state.pendingCommands.map(\.id))
        state.neverSentTaskOperationIDs = Set(state.pendingTaskOperations.map(\.id))
        state.neverSentDurationOperationIDs = Set(state.pendingDurationOperations.map(\.id))
        state.neverSentAutoStartOperationIDs = Set(state.pendingAutoStartOperations.map { $0.id.uuidString.lowercased() })
        state.neverSentSelectedTaskOperationIDs = Set(state.pendingSelectedTaskOperations.map { $0.id.uuidString.lowercased() })
        return state
    }

    func domainCounts(_ request: SyncRequest) -> [Int] {
        [request.commands.count, request.taskOperations.count, request.durationOperations.count,
         (request.autoStartOperations ?? []).count, request.selectedTaskOperations.count]
    }

    func requestForAll(_ state: PersistedTimerState) -> SyncRequest {
        SyncRequest(deviceId: state.deviceId, lastRevision: state.revision,
                    commands: state.pendingCommands, taskOperations: state.pendingTaskOperations,
                    durationOperations: state.pendingDurationOperations,
                    autoStartOperations: state.pendingAutoStartOperations,
                    selectedTaskOperations: state.pendingSelectedTaskOperations)
    }

    func allIDs(_ request: SyncRequest) -> Set<String> {
        Set(request.commands.map(\.id) + request.taskOperations.map(\.id)
            + request.durationOperations.map(\.id)
            + (request.autoStartOperations ?? []).map { $0.id.uuidString.lowercased() }
            + request.selectedTaskOperations.map { $0.id.uuidString.lowercased() })
    }

    func removingSent(_ request: SyncRequest, from state: PersistedTimerState) -> PersistedTimerState {
        var updated = state
        let ids = allIDs(request)
        updated.pendingCommands.removeAll { ids.contains($0.id) }
        updated.pendingTaskOperations.removeAll { ids.contains($0.id) }
        updated.pendingDurationOperations.removeAll { ids.contains($0.id) }
        updated.pendingAutoStartOperations.removeAll { ids.contains($0.id.uuidString.lowercased()) }
        updated.pendingSelectedTaskOperations.removeAll { ids.contains($0.id.uuidString.lowercased()) }
        updated.outgoingSyncClaim = nil
        return updated
    }

    func makeCommands(count: Int, baseWallMs: Int64) -> [TimerCommand] {
        (0..<count).map { index in
            let wallMs = baseWallMs + Int64(index) * 1_000
            return TimerCommand(
                id: String(format: "batch-command-%05d", index),
                deviceSequence: Int64(index + 1),
                timerId: "timer-batch-\(index % 7)",
                taskId: nil,
                type: .pause,
                phase: .focus,
                plannedDurationMs: 60_000,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1_000),
                hlcWallMs: wallMs,
                hlcCounter: 0,
                observedElapsedMs: 0
            )
        }
    }

    func makeTasks(count: Int, baseWallMs: Int64) -> [TaskOperation] {
        (0..<count).map { index in
            let wallMs = baseWallMs + Int64(index) * 1_000
            let title = String(format: "Batch task %05d", index)
            let taskId = FocusTask(title: title)!.id.uuidString.lowercased()
            return TaskOperation(
                id: String(format: "batch-task-op-%05d", index),
                taskId: taskId,
                type: .upsert,
                title: title,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1_000),
                hlcWallMs: wallMs,
                hlcCounter: 0
            )
        }
    }

    func makeDurations(count: Int, baseWallMs: Int64) -> [DurationOperation] {
        let phases: [TimerPhase] = [.focus, .shortBreak, .longBreak]
        let values: [Int64] = [1_500_000, 300_000, 900_000]
        return (0..<count).map { index in
            let wallMs = baseWallMs + Int64(index) * 1_000
            return DurationOperation(
                id: String(format: "batch-duration-%05d", index),
                phase: phases[index % 3],
                durationMs: values[index % 3],
                occurredAt: Date(timeIntervalSince1970: TimeInterval(wallMs) / 1_000),
                hlcWallMs: wallMs,
                hlcCounter: 0
            )
        }
    }
}
