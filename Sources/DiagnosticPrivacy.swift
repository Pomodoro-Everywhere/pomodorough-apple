import Foundation
import Sentry

// Rebuild diagnostics from an allowlist. Never carry descriptions, userInfo,
// requests, stacks, or scope metadata across the monitoring boundary.
// Fixed-taxonomy diagnostics carry only bounded literal reasons
// (operation names, capped lengths, enum outcomes, counts) — never ids,
// revisions, or user content. The capture boundary preserves the reason
// instead of collapsing it to OtherError.
protocol FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { get }
    var diagnosticDescription: String { get }
}

enum DiagnosticPrivacy {
    static let domain = "PomodoroughDiagnostic"
    static let operations: Set<String> = [
        "application.failure", "account.failure", "api.failure", "room.failure",
        "watch.failure", "persistence.failure", "timer.failure"
    ]
    static let identities: Set<String> = [
        "AppError.configuration", "AppError.missingPresentationAnchor", "AppError.missingIDToken",
        "AppError.unauthorized", "AppError.conflict", "AppError.server",
        "AppError.historyReplacementUnavailable", "AppError.invalidResponse", "AppError.invalidLocalClock",
        "NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "WCErrorDomain", "OtherError",
        "WatchCommand.unknown", "WatchCommand.staleWorkspace",
        "WatchRefusal.pause", "WatchRefusal.start", "WatchRefusal.resume", "WatchRefusal.finish",
        "Iroh.foregroundSync", "SignOut.stage", "SignOut.mutationRefused",
        "Bootstrap.batchPlan", "Sync.boundary", "Widget.decodeFailures"
    ]

    static func identity(_ error: Error) -> String {
        if let fixed = error as? any FixedTaxonomyDiagnostic {
            return fixed.diagnosticIdentity
        }
        if let error = error as? AppError {
            switch error {
            case .configuration: return "AppError.configuration"
            case .missingPresentationAnchor: return "AppError.missingPresentationAnchor"
            case .missingIDToken: return "AppError.missingIDToken"
            case .unauthorized: return "AppError.unauthorized"
            case .conflict: return "AppError.conflict"
            case .server: return "AppError.server"
            case .historyReplacementUnavailable: return "AppError.historyReplacementUnavailable"
            case .invalidResponse: return "AppError.invalidResponse"
            case .invalidLocalClock: return "AppError.invalidLocalClock"
            }
        }
        let name = (error as NSError).domain
        return identities.contains(name) ? name : "OtherError"
    }

    static func operation(file: StaticString) -> String {
        let name = String(describing: file).split(separator: "/").last.map(String.init) ?? ""
        switch name {
        case "AccountLifecycleController.swift", "SessionRevocationController.swift": return "account.failure"
        case "APIClient.swift": return "api.failure"
        case "RoomReplicationController.swift", "IrohReplicationService.swift": return "room.failure"
        case "WatchSyncService.swift": return "watch.failure"
        case "PersistedStateLoader.swift", "AppStatePersistenceCoordinator.swift", "IrohRoomStore.swift":
            return "persistence.failure"
        case "TimerAlarmScheduler.swift", "TimerSessionController.swift", "TimerLiveActivityCoordinator.swift",
             "CompletionChimePlayer.swift", "TimerDomainModels.swift", "PersistedTimerState.swift":
            return "timer.failure"
        default: return "application.failure"
        }
    }

    static func diagnostic(_ error: Error, file: StaticString = #fileID) -> NSError {
        if let fixed = error as? any FixedTaxonomyDiagnostic {
            return NSError(domain: domain, code: boundedCode((error as NSError).code), userInfo: [
                "identity": fixed.diagnosticIdentity, "operation": operation(file: file),
                NSLocalizedDescriptionKey: fixed.diagnosticDescription
            ])
        }
        let name = identity(error)
        let code = boundedCode((error as NSError).code)
        return NSError(domain: domain, code: code, userInfo: [
            "identity": name, "operation": operation(file: file),
            NSLocalizedDescriptionKey: "\(name) (\(code))"
        ])
    }

    static func publicSummary(_ error: Error) -> String {
        diagnostic(error).localizedDescription
    }

    private static func boundedCode(_ code: Int) -> Int {
        (-65535...65535).contains(code) ? code : 0
    }

    static func install(on options: Options) {
        options.sendDefaultPii = false
        #if os(iOS) || os(tvOS)
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        #endif
        options.enableLogs = false
        options.beforeSend = { event in scrub(event) }
        options.beforeBreadcrumb = { _ in nil }
        options.tracesSampleRate = 0
    }

    static func scrub(_ event: Event, validate: (Event) throws -> Void = validateEnvelope) -> Event? {
        do {
            let clean = Event(level: event.level)
            let error = event.error.map { $0 as NSError }
            let isDiagnostic = error?.domain == domain
            let candidate = isDiagnostic ? error?.userInfo["identity"] as? String : error.map { identity($0) }
            let name = candidate.flatMap { identities.contains($0) ? $0 : nil } ?? "OtherError"
            let operation = isDiagnostic ? error?.userInfo["operation"] as? String : nil
            let safeOperation = operation.flatMap { operations.contains($0) ? $0 : nil } ?? "application.failure"
            let code = boundedCode(error?.code ?? 0)
            clean.message = SentryMessage(formatted: "\(safeOperation): \(name) (\(code))")
            clean.tags = ["operation": safeOperation, "error_identity": name, "error_code": String(code)]
            clean.exceptions = [Exception(value: "\(name) (\(code))", type: name)]
            try validate(clean)
            return clean
        } catch {
            // A failed privacy check must never fall back to the original event.
            return nil
        }
    }

    private static func validateEnvelope(_ event: Event) throws {
        // Validate the actual serialized SDK payload; serialization failure drops it.
        _ = try JSONSerialization.data(withJSONObject: event.serialize())
    }
}
