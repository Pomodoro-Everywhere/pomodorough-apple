import Foundation
import Sentry
import Testing
@testable import Pomodorough

// R54-L04: Core failures keep a finite case identity and a static boundary
// through the final hook and the real SDK transport. Associated payloads
// (raw Core JSON, task ids and titles, workspace snapshots) never cross.
@Suite("R54-L04 Core diagnostic identity", .serialized)
struct CoreDiagnosticIdentityTests {
    static let payload = #"{"taskId":"l04-task-id-canary","title":"L04 Secret Task Title","#
        + #""snapshot":{"workspace":"l04-workspace-canary"}} private@example.test token=secret-canary"#
    // Numeric payloads reach user text grouped with the host locale's
    // separator (a no-break space here); scan raw and every grouped spelling.
    static let numericPayloads = [Int.max, 9_876_543, 8_675_309]
    static let canaries = [
        "l04-task-id-canary", "L04 Secret Task Title", "l04-workspace-canary",
        "private@example.test", "token=secret-canary", "taskId", "did not win"
    ] + numericPayloads.flatMap { numericSpellings($0) }

    static func numericSpellings(_ value: Int) -> [String] {
        let digits = Array(String(value))
        let groups = stride(from: digits.count, to: 0, by: -3).reversed()
            .map { String(digits[max(0, $0 - 3)..<$0]) }
        return [String(value)] + [",", ".", "'", " ", "\u{00A0}", "\u{202F}"]
            .map { groups.joined(separator: $0) }
    }

    // Bridged NSError codes follow Swift's case layout: payload cases first.
    static func coreCases(_ text: String) -> [(error: SharedCoreError, name: String, code: Int)] {
        [
            (.runtimeInitializationFailed(text), "runtimeInitializationFailed", 0),
            (.checksumMismatch(expected: text, actual: text), "checksumMismatch", 1),
            (.missingExport(text), "missingExport", 2),
            (.invalidExportSignature(text), "invalidExportSignature", 3),
            (.inputTooLarge(Int.max), "inputTooLarge", 4),
            (.allocationFailed(length: 9_876_543), "allocationFailed", 5),
            (.memoryOutOfBounds(pointer: 4_000_000_000, length: 7, byteCount: 8_675_309), "memoryOutOfBounds", 6),
            (.invalidABIResult(text), "invalidABIResult", 7),
            (.invalidInput(text), "invalidInput", 8),
            (.core(text), "core", 9),
            (.invalidResponse(text), "invalidResponse", 10),
            (.resourceMissing, "resourceMissing", 11)
        ]
    }

    @Test
    func everyCoreCaseKeepsCaseNameAndDropsPayload() throws {
        let options = Options()
        DiagnosticPrivacy.install(on: options)
        for (error, name, code) in Self.coreCases(Self.payload) {
            let identity = "SharedCoreError.\(name)"
            #expect(DiagnosticPrivacy.identities.contains(identity))
            #expect(DiagnosticPrivacy.identity(error) == identity)
            let diagnostic = DiagnosticPrivacy.diagnostic(error, file: "AppModel.swift")
            #expect(diagnostic.localizedDescription == "\(identity) (\(code))")
            // Manual diagnostics and raw automatic events take different hook branches.
            for event in [Event(error: diagnostic), Event(error: error)] {
                let clean = try #require(options.beforeSend?(event))
                #expect(clean.tags?["error_identity"] == identity)
                #expect(clean.tags?["error_code"] == String(code))
                #expect(clean.exceptions?.first?.type == identity)
                #expect(clean.exceptions?.first?.value == "\(identity) (\(code))")
                let bytes = try JSONSerialization.data(withJSONObject: clean.serialize(),
                    options: [.withoutEscapingSlashes])
                assertNoPayload(in: String(decoding: bytes, as: UTF8.self))
            }
        }
    }

    @Test
    func payloadWitnessesReachUserVisibleText() {
        // Baseline witness: the canaries are really inside each error, so a
        // clean envelope proves the scrub dropped them rather than never saw them.
        for (error, name, _) in Self.coreCases(Self.payload) where name != "resourceMissing" {
            let text = error.localizedDescription
            #expect(Self.canaries.contains { text.contains($0) }, "fixture lost payload: \(name): \(text)")
        }
    }

