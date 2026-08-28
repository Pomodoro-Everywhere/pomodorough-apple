import Foundation
import Testing
@testable import Pomodorough

@Suite("Responsibility split compatibility")
struct ResponsibilitySplitCompatibilityTests {
    @Test @MainActor
    func timerControllerReturnsAtomicCommandTransitionAndAlarmPlan() throws {
        let controller = TimerSessionController(sharedCoreProvider: { try SharedCore.bundled() })
        let original = PersistedTimerState.fresh()
        let date = Date(timeIntervalSince1970: 1_000)
        let transition = try controller.makeCommand(
            .init(
                type: .start,
                timerID: "timer-split0001",
                taskID: "task-split0001",
                phase: .focus,
                duration: 60,
                elapsed: 0,
                occurredAt: date,
                localDate: date
            ),
            state: original
        )

        #expect(original.pendingCommands.isEmpty)
        #expect(transition.state.pendingCommands == [transition.command])
        #expect(transition.command.deviceSequence == 1)
        #expect(transition.command.taskId == "task-split0001")
        #expect(transition.state.localTimerOwners["timer-split0001"] == original.deviceId)
        #expect(try JSONDecoder.api.decode(
            TimerCommand.self,
            from: JSONEncoder.api.encode(transition.command)
        ) == transition.command)
        #expect(controller.alarmPlan(for: .resume(
            timerID: "timer-split0001",
            phase: .focus,
            duration: 42
        )).actions == [.resume(
            timerID: "timer-split0001",
            phase: .focus,
            duration: 42
        )])
        let automaticBreak = controller.makeAutomaticBreak(
            phase: .shortBreak,
            state: transition.state
        )
        #expect(controller.automaticBreakAlarmPlan(
            automaticBreak,
            replacing: "timer-split0001",
            cancelsPreviousAlarm: true
        ).actions == [
            .cancel(timerID: "timer-split0001"),
            .schedule(
                timerID: automaticBreak.timerID,
                phase: automaticBreak.phase,
                duration: automaticBreak.duration
            )
        ])
        #expect(TimerSessionController.nextPhaseGeneration(after: .max) == 0)
    }

    @Test @MainActor
    func synchronizationPlanStopsAtProvisionalBreakWithoutReordering() throws {
        let controller = TimerSessionController(sharedCoreProvider: { try SharedCore.bundled() })
        let synchronization = AccountSynchronization(
            api: APIClient(),
            sharedCoreProvider: { try SharedCore.bundled() }
        )
        let date = Date(timeIntervalSince1970: 2_000)
        let finish = try controller.makeCommand(
            .init(
                type: .finish,
                timerID: "timer-focus0001",
                taskID: nil,
                phase: .focus,
                duration: 60,
                elapsed: 60,
                occurredAt: date,
                localDate: date
            ),
            state: .fresh()
        )
        let start = try controller.makeCommand(
            .init(
                type: .start,
                timerID: "timer-break0001",
                taskID: nil,
                phase: .shortBreak,
                duration: 30,
                elapsed: 0,
                occurredAt: date,
                localDate: date
            ),
            state: finish.state
        )
        var state = start.state
        state.provisionalBreaks = [ProvisionalBreak(
            focusTimerId: "timer-focus0001",
            finishCommandId: finish.command.id,
            breakTimerId: "timer-break0001",
            startCommandId: start.command.id
        )]

        let plan = synchronization.makeSyncPlan(state: state)
        #expect(plan.batch.commands.map(\.id) == [finish.command.id])
        #expect(plan.request.commands.map(\.id) == [finish.command.id])
        #expect(plan.request.lastRevision == state.revision)
        #expect(state.pendingCommands.map(\.id) == [finish.command.id, start.command.id])
    }

    @Test @MainActor
    func appModelKeepsTimerCommandOrderAndAlarmOrder() async throws {
        let suiteName = "ResponsibilitySplitCompatibilityTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingUserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingAlarmScheduler()
        let anchor = Date(timeIntervalSince1970: 1_000)
        let model = AppModel(
            defaults: defaults,
            alarmScheduler: scheduler,
            now: { anchor },
            uptime: { 100 }
        )
        model.setDurationMinutes(1, for: .focus)

        model.start()
        await model.waitForAlarmOperations()
        let running = try #require(model.canonicalTimer)
        model.pause(at: running.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()
        let paused = try #require(model.canonicalTimer)
        model.resume(at: paused.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()
        let resumed = try #require(model.canonicalTimer)
        model.cancel(at: resumed.anchorAt.addingTimeInterval(10))
        await model.waitForAlarmOperations()

        let data = try #require(defaults.data(forKey: PersistedStateLoader.storageKey))
        let state = try JSONDecoder.api.decode(PersistedTimerState.self, from: data)
        #expect(state.pendingCommands.map(\.type) == [.start, .pause, .resume, .cancel, .clear])
        #expect(state.pendingCommands.map(\.deviceSequence) == [1, 2, 3, 4, 5])
        #expect(state.pendingCommands.suffix(2).map(\.occurredAt).allSatisfy {
            $0 == state.pendingCommands[state.pendingCommands.count - 2].occurredAt
        })
        #expect(state.pendingCommands.suffix(2).map(\.observedElapsedMs).allSatisfy {
            $0 == state.pendingCommands[state.pendingCommands.count - 2].observedElapsedMs
        })
        #expect(scheduler.operations == [
            .schedule(timerID: running.id, phase: .focus, duration: 60),
            .pause(timerID: running.id),
            .resume(timerID: running.id, phase: .focus, duration: 50),
            .cancel(timerID: running.id)
        ])
    }

    @Test @MainActor
    func sharedCoreTimeCompletionMatchesNativeHistoryProjection() throws {
        let timer = TestFixtures.timer(status: .running, elapsed: 0)
        let completionDate = timer.anchorAt.addingTimeInterval(timer.plannedDuration)
        let native = TimerReducer.projectingTimeCompletion(timer, history: [], at: completionDate)
        let core = try SharedCore.bundled()
        let output = try core.applyProjection(CoreProjectionInput(
            base: CoreProjectionBase(
                canonicalTimer: timer,
                history: [],
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: false,
                selectedTaskId: nil
            ),
            pending: CoreProjectionPending(
                commands: [],
                taskOperations: [],
                durationOperations: [],
                autoStartOperations: [],
                selectedTaskOperations: []
            ),
            now: completionDate
        ))

        #expect(native.timer?.status == .completed)
        #expect(output.canonicalTimer == native.timer)
        #expect(output.history == native.history)
    }
}
