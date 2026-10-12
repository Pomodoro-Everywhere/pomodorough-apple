import Foundation

extension WorkspaceIntentAdmission {
    func buildRequest(
        kind: WorkspaceIntentKind,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) throws -> WorkspaceIntentRequest {
        let state = snapshot.state
        let occurredAt = try state.trustedOccurrenceDate(for: snapshot.localDate, uptime: snapshot.trustedClockUptime)
        let selection = intentSelection(state: state)
        let allocation = intentAllocation(state: state)
        let observation = intentObservation(state: state)
        let clock = intentClock(occurredAt: occurredAt, physicalNow: snapshot.localDate)
        let identities = try intentIdentities(kind: kind, state: state, occurredAt: occurredAt)
        let intervals = intentIntervals(occurredAt: occurredAt)
        let workspace = intentWorkspace(state: state, snapshot: snapshot)
        let ownership = intentOwnership(kind: kind, state: state)
        let durability = intentDurability(kind: kind, state: state)
        let localDurations = intentLocalDurations(kind: kind, state: state)
        return WorkspaceIntentRequest(
            replicationMode: snapshot.replicationMode == .centralized ? "centralized" : "iroh",
            intent: kind,
            workspace: workspace,
            selection: selection,
            allocation: allocation,
            observation: observation,
            clock: clock,
            identities: identities,
            calendarIntervals: intervals,
            ownership: ownership,
            durability: durability,
            localDurationsMs: localDurations
        )
    }

    func intentSelection(state: PersistedTimerState) -> WorkspaceIntentSelection {
        WorkspaceIntentSelection(
            phase: state.settings.selectedPhase,
            generation: String(state.selectedPhaseGeneration),
            explicit: state.hasExplicitPhaseSelection
        )
    }

    func intentAllocation(state: PersistedTimerState) -> WorkspaceIntentAllocation {
        WorkspaceIntentAllocation(
            deviceId: state.deviceId,
            deviceSequence: state.nextSequence - 1,
            hlc: WorkspaceIntentHLC(wallMs: state.hlcWallMs, counter: state.hlcCounter),
            lastUuid: state.lastUuidV7?.uuidString.lowercased()
        )
    }

    func intentObservation(state: PersistedTimerState) -> WorkspaceIntentObservation {
        var times: [String: String] = [:]
        for (id, date) in state.localCommandDates {
            if let string = APIDateCodec.string(from: date) {
                times[id] = string
            }
        }
        return WorkspaceIntentObservation(canonicalAnchorAt: nil, commandTimes: times)
    }

    func intentClock(occurredAt: Date, physicalNow: Date) -> WorkspaceIntentClock {
        WorkspaceIntentClock(occurredAt: occurredAt, physicalNow: physicalNow, observedAt: physicalNow)
    }

    func intentIntervals(occurredAt: Date) -> [WorkspaceIntentInterval] {
        guard let day = Calendar.current.dateInterval(of: .day, for: occurredAt),
              let start = APIDateCodec.string(from: day.start),
              let end = APIDateCodec.string(from: day.end) else { return [] }
        return [WorkspaceIntentInterval(start: start, end: end)]
    }
}
