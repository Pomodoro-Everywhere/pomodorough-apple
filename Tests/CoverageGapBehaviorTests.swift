import Foundation
import Testing
@testable import Pomodorough

@Suite("Coverage gap behavior")
struct CoverageGapBehaviorTests {
    @Test func taskTimeTextFormatsMinuteHourAndRemainderBoundaries() {
        let cases: [(Int64, String, String)] = [
            (59 * 60_000, "59m", "59 minutes"),
            (60 * 60_000, "1h", "1 hour"),
            (61 * 60_000, "1h 1m", "1 hours 1 minutes")
        ]

        for (milliseconds, compact, spoken) in cases {
            #expect(TaskTimeText.compact(milliseconds) == compact)
            #expect(TaskTimeText.spoken(milliseconds) == spoken)
        }
    }

    @Test func coreOperationRoundTripsPreserveTrustedDeviceAndNullableSelection() throws {
        let deviceID = "device-coverage"
        let duration = TestFixtures.durationOperation(
            id: "duration-coverage",
            phase: .longBreak,
            durationMs: 20 * 60_000,
            wallMs: 1_000
        )
        let selection = TestFixtures.selectedTaskOperation(
            deviceID: deviceID,
            taskID: nil,
            wallMs: 1_000
        )

        #expect(try CoreDurationOperation(duration, deviceId: deviceID)
            .native(deviceId: deviceID) == duration)
        #expect(try CoreSelectedTaskOperation(selection)
            .native(deviceId: deviceID) == selection)
    }

    @Test func coreOperationConversionRejectsDeviceSubstitutionAndMalformedIdentity() throws {
        let duration = TestFixtures.durationOperation(
            id: "duration-coverage",
            phase: .focus,
            durationMs: 25 * 60_000,
            wallMs: 1_000
        )
        let selection = TestFixtures.selectedTaskOperation(
            deviceID: "device-coverage",
            taskID: nil,
            wallMs: 1_000
        )
        let malformedSelection = try replacingJSONField(
            in: CoreSelectedTaskOperation(selection),
            key: "id",
            value: "not-a-uuid"
        )

        #expect(throws: SharedCoreError.self) {
            _ = try CoreDurationOperation(duration, deviceId: "device-a")
                .native(deviceId: "device-b")
        }
        #expect(throws: SharedCoreError.self) {
            _ = try malformedSelection.native(deviceId: "device-coverage")
        }
    }

    @Test func strictRPCValidationAcceptsAllMutableOperationClockContracts() throws {
        let common: [String: Any] = [
            "id": "operation-coverage",
            "occurredAt": "1970-01-01T00:00:01Z",
            "hlcWallMs": 1_000,
            "hlcCounter": 0
        ]
        try IrohRPCMessageValidation.validateTimerOperation(common.merging([
            "deviceSequence": 1,
            "timerId": "timer-coverage",
            "type": "start",
            "phase": "focus",
            "plannedDurationMs": 60_000,
            "observedElapsedMs": 0
        ]) { _, new in new })
        try IrohRPCMessageValidation.validateTaskOperation(common.merging([
            "taskId": "aaf83054-24b2-8c0e-901f-a974147bfe82",
            "type": "delete"
        ]) { _, new in new })
        try IrohRPCMessageValidation.validateDurationOperation([
            "id": "duration-legacy",
            "phase": "focus",
            "durationMs": 60_000,
            "occurredAt": "1970-01-01T00:00:00Z",
            "hlcWallMs": 0,
            "hlcCounter": 0
        ])
    }

    @Test func strictRPCValidationRejectsNullOptionalsAndNonEpochLegacyClock() {
        let nullTitle: [String: Any] = [
            "id": "task-operation-coverage",
            "taskId": "aaf83054-24b2-8c0e-901f-a974147bfe82",
            "type": "delete",
            "title": NSNull(),
            "occurredAt": "1970-01-01T00:00:01Z",
            "hlcWallMs": 1_000,
            "hlcCounter": 0
        ]
        let invalidSentinel: [String: Any] = [
            "id": "duration-legacy",
            "phase": "focus",
            "durationMs": 60_000,
            "occurredAt": "1970-01-01T00:00:01Z",
            "hlcWallMs": 0,
            "hlcCounter": 0
        ]

        #expect(throws: IrohProtocolError.self) {
            try IrohRPCMessageValidation.validateTaskOperation(nullTitle)
        }
        #expect(throws: IrohProtocolError.self) {
            try IrohRPCMessageValidation.validateDurationOperation(invalidSentinel)
        }
    }

    @Test func inventoryOrderingUsesDomainThenUTF8IdentityAndRejectsDuplicates() {
        let digest = Base64URL.encode(Data(repeating: 1, count: 32))
        let ordered = [
            IrohInventoryEntry(domain: .duration, id: "operation-a", digest: digest),
            IrohInventoryEntry(domain: .duration, id: "operation-b", digest: digest),
            IrohInventoryEntry(domain: .genesis, id: "genesis", digest: digest)
        ].sorted { IrohRPCMessageValidation.precedes($0, $1) }

        #expect(IrohRPCMessageValidation.entriesAreStrictlyOrdered(ordered))
        #expect(!IrohRPCMessageValidation.entriesAreStrictlyOrdered([ordered[0], ordered[0]]))
        #expect(IrohRPCMessageValidation.validCursor("genesis\0genesis"))
        #expect(!IrohRPCMessageValidation.validCursor("genesis\0other"))
    }

    private func replacingJSONField<Value: Codable>(
        in value: Value,
        key: String,
        value replacement: Any
    ) throws -> Value {
        let encoded = try JSONEncoder.api.encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = replacement
        return try JSONDecoder.api.decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Suite("Persisted queue reconciliation behavior")
struct PersistedQueueReconciliationBehaviorTests {
    @Test func rebaseRepairsEveryPendingDomainWithoutChangingOperationIdentityOrPayload() throws {
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let serverDate = Date(timeIntervalSince1970: 2_000)
        let task = try #require(FocusTask(title: "Rebased task"))
        let selectionID = UUID(uuidString: "018f24e8-7400-7000-8000-000000000004")!
        let autoStartID = UUID(uuidString: "018f24e8-7400-7000-8000-000000000003")!
        let queue = PersistedPendingOperationQueue(
            commands: [command(at: oldDate)],
            taskOperations: [taskOperation(task, at: oldDate)],
            durationOperations: [durationOperation(at: oldDate)],
            autoStartOperations: [AutoStartOperation(
                id: autoStartID,
                deviceId: "device-rebase",
                enabled: true,
                occurredAt: oldDate,
                hlcWallMs: 1_000_000,
                hlcCounter: 0
            )],
            selectedTaskOperations: [SelectedTaskOperation(
                id: selectionID,
                deviceId: "device-rebase",
                taskId: task.id.uuidString.lowercased(),
                occurredAt: oldDate,
                hlcWallMs: 1_000_000,
                hlcCounter: 0
            )]
        )

        let result = try PersistedQueueReconciliation.rebase(
            queue,
            currentClock: PersistedClockValue(wallMs: 1_500_000, counter: 0),
            afterServerClock: PersistedClockValue(wallMs: 2_000_000, counter: 7),
            serverTime: serverDate
        )

        #expect(result.queue.commands[0].id == queue.commands[0].id)
        #expect(result.queue.commands[0].type == .start)
        #expect(result.queue.taskOperations[0].title == task.title)
        #expect(result.queue.durationOperations[0].durationMs == 30 * 60_000)
        #expect(result.queue.autoStartOperations[0].enabled)
        #expect(result.queue.selectedTaskOperations[0].taskId == task.id.uuidString.lowercased())
        #expect(allClocks(in: result.queue).allSatisfy { $0 == PersistedClockValue(wallMs: 2_000_000, counter: 8) })
        #expect(allDates(in: result.queue).allSatisfy { $0 == serverDate })
        #expect(result.clock == PersistedClockValue(wallMs: 2_000_000, counter: 8))
        #expect(result.queue.hasValidOperationsAndIdentity(deviceID: "device-rebase"))
    }

    @Test func rebasePreservesValidLaterClockAndNeverMovesCurrentClockBackward() throws {
        let serverDate = Date(timeIntervalSince1970: 2_000)
        let validDate = serverDate.addingTimeInterval(1)
        let valid = DurationOperation(
            id: "duration-valid-clock",
            phase: .shortBreak,
            durationMs: 8 * 60_000,
            occurredAt: validDate,
            hlcWallMs: 2_001_000,
            hlcCounter: 2
        )
        let queue = PersistedPendingOperationQueue(
            commands: [],
            taskOperations: [],
            durationOperations: [valid],
            autoStartOperations: [],
            selectedTaskOperations: []
        )

        let result = try PersistedQueueReconciliation.rebase(
            queue,
            currentClock: PersistedClockValue(wallMs: 2_010_000, counter: 4),
            afterServerClock: PersistedClockValue(wallMs: 2_000_000, counter: 7),
            serverTime: serverDate
        )

        #expect(result.queue.durationOperations == [valid])
        #expect(result.clock == PersistedClockValue(wallMs: 2_010_000, counter: 4))
        #expect(result.queue.maximumClock == PersistedClockValue(wallMs: 2_001_000, counter: 2))
    }

    @Test func reconciliationRemovesOnlySentOperationsAndReplaysConcurrentLocalChanges() throws {
        let taskA = try #require(FocusTask(title: "Canonical task"))
        let taskB = try #require(FocusTask(title: "Concurrent task"))
        let sentDuration = TestFixtures.durationOperation(
            id: "duration-sent",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 2_000_000
        )
        let newerDuration = TestFixtures.durationOperation(
            id: "duration-newer",
            phase: .longBreak,
            durationMs: 25 * 60_000,
            wallMs: 2_001_000
        )
        let durationResult = try PersistedQueueReconciliation.reconcileDurations(
            canonical: .defaults,
            pending: [sentDuration, newerDuration],
            sent: [sentDuration],
            acknowledgements: [DurationAcknowledgement(
                operationId: sentDuration.id,
                outcome: .applied,
                reason: ""
            )]
        )
        #expect(durationResult.pendingOperations == [newerDuration])
        #expect(durationResult.durations.longBreak == newerDuration.durationMs)

        let sentAuto = TestFixtures.autoStartOperation(
            deviceID: "device-reconcile",
            enabled: true,
            wallMs: 2_000_000
        )
        let newerAuto = TestFixtures.autoStartOperation(
            deviceID: "device-reconcile",
            enabled: false,
            wallMs: 2_001_000
        )
        let autoResult = try PersistedQueueReconciliation.reconcileAutoStart(
            canonical: true,
            deviceID: "device-reconcile",
            pending: [sentAuto, newerAuto],
            sent: [sentAuto],
            acknowledgements: [AutoStartAcknowledgement(
                operationId: sentAuto.id,
                outcome: .ignored,
                reason: "stale"
            )]
        )
        #expect(autoResult.pendingOperations == [newerAuto])
        #expect(autoResult.value)

        let sentSelection = TestFixtures.selectedTaskOperation(
            deviceID: "device-reconcile",
            taskID: taskA.id,
            wallMs: 2_000_000
        )
        let newerSelection = TestFixtures.selectedTaskOperation(
            deviceID: "device-reconcile",
            taskID: taskB.id,
            wallMs: 2_001_000
        )
        let selectionResult = try PersistedQueueReconciliation.reconcileSelectedTask(
            canonicalTaskID: taskA.id.uuidString,
            canonicalTasks: [taskA, taskB],
            deviceID: "device-reconcile",
            pending: [sentSelection, newerSelection],
            sent: [sentSelection],
            acknowledgements: [SelectedTaskAcknowledgement(
                operationId: sentSelection.id,
                outcome: .rejected,
                reason: "lost race"
            )]
        )
        #expect(selectionResult.pendingOperations == [newerSelection])
        #expect(selectionResult.selectedTaskID == taskB.id)
    }

    @Test func reconciliationFailsClosedOnInvalidCanonicalDataIdentityAndAcknowledgements() throws {
        let duration = TestFixtures.durationOperation(
            id: "duration-exact-ack",
            phase: .focus,
            durationMs: 30 * 60_000,
            wallMs: 2_000_000
        )
        #expect(throws: AppError.self) {
            _ = try PersistedQueueReconciliation.reconcileDurations(
                canonical: DurationValues(focus: 0, shortBreak: 300_000, longBreak: 900_000),
                pending: [duration],
                sent: [duration],
                acknowledgements: []
            )
        }
        let auto = TestFixtures.autoStartOperation(
            deviceID: "device-a",
            enabled: true,
            wallMs: 2_000_000
        )
        #expect(throws: AppError.self) {
            _ = try PersistedQueueReconciliation.reconcileAutoStart(
                canonical: true,
                deviceID: "device-b",
                pending: [auto],
                sent: [auto],
                acknowledgements: [AutoStartAcknowledgement(
                    operationId: auto.id,
                    outcome: .applied,
                    reason: ""
                )]
            )
        }
        #expect(throws: AppError.self) {
            _ = try PersistedQueueReconciliation.reconcileSelectedTask(
                canonicalTaskID: UUID().uuidString,
                canonicalTasks: [],
                deviceID: "device-a",
                pending: [],
                sent: [],
                acknowledgements: []
            )
        }
    }

    @Test func taskReplayAndLocalDateRetentionAreDeterministic() throws {
        let old = try #require(FocusTask(title: "Old title"))
        let renamed = try #require(FocusTask(title: "Renamed title"))
        let deleteOld = TaskOperation(
            id: "delete-old",
            taskId: old.id.uuidString.lowercased(),
            type: .delete,
            title: nil,
            occurredAt: Date(timeIntervalSince1970: 2_001),
            hlcWallMs: 2_001_000,
            hlcCounter: 0
        )
        let addRenamed = taskOperation(renamed, at: Date(timeIntervalSince1970: 2_002))
        let tasks = PersistedQueueReconciliation.applyingTaskOperations(
            [addRenamed, deleteOld],
            to: [old]
        )
        #expect(tasks == [renamed])

        let first = command(at: Date(timeIntervalSince1970: 2_000))
        let second = TimerCommand(
            id: "command-without-local-date",
            deviceSequence: 2,
            timerId: first.timerId,
            taskId: nil,
            type: .pause,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: first.occurredAt,
            hlcWallMs: first.hlcWallMs,
            hlcCounter: 1,
            observedElapsedMs: 10_000
        )
        let localDate = Date(timeIntervalSince1970: 2_010)
        let projected = PersistedQueueReconciliation.localProjection(
            of: [first, second],
            localDates: [first.id: localDate, "orphan": .distantPast]
        )
        #expect(projected[0].occurredAt == localDate)
        #expect(projected[1] == second)
        #expect(PersistedQueueReconciliation.retainedLocalCommandDates(
            [first.id: localDate, "orphan": .distantPast],
            pendingCommands: [first]
        ) == [first.id: localDate])
    }

    private func command(at date: Date) -> TimerCommand {
        TimerCommand(
            id: "command-rebase",
            deviceSequence: 1,
            timerId: "timer-rebase",
            taskId: nil,
            type: .start,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: date,
            hlcWallMs: 1_000_000,
            hlcCounter: 0,
            observedElapsedMs: 0
        )
    }

    private func taskOperation(_ task: FocusTask, at date: Date) -> TaskOperation {
        TaskOperation(
            id: "task-operation-\(task.id.uuidString.lowercased())",
            taskId: task.id.uuidString.lowercased(),
            type: .upsert,
            title: task.title,
            occurredAt: date,
            hlcWallMs: Int64(date.timeIntervalSince1970 * 1_000),
            hlcCounter: 0
        )
    }

    private func durationOperation(at date: Date) -> DurationOperation {
        DurationOperation(
            id: "duration-rebase",
            phase: .focus,
            durationMs: 30 * 60_000,
            occurredAt: date,
            hlcWallMs: 1_000_000,
            hlcCounter: 0
        )
    }

    private func allClocks(in queue: PersistedPendingOperationQueue) -> [PersistedClockValue] {
        queue.commands.map { .init(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + queue.taskOperations.map { .init(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + queue.durationOperations.map { .init(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + queue.autoStartOperations.map { .init(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
            + queue.selectedTaskOperations.map { .init(wallMs: $0.hlcWallMs, counter: $0.hlcCounter) }
    }

    private func allDates(in queue: PersistedPendingOperationQueue) -> [Date] {
        queue.commands.map(\.occurredAt)
            + queue.taskOperations.map(\.occurredAt)
            + queue.durationOperations.map(\.occurredAt)
            + queue.autoStartOperations.map(\.occurredAt)
            + queue.selectedTaskOperations.map(\.occurredAt)
    }
}

@Suite("Synchronized mutation coverage behavior")
struct SynchronizedMutationCoverageBehaviorTests {
    @Test @MainActor
    func blockedAndNoOpMutationsDoNotCreateDurableWork() throws {
        let controller = makeController()
        var state = PersistedTimerState.fresh()
        let task = try #require(FocusTask(title: "Known task"))
        state.tasks = [task]
        state.knownTasks = [task]

        #expect(try controller.plan(
            .startTimer,
            from: snapshot(state, blocked: true)
        ) == nil)
        #expect(try controller.plan(
            .selectTask(UUID()),
            from: snapshot(state)
        ) == nil)
        #expect(try controller.plan(
            .selectTask(nil),
            from: snapshot(state)
        ) == nil)
        #expect(try controller.plan(
            .setAutoStartBreaks(false),
            from: snapshot(state)
        ) == nil)
        #expect(try controller.plan(
            .setDurationMinutes(state.settings.focusMinutes, for: .focus),
            from: snapshot(state)
        ) == nil)
    }

    @Test @MainActor
    func localPhaseSelectionPersistsWithoutLaunchingSynchronization() throws {
        let state = PersistedTimerState.fresh()
        let transition = try #require(try makeController().plan(
            .selectPhase(.longBreak),
            from: snapshot(state)
        ))

        #expect(transition.state.settings.selectedPhase == .longBreak)
        #expect(transition.state.hasExplicitPhaseSelection)
        #expect(transition.state.selectedPhaseGeneration == 1)
        #expect(transition.projection == nil)
        #expect(transition.effects == [.persist])
    }

    @Test @MainActor
    func selectedTaskAutoStartAndTaskDeleteProduceWinningSynchronizedOperations() throws {
        let controller = makeController()
        let task = try #require(FocusTask(title: "Selected for focus"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.knownTasks = [task]

        let selected = try #require(try controller.plan(
            .selectTask(task.id),
            from: snapshot(state)
        ))
        let selectedID = try #require(selected.state.pendingSelectedTaskOperations.last?.id)
        #expect(selected.state.selectedTaskID == task.id)
        #expect(selected.requirements.selectedTaskOperationIDs == [selectedID.uuidString.lowercased()])
        #expect(selected.projection?.selectedTaskId == task.id.uuidString.lowercased())

        let autoStart = try #require(try controller.plan(
            .setAutoStartBreaks(true),
            from: snapshot(selected.state, selectedTaskID: task.id)
        ))
        let autoID = try #require(autoStart.state.pendingAutoStartOperations.last?.id)
        #expect(autoStart.requirements.autoStartOperationIDs == [autoID.uuidString.lowercased()])
        #expect(autoStart.projection?.autoStartBreaks == true)

        let deleted = try #require(try controller.plan(
            .task(.delete, task),
            from: snapshot(autoStart.state, selectedTaskID: task.id, autoStart: true)
        ))
        #expect(deleted.state.pendingTaskOperations.last?.type == .delete)
        #expect(deleted.state.pendingSelectedTaskOperations.last?.taskId == nil)
        #expect(deleted.requirements.taskOperationIDs.count == 1)
        #expect(deleted.requirements.selectedTaskOperationIDs.count == 1)
        #expect(deleted.projection?.tasks.isEmpty == true)
        #expect(deleted.projection?.selectedTaskId == nil)
    }

    @Test @MainActor
    func timerLifecyclePlansStartPauseResumeCancelAndClearWithRequiredEffects() throws {
        let controller = makeController()
        let task = try #require(FocusTask(title: "Lifecycle task"))
        var state = PersistedTimerState.fresh()
        state.tasks = [task]
        state.knownTasks = [task]
        state.selectedTaskID = task.id

        let started = try #require(try controller.plan(.startTimer, from: snapshot(state)))
        let running = try #require(started.projection?.canonicalTimer)
        #expect(started.state.pendingCommands.last?.taskId == task.id.uuidString.lowercased())
        #expect(started.effects.count == 5)

        let paused = try #require(try controller.plan(
            .pauseTimer(at: running.anchorAt.addingTimeInterval(10)),
            from: snapshot(started.state, timer: running, dateOffset: 10)
        ))
        let pausedTimer = try #require(paused.projection?.canonicalTimer)
        #expect(paused.state.pendingCommands.last?.type == .pause)
        #expect(pausedTimer.status == .paused)
        #expect(paused.effects.last == .alarm(
            TimerSessionController.AlarmPlan(actions: [.pause(timerID: running.id)]),
            cancelReportsError: true
        ))

        let resumed = try #require(try controller.plan(
            .resumeTimer(at: pausedTimer.anchorAt.addingTimeInterval(5)),
            from: snapshot(paused.state, timer: pausedTimer, dateOffset: 15)
        ))
        let resumedTimer = try #require(resumed.projection?.canonicalTimer)
        #expect(resumed.state.pendingCommands.last?.type == .resume)
        #expect(resumedTimer.status == .running)

        let cancelled = try #require(try controller.plan(
            .cancelTimer(at: resumedTimer.anchorAt.addingTimeInterval(5)),
            from: snapshot(resumed.state, timer: resumedTimer, dateOffset: 20)
        ))
        #expect(cancelled.state.pendingCommands.suffix(2).map(\.type) == [.cancel, .clear])
        #expect(cancelled.requirements.timerCommandIDs.count == 2)
        #expect(cancelled.projection?.canonicalTimer == nil)

        var completedState = PersistedTimerState.fresh()
        completedState.canonicalTimer = TestFixtures.timer(status: .completed, elapsed: 60_000)
        let cleared = try #require(try controller.plan(
            .clearTimer,
            from: snapshot(completedState)
        ))
        #expect(cleared.state.pendingCommands.last?.type == .clear)
        #expect(cleared.effects.suffix(2) == [
            .clearCompletionAlert(timerID: "timer-test0001"),
            .alarm(
                TimerSessionController.AlarmPlan(actions: [.cancel(timerID: "timer-test0001")]),
                cancelReportsError: false
            )
        ])
    }

    @Test @MainActor
    func explicitCommandAndPreparedCommitUseCoreProjectionTransactionBoundary() throws {
        let controller = makeController()
        let state = PersistedTimerState.fresh()
        let command = SynchronizedWorkspaceMutationController.CommandIntent(
            type: .start,
            timerID: "timer-explicit-command",
            taskID: nil,
            phase: .shortBreak,
            duration: 300,
            elapsed: 0
        )
        let commanded = try #require(try controller.plan(
            .command(command),
            from: snapshot(state)
        ))
        #expect(commanded.state.pendingCommands.last?.timerId == "timer-explicit-command")
        #expect(commanded.projection?.canonicalTimer?.phase == .shortBreak)

        var preparedState = state
        preparedState.settings.selectedPhase = .longBreak
        let committed = try #require(try controller.plan(
            .commit(.init(
                state: preparedState,
                requirements: .init()
            )),
            from: snapshot(state)
        ))
        #expect(committed.state.settings.selectedPhase == .longBreak)
        #expect(committed.requirements == .init())
        #expect(committed.effects == [
            .persistAtomically(previous: state, rebuildsOnRollback: true),
            .launchSync
        ])
    }

    @MainActor
    private func makeController() -> SynchronizedWorkspaceMutationController {
        SynchronizedWorkspaceMutationController(
            timerSessionController: TimerSessionController {
                try SharedCore.bundled()
            },
            timerIDProvider: { "timer-coverage-lifecycle" }
        )
    }

    private func snapshot(
        _ state: PersistedTimerState,
        timer: CanonicalTimer? = nil,
        selectedTaskID: UUID? = nil,
        autoStart: Bool = false,
        dateOffset: TimeInterval = 0,
        blocked: Bool = false
    ) -> SynchronizedWorkspaceMutationController.Snapshot {
        SynchronizedWorkspaceMutationController.Snapshot(
            state: state,
            canonicalTimer: timer ?? state.canonicalTimer,
            tasks: state.tasks,
            projectedAutoStartBreaks: autoStart,
            projectedSelectedTaskID: selectedTaskID ?? state.selectedTaskID,
            replicationMode: .centralized,
            localDate: Date(timeIntervalSince1970: 1_710_000_001 + dateOffset),
            trustedClockUptime: 100 + dateOffset,
            isWorkspaceMutationBlocked: blocked
        )
    }
}