    @Test
    func operationTaxonomyIsTheExactStaticSet() throws {
        #expect(DiagnosticPrivacy.operations == [
            "application.failure", "account.failure", "api.failure", "room.failure",
            "watch.failure", "persistence.failure", "timer.failure",
            "mutation.failure", "projection.failure", "bootstrap.failure", "sync.failure"
        ])
        let options = Options()
        DiagnosticPrivacy.install(on: options)
        for operation in [
            "mutation.failure", "projection.failure", "bootstrap.failure", "persistence.failure", "sync.failure"
        ] {
            let error = NSError(domain: DiagnosticPrivacy.domain, code: 9, userInfo: [
                "identity": "SharedCoreError.core", "operation": operation
            ])
            let clean = try #require(options.beforeSend?(Event(error: error)))
            #expect(clean.tags?["operation"] == operation)
        }
        let forged = NSError(domain: DiagnosticPrivacy.domain, code: 9, userInfo: [
            "identity": "SharedCoreError.core", "operation": Self.payload
        ])
        let clean = try #require(options.beforeSend?(Event(error: forged)))
        #expect(clean.tags?["operation"] == "application.failure")
    }

    // Near misses of real case names: case, whitespace, control and invisible
    // characters, homoglyphs, payload suffixes, truncations and qualifiers.
    static let forgedIdentities = [
        "SharedCoreError.Core", "sharedcoreerror.core", "SHAREDCOREERROR.CORE",
        "SharedCoreError.core ", " SharedCoreError.core", "SharedCoreError.core\n",
        "SharedCoreError.core\u{0}", "SharedCoreError.core(\"\(payload)\")", "SharedCoreError.core: \(payload)",
        "SharedCoreError.", "SharedCoreError", "SharedCoreError.coreX", "SharedCoreError.core.core",
        "SharedCoreError.\u{03F2}ore", "SharedCoreError.core\u{200B}", "Pomodorough.SharedCoreError",
        "SharedCoreError.invalidResponse \(payload)", "OtherError \(payload)", ""
    ]

    static func manualDiagnostic(identity: Any, operation: Any = "mutation.failure") -> NSError {
        NSError(domain: DiagnosticPrivacy.domain, code: 9, userInfo: ["identity": identity, "operation": operation])
    }

    @Test
    func forgedPrefixedIdentitiesCollapseToOtherErrorThroughTransport() throws {
        // Controls: every real case name survives, so each forgery fails on exactness alone.
        for (_, name, _) in Self.coreCases("") {
            let diagnostic = Self.manualDiagnostic(identity: "SharedCoreError.\(name)")
            let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
            expectEnvelope(sent, operation: "mutation.failure", identity: "SharedCoreError.\(name)", code: 9)
        }
        for forged in Self.forgedIdentities {
            let diagnostic = Self.manualDiagnostic(identity: forged)
            let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
            expectEnvelope(sent, operation: "mutation.failure", identity: "OtherError", code: 9)
        }
        let untyped = Self.manualDiagnostic(identity: ["SharedCoreError.core"], operation: 7)
        let sent = try captureThroughOfflineSDK { $0.capture(error: untyped, scope: Scope()) }
        expectEnvelope(sent, operation: "application.failure", identity: "OtherError", code: 9)
    }

    @Test
    func coreCasesStayDistinctAcrossMutationAndProjectionThroughTransport() async throws {
        var pairs = Set<String>()
        for (error, name, code) in [
            (SharedCoreError.core(Self.payload), "core", 9),
            (SharedCoreError.invalidResponse(Self.payload), "invalidResponse", 10)
        ] {
            for boundary in AppModelBoundary.allCases {
                let diagnostic = try await MainActor.run { try recordedDiagnostic(error, at: boundary) }
                let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
                let identity = "SharedCoreError.\(name)"
                expectEnvelope(sent, operation: boundary.rawValue, identity: identity, code: code)
                pairs.insert("\(envelopeTag(sent, "operation"))|\(envelopeTag(sent, "error_identity"))")
            }
        }
        #expect(pairs == [
            "mutation.failure|SharedCoreError.core", "projection.failure|SharedCoreError.core",
            "mutation.failure|SharedCoreError.invalidResponse", "projection.failure|SharedCoreError.invalidResponse"
        ])
    }

    @Test
    func bootstrapBoundaryKeepsCoreCaseThroughTransport() async throws {
        let error = SharedCoreError.checksumMismatch(expected: Self.payload, actual: Self.payload)
        let diagnostic = try await MainActor.run { try bootstrapDiagnostic(error) }
        let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
        expectEnvelope(sent, operation: "bootstrap.failure", identity: "SharedCoreError.checksumMismatch", code: 1)
    }

    @Test
    func persistenceBoundarySurvivesTransport() async throws {
        let diagnostic = try await MainActor.run { try journalClearDiagnostic() }
        let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
        expectEnvelope(sent, operation: "persistence.failure", identity: "NSCocoaErrorDomain", code: 512)
    }

    @Test
    func didNotWinProjectionKeepsCaseWithoutItsTextThroughTransport() async throws {
        let error = try await MainActor.run { try didNotWinError() }
        #expect(error == .invalidResponse("new synchronized mutation did not win Core projection"))
        let diagnostic = DiagnosticPrivacy.diagnostic(error, file: "AppModel.swift")
        let sent = try captureThroughOfflineSDK { $0.capture(error: diagnostic, scope: Scope()) }
        expectEnvelope(sent, operation: "application.failure", identity: "SharedCoreError.invalidResponse", code: 10)
    }

    @Test
    func rawAutomaticCoreErrorsKeepCaseThroughTransport() throws {
        let cases: [(SharedCoreError, String, Int)] = [
            (.invalidInput(Self.payload), "invalidInput", 8),
            (.memoryOutOfBounds(pointer: 4_000_000_000, length: 7, byteCount: 8_675_309), "memoryOutOfBounds", 6)
        ]
        for (error, name, code) in cases {
            let sent = try captureThroughOfflineSDK { $0.capture(error: error, scope: Scope()) }
            expectEnvelope(sent, operation: "application.failure", identity: "SharedCoreError.\(name)", code: code)
        }
    }
}

