import Foundation
import Sentry
import Testing
import zlib
@testable import Pomodorough

@Suite("R53-L01 final diagnostic privacy")
struct DiagnosticPrivacyTests {
    static let canaries = [
        "private@example.test", "token=secret-canary", "invite-secret-canary",
        "https://private.test/#secret", "/private/account/secret", "Secret Task Title"
    ]
    // Scope-only values on keys the event never sets, so each prepared-side
    // control proves the SDK merged that scope field before the hook ran.
    static let scopeCanaries = [
        "scope-user@example.test", "scope-tag-canary", "scope-context-canary",
        "scope-breadcrumb-canary", "scope-extra-canary"
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
        event.eventId = SentryId(uuidString: "12345678-1234-5678-9abc-123456789abc")
        event.timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        let originalID = event.eventId.sentryIdString
        let clean = try #require(options.beforeSend?(event))
        try assertNoCanaries(clean)
        let payload = clean.serialize()
        #expect(payload["event_id"] as? String == originalID)
        #expect(originalID == "12345678123456789abc123456789abc")
        #expect((payload["timestamp"] as? NSNumber)?.doubleValue == 1_700_000_000.125)
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
    func invalidReleaseBlocksOtherwiseValidDistFallback() throws {
        let invalid = ["", " 0.47.0@56", "0.47.0@56\r\n", "0.47.0@56\0",
            "0.47.0@５６", "0.47.0@+56", "0.47.0@5.6", "0.47.0@5e6",
            "1234567.0.0@56", "0.1234567.0@56", "0.0.1234567@56", "0.47@56",
            "0.47.0@56\u{2028}", "0.47.0@56\u{200B}"]
        for release in invalid + Self.canaries {
            let event = contaminatedEvent()
            event.releaseName = release
            event.environment = "production"
            event.dist = "62"
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.serialize()["release"] == nil)
            #expect(clean.serialize()["dist"] == nil)
            #expect(clean.environment == "production")
            try assertNoCanaries(clean)
        }
    }

