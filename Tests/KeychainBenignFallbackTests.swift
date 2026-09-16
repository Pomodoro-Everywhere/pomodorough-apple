import Foundation
import Security
import Testing
@testable import Pomodorough

// S3 (POMODOROUGH-19, 1757 events): -34018 missing-entitlement loads fall
// back to absent so the app continues offline instead of throwing into
// Sentry. Saves still throw, flagged benign so reporters skip Sentry.
@Suite("Keychain benign fallback")
struct KeychainBenignFallbackTests {
    private static let missingEntitlement: OSStatus = -34018

    @Test func revocationLoadFallsBackToEmpty() throws {
        let store = KeychainLogoutRevocationStore(security: RecordingKeychainSecurity(
            copyStatus: Self.missingEntitlement
        ))
        #expect(try store.load() == [])
    }

    @Test func tokenLoadFallsBackToNil() throws {
        let store = KeychainStore(security: RecordingKeychainSecurity(
            copyStatus: Self.missingEntitlement
        ))
        #expect(try store.load() == nil)
    }

    @Test func endpointKeyLoadFallsBackToNil() throws {
        let store = IrohEndpointKeychainStore(security: RecordingKeychainSecurity(
            copyStatus: Self.missingEntitlement
        ))
        #expect(try store.load() == nil)
    }

    @Test func roomSecretLoadAndEnumerateFallBack() throws {
        let store = IrohRoomSecretKeychainStore(security: RecordingKeychainSecurity(
            copyStatus: Self.missingEntitlement,
            copyAccountsStatus: Self.missingEntitlement
        ))
        #expect(try store.load(roomID: String(repeating: "a", count: 32)) == nil)
        #expect(try store.accountDeletionAccounts() == [])
    }

    @Test func realFailuresStillThrow() {
        #expect(throws: KeychainError.self) {
            _ = try KeychainStore(security: RecordingKeychainSecurity(
                copyStatus: errSecAuthFailed
            )).load()
        }
        #expect(throws: KeychainError.self) {
            _ = try KeychainLogoutRevocationStore(security: RecordingKeychainSecurity(
                copyStatus: errSecInteractionNotAllowed
            )).load()
        }
    }

    @Test func benignFlagMarksMissingEntitlementOnly() {
        let benign = KeychainError(operation: "load", status: Self.missingEntitlement, message: "x")
        #expect(benign.isBenignUnavailable)
        let real = KeychainError(operation: "load", status: errSecAuthFailed, message: "x")
        #expect(!real.isBenignUnavailable)
        #expect(!KeychainAvailability.isUnavailable(errSecItemNotFound))
        #expect(KeychainAvailability.isUnavailable(Self.missingEntitlement))
    }
}