private enum AppModelBoundary: String, CaseIterable, Sendable {
    case mutation = "mutation.failure"
    case projection = "projection.failure"
}

// Drives the production AppModel catch and returns what SentryCapture hands
// SentrySDK.capture(error:). The user reads the authored workspace sentence,
// never the raw Core text.
@MainActor
private func recordedDiagnostic(_ error: SharedCoreError, at boundary: AppModelBoundary) throws -> any Error {
    let suite = "PomodoroughTests.R54L04.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54L04-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
        api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
        roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
        alarmScheduler: RecordingAlarmScheduler(),
        sharedCoreProvider: { throw error }
    )
    model.errorMessage = nil
    let recorded = LockedTestValue<[any Error]>([])
    SentryCapture.setTestBackend { recorded.value = recorded.value + [$0] }
    defer { SentryCapture.resetForTesting() }
    switch boundary {
    case .mutation: #expect(model.start() == false)
    case .projection: #expect(model.rebuildOptimisticState() == false)
    }
    #expect(model.errorMessage == UserFacingFailure.sentence(for: error, during: .changeWorkspace))
    #expect(model.errorMessage != error.localizedDescription)
    try #require(recorded.value.count == 1, "expected one capture, got \(recorded.value.count)")
    return recorded.value[0]
}

@MainActor
private func bootstrapDiagnostic(_ error: SharedCoreError) throws -> any Error {
    SentryCapture.resetForTesting()
    let recorded = LockedTestValue<[any Error]>([])
    SentryCapture.setTestBackend { recorded.value = recorded.value + [$0] }
    defer { SentryCapture.resetForTesting() }
    let lifecycle = AccountLifecycleController(api: APIClient(),
        googleIdentityProvider: RecordingGoogleIdentityProvider())
    let transition = lifecycle.bootstrapFailure(error, stage: .submission(.keepRemote))
    #expect(transition.historyResolutionState == .retryable(.keepRemote))
    try #require(recorded.value.count == 1, "expected one capture, got \(recorded.value.count)")
    return recorded.value[0]
}

