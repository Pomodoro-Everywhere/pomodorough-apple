import Foundation
import OSLog

/// The workspace a task deletion belongs to. `owner` is `room:<room id>`
/// in iroh mode, `account:<user id>` for an account workspace and `local`
/// for the signed-out workspace. `generation` is the phone's workspace
/// generation, which rotates at every sign-in, sign-out, account switch and
/// account deletion, so a marker never matches a later workspace with the
/// same owner.
struct TaskDeletionWorkspace: Codable, Equatable, Sendable {
    static let signedOutOwner = "local"

    let owner: String
    let generation: UUID

    static func owner(accountID: String?) -> String {
        accountID.map { "account:\($0)" } ?? signedOutOwner
    }
}

/// The durable record of a task deletion whose undo window is open. It is
/// written when the board hides the task and cleared on Undo or once the
/// workspace delete has been written, so a process that dies inside the
/// window can finish the deletion at the next start.
struct TaskDeletionMarker: Codable, Equatable, Sendable {
    let taskID: UUID
    let workspace: TaskDeletionWorkspace
}

/// Keeps at most one marker in the app's key-value store. A marker that
/// cannot be decoded is removed and reported as absent, so a damaged entry
/// never deletes anything.
struct TaskDeletionMarkerStore {
    static let key = "pending-task-deletion-v1"
    private static let logger = Logger(subsystem: "me.egigoka.pomodorough", category: "TaskDeletionMarker")

    let defaults: UserDefaults

    func save(_ marker: TaskDeletionMarker) {
        do {
            defaults.set(try JSONEncoder().encode(marker), forKey: Self.key)
        } catch {
            // A two-field Codable value cannot fail to encode; if it ever
            // does, the deletion keeps its in-memory window only.
            Self.logger.error("task deletion marker encode failed: \(DiagnosticPrivacy.publicSummary(error), privacy: .public)")
        }
    }

    func load() -> TaskDeletionMarker? {
        guard let bytes = defaults.data(forKey: Self.key) else { return nil }
        guard let marker = try? JSONDecoder().decode(TaskDeletionMarker.self, from: bytes) else {
            clear()
            return nil
        }
        return marker
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
