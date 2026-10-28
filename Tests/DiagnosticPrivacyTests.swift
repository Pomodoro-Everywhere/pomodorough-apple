import Foundation
import Sentry
import Testing
@testable import Pomodorough

@Suite("R53-L01 final diagnostic privacy")
struct DiagnosticPrivacyTests {
    static let canaries = [
        "private@example.test", "token=secret-canary", "invite-secret-canary",
        "https://private.test/#secret", "/private/account/secret", "Secret Task Title"
    ]

    @Test
    func finalHooksDiscardAutomaticPayloadAndBreadcrumbs() throws {
        let options = Options()
        DiagnosticPrivacy.install(on: options)
        let event = contaminatedEvent()
        let clean = try #require(options.beforeSend?(event))
        try assertNoCanaries(clean)
        #expect(clean.tags?["error_identity"] == "NSURLErrorDomain")
        #expect(clean.tags?["error_code"] == "-1001")
        let exceptions = try #require(clean.exceptions)
        #expect(exceptions.count == 1)
        #expect(exceptions.first?.type == "NSURLErrorDomain")
        #expect(exceptions.first?.value == "NSURLErrorDomain (-1001)")
        #expect(clean.request == nil)
        #expect(clean.context == nil)
        #expect(clean.extra == nil)
        #expect(clean.error == nil)
        let breadcrumb = Breadcrumb()
        breadcrumb.message = Self.canaries.joined(separator: " ")
        breadcrumb.data = ["url": Self.canaries]
        #expect(options.beforeBreadcrumb?(breadcrumb) == nil)
    }

    @Test
    func manualIdentitySurvivesFinalHookWithoutUserText() throws {
        let message = Self.canaries.joined(separator: " ")
        let original = AppError.server(message)
        #expect(original.localizedDescription == message)
        let diagnostic = DiagnosticPrivacy.diagnostic(original, file: "AccountLifecycleController.swift")
        let options = Options()
        DiagnosticPrivacy.install(on: options)
        let clean = try #require(options.beforeSend?(Event(error: diagnostic)))
        try assertNoCanaries(clean)
        #expect(clean.tags?["operation"] == "account.failure")
        #expect(clean.tags?["error_identity"] == "AppError.server")
        let exceptions = try #require(clean.exceptions)
        #expect(exceptions.count == 1)
        #expect(exceptions.first?.type == "AppError.server")
        #expect(exceptions.first?.value == "AppError.server (1)")
        #expect(!DiagnosticPrivacy.publicSummary(original).contains(message))
        #expect(original.localizedDescription == message)
    }

    @Test
    func failedPrivacyValidationDropsRatherThanReturnsOriginal() {
        let event = contaminatedEvent()
        let clean = DiagnosticPrivacy.scrub(event) { _ in throw URLError(.cannotDecodeContentData) }
        #expect(clean == nil)
    }

    @Test
    func finalHookPreservesHistoricalMetadataWithoutPrivatePayload() throws {
        let options = Options()
        options.releaseName = "0.53.0@62"
        options.environment = "production"
        DiagnosticPrivacy.install(on: options)
        let event = contaminatedEvent()
        event.releaseName = "0.47.0@56"
        event.environment = "testflight"
        event.dist = "62" // SDK fallback can supply today's build for an old crash.
        event.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let originalID = event.eventId.sentryIdString
        let clean = try #require(options.beforeSend?(event))
        try assertNoCanaries(clean)
        let payload = clean.serialize()
        #expect(payload["event_id"] as? String == originalID)
        #expect((payload["timestamp"] as? NSNumber)?.doubleValue == 1_700_000_000)
        #expect(payload["release"] as? String == "0.47.0@56")
        #expect(payload["environment"] as? String == "testflight")
        #expect(payload["dist"] as? String == "56")
        #expect(clean.user == nil)
        #expect(clean.threads == nil)
        #expect(clean.stacktrace == nil)
    }