@Suite("Persisted migration coverage behavior")
struct PersistedMigrationCoverageBehaviorTests {
    @Test func legacyTaskMigrationAssignsTimerSurfacesAndAvoidsDuplicateUpserts() throws {
        let task = try #require(FocusTask(title: "Migrated assignment"))
        var state = PersistedTimerState.fresh()
        state.canonicalTimer = TestFixtures.timer(status: .running, elapsed: 1_000)
        state.pendingCommands = [TestFixtures.command(.start, sequence: 1, elapsed: 0)]
        state.history = [TestFixtures.history(
            id: "timer-test0001", durationMs: 60_000, date: TestFixtures.anchor
        )]
        let legacy = LocalTaskState(
            tasks: [task], selectedTaskID: task.id, assignments: ["timer-test0001": task]
        )

        let first = try PersistedLegacyMigration.migrateTasks(
            legacy, state: &state, at: TestFixtures.anchor
        )
        let second = try PersistedLegacyMigration.migrateTasks(
            legacy, state: &state, at: TestFixtures.anchor.addingTimeInterval(1)
        )

        #expect(state.pendingCommands[0].taskId == task.id.uuidString.lowercased())
        #expect(state.canonicalTimer?.taskId == task.id.uuidString.lowercased())
        #expect(state.history[0].taskId == task.id.uuidString.lowercased())
        #expect(state.selectedTaskID == task.id)
        #expect(first.enqueuedOperationIDs.count == 1)
        #expect(second.enqueuedOperationIDs.isEmpty)
    }

