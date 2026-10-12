import Foundation
import OSLog

extension WorkspaceIntentAdmission {
    func adopt(
        response: WorkspaceIntentResponse,
        kind: WorkspaceIntentKind,
        category: WorkspaceIntentCategory,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) throws -> WorkspaceIntentPlan {
        let parts = try validatedParts(response: response, category: category, snapshot: snapshot)
        try ensureChanged(response: response, category: category, snapshot: snapshot)
        var state = snapshot.state
        try applyQueues(workspaceLocal: parts.local, neverSent: parts.neverSent, state: &state)
        applyAllocation(allocation: parts.allocation, state: &state)
        try applyObservation(observation: parts.observation, state: &state)
        applySelection(selection: parts.selection, state: &state)
        applyDependencies(workspace: parts.workspace, state: &state)
        applyOwnership(response: response, state: &state)
        applyOptimistic(kind: kind, snapshot: snapshot, state: &state)
        return makePlan(response: response, state: state)
    }

    func validatedParts(
        response: WorkspaceIntentResponse,
        category: WorkspaceIntentCategory,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) throws -> (
        workspace: WorkspaceIntentResponseWorkspace,
        local: WorkspaceIntentResponseLocal,
        neverSent: WorkspaceIntentResponseNeverSent,
        allocation: WorkspaceIntentResponseAllocation,
        observation: WorkspaceIntentResponseObservation,
        selection: WorkspaceIntentResponseSelection
    ) {
        guard response.outcome == "planned",
              let workspace = response.workspace,
              let local = workspace.local,
              let neverSent = workspace.neverSent,
              let allocation = response.allocation,
              let observation = response.observation,
              let selection = response.selection else {
            throw diagnosed(
                category: category,
                snapshot: snapshot,
                reason: response.reason ?? "invalid Core plan",
                queued: 0,
                applied: 0,
                retarget: false
            )
        }
        return (workspace, local, neverSent, allocation, observation, selection)
    }

    func ensureChanged(
        response: WorkspaceIntentResponse,
        category: WorkspaceIntentCategory,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) throws {
        let counts = outcomeCounts(response: response)
        let hasMembers = response.commands?.isEmpty == false || hasNewOperations(response: response)
        guard !hasMembers, selectionUnchanged(response: response, snapshot: snapshot) else { return }
        throw diagnosed(
            category: category,
            snapshot: snapshot,
            reason: "unchangedOrIneligible",
            queued: counts.queued,
            applied: counts.applied,
            retarget: false
        )
    }

    func makePlan(response: WorkspaceIntentResponse, state: PersistedTimerState) -> WorkspaceIntentPlan {
        let counts = outcomeCounts(response: response)
        return WorkspaceIntentPlan(
            state: state,
            projection: response.projection,
            requirements: planRequirements(response: response),
            queued: counts.queued,
            applied: counts.applied,
            coreReason: response.reason ?? ""
        )
    }

    func outcomeCounts(response: WorkspaceIntentResponse) -> (queued: Int, applied: Int) {
        var queued = 0
        var applied = 0
        let groups: [[WorkspaceIntentOutcome]?] = [
            response.groupOutcomes?.commands,
            response.groupOutcomes?.taskOperations,
            response.groupOutcomes?.durationOperations,
            response.groupOutcomes?.autoStartOperations,
            response.groupOutcomes?.selectedTaskOperations,
        ]
        for group in groups {
            for outcome in group ?? [] {
                if outcome.outcome == "queued" { queued += 1 }
                if outcome.outcome == "applied" { applied += 1 }
            }
        }
        for outcome in response.commandOutcomes ?? [] {
            if outcome.outcome == "queued" { queued += 1 }
            if outcome.outcome == "applied" { applied += 1 }
        }
        return (queued, applied)
    }

    func hasNewOperations(response: WorkspaceIntentResponse) -> Bool {
        let ids = response.atomicOperationIds
        let commands = response.atomicCommandIds ?? []
        return !(commands.isEmpty
            && (ids?.taskOperations ?? []).isEmpty
            && (ids?.durationOperations ?? []).isEmpty
            && (ids?.autoStartOperations ?? []).isEmpty
            && (ids?.selectedTaskOperations ?? []).isEmpty)
    }

    func selectionUnchanged(
        response: WorkspaceIntentResponse,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) -> Bool {
        (response.commands ?? []).isEmpty && !hasNewOperations(response: response)
    }
}