    @Test
    func absentReleaseValidatesStandaloneDistInIsolation() throws {
        // Release stays nil so only the standalone dist validator decides.
        for dist in ["", "56\n", "56\0", "５６", "12345678901", "+56", "56-secret"] + Self.canaries {
            let event = contaminatedEvent()
            event.releaseName = nil
            event.dist = dist
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.serialize()["release"] == nil)
            #expect(clean.serialize()["dist"] == nil)
            try assertNoCanaries(clean)
        }
        for dist in ["1234567890", "0"] {
            let event = contaminatedEvent()
            event.releaseName = nil
            event.dist = dist
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.serialize()["release"] == nil)
            #expect(clean.serialize()["dist"] as? String == dist)
        }
    }

    @Test
    func invalidEnvironmentDoesNotDiscardHistoricalRelease() throws {
        for environment in ["", "Production", " production", "production\n", "production-secret"] + Self.canaries {
            let event = contaminatedEvent()
            event.environment = environment
            event.releaseName = "0.47.0@56"
            event.dist = Self.canaries[0]
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.serialize()["environment"] == nil)
            #expect(clean.releaseName == "0.47.0@56")
            #expect(clean.dist == "56")
            try assertNoCanaries(clean)
        }
    }

    @Test
    func boundedNumericMetadataAcceptsMaximumLengthsAndLeadingZeros() throws {
        for release in ["999999.999999.999999@1234567890", "000000.000000.000000@0000000000"] {
            let event = contaminatedEvent()
            event.releaseName = release
            event.dist = Self.canaries[1]
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.releaseName == release)
            #expect(clean.dist == release.split(separator: "@").last.map(String.init))
            try assertNoCanaries(clean)
        }
    }

    @Test
    func appBundleReleaseSurvivesHookWhilePreReleaseFormsDrop() throws {
        // Mirrors SentrySetup.startIfConfigured's version@build composition from
        // the hosting app bundle. A version format the hook rejects fails here
        // instead of silently dropping release attribution in production.
        #expect(Bundle.main.bundleURL.lastPathComponent == "Pomodorough.app")
        let info = try #require(Bundle.main.infoDictionary)
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)
        let event = contaminatedEvent()
        event.releaseName = "\(version)@\(build)"
        let clean = try scrubWithInstalledHook(event)
        #expect(clean.releaseName == "\(version)@\(build)")
        #expect(clean.dist == build)
        // Pre-release and short forms sit outside the numeric policy: they drop
        // whole, with their dist, rather than being truncated or relabelled.
        for release in ["0.54.0-beta@63", "0.54.0-beta.1@63", "0.54.0-rc1@63", "1.0@63", "0.54.0+63@63", "v0.54.0@63"] {
            let event = contaminatedEvent()
            event.releaseName = release
            event.dist = "63"
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.releaseName == nil, "\(release) unexpectedly kept")
            #expect(clean.dist == nil)
        }
    }

    @Test
    func environmentAllowlistCoversEverySentrySetupEnvironment() throws {
        let produced = Set([true, false].flatMap { isDebug in
            [true, false].map { SentrySetup.environment(isDebug: isDebug, isTestFlight: $0) }
        })
        // A new SentrySetup environment fails this literal until the hook allowlist is reviewed.
        #expect(produced == ["development", "testflight", "production"])
        for environment in produced {
            let event = contaminatedEvent()
            event.environment = environment
            let clean = try scrubWithInstalledHook(event)
            #expect(clean.environment == environment)
        }
    }

    @Test
    func offlineSDKTransportPreservesPreparedMetadataAndDropsScope() throws {
        // Real SentryClient prepare/beforeSend/envelope/gzip path; the
        // URLProtocol captures the request body so nothing leaves the host.
        for release in ["0.47.0@56", "0.53.0@62"] {
            let event = eventLeavingUserAndBreadcrumbsToScope()
            event.eventId = SentryId(uuidString: "12345678-1234-5678-9abc-123456789abc")
            event.timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
            event.releaseName = release
            event.environment = "testflight"
            event.dist = "62"
            let sent = try captureThroughOfflineSDK(event, scope: contaminatedScope())
            expectScopeReachedHook(sent.prepared)
            #expect(sent.id.sentryIdString == "12345678123456789abc123456789abc")
            #expect(sent.prepared["event_id"] as? String == sent.id.sentryIdString)
            #expect((sent.prepared["timestamp"] as? NSNumber)?.doubleValue == 1_700_000_000.125)
            #expect(sent.header["event_id"] as? String == sent.id.sentryIdString)
            #expect(sent.event["event_id"] as? String == sent.id.sentryIdString)
            #expect((sent.event["timestamp"] as? NSNumber)?.doubleValue == 1_700_000_000.125)
            #expect(sent.event["release"] as? String == release)
            #expect(sent.event["environment"] as? String == "testflight")
            #expect(sent.event["dist"] as? String == release.split(separator: "@").last.map(String.init))
            for key in ["user", "threads", "stacktrace", "contexts", "request", "extra", "breadcrumbs"] {
                #expect(sent.event[key] == nil, "envelope event kept \(key)")
            }
            assertNoCanaries(in: sent.text)
        }
    }

    @Test
    func offlineSDKTransportDoesNotRelabelInvalidMetadataWithCurrentBuild() throws {
        // Options carry today's 0.53.0@62/production. The SDK only fills nil
        // fields, so an invalid historical value must drop, not become today's.
        for (release, environment) in [("0.47.0@56-secret", "testflight\n"), (Self.canaries[1], Self.canaries[0])] {
            let event = eventLeavingUserAndBreadcrumbsToScope()
            event.timestamp = Date(timeIntervalSince1970: 1_600_000_000.5)
            event.releaseName = release
            event.environment = environment
            event.dist = "62"
            let originalID = event.eventId.sentryIdString
            let sent = try captureThroughOfflineSDK(event, scope: contaminatedScope())
            #expect(sent.prepared["release"] as? String == release)
            #expect(sent.prepared["environment"] as? String == environment)
            expectScopeReachedHook(sent.prepared)
            #expect(sent.id.sentryIdString == originalID)
            #expect(sent.header["event_id"] as? String == originalID)
            #expect(sent.event["event_id"] as? String == originalID)
            #expect((sent.event["timestamp"] as? NSNumber)?.doubleValue == 1_600_000_000.5)
            #expect(sent.event["release"] == nil)
            #expect(sent.event["dist"] == nil)
            #expect(sent.event["environment"] == nil)
            assertNoCanaries(in: sent.text)
        }
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
        #expect(contaminatedEvent().user != nil)
        #expect(contaminatedEvent().threads?.first?.stacktrace != nil)
        #expect(contaminatedEvent().stacktrace != nil)
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
        let user = User()
        user.email = Self.canaries[0]
        event.user = user
        let frame = Frame()
        frame.function = text
        let stack = SentryStacktrace(frames: [frame], registers: ["private": text])
        event.stacktrace = stack
        let thread = SentryThread(threadId: 1)
        thread.name = text
        thread.stacktrace = stack
        event.threads = [thread]
        return event
    }

    private func scrubWithInstalledHook(_ event: Event) throws -> Event {
        let options = Options()
        DiagnosticPrivacy.install(on: options)
        return try #require(options.beforeSend?(event))
    }

    // The SDK applies scope breadcrumbs only when the event has none; a
    // user-less event makes the prepared user a scope-only witness.
    private func eventLeavingUserAndBreadcrumbsToScope() -> Event {
        let event = contaminatedEvent()
        event.user = nil
        event.breadcrumbs = nil
        return event
    }

    private func contaminatedScope() -> Scope {
        let scope = Scope()
        let user = User()
        user.email = Self.scopeCanaries[0]
        scope.setUser(user)
        scope.setTag(value: Self.scopeCanaries[1], key: "scope_tag")
        scope.setContext(value: ["payload": Self.scopeCanaries[2]], key: "scope_context")
        let crumb = Breadcrumb()
        crumb.message = Self.scopeCanaries[3]
        scope.addBreadcrumb(crumb)
        scope.setExtra(value: Self.scopeCanaries[4], key: "scope_private")
        return scope
    }

    private func expectScopeReachedHook(_ prepared: [String: Any]) {
        let contexts = prepared["contexts"] as? [String: Any]
        let crumbs = prepared["breadcrumbs"] as? [[String: Any]] ?? []
        #expect((prepared["user"] as? [String: Any])?["email"] as? String == Self.scopeCanaries[0])
        #expect((prepared["tags"] as? [String: Any])?["scope_tag"] as? String == Self.scopeCanaries[1])
        #expect((contexts?["scope_context"] as? [String: Any])?["payload"] as? String == Self.scopeCanaries[2])
        #expect(crumbs.map { $0["message"] as? String } == [Self.scopeCanaries[3]])
        #expect((prepared["extra"] as? [String: Any])?["scope_private"] as? String == Self.scopeCanaries[4])
    }

    private func assertNoCanaries(_ event: Event) throws {
        try assertNoCanaries(event.serialize())
    }

    private func assertNoCanaries(_ payload: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        assertNoCanaries(in: String(decoding: bytes, as: UTF8.self))
    }

    private func assertNoCanaries(in serialized: String) {
        // Serializers may escape "/" as "\/"; normalize so URL/path canaries cannot hide.
        let json = serialized.replacingOccurrences(of: "\\/", with: "/")
        for canary in Self.canaries + Self.scopeCanaries {
            #expect(!json.contains(canary), "serialized output leaked \(canary)")
        }
    }
}