    @Test func durationAndAutoStartMigrationsCoverChangedAndNoOpContracts() throws {
        var state = PersistedTimerState.fresh()
        state.settings.durationsMs.focus = 30 * 60_000
        let durations = PersistedLegacyMigration.migrateDurationSettings(state: &state)
        #expect(durations.enqueuedOperationIDs.count == 1)
        #expect(state.pendingDurationOperations[0].phase == .focus)

        let skipped = try PersistedLegacyMigration.migrateAutoStartBreaks(
            explicitlySet: false, state: &state, at: TestFixtures.anchor
        )
        #expect(!skipped.didMigrate)
        state.settings.autoStartBreaks = true
        let migrated = try PersistedLegacyMigration.migrateAutoStartBreaks(
            explicitlySet: false, state: &state, at: TestFixtures.anchor
        )
        #expect(migrated.didMigrate)
        #expect(state.pendingAutoStartOperations.last?.deviceId == state.deviceId)
    }

    @Test func selectedTaskMigrationRequiresProjectedTaskAndUsesUuidV7Identity() throws {
        let task = try #require(FocusTask(title: "Selected legacy task"))
        var state = PersistedTimerState.fresh()
        state.selectedTaskID = task.id
        let skipped = try PersistedLegacyMigration.migrateSelectedTask(
            state: &state, at: TestFixtures.anchor
        )
        #expect(!skipped.didMigrate)

        state.tasks = [task]
        let migrated = try PersistedLegacyMigration.migrateSelectedTask(
            state: &state, at: TestFixtures.anchor
        )
        #expect(migrated.didMigrate)
        #expect(state.pendingSelectedTaskOperations.last?.id == migrated.operationID)
        #expect(state.pendingSelectedTaskOperations.last?.taskId == task.id.uuidString.lowercased())
    }

