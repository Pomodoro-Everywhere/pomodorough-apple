#if DEBUG
import Foundation
import Security

/// UI-test room secret storage that fails like a device without the
/// Keychain entitlement. Selected only by the DEBUG launch environment
/// `POMODOROUGH_UI_TEST_ROOM_SECRETS=unavailable`, so a signed build that
/// can use the Keychain still meets the failure the test drives.
struct UITestUnavailableRoomSecretStore: IrohRoomSecretStoring {
    static let environmentKey = "POMODOROUGH_UI_TEST_ROOM_SECRETS"

    private static let missingEntitlement = KeychainError(
        operation: "save", status: errSecMissingEntitlement, message: "UI test: Keychain unavailable."
    )

    /// The room store for this launch: the failing store when the UI test
    /// asks for it, otherwise the default store.
    static func roomStore(environment: [String: String]) -> IrohRoomStore {
        guard environment[environmentKey] == "unavailable" else { return IrohRoomStore() }
        return IrohRoomStore(secretStore: UITestUnavailableRoomSecretStore())
    }

    func load(roomID: String) throws -> Data? { throw Self.missingEntitlement }
    func save(_ secret: Data, roomID: String) throws { throw Self.missingEntitlement }
    func delete(roomID: String) throws { throw Self.missingEntitlement }
    // Account deletion finds no room secrets here and deletes nothing, so a
    // UI test must not use this stub to check room-secret cleanup.
    func accountDeletionAccounts() throws -> [String] { [] }
    func deleteAccount(named account: String) throws {}
}
#endif