private struct OfflineSDKCapture {
    let id: SentryId
    let prepared: [String: Any]
    let header: [String: Any]
    let event: [String: Any]
    let text: String
}

private func captureThroughOfflineSDK(_ event: Event, scope: Scope) throws -> OfflineSDKCapture {
    let host = "r54-\(UUID().uuidString.lowercased()).invalid"
    let session = privacyTransportSession()
    defer { session.invalidateAndCancel() }
    let options = offlinePrivacyOptions(host: host, session: session)
    defer { try? FileManager.default.removeItem(atPath: options.cacheDirectoryPath) }
    let installed = try #require(options.beforeSend)
    let prepared = LockedTestValue<Data?>(nil)
    options.beforeSend = { event in
        prepared.value = try? JSONSerialization.data(withJSONObject: event.serialize())
        return installed(event)
    }
    let client = try #require(SentryClient(options: options))
    defer { client.close() }
    let id = client.capture(event: event, scope: scope)
    let bodies = flushUntilDelivered(client, host: host)
    try #require(bodies.count == 1, "expected one offline envelope, got \(bodies.count)")
    let preparedBytes = try #require(prepared.value, "beforeSend never saw a serializable prepared event")
    let preparedEvent = try #require(JSONSerialization.jsonObject(with: preparedBytes) as? [String: Any])
    let envelope = try decodedPrivacyEnvelope(bodies[0])
    return OfflineSDKCapture(id: id, prepared: preparedEvent, header: envelope.header,
        event: envelope.event, text: envelope.text)
}

