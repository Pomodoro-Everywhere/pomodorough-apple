#if DEBUG
import Foundation
import Security
import Synchronization

/// In-memory generic-password keychain for DEBUG test processes, chosen by
/// `KeychainSecurityDefault`. Items are keyed by service and account and
/// follow SecItem status semantics for the queries the Keychain-backed
/// stores send. `processShared` is one keychain for the whole process, so
/// separately built default stores still see each other's items, as they
/// did with the system Keychain. Nothing outlives the process.
final class IsolatedTestKeychainSecurity: KeychainSecurityOperating {
    static let processShared = IsolatedTestKeychainSecurity()

    private struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    private let items = Mutex<[ItemKey: Data]>([:])

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        guard let key = Self.itemKey(query) else { return (errSecParam, nil) }
        guard let data = items.withLock({ $0[key] }) else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func copyAccounts(_ query: [String: Any]) -> (status: OSStatus, accounts: [String]) {
        guard let service = query[kSecAttrService as String] as? String else { return (errSecParam, []) }
        let accounts = items.withLock { stored in
            stored.keys.filter { $0.service == service }.map(\.account).sorted()
        }
        return accounts.isEmpty ? (errSecItemNotFound, []) : (errSecSuccess, accounts)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let key = Self.itemKey(query),
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        return items.withLock { stored in
            guard stored[key] != nil else { return errSecItemNotFound }
            stored[key] = data
            return errSecSuccess
        }
    }

    func add(_ query: [String: Any]) -> OSStatus {
        guard let key = Self.itemKey(query),
              let data = query[kSecValueData as String] as? Data else { return errSecParam }
        return items.withLock { stored in
            guard stored[key] == nil else { return errSecDuplicateItem }
            stored[key] = data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard let key = Self.itemKey(query) else { return errSecParam }
        return items.withLock { stored in
            stored.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func errorMessage(for status: OSStatus) -> String? {
        SecCopyErrorMessageString(status, nil) as String?
    }

    private static func itemKey(_ query: [String: Any]) -> ItemKey? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        return ItemKey(service: service, account: account)
    }
}
#endif
