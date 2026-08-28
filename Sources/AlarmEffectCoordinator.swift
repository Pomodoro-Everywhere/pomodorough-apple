import Foundation

@MainActor
struct AlarmEffectCoordinator {
    enum Effect: Equatable, Sendable {
        case schedule(timerID: String, phase: TimerPhase, duration: TimeInterval)
        case pause(timerID: String)
        case resume(timerID: String, phase: TimerPhase, duration: TimeInterval)
        case cancel(timerID: String, reportsError: Bool)
    }

    struct FinishInput: Sendable {
        let timer: CanonicalTimer
        let completionDate: Date
        let occurredAt: Date
        let localDate: Date
        let state: PersistedTimerState
        let replicationMode: ReplicationMode
        let physicalNow: Date
        let autoStartsBreak: Bool
        let automatic: Bool

        init(
            timer: CanonicalTimer,
            completionDate: Date,
            occurredAt: Date,
            localDate: Date,
            state: PersistedTimerState,
            replicationMode: ReplicationMode,
            physicalNow: Date,
            autoStartsBreak: Bool,
            automatic: Bool = false
        ) {
            self.timer = timer
            self.completionDate = completionDate
            self.occurredAt = occurredAt
            self.localDate = localDate
            self.state = state
            self.replicationMode = replicationMode
            self.physicalNow = physicalNow
            self.autoStartsBreak = autoStartsBreak
            self.automatic = automatic
        }
    }

    enum FinishPlan: Sendable {
        case ignored
        case finish(TimerSessionController.FinishTransition)
        case irohBreak(
            TimerSessionController.AutomaticBreak,
            TimerSessionController.FinishTransition
        )
        case centralizedBreak(
            TimerSessionController.AutomaticBreak,
            TimerSessionController.FinishTransition
        )
    }

    enum IrohCompletionPlan: Sendable {
        case persist(PersistedTimerState, timerID: String)
        case automaticBreak(
            state: PersistedTimerState,
            timer: CanonicalTimer,
            completedAt: Date,
            nextPhase: TimerPhase
        )
    }

    private let timerSessionController: TimerSessionController

    init(timerSessionController: TimerSessionController) {
        self.timerSessionController = timerSessionController
    }

    func effects(
        for plan: TimerSessionController.AlarmPlan,
        cancelReportsError: Bool = true
    ) -> [Effect] {
        plan.actions.map { action in
            switch action {
            case .schedule(let timerID, let phase, let duration):
                return .schedule(timerID: timerID, phase: phase, duration: duration)
            case .pause(let timerID):
                return .pause(timerID: timerID)
            case .resume(let timerID, let phase, let duration):
                return .resume(timerID: timerID, phase: phase, duration: duration)
            case .cancel(let timerID):
                return .cancel(timerID: timerID, reportsError: cancelReportsError)
            }
        }
    }

    func effects(for publicationEffects: [AppStatePublisher.Effect]) -> [Effect] {
        publicationEffects.map { effect in
            switch effect {
            case .cancelAlarm(let timerID, let reportsError):
                return .cancel(timerID: timerID, reportsError: reportsError)
            }
        }
    }

    func finishPlan(_ input: FinishInput) throws -> FinishPlan {
        guard let transition = try timerSessionController.planFinish(
            timer: input.timer,
            completionDate: input.completionDate,
            occurredAt: input.occurredAt,
            localDate: input.localDate,
            state: input.state,
            replicationMode: input.replicationMode,
            physicalNow: input.physicalNow,
            automatic: input.automatic,
            autoStartsBreak: input.autoStartsBreak
        ) else { return .ignored }
        guard transition.queueAutoBreak else {
            return .finish(transition)
        }
        let automaticBreak = timerSessionController.makeAutomaticBreak(
            phase: transition.nextPhase,
            state: transition.state
        )
        if input.replicationMode == .iroh {
            return .irohBreak(automaticBreak, transition)
        }
        return .centralizedBreak(automaticBreak, transition)
    }

    func irohCompletionPlan(
        timer: CanonicalTimer,
        at date: Date,
        state: PersistedTimerState,
        replicationMode: ReplicationMode,
        physicalNow: Date,
        autoStartsBreak: Bool
    ) throws -> IrohCompletionPlan? {
        guard let decision = try timerSessionController.completionDecision(
            for: timer,
            at: date,
            state: state,
            replicationMode: replicationMode,
            physicalNow: physicalNow,
            autoStartsBreak: autoStartsBreak
        ) else { return nil }
        var updated = state
        if !updated.hasExplicitPhaseSelection, let selectedPhase = decision.selectedPhase {
            updated.settings.selectedPhase = selectedPhase
        }
        guard let generatedBreakPhase = decision.generatedBreakPhase else {
            return .persist(updated, timerID: timer.id)
        }
        return .automaticBreak(
            state: updated,
            timer: timer,
            completedAt: decision.completedAt,
            nextPhase: generatedBreakPhase
        )
    }

    static func errorMessage(for error: Error) -> String {
        String(localized: "Timer continues in Pomodorough, but its system alarm could not be updated. \(error.localizedDescription)")
    }
}