    @Test func timerOwnershipMigrationAcceptsLocalOwnerAndRejectsRemoteOwner() {
        var local = PersistedTimerState.fresh()
        var localTimer = TestFixtures.timer(status: .running, elapsed: 1_000)
        localTimer.startedByDeviceId = local.deviceId
        local.canonicalTimer = localTimer
        let migrated = PersistedLegacyMigration.migrateTimerOwnership(state: &local)
        #expect(migrated.didMigrate)
        #expect(local.localTimerOwners["timer-test0001"] == local.deviceId)

        var remote = PersistedTimerState.fresh()
        var timer = TestFixtures.timer(status: .running, elapsed: 1_000)
        timer.startedByDeviceId = "other-device"
        remote.canonicalTimer = timer
        #expect(!PersistedLegacyMigration.migrateTimerOwnership(state: &remote).didMigrate)
    }

    @Test func loaderFallsBackFromCorruptCurrentWithoutUsingValidLegacyState() throws {
        let suite = "PersistedMigrationCoverage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = PersistedTimerState.fresh()
        legacy.deviceId = "legacy-device"
        defaults.set(try JSONEncoder.api.encode(legacy), forKey: PersistedStateLoader.legacyStorageKey)
        let corrupt = Data(#"{"deviceId":17}"#.utf8)
        defaults.set(corrupt, forKey: PersistedStateLoader.storageKey)

        let load = PersistedStateLoader(defaults: defaults).load()

        #expect(load.storedData == corrupt)
        #expect(load.decodedState == nil)
        #expect(load.localState.deviceId != "legacy-device")
    }

    @Test func transitionPersistenceGateFailsClosedAtEveryBoundary() {
        let valid = transition(migrations: [.tasks])
        let failed = transition(migrations: [.tasks], migrationFailed: true)
        let invalid = transition(migrations: [.tasks], stagedStateWasValid: false)
        let empty = transition(migrations: [])

        #expect(valid.shouldPersist(projectionSucceeded: true))
        #expect(!valid.shouldPersist(projectionSucceeded: false))
        #expect(!failed.shouldPersist(projectionSucceeded: true))
        #expect(!invalid.shouldPersist(projectionSucceeded: true))
        #expect(!empty.shouldPersist(projectionSucceeded: true))
        #expect(failed.shouldReportInvalidLocalClock)
    }

    private func transition(
        migrations: Set<PersistedStateMigration>,
        migrationFailed: Bool = false,
        stagedStateWasValid: Bool = true
    ) -> PersistedStateTransition {
        PersistedStateTransition(
            state: .fresh(), migrations: migrations, removesLegacyTasksAfterProjection: false,
            migrationFailed: migrationFailed, stagedStateWasValid: stagedStateWasValid
        )
    }
}

@Suite("Account lifecycle coverage behavior")
struct AccountLifecycleCoverageBehaviorTests {
    @Test @MainActor
    func busyAndStaleOperationsFailClosedWhileDeletionCompletesReset() {
        let lifecycle = makeLifecycle()
        #expect(lifecycle.beginSignIn(isWorking: true) == nil)
        #expect(lifecycle.beginSignOut(
            isWorking: true, preservesBootstrapResolution: false, pendingStrategy: nil
        ) == nil)
        #expect(lifecycle.beginAccountSwitchCancellation(
            hasPendingAccountSwitch: false, isWorking: false
        ) == nil)
        let stale = lifecycle.currentOperation
        _ = lifecycle.completeDeletion()
        #expect(lifecycle.invalidateUnauthorized(
            stale, preservesBootstrapResolution: false, pendingStrategy: nil
        ) == nil)
        #expect(lifecycle.currentOperation.generation == stale.generation + 1)
    }

    @Test @MainActor
    func bootstrapRetryChoosesSignInVerifySubmitThenPreflight() {
        let lifecycle = makeLifecycle()
        let request = BootstrapResolveRequest(
            requestId: "bootstrap-resolution-coverage", deviceId: "device-coverage",
            expectedRevision: 1, strategy: .keepRemote, commands: [], taskOperations: [],
            durationOperations: [], autoStartOperations: [], selectedTaskOperations: []
        )
        #expect(lifecycle.bootstrapRetryAction(isSignedIn: false, pendingRequest: nil) == .signIn)
        let operation = lifecycle.currentOperation
        #expect(lifecycle.bootstrapRetryAction(isSignedIn: true, pendingRequest: nil) == .verify(operation))
        lifecycle.markVerified(operation)
        #expect(lifecycle.bootstrapRetryAction(
            isSignedIn: true, pendingRequest: request
        ) == .submit(request, operation))
        #expect(lifecycle.bootstrapRetryAction(isSignedIn: true, pendingRequest: nil) == .preflight(operation))
    }

    @Test @MainActor
    func centralizedSignOutEitherPreservesResolutionOrRebuildsFreshState() {
        let lifecycle = makeLifecycle()
        var state = PersistedTimerState.fresh()
        state.nextSequence = 9

        let preserved = lifecycle.signedOutStorageTransition(
            state: state, replicationMode: .centralized,
            preservesBootstrapResolution: true, activeReturnState: nil
        )
        let cleared = lifecycle.signedOutStorageTransition(
            state: state, replicationMode: .centralized,
            preservesBootstrapResolution: false, activeReturnState: nil
        )

        #expect(preserved.state == state)
        #expect(!preserved.rebuildsProjection)
        #expect(cleared.state.nextSequence == PersistedTimerState.fresh().nextSequence)
        #expect(cleared.rebuildsProjection)
    }

    @Test @MainActor
    func identityDelegationPreservesURLResultAndSignsOutExactlyOnce() {
        let identity = RecordingGoogleIdentityProvider()
        let lifecycle = AccountLifecycleController(api: APIClient(), googleIdentityProvider: identity)
        let url = URL(string: "pomodorough://identity-callback")!

        #expect(lifecycle.handleGoogleSignInURL(url))
        lifecycle.signOutIdentity()

        #expect(identity.handledURLs == [url])
        #expect(identity.signOutCount == 1)
    }

    @MainActor
    private func makeLifecycle() -> AccountLifecycleController {
        AccountLifecycleController(
            api: APIClient(), googleIdentityProvider: RecordingGoogleIdentityProvider()
        )
    }
}
