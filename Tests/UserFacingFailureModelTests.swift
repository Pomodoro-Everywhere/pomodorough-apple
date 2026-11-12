import AuthenticationServices
import Foundation
import Security
import Testing
@testable import Pomodorough

/// IOS27-04 and IOS27-18 through the production sign-in and room paths: a
/// cancelled sign-in shows nothing, and a failure shows an authored sentence.
@Suite("User-facing failures through the model")
@MainActor
struct UserFacingFailureModelTests {
    private static let secureStorageSentence =
        "Pomodorough could not use secure storage on this device. Unlock or restart the device, then try again."

    @Test func cancelledSignInShowsNothing() async throws {
        let fixture = try UserFacingFailureModelFixture(scenario: "apple-api-coverage-model-sign-in-r2-cancelled")
        defer { fixture.cleanUp() }
        fixture.identity.identityTokenResult = .failure(NSError(domain: "com.google.GIDSignIn", code: -5))
        let model = fixture.makeModel()

        try await fixture.signIn(model)

        #expect(fixture.identity.nonces == ["model-nonce"], "the prompt was shown and then closed")
        #expect(model.errorMessage == nil, "a cancelled sign-in is not a failure")
        #expect(model.user == nil)
    }

    @Test func signInKeychainFailureShowsTheSecureStorageSentence() async throws {
        let fixture = try UserFacingFailureModelFixture(scenario: "apple-api-coverage-model-sign-in-r2-keychain")
        defer { fixture.cleanUp() }
        fixture.identity.identityTokenResult = .failure(UnavailableRoomSecretStore.missingEntitlement)
        let model = fixture.makeModel()

        try await fixture.signIn(model)

        #expect(model.errorMessage == Self.secureStorageSentence)
    }

    @Test func signInFailureWithRawTextShowsTheSignInSentence() async throws {
        let fixture = try UserFacingFailureModelFixture(scenario: "apple-api-coverage-model-sign-in-r2-raw")
        defer { fixture.cleanUp() }
        fixture.identity.identityTokenResult = .failure(NSError(
            domain: "com.google.GIDSignIn", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "RawCanary keychain error -25300"]
        ))
        let model = fixture.makeModel()

        try await fixture.signIn(model)

        #expect(model.errorMessage == "Sign-in did not finish. Try again.")
    }

    /// R54 condition for L3: a closed or cancelled prompt is not reported.
    @Test func cancelledSignInIsNotReported() async throws {
        let cancellations: [Error] = [
            NSError(domain: "com.google.GIDSignIn", code: -5),
            ASAuthorizationError(.canceled),
            GoogleConsentCallbackError.declined,
        ]
        let reported = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { reported.value.append(($0 as NSError).userInfo["operation"] as? String ?? "") }
        defer { SentryCapture.resetForTesting() }
        for cancellation in cancellations {
            let identity = RecordingGoogleIdentityProvider()
            identity.identityTokenResult = .failure(cancellation)
            let controller = signInController(identity: identity)

            let transition = await controller.authenticate(controller.currentOperation, deviceID: "test-device", platform: "test")

            #expect(transition == .cancelled, "\(cancellation)")
        }
        #expect(!reported.value.contains(DiagnosticOperation.account.rawValue), "\(reported.value)")
    }

    /// Batch B follow-up E: only the person's own cancel or decline is
    /// silent. A cancelled request or task is a failure the person must see.
    @Test func cancelledRequestOrTaskShowsTheSignInSentence() async throws {
        for failure: Error in [CancellationError(), URLError(.cancelled)] {
            let fixture = try UserFacingFailureModelFixture(scenario: "apple-api-coverage-model-sign-in-r2-raw")
            defer { fixture.cleanUp() }
            fixture.identity.identityTokenResult = .failure(failure)
            let model = fixture.makeModel()

            try await fixture.signIn(model)

            #expect(fixture.identity.nonces == ["model-nonce"], "\(failure)")
            #expect(model.errorMessage == "Sign-in did not finish. Try again.", "\(failure)")
            #expect(model.user == nil)
        }
    }

    /// R54 condition for L3: cancellation is read from the error, not from
    /// the task, so a real failure that arrives while the sign-in task is
    /// cancelled is still shown and reported.
    @Test func realFailureWhileTheTaskIsCancelledIsStillReported() async throws {
        let identity = TaskCancellingGoogleIdentityProvider(failure: UnavailableRoomSecretStore.missingEntitlement)
        let controller = signInController(identity: identity)
        let reported = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { reported.value.append(($0 as NSError).userInfo["operation"] as? String ?? "") }
        defer { SentryCapture.resetForTesting() }

        let transition = await Task { @MainActor in
            await controller.authenticate(controller.currentOperation, deviceID: "test-device", platform: "test")
        }.value

        #expect(identity.sawCancelledTask.value, "the failure must arrive while the task is cancelled")
        #expect(transition == .failed(Self.secureStorageSentence))
        #expect(reported.value.contains(DiagnosticOperation.account.rawValue), "\(reported.value)")
    }

    private func signInController(identity: any GoogleIdentityProviding) -> AccountLifecycleController {
        let session = TestFixtures.session(for: "apple-api-coverage-model-sign-in-r2-report")
        return AccountLifecycleController(
            api: APIClient(session: session, keychain: EmptyTokenStore(), logoutRevocationStore: TestLogoutRevocationStore()),
            googleIdentityProvider: identity,
            revocationStore: TestLogoutRevocationStore()
        )
    }

    @Test func createRoomKeychainFailureShowsTheSecureStorageSentence() async throws {
        let fixture = try UserFacingFailureModelFixture(scenario: "user-facing-failure-create-room")
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(secretStore: UnavailableRoomSecretStore())

        #expect(await model.createIrohRoom(name: "Release room") == false)

        #expect(model.errorMessage == Self.secureStorageSentence)
        #expect(model.replicationMode == .offline)
    }
}