// One flush is not a delivery barrier. Each new transport's reachability
// observer runs an initial send pass off the transport queue; when it holds
// the sending flag across the capture's store, the store's and the flush's
// passes both see "Already sending", the stray pass ends the flush early, and
// the stored envelope waits on disk for another trigger. Re-flushing is that
// trigger; the strict single-body check stays with the caller.
private func flushUntilDelivered(_ client: SentryClient, host: String) -> [Data] {
    let deadline = Date.now.addingTimeInterval(15)
    client.flush(timeout: 5)
    var reflushes = 0
    while PrivacyEnvelopeProtocol.bodies(for: host).isEmpty, Date.now < deadline {
        reflushes += 1
        client.flush(timeout: 1)
        Thread.sleep(forTimeInterval: 0.01)
    }
    if reflushes > 0 {
        print("R54-L01 offline envelope needed \(reflushes) re-flush(es); delivered: \(PrivacyEnvelopeProtocol.bodies(for: host).count)")
    }
    return PrivacyEnvelopeProtocol.bodies(for: host)
}

private func privacyTransportSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PrivacyEnvelopeProtocol.self]
    return URLSession(configuration: configuration)
}

private func offlinePrivacyOptions(host: String, session: URLSession) -> Options {
    let options = Options()
    options.dsn = "https://public@\(host)/1"
    options.urlSession = session
    options.releaseName = "0.53.0@62"
    options.environment = "production"
    options.cacheDirectoryPath = FileManager.default.temporaryDirectory.appendingPathComponent(host).path
    options.sendClientReports = false
    options.attachStacktrace = false
    DiagnosticPrivacy.install(on: options)
    return options
}

private func decodedPrivacyEnvelope(_ compressed: Data) throws
    -> (header: [String: Any], event: [String: Any], text: String) {
    let output = try gunzippedEnvelope(compressed)
    let lines = output.split(separator: 10, omittingEmptySubsequences: true)
    let headerLine = try #require(lines.first)
    let header = try #require(JSONSerialization.jsonObject(with: Data(headerLine)) as? [String: Any])
    for index in 1..<lines.count where index + 1 < lines.count {
        guard let item = try? JSONSerialization.jsonObject(with: Data(lines[index])) as? [String: Any],
              item["type"] as? String == "event" else { continue }
        let event = try #require(JSONSerialization.jsonObject(with: Data(lines[index + 1])) as? [String: Any])
        return (header, event, String(decoding: output, as: UTF8.self))
    }
    throw NSError(domain: "MissingOfflineEventEnvelope", code: 1)
}

private func gunzippedEnvelope(_ compressed: Data) throws -> Data {
    var stream = z_stream()
    try #require(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&stream) }
    var output = Data(count: 1_048_576)
    let status = compressed.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { destination in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(destination.count)
            return inflate(&stream, Z_FINISH)
        }
    }
    try #require(status == Z_STREAM_END, "Offline envelope must fit bounded decompression buffer")
    output.count = Int(stream.total_out)
    return output
}

private final class PrivacyEnvelopeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String: [Data]] = [:]

    static func bodies(for host: String) -> [Data] {
        lock.withLock { recorded[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let bytes = requestBody()
        Self.lock.withLock { Self.recorded[host, default: []].append(bytes) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    // URLSession hands protocols the body as a stream, not httpBody.
    private func requestBody() -> Data {
        var bytes = request.httpBody ?? Data()
        guard let stream = request.httpBodyStream else { return bytes }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
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
