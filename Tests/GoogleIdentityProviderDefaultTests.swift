import Foundation
import Testing
@testable import Pomodorough

/// A test that omits an injected Google provider must never start real
/// sign-in. These tests check which provider is chosen; they never call
/// sign-in or handle a URL, because the test-process provider stops there.
@Suite("Default Google identity provider of a test process")
@MainActor
struct GoogleIdentityProviderDefaultTests {
    @Test func testProcessDefaultRefusesRealSignIn() {
        #expect(KeychainTestProcessGuard.isTestProcess)
        #expect(GoogleIdentityProviderDefault.resolve() is TestProcessGoogleIdentityProvider)
    }

    @Test func onlyATestProcessGetsTheRefusingProvider() {
        #expect(GoogleIdentityProviderDefault.resolve(isTestProcess: true) is TestProcessGoogleIdentityProvider)
        #expect(GoogleIdentityProviderDefault.resolve(isTestProcess: false) is SystemGoogleIdentityProvider)
    }

    /// Builds the model with fakes for everything except Google.
    @Test func modelBuiltWithoutAProviderRefusesRealSignIn() {
        let model = AppModel(
            api: APIClient(
                session: TestFixtures.session(for: "default-google-\(UUID().uuidString)"),
                keychain: EmptyTokenStore(),
                logoutRevocationStore: TestLogoutRevocationStore()
            ),
            roomStore: IrohRoomStore(secretStore: MemoryIrohRoomSecretStore()),
            endpointKeyStore: PreviewEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler()
        )
        let provider = Mirror(reflecting: model).descendant("googleIdentityProvider")
        #expect(provider is TestProcessGoogleIdentityProvider, "the model default would start real sign-in")
    }

    @Test func refusingProviderSignOutDoesNothing() {
        let provider = TestProcessGoogleIdentityProvider()
        provider.signOut()
        provider.signOut()
    }
}