/// Cancels the sign-in task, then fails for a real reason.
private final class TaskCancellingGoogleIdentityProvider: GoogleIdentityProviding, @unchecked Sendable {
    let failure: Error
    let sawCancelledTask = LockedTestValue(false)

    init(failure: Error) { self.failure = failure }

    func identityToken(nonce: String) async throws -> String {
        withUnsafeCurrentTask { $0?.cancel() }
        sawCancelledTask.value = Task.isCancelled
        throw failure
    }

    func handle(_ url: URL) -> Bool { false }
    func signOut() {}
}

/// Room secret storage on a device whose Keychain is unavailable.
private struct UnavailableRoomSecretStore: IrohRoomSecretStoring {
    static let missingEntitlement = KeychainError(
        operation: "save", status: errSecMissingEntitlement, message: "A required entitlement isn't present."
    )

    func load(roomID: String) throws -> Data? { throw Self.missingEntitlement }
    func save(_ secret: Data, roomID: String) throws { throw Self.missingEntitlement }
    func delete(roomID: String) throws { throw Self.missingEntitlement }
    func accountDeletionAccounts() throws -> [String] { [] }
    func deleteAccount(named account: String) throws {}
}

/// Endpoint key storage on a device whose Keychain is unavailable. The
/// fixture never uses the system Keychain: on macOS a read of the installed
/// app's endpoint key from the test host raises a system password prompt.
private struct UnavailableEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { throw UnavailableRoomSecretStore.missingEntitlement }
    func save(_ key: Data) throws { throw UnavailableRoomSecretStore.missingEntitlement }
}

/// Offline model on isolated defaults and files with a stubbed server.
@MainActor
private struct UserFacingFailureModelFixture {
    let scenario: String
    let suiteName = "PomodoroughTests.UserFacingFailure.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let session: URLSession
    let identity = RecordingGoogleIdentityProvider()

    init(scenario: String) throws {
        self.scenario = scenario
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        session = TestFixtures.session(for: scenario)
    }

    func makeModel(secretStore: IrohRoomSecretStoring = MemoryIrohRoomSecretStore()) -> AppModel {
        AppModel(
            api: APIClient(
                session: session,
                keychain: EmptyTokenStore(),
                logoutRevocationStore: TestLogoutRevocationStore()
            ),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(
                fileURL: directory.appendingPathComponent("account-deletion.json")
            ),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("timer-state.json")
            ),
            roomStore: IrohRoomStore(
                fileURL: directory.appendingPathComponent("iroh-rooms.json"),
                secretStore: secretStore
            ),
            endpointKeyStore: UnavailableEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: identity
        )
    }

    func signIn(_ model: AppModel) async throws {
        model.signIn()
        for _ in 0..<500 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isWorking)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
