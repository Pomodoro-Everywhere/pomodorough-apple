import Foundation
import Security

protocol TokenStoring: Sendable {
    func load() throws -> TokenPair?
    func save(_ tokens: TokenPair) throws
    func delete() throws
}

protocol KeychainSecurityOperating: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    func errorMessage(for status: OSStatus) -> String?
}

struct SystemKeychainSecurity: KeychainSecurityOperating {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func errorMessage(for status: OSStatus) -> String? {
        SecCopyErrorMessageString(status, nil) as String?
    }
}

struct KeychainStore: TokenStoring {
    private let service = "me.egigoka.pomodorough.native-auth"
    private let account = "token-pair"
    private let security: any KeychainSecurityOperating

    init(security: any KeychainSecurityOperating = SystemKeychainSecurity()) {
        self.security = security
    }

    func load() throws -> TokenPair? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = security.copyMatching(query)
        let status = result.status
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result.data else {
            throw error(operation: "load", status: status)
        }
        return try JSONDecoder.api.decode(TokenPair.self, from: data)
    }

    func save(_ tokens: TokenPair) throws {
        let data = try JSONEncoder.api.encode(tokens)
        let attributes = [kSecValueData as String: data]
        let status = security.update(baseQuery, attributes: attributes)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let addStatus = security.add(query)
            guard addStatus == errSecSuccess else {
                throw error(operation: "save (add)", status: addStatus)
            }
        } else if status != errSecSuccess {
            throw error(operation: "save (update)", status: status)
        }
    }

    func delete() throws {
        let status = security.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(operation: "delete", status: status)
        }
    }

    private func error(operation: String, status: OSStatus) -> KeychainError {
        KeychainError(
            operation: operation,
            status: status,
            message: security.errorMessage(for: status) ?? "Unknown error"
        )
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

struct KeychainError: LocalizedError, Equatable {
    let operation: String
    let status: OSStatus
    let message: String

    var errorDescription: String? {
        return "Keychain \(operation) failed (OSStatus \(status)): \(message)"
    }
}
