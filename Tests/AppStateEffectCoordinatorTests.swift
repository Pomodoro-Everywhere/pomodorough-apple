import Foundation
import Testing
@testable import Pomodorough

@Suite("App state publication and alarm effects")
struct AppStateEffectCoordinatorTests {
    @Test @MainActor
    func publisherPreservesTaskIdentityAndCompletionCancellationPlan() throws {
        let task = try #require(FocusTask(title: "Projection task"))
        var state = PersistedTimerState.fresh()
        state.knownTasks = [task]
        let output = CoreProjectionOutput(
            canonicalTimer: nil,
            history: [],
            tasks: [task],
            durationsMs: state.settings.durationsMs,
            autoStartBreaks: true,
            selectedTaskId: task.id.uuidString.lowercased(),
            timerOutcomes: [:],
            winningOperationIds: .init(
                tasks: [:],
                durations: [:],
                autoStart: nil,
                selectedTask: nil
            )
        )

        let publication = AppStatePublisher().publication(
            output: output,
            state: state,
            completionAlertTimerID: "timer-completed",
            completionQueuedFor: "timer-completed"
        )

        #expect(publication.tasks == [task])
        #expect(publication.state.knownTasks == [task])
        #expect(publication.selectedTaskID == task.id)
        #expect(publication.autoStartBreaks)
        #expect(publication.completionAlertTimerID == "timer-completed")
        #expect(publication.completionQueuedFor == nil)
        #expect(publication.effects.isEmpty)

        let activeTimer = CanonicalTimer(
            id: "active-timer",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: Date(timeIntervalSince1970: 1_000),
            lastIntent: nil
        )
        let completion = AppStatePublisher().completionPresentation(
            alertTimerID: "timer-completed",
            currentTimer: activeTimer
        )
        #expect(completion.alertTimerID == nil)
        #expect(completion.effects == [
            .cancelAlarm(timerID: "timer-completed", reportsError: false)
        ])
    }

    @Test @MainActor
    func alarmCoordinatorPreservesEffectOrderAndFinishRouting() throws {
        let timerController = TimerSessionController(
            sharedCoreProvider: { try SharedCore.bundled() }
        )
        let coordinator = AlarmEffectCoordinator(timerSessionController: timerController)
        let effects = coordinator.effects(
            for: .init(actions: [
                .cancel(timerID: "timer-focus"),
                .schedule(timerID: "timer-break", phase: .shortBreak, duration: 300)
            ]),
            cancelReportsError: false
        )
        #expect(effects == [
            .cancel(timerID: "timer-focus", reportsError: false),
            .schedule(timerID: "timer-break", phase: .shortBreak, duration: 300)
        ])

        let fixture = try makeFinishFixture(timerController: timerController)
        let completionDate = fixture.date.addingTimeInterval(60)
        let plan = try coordinator.finishPlan(.init(
            timer: fixture.timer,
            completionDate: completionDate,
            occurredAt: completionDate,
            localDate: completionDate,
            state: fixture.state,
            replicationMode: .centralized,
            physicalNow: completionDate,
            autoStartsBreak: false
        ))
        guard case .finish(let transition) = plan else {
            Issue.record("Expected finish-only plan")
            return
        }
        #expect(transition.command.type == .finish)
        #expect(transition.command.timerId == fixture.timer.id)
    }

    @Test
    func durableDeletionJournalReopensExactRecordAndFailsClosedOnCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughDeletionJournal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let record = AccountDeletionJournal.Record(
            phase: .prepared,
            roomIDs: ["room-b", "room-a"]
        )

        try AccountDeletionJournal(fileURL: url).save(record)

        #expect(try AccountDeletionJournal(fileURL: url).load() == .record(
            .init(phase: .prepared, roomIDs: ["room-a", "room-b"])
        ))
        try Data("damaged".utf8).write(to: url, options: .atomic)
        #expect(try AccountDeletionJournal(fileURL: url).load() == .corrupt)
    }

    @Test
    func durableWorkspaceStoreReopensExactBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroughDurableWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let data = Data("durable-workspace".utf8)

        try AtomicDurableFileStore(fileURL: url).write(data)

        #expect(try AtomicDurableFileStore(fileURL: url).read() == data)
    }

    @MainActor
    private func makeFinishFixture(
        timerController: TimerSessionController
    ) throws -> (state: PersistedTimerState, timer: CanonicalTimer, date: Date) {
        var state = PersistedTimerState.fresh()
        state.settings.autoStartBreaks = false
        let date = Date(timeIntervalSince1970: 1_000)
        let start = try timerController.makeCommand(
            .init(
                type: .start,
                timerID: "timer-finish-plan",
                taskID: nil,
                phase: .focus,
                duration: 60,
                elapsed: 0,
                occurredAt: date,
                localDate: date
            ),
            state: state
        )
        state = start.state
        let timer = try #require(try timerController.project(
            state,
            now: date,
            replicationMode: .centralized,
            physicalNow: date
        ).canonicalTimer)
        return (state, timer, date)
    }
}
