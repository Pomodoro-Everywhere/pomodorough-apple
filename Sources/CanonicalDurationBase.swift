import Foundation
import OSLog

extension PersistedTimerState {
    func canonicalDurations() -> DurationValues {
        canonicalDurationsMs ?? settings.durationsMs
    }

    func isDurationDomainSuppressed() -> Bool {
        !pendingDurationOperations.isEmpty
            && safeProjectionDurationOperations().isEmpty
    }

    func effectiveDurationMs(for phase: TimerPhase) -> Int64 {
        if isDurationDomainSuppressed() {
            return canonicalDurations().durationMs(for: phase)
        }
        return settings.durationMs(for: phase)
    }

    mutating func installCanonicalDurations(_ values: DurationValues) {
        canonicalDurationsMs = values
    }
}

struct DurationBaseDiagnostics: Sendable {
    let category: WorkspaceIntentCategory
    let reason: String
    let pendingDurations: Int
    let hasCanonical: Bool
    let usesCanonical: Bool
    let suppressed: Bool
    let provenance: String

    func publicMessage() -> String {
        String(localized: "durationBase category=\(category.rawValue) reason=\(reason) ")
            + String(localized: "pendingDurations=\(pendingDurations) ")
            + String(localized: "hasCanonical=\(hasCanonical) usesCanonical=\(usesCanonical) ")
            + String(localized: "suppressed=\(suppressed) core=\(provenance)")
    }
}

extension DurationBaseDiagnostics {
    static func log(
        category: WorkspaceIntentCategory,
        reason: String,
        state: PersistedTimerState
    ) -> DurationBaseDiagnostics {
        let diagnostics = DurationBaseDiagnostics(
            category: category,
            reason: reason,
            pendingDurations: state.pendingDurationOperations.count,
            hasCanonical: state.canonicalDurationsMs != nil,
            usesCanonical: state.isDurationDomainSuppressed(),
            suppressed: state.isDurationDomainSuppressed(),
            provenance: WorkspaceIntentProvenance.current()
        )
        Logger(subsystem: "me.egigoka.pomodorough", category: "DurationBase")
            .error("\(diagnostics.publicMessage(), privacy: .public)")
        return diagnostics
    }
}
