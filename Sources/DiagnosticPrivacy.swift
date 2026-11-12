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

// Static monitoring boundaries. The capturing file picks a default; sites in
// files that span several boundaries (AppModel) name theirs explicitly so the
// final hook can tell a durable mutation from a projection or a bootstrap.
enum DiagnosticOperation: String, CaseIterable, Sendable {
    case application = "application.failure"
    case account = "account.failure"
    case api = "api.failure"
    case room = "room.failure"
    case watch = "watch.failure"
    case persistence = "persistence.failure"
    case timer = "timer.failure"
    case mutation = "mutation.failure"
    case projection = "projection.failure"
    case bootstrap = "bootstrap.failure"
    case sync = "sync.failure"
}

enum DiagnosticPrivacy {
    static let domain = "PomodoroughDiagnostic"
    static let operations = Set(DiagnosticOperation.allCases.map(\.rawValue))
    static let identities: Set<String> = [
        "AppError.configuration", "AppError.missingPresentationAnchor", "AppError.missingIDToken",
        "AppError.unauthorized", "AppError.conflict", "AppError.server",
        "AppError.historyReplacementUnavailable", "AppError.invalidResponse", "AppError.invalidLocalClock",
        "NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "WCErrorDomain", "OtherError",
        "WatchCommand.unknown", "WatchCommand.staleWorkspace",
        "WatchRefusal.pause", "WatchRefusal.start", "WatchRefusal.resume", "WatchRefusal.finish",
        "Iroh.foregroundSync", "SignOut.stage", "SignOut.mutationRefused",
        "Bootstrap.batchPlan", "Bootstrap.install", "Sync.boundary", "Widget.decodeFailures",
        "WorkspaceIntent.coreRejected", "WorkspaceIntent.invalidCoreResponse",
        "WorkspaceIntent.ignoredRetarget",
        "AccountSwitch.confirm", "AccountSwitch.cancel", "Iroh.foregroundRefresh",
        "SharedCoreError.resourceMissing", "SharedCoreError.runtimeInitializationFailed",
        "SharedCoreError.checksumMismatch", "SharedCoreError.missingExport",
        "SharedCoreError.invalidExportSignature", "SharedCoreError.inputTooLarge",
        "SharedCoreError.allocationFailed", "SharedCoreError.memoryOutOfBounds",
        "SharedCoreError.invalidABIResult", "SharedCoreError.invalidInput",
        "SharedCoreError.core", "SharedCoreError.invalidResponse"
    ]
    // System domains reported by name. Kept apart from `identities` so an
    // NSError whose domain spells a fixed or Core identity stays OtherError.
    static let errorDomains: Set<String> = [
        "NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "WCErrorDomain"
    ]

