import Foundation
import Security

protocol TokenStoring: Sendable {
    // size-exception: protocol requirement is one declaration; the audit span includes a separate conformer's body.
    func load() throws -> TokenPair?
    func save(_ tokens: TokenPair) throws
    func delete() throws
}

struct KeychainLogoutRevocationStore: LogoutRevocationStoring {
    private struct Payload: Codable {
        let obligations: [LogoutRevocationObligation]
    }

    private let service = "me.egigoka.pomodorough.native-auth"
    private let account = "logout-revocations-v1"
    private let security: any KeychainSecurityOperating
    private static let mutationLock = NSLock()

    init(security: any KeychainSecurityOperating = SystemKeychainSecurity()) {
        self.security = security
    }

    func load() throws -> [LogoutRevocationObligation] {
        try Self.mutationLock.withLock { try loadUnlocked() }
    }

    private func loadUnlocked() throws -> [LogoutRevocationObligation] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        if result.status == errSecItemNotFound { return [] }
        guard result.status == errSecSuccess, let data = result.data else {
            throw error(operation: "load", status: result.status)
        }
        return try JSONDecoder.api.decode(Payload.self, from: data).obligations
    }

    func append(_ obligation: LogoutRevocationObligation) throws {
        try Self.mutationLock.withLock {
            var obligations = try loadUnlocked()
            obligations.append(obligation)
            try save(obligations)
        }
    }

    func replace(_ obligation: LogoutRevocationObligation) throws {
        try Self.mutationLock.withLock {
            var obligations = try loadUnlocked()
            guard let index = obligations.firstIndex(where: { $0.id == obligation.id }) else {
                throw KeychainError(
                    operation: "logout revocation replace",
                    status: errSecItemNotFound,
                    message: "Pending logout obligation was not found"
                )
            }
            obligations[index] = obligation
            try save(obligations)
        }
    }

    func remove(id: UUID) throws {
        try Self.mutationLock.withLock {
            var obligations = try loadUnlocked()
            obligations.removeAll { $0.id == id }
            if obligations.isEmpty { try delete() } else { try save(obligations) }
        }
    }

    private func save(_ obligations: [LogoutRevocationObligation]) throws {
        let data = try JSONEncoder.api.encode(Payload(obligations: obligations))
        let status = security.update(baseQuery, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let added = security.add(query)
            guard added == errSecSuccess else { throw error(operation: "save", status: added) }
        } else if status != errSecSuccess {
            throw error(operation: "save", status: status)
        }
    }

    private func delete() throws {
        let status = security.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(operation: "delete", status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    private func error(operation: String, status: OSStatus) -> KeychainError {
        KeychainError(
            operation: "logout revocation \(operation)",
            status: status,
            message: security.errorMessage(for: status) ?? "Unknown error"
        )
    }
}

protocol IrohEndpointKeyStoring: Sendable {
    func load() throws -> Data?
    func save(_ key: Data) throws
}

protocol IrohRoomSecretStoring: Sendable {
    func load(roomID: String) throws -> Data?
    func save(_ secret: Data, roomID: String) throws
    func delete(roomID: String) throws
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

struct IrohEndpointKeychainStore: IrohEndpointKeyStoring {
    private let service = "me.egigoka.pomodorough.iroh"
    private let account = "endpoint-secret-v1"
    private let security: any KeychainSecurityOperating

    init(security: any KeychainSecurityOperating = SystemKeychainSecurity()) {
        self.security = security
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data, data.count == 32 else {
            throw error(operation: "load", status: result.status)
        }
        return data
    }

    func save(_ key: Data) throws {
        guard key.count == 32 else {
            throw KeychainError(operation: "save", status: errSecParam, message: "Endpoint key must be 32 bytes")
        }
        let attributes = [kSecValueData as String: key]
        let status = security.update(baseQuery, attributes: attributes)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = key
            let addStatus = security.add(query)
            guard addStatus == errSecSuccess else { throw error(operation: "save (add)", status: addStatus) }
        } else if status != errSecSuccess {
            throw error(operation: "save (update)", status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    private func error(operation: String, status: OSStatus) -> KeychainError {
        KeychainError(
            operation: "Iroh endpoint key \(operation)",
            status: status,
            message: security.errorMessage(for: status) ?? "Unknown error"
        )
    }
}

struct IrohRoomSecretKeychainStore: IrohRoomSecretStoring {
    private let service = "me.egigoka.pomodorough.iroh-room"
    private let security: any KeychainSecurityOperating

    init(security: any KeychainSecurityOperating = SystemKeychainSecurity()) {
        self.security = security
    }

    func load(roomID: String) throws -> Data? {
        var query = baseQuery(roomID: roomID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = security.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data, data.count == 32 else {
            throw error(operation: "load", status: result.status)
        }
        return data
    }

    func save(_ secret: Data, roomID: String) throws {
        guard secret.count == 32, IrohProtocolV1.isValidRoomID(roomID) else {
            throw KeychainError(operation: "Iroh room secret save", status: errSecParam, message: "Invalid room secret")
        }
        let query = baseQuery(roomID: roomID)
        let attributes = [kSecValueData as String: secret]
        let status = security.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = secret
            let addStatus = security.add(addQuery)
            guard addStatus == errSecSuccess else { throw error(operation: "save (add)", status: addStatus) }
        } else if status != errSecSuccess {
            throw error(operation: "save (update)", status: status)
        }
    }

    func delete(roomID: String) throws {
        let status = security.delete(baseQuery(roomID: roomID))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(operation: "delete", status: status)
        }
    }

    private func baseQuery(roomID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "room-secret-v1.\(roomID)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    private func error(operation: String, status: OSStatus) -> KeychainError {
        KeychainError(
            operation: "Iroh room secret \(operation)",
            status: status,
            message: security.errorMessage(for: status) ?? "Unknown error"
        )
    }
}

struct KeychainError: LocalizedError, Equatable {
    let operation: String
    let status: OSStatus
    let message: String

    var errorDescription: String? {
        return String(localized: "Keychain \(operation) failed (OSStatus \(status)): \(message)")
    }
}
