#if DEBUG
import Foundation
import Security
import Testing
@testable import Pomodorough

// R54-APB02: no test process may reach the system Keychain through a default.
@Suite("Keychain test isolation")
struct KeychainTestIsolationTests {
    private static let canaryService = "me.egigoka.pomodorough.keychain-guard-canary"

    @Test func testProcessDefaultResolvesToIsolatedKeychain() {
        #expect(KeychainTestProcessGuard.isTestProcess)
        #expect(KeychainSecurityDefault.resolve() is IsolatedTestKeychainSecurity)
    }

    // Each default store reads through KeychainSecurityDefault. Were one to
    // reach SystemKeychainSecurity, the guard would record an issue here.
    // Only reads: the process-shared keychain is visible to parallel tests.
    @Test func defaultBuiltStoresReadWithoutReachingSystemKeychain() throws {
        _ = try KeychainStore().load()
        _ = try KeychainLogoutRevocationStore().load()
        _ = try IrohEndpointKeychainStore().load()
        _ = try IrohRoomSecretKeychainStore().accountDeletionAccounts()
    }

    // Canary: the guard must trip for every SecItem operation, refuse the
    // call, and report it as an issue the running test owns.
    @Test(arguments: SystemKeychainOperation.allCases)
    func systemKeychainCallInTestProcessIsBlockedAndReported(_ operation: SystemKeychainOperation) throws {
        // Without the principal class the guard stops the process instead.
        try #require(KeychainTestProcessGuard.hasViolationReporter, "NSPrincipalClass did not install the reporter")
        var status: OSStatus?
        withKnownIssue("Guard must report the blocked System Keychain call") {
            status = Self.perform(operation, on: SystemKeychainSecurity())
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains(Self.canaryService) }
        }
        #expect(status == KeychainTestProcessGuard.refusedStatus)
    }

    private static func perform(_ operation: SystemKeychainOperation, on security: SystemKeychainSecurity) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: canaryService,
            kSecAttrAccount as String: "canary-\(operation.rawValue)",
        ]
        switch operation {
        case .copyMatching:
            return security.copyMatching(query).status
        case .copyAccounts:
            return security.copyAccounts(query).status
        case .update:
            return security.update(query, attributes: [kSecValueData as String: Data([1])])
        case .add:
            query[kSecValueData as String] = Data([1])
            return security.add(query)
        case .delete:
            return security.delete(query)
        }
    }
}

@Suite("Isolated test keychain semantics")
struct IsolatedTestKeychainSecurityTests {
    private let tokens = TokenPair(
        accessToken: "isolated-access",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
        refreshToken: "isolated-refresh",
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 3_000)
    )

    @Test func tokenStoreRoundTripsThroughAddUpdateAndDelete() throws {
        let store = KeychainStore(security: IsolatedTestKeychainSecurity())
        #expect(try store.load() == nil)
        try store.save(tokens)
        #expect(try store.load() == tokens)
        try store.save(tokens)
        #expect(try store.load() == tokens)
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }

    @Test func separatelyBuiltStoresShareOneKeychain() throws {
        let security = IsolatedTestKeychainSecurity()
        try KeychainStore(security: security).save(tokens)
        #expect(try KeychainStore(security: security).load() == tokens)
        #expect(try KeychainStore(security: IsolatedTestKeychainSecurity()).load() == nil)
    }

    @Test func roomSecretsEnumerateAndDeleteByAccount() throws {
        let security = IsolatedTestKeychainSecurity()
        let store = IrohRoomSecretKeychainStore(security: security)
        let first = Data(0...31)
        let second = Data(32...63)
        let firstRoom = try IrohProtocolV1.roomID(for: first)
        let secondRoom = try IrohProtocolV1.roomID(for: second)
        try store.save(first, roomID: firstRoom)
        try store.save(second, roomID: secondRoom)
        try IrohEndpointKeychainStore(security: security).save(Data(64...95))

        let accounts = try store.accountDeletionAccounts()
        #expect(accounts == ["room-secret-v1.\(firstRoom)", "room-secret-v1.\(secondRoom)"].sorted())
        try store.deleteAccount(named: accounts[0])
        #expect(try store.accountDeletionAccounts() == [accounts[1]])
        #expect(try IrohEndpointKeychainStore(security: security).load() == Data(64...95))
    }

    @Test func addOfExistingItemReportsDuplicate() {
        let security = IsolatedTestKeychainSecurity()
        let query: [String: Any] = [
            kSecAttrService as String: "isolated-service",
            kSecAttrAccount as String: "isolated-account",
            kSecValueData as String: Data([1]),
        ]
        #expect(security.add(query) == errSecSuccess)
        #expect(security.add(query) == errSecDuplicateItem)
        #expect(security.update(query, attributes: [:]) == errSecParam)
    }
}
#endif