    @Test
    func finalHookRejectsUnboundedMetadata() throws {
        for value in Self.canaries + ["0.47.0@56\n", "0.47.0@56-secret", "0.47.0@12345678901"] {
            let event = contaminatedEvent()
            event.releaseName = value
            event.environment = value
            event.dist = value
            let options = Options()
            DiagnosticPrivacy.install(on: options)
            let clean = try #require(options.beforeSend?(event))
            try assertNoCanaries(clean)
            #expect(clean.releaseName == nil)
            #expect(clean.environment == nil)
            #expect(clean.dist == nil)
        }
    }

    @Test
    func finalHookPreservesCurrentMetadataAndNumericDistWithoutRelease() throws {
        let options = Options()
        DiagnosticPrivacy.install(on: options)
        for environment in ["development", "testflight", "production"] {
            let event = contaminatedEvent()
            event.releaseName = "0.53.0@62"
            event.environment = environment
            event.dist = "62"
            let clean = try #require(options.beforeSend?(event))
            try assertNoCanaries(clean)
            #expect(clean.releaseName == event.releaseName)
            #expect(clean.environment == environment)
            #expect(clean.dist == "62")
        }
        let event = contaminatedEvent()
        event.dist = "62"
        let clean = try #require(options.beforeSend?(event))
        #expect(clean.releaseName == nil)
        #expect(clean.dist == "62")
        try assertNoCanaries(clean)
    }

    @Test
    func fixedTaxonomyReasonsSurviveCaptureBoundary() {
        // R53 regression pin: ca24aad collapsed every fixed literal to
        // OtherError. Operation names are static taxonomy, not user data.
        let cases: [(Error, String, String)] = [
            (WatchPauseRefusedError(), "WatchRefusal.pause", "pause"),
            (WatchStartRefusedError(), "WatchRefusal.start", "start"),
            (WatchResumeRefusedError(), "WatchRefusal.resume", "resume"),
            (WatchFinishRefusedError(), "WatchRefusal.finish", "finish"),
            (WatchUnknownCommandError(nameLength: 6), "WatchCommand.unknown", "unknown_command len=6"),
            (WatchStaleWorkspaceError(), "WatchCommand.staleWorkspace", "stale_workspace"),
            (IrohForegroundSyncDiagnostics(), "Iroh.foregroundSync", "foreground backend=iroh outcome=sync-false"),
        ]
        for (error, identity, reason) in cases {
            #expect(DiagnosticPrivacy.identities.contains(identity))
            #expect(DiagnosticPrivacy.identity(error) == identity)
            #expect(DiagnosticPrivacy.diagnostic(error).localizedDescription == reason)
        }
    }

    @Test
    func unknownDomainsAndOversizedCodesAreBounded() throws {
        let error = NSError(domain: Self.canaries[0], code: Int.max,
            userInfo: [NSLocalizedDescriptionKey: Self.canaries[1]])
        let clean = try #require(DiagnosticPrivacy.scrub(Event(error: error)))
        try assertNoCanaries(clean)
        #expect(clean.tags?["error_identity"] == "OtherError")
        #expect(clean.tags?["error_code"] == "0")
    }

