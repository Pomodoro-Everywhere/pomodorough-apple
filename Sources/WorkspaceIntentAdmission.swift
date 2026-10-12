import Foundation
import OSLog

enum WorkspaceIntentAdmissionError: Error {
    case coreRejected(WorkspaceMutationDiagnostics)
    case invalidCoreResponse(WorkspaceMutationDiagnostics)
    case ignoredRetarget(WorkspaceMutationDiagnostics)
}

@MainActor
final class WorkspaceIntentAdmission {
    let sharedCoreProvider: @MainActor () throws -> SharedCore
    static let logger = Logger(subsystem: "me.egigoka.pomodorough", category: "WorkspaceIntent")

    init(sharedCoreProvider: @escaping @MainActor () throws -> SharedCore) {
        self.sharedCoreProvider = sharedCoreProvider
    }

    func plan(
        kind: WorkspaceIntentKind,
        category: WorkspaceIntentCategory,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot
    ) throws -> WorkspaceIntentPlan {
        let input = try buildRequest(kind: kind, snapshot: snapshot)
        let core = try sharedCoreProvider()
        let response: WorkspaceIntentResponse
        do {
            response = try core.dispatch("workspace.intent.v1", input: input, as: WorkspaceIntentResponse.self)
        } catch let error as SharedCoreError {
            throw diagnosed(category: category, snapshot: snapshot, reason: coreMessage(error), queued: 0, applied: 0, retarget: isRetarget(kind))
        } catch {
            throw diagnosed(category: category, snapshot: snapshot, reason: String(describing: error), queued: 0, applied: 0, retarget: isRetarget(kind))
        }
        return try adopt(response: response, kind: kind, category: category, snapshot: snapshot)
    }

    func isRetarget(_ kind: WorkspaceIntentKind) -> Bool {
        if case .selectTask = kind { return true }
        return false
    }

    func coreMessage(_ error: SharedCoreError) -> String {
        switch error {
        case .core(let message): return message
        case .invalidResponse(let message): return message
        case .invalidInput(let message): return message
        default: return String(describing: error)
        }
    }

    func diagnosed(
        category: WorkspaceIntentCategory,
        snapshot: SynchronizedWorkspaceMutationController.Snapshot,
        reason: String,
        queued: Int,
        applied: Int,
        retarget: Bool
    ) -> WorkspaceIntentAdmissionError {
        let diagnostics = WorkspaceMutationDiagnostics(
            category: category,
            coreReason: reason,
            pendingCommands: snapshot.state.pendingCommands.count,
            pendingTasks: snapshot.state.pendingTaskOperations.count,
            pendingDurations: snapshot.state.pendingDurationOperations.count,
            pendingAutoStart: snapshot.state.pendingAutoStartOperations.count,
            pendingSelected: snapshot.state.pendingSelectedTaskOperations.count,
            queued: queued,
            applied: applied,
            isIgnoredRetarget: retarget && reason.contains("retained-ledger"),
            provenance: WorkspaceIntentProvenance.current()
        )
        Self.logger.error("\(diagnostics.publicMessage(), privacy: .public)")
        if diagnostics.isIgnoredRetarget {
            return .ignoredRetarget(diagnostics)
        }
        return .coreRejected(diagnostics)
    }
}

struct WorkspaceIntentPlan: Sendable {
    let state: PersistedTimerState
    let projection: CoreProjectionOutput?
    let requirements: SynchronizedWorkspaceMutationController.Requirements
    let queued: Int
    let applied: Int
    let coreReason: String
}