    static func identity(_ error: Error) -> String {
        if let fixed = error as? any FixedTaxonomyDiagnostic {
            return fixed.diagnosticIdentity
        }
        if let error = error as? SharedCoreError {
            return coreIdentity(error)
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
        return errorDomains.contains(name) ? name : "OtherError"
    }

    // Case name only. Core payloads can carry raw JSON, task ids or titles, and
    // workspace snapshots, so no associated value crosses this boundary.
    private static func coreIdentity(_ error: SharedCoreError) -> String {
        switch error {
        case .resourceMissing: return "SharedCoreError.resourceMissing"
        case .runtimeInitializationFailed: return "SharedCoreError.runtimeInitializationFailed"
        case .checksumMismatch: return "SharedCoreError.checksumMismatch"
        case .missingExport: return "SharedCoreError.missingExport"
        case .invalidExportSignature: return "SharedCoreError.invalidExportSignature"
        case .inputTooLarge: return "SharedCoreError.inputTooLarge"
        case .allocationFailed: return "SharedCoreError.allocationFailed"
        case .memoryOutOfBounds: return "SharedCoreError.memoryOutOfBounds"
        case .invalidABIResult: return "SharedCoreError.invalidABIResult"
        case .invalidInput: return "SharedCoreError.invalidInput"
        case .core: return "SharedCoreError.core"
        case .invalidResponse: return "SharedCoreError.invalidResponse"
        }
    }

    static func operation(file: StaticString) -> DiagnosticOperation {
        let name = String(describing: file).split(separator: "/").last.map(String.init) ?? ""
        switch name {
        case "AccountLifecycleController.swift", "SessionRevocationController.swift": return .account
        case "APIClient.swift": return .api
        case "RoomReplicationController.swift", "IrohReplicationService.swift": return .room
        case "WatchSyncService.swift": return .watch
        case "PersistedStateLoader.swift", "AppStatePersistenceCoordinator.swift", "IrohRoomStore.swift":
            return .persistence
        case "TimerAlarmScheduler.swift", "TimerSessionController.swift", "TimerLiveActivityCoordinator.swift",
             "CompletionChimePlayer.swift", "TimerDomainModels.swift", "PersistedTimerState.swift":
            return .timer
        default: return .application
        }
    }

    static func diagnostic(
        _ error: Error,
        operation: DiagnosticOperation? = nil,
        file: StaticString = #fileID
    ) -> NSError {
        let boundary = (operation ?? Self.operation(file: file)).rawValue
        let code = boundedCode((error as NSError).code)
        if let fixed = error as? any FixedTaxonomyDiagnostic {
            return NSError(domain: domain, code: code, userInfo: [
                "identity": fixed.diagnosticIdentity, "operation": boundary,
                NSLocalizedDescriptionKey: fixed.diagnosticDescription
            ])
        }
        let name = identity(error)
        return NSError(domain: domain, code: code, userInfo: [
            "identity": name, "operation": boundary,
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
            preserveMetadata(from: event, on: clean)
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

    private static func preserveMetadata(from event: Event, on clean: Event) {
        clean.eventId = event.eventId
        clean.timestamp = event.timestamp
        if let environment = event.environment,
           ["development", "testflight", "production"].contains(environment) {
            clean.environment = environment
        }
        // Historical crashes retain their own numeric version@build, never today's build.
        // Reject arbitrary scope text; the release suffix owns dist because the SDK
        // may have filled a missing historical dist with the current bundle's build.
        if let release = event.releaseName,
           release.range(of: #"\A[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}@[0-9]{1,10}\z"#,
               options: .regularExpression) != nil {
            clean.releaseName = release
            clean.dist = release.split(separator: "@").last.map(String.init)
        } else if event.releaseName == nil, let dist = event.dist,
                  dist.range(of: #"\A[0-9]{1,10}\z"#, options: .regularExpression) != nil {
            clean.dist = dist
        }
    }
}

// WatchSyncPayload.swift compiles standalone inside the R49-AP06 probe,
// so the watch fixed-taxonomy conformances live here rather than beside
// their types. Reasons stay bare literals: never ids or user content.
extension WatchUnknownCommandError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { "WatchCommand.unknown" }
    var diagnosticDescription: String { errorDescription ?? diagnosticIdentity }
}

extension WatchPauseRefusedError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { "WatchRefusal.pause" }
    var diagnosticDescription: String { errorDescription ?? diagnosticIdentity }
}

extension WatchStartRefusedError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { "WatchRefusal.start" }
    var diagnosticDescription: String { errorDescription ?? diagnosticIdentity }
}

extension WatchResumeRefusedError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { "WatchRefusal.resume" }
    var diagnosticDescription: String { errorDescription ?? diagnosticIdentity }
}

extension WatchFinishRefusedError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { "WatchRefusal.finish" }
    var diagnosticDescription: String { errorDescription ?? diagnosticIdentity }
}

extension WatchStaleWorkspaceError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String { "WatchCommand.staleWorkspace" }
    var diagnosticDescription: String { errorDescription ?? diagnosticIdentity }
}

// WorkspaceIntentAdmission.swift is peer-owned, so the admission identity is
// classified here at the capture boundary. Only the case name, the static
// category, and counts cross it: never the Core reason or the provenance.
extension WorkspaceIntentAdmissionError: FixedTaxonomyDiagnostic {
    var diagnosticIdentity: String {
        switch self {
        case .coreRejected: "WorkspaceIntent.coreRejected"
        case .invalidCoreResponse: "WorkspaceIntent.invalidCoreResponse"
        case .ignoredRetarget: "WorkspaceIntent.ignoredRetarget"
        }
    }

    var diagnosticDescription: String {
        let diagnostics: WorkspaceMutationDiagnostics
        switch self {
        case .coreRejected(let value), .invalidCoreResponse(let value), .ignoredRetarget(let value):
            diagnostics = value
        }
        let pending = [
            diagnostics.pendingCommands, diagnostics.pendingTasks, diagnostics.pendingDurations,
            diagnostics.pendingAutoStart, diagnostics.pendingSelected
        ].map(String.init).joined(separator: "/")
        return "\(diagnosticIdentity) category=\(diagnostics.category.rawValue) pending=\(pending) "
            + "queued=\(diagnostics.queued) applied=\(diagnostics.applied)"
    }
}