    @Test @MainActor
    func apiResponseCanariesKeepRetryOutcomeThroughFinalHook() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        #expect(try await client.restoreTokens())
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            let options = Options()
            DiagnosticPrivacy.install(on: options)
            guard let clean = options.beforeSend?(Event(error: error as NSError)),
                  let bytes = try? JSONSerialization.data(withJSONObject: clean.serialize()) else {
                Issue.record("Final production hook dropped a valid diagnostic")
                return
            }
            let exception = clean.exceptions?.first
            recorded.value = [
                String(decoding: bytes, as: UTF8.self),
                "\(exception?.type ?? "")|\(exception?.value ?? "")"
            ]
        }
        defer { SentryCapture.resetForTesting() }
        let controller = AccountLifecycleController(api: client,
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore())
        let result = await controller.verifyRestoredSession(controller.currentOperation,
            isSignedIn: true, hasAccountState: true)
        #expect(result == .retry)
        let json = try #require(recorded.value.first)
        for canary in Self.canaries { #expect(!json.contains(canary)) }
        #expect(json.contains("AppError.server"))
        #expect(json.contains("account.failure"))
        #expect(recorded.value.last == "AppError.server|AppError.server (1)")
        do {
            _ = try await client.me()
            Issue.record("Expected server error")
        } catch {
            #expect(error.localizedDescription == Self.canaries.joined(separator: " "))
        }
    }

    @Test
    func contaminatedFixtureFailsWithoutScrub() throws {
        // Baseline-red proof: the raw event carries every canary, so a
        // pre-fix passthrough fails assertNoCanaries for the right reason.
        let bytes = try JSONSerialization.data(
            withJSONObject: contaminatedEvent().serialize(), options: [.sortedKeys])
        let json = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        for canary in Self.canaries {
            #expect(json.contains(canary), "fixture lost canary: \(canary)")
        }
    }

    @Test
    func publicLogLinesNeverCarryRawErrorText() throws {
        // Suite pin for the OSLog boundary: restoring one raw
        // `localizedDescription` interpolation under `.public` turns red here.
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        for directory in ["Sources", "Watch", "LiveActivity"] {
            let url = root.appending(path: directory)
            guard let enumerator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for line in source.components(separatedBy: "\n") where line.contains("privacy: .public") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    #expect(!line.contains("localizedDescription"),
                        "raw error text in public log \(file.lastPathComponent): \(trimmed)")
                    #expect(!line.contains("errorMessage"),
                        "user-facing text in public log \(file.lastPathComponent): \(trimmed)")
                    #expect(!line.contains("failureMessage"),
                        "user-facing text in public log \(file.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(scanned > 50, "source scan covered nothing")
    }

    @Test @MainActor
    func userFacingFailuresKeepRawTextThroughProductionPaths() async throws {
        let canary = Self.canaries.joined(separator: " ")
        #expect(AppError.server(canary).localizedDescription == canary)
        #expect(AppError.conflict(canary).localizedDescription == canary)
        #expect(!DiagnosticPrivacy.publicSummary(AppError.server(canary)).contains(canary))
        #expect(!DiagnosticPrivacy.publicSummary(AppError.conflict(canary)).contains(canary))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session, keychain: StaticTokenStore())
        let controller = AccountLifecycleController(api: client,
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            revocationStore: TestLogoutRevocationStore())
        let transition = await controller.authenticate(controller.currentOperation,
            deviceID: "test-device", platform: "test")
        guard case .failed(let message) = transition else {
            Issue.record("Expected failed transition, got \(transition)")
            return
        }
        #expect(message == canary)
        let diagnostic = DiagnosticPrivacy.diagnostic(AppError.server(canary),
            file: "AccountLifecycleController.swift")
        #expect(!DiagnosticPrivacy.publicSummary(diagnostic).contains(canary))
        let guarded = APIClient(session: session, keychain: EmptyTokenStore())
        let outcome = await guarded.deleteAccount(confirmation: "test")
        #expect(outcome == .unknown(AppError.unauthorized.localizedDescription))
    }

    private func contaminatedEvent() -> Event {
        let text = Self.canaries.joined(separator: " ")
        let event = Event(error: NSError(domain: NSURLErrorDomain, code: -1001,
            userInfo: [NSLocalizedDescriptionKey: text, "arbitrary": Self.canaries]))
        event.message = SentryMessage(formatted: text)
        event.extra = ["private": Self.canaries]
        event.context = ["private": ["payload": text]]
        event.tags = ["private": text]
        event.fingerprint = Self.canaries
        event.transaction = text
        let request = SentryRequest()
        request.url = Self.canaries[3]
        request.headers = ["Authorization": text]
        request.fragment = text
        request.queryString = text
        event.request = request
        event.exceptions = [Exception(value: text, type: text)]
        let crumb = Breadcrumb()
        crumb.message = text
        event.breadcrumbs = [crumb]
        return event
    }

    private func assertNoCanaries(_ event: Event) throws {
        let bytes = try JSONSerialization.data(withJSONObject: event.serialize(), options: [.sortedKeys])
        let json = String(decoding: bytes, as: UTF8.self)
        for canary in Self.canaries { #expect(!json.contains(canary)) }
    }
}

private final class PrivacyResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil),
              let body = try? JSONSerialization.data(withJSONObject: [
                "error": DiagnosticPrivacyTests.canaries.joined(separator: " ")
              ]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