@MainActor
private func journalClearDiagnostic() throws -> any Error {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("R54L04Journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = AccountDeletionJournal(
        fileURL: directory.appendingPathComponent("deletion.json"),
        beforeClear: {
            throw NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [
                NSLocalizedDescriptionKey: CoreDiagnosticIdentityTests.payload,
                NSFilePathErrorKey: "/private/l04-workspace-canary"
            ])
        }
    )
    try journal.save(.init(phase: .prepared, roomIDs: ["l04-workspace-canary"]))
    let suite = "PomodoroughTests.R54L04Journal.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
        api: APIClient(keychain: StaticTokenStore()), defaults: defaults,
        accountDeletionJournal: journal,
        roomStore: TestFixtures.emptyIrohRoomStore(in: directory),
        alarmScheduler: RecordingAlarmScheduler()
    )
    let recorded = LockedTestValue<[any Error]>([])
    SentryCapture.setTestBackend { recorded.value = recorded.value + [$0] }
    defer { SentryCapture.resetForTesting() }
    #expect(model.clearAccountDeletionState() == false)
    try #require(recorded.value.count == 1, "expected one capture, got \(recorded.value.count)")
    return recorded.value[0]
}

// The real controller and bundled Core produce the historical did-not-win throw.
@MainActor
private func didNotWinError() throws -> SharedCoreError {
    let controller = SynchronizedWorkspaceMutationController(
        timerSessionController: TimerSessionController { try SharedCore.bundled() },
        timerIDProvider: { "timer-r54-l04" }
    )
    let state = PersistedTimerState.fresh()
    let snapshot = SynchronizedWorkspaceMutationController.Snapshot(
        state: state, canonicalTimer: state.canonicalTimer, tasks: state.tasks,
        projectedAutoStartBreaks: false, projectedSelectedTaskID: state.selectedTaskID,
        replicationMode: .centralized, localDate: Date(timeIntervalSince1970: 1_710_000_001),
        trustedClockUptime: 100, isWorkspaceMutationBlocked: false
    )
    let intent = SynchronizedWorkspaceMutationController.Intent.commit(.init(
        state: state, requirements: .init(timerCommandIDs: ["r54-l04-missing-command"])))
    do {
        _ = try controller.plan(intent, from: snapshot)
    } catch let error as SharedCoreError {
        return error
    }
    throw NSError(domain: "R54L04ExpectedDidNotWin", code: 1)
}

func envelopeTag(_ sent: OfflineSDKCapture, _ key: String) -> String {
    (sent.event["tags"] as? [String: Any])?[key] as? String ?? ""
}

func expectEnvelope(_ sent: OfflineSDKCapture, operation: String, identity: String, code: Int) {
    #expect(envelopeTag(sent, "operation") == operation)
    #expect(envelopeTag(sent, "error_identity") == identity)
    #expect(envelopeTag(sent, "error_code") == String(code))
    let values = (sent.event["exception"] as? [String: Any])?["values"] as? [[String: Any]]
    #expect(values?.count == 1)
    #expect(values?.first?["type"] as? String == identity)
    #expect(values?.first?["value"] as? String == "\(identity) (\(code))")
    let message = sent.event["message"] as? [String: Any]
    #expect(message?["formatted"] as? String == "\(operation): \(identity) (\(code))")
    assertNoPayload(in: sent.text)
}

func assertNoPayload(in serialized: String) {
    // Serializers may escape "/" as "\/"; normalize so path canaries cannot hide.
    let text = serialized.replacingOccurrences(of: "\\/", with: "/")
    for canary in CoreDiagnosticIdentityTests.canaries {
        #expect(!text.contains(canary), "serialized output leaked \(canary)")
    }
}
