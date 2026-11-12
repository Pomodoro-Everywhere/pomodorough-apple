import Foundation

enum ReplicationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case offline
    case iroh
    case centralized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .offline: String(localized: "On device")
        case .iroh: String(localized: "Iroh room")
        case .centralized: String(localized: "Pomodorough Cloud")
        }
    }
}

enum IrohConnectionStatus: Equatable, Sendable {
    case stopped
    case starting
    case listening(endpointMark: String)
    case syncing(peerMark: String)
    case waitingForPeers
    case conflict
    case unavailable(String)

    var label: String {
        switch self {
        case .stopped: String(localized: "Not connected")
        case .starting: String(localized: "Opening route")
        case .listening: String(localized: "Ready for peers")
        case .syncing: String(localized: "Exchanging changes")
        case .waitingForPeers: String(localized: "Waiting for peers")
        case .conflict: String(localized: "Repair required")
        case .unavailable: String(localized: "Unavailable")
        }
    }
}

/// A room or peer-protocol failure. The person reads `errorDescription`,
/// one authored sentence for each case. The reason text names protocol and
/// storage detail for logs, diagnostics and the peer wire, through
/// `diagnosticDetail`; it never reaches the person.
enum IrohProtocolError: Error, LocalizedError, Sendable {
    case invalidInvite(String)
    case invalidFrame
    case authenticationFailed
    case wrongRoom
    case invalidMessage(String)
    case immutableConflict
    case limit(String)
    case notFound
    case unavailable(String)
    /// The person tried to join a room while another room is active.
    case roomAlreadyActive

    var errorDescription: String? {
        switch self {
        case .invalidInvite:
            String(localized: "iroh-error.invalid-invite",
                   defaultValue: "This room invite is not valid. Ask for a new invite, then try again.")
        case .invalidFrame, .invalidMessage:
            String(localized: "iroh-error.invalid-data", defaultValue: "Room data could not be read. Try again.")
        case .authenticationFailed:
            String(localized: "iroh-error.authentication-failed",
                   defaultValue: "The room did not accept this device. Ask for a new invite, then try again.")
        case .wrongRoom:
            String(localized: "iroh-error.wrong-room",
                   defaultValue: "The other device is in a different room. Check the invite, then try again.")
        case .immutableConflict:
            String(localized: "iroh-error.immutable-conflict",
                   defaultValue: "This room has two conflicting changes, so syncing is paused.")
        case .limit:
            String(localized: "iroh-error.limit",
                   defaultValue: "The room reached a size limit, so the change was not synced.")
        case .notFound:
            String(localized: "iroh-error.not-found", defaultValue: "The room data was not found. Try again.")
        case .unavailable:
            String(localized: "iroh-error.unavailable",
                   defaultValue: "The room is not available right now. Restart Pomodorough, then try again.")
        case .roomAlreadyActive:
            String(localized: "iroh-error.room-already-active",
                   defaultValue: "Leave the current room before joining another room.")
        }
    }

    /// The reason the thrower recorded, when the case carries one.
    var reason: String? {
        switch self {
        case .invalidInvite(let reason), .invalidMessage(let reason), .limit(let reason), .unavailable(let reason):
            reason
        case .invalidFrame, .authenticationFailed, .wrongRoom, .immutableConflict, .notFound, .roomAlreadyActive:
            nil
        }
    }

    /// Protocol detail for logs, diagnostics and the peer wire's error
    /// message. The wire text is unchanged from protocol version 1.
    var diagnosticDetail: String {
        switch self {
        case .invalidInvite(let reason): String(localized: "Invalid room invite: \(reason)")
        case .invalidFrame: String(localized: "Peer sent a malformed synchronization frame.")
        case .authenticationFailed: String(localized: "Room authentication failed.")
        case .wrongRoom: String(localized: "Peer requested a different room.")
        case .invalidMessage(let reason): String(localized: "Peer sent an invalid synchronization message: \(reason)")
        case .immutableConflict: String(localized: "Room contains two different operations with the same immutable ID.")
        case .limit(let reason): String(localized: "Synchronization limit exceeded: \(reason)")
        case .notFound: String(localized: "Requested room operation was not found.")
        case .unavailable(let reason): reason
        case .roomAlreadyActive:
            String(localized: "Peer sent an invalid synchronization message: \("Leave the current room before joining another room.")")
        }
    }
}

typealias IrohFrameCodec = IrohAuthenticatedFrameCodec
typealias IrohMessageCodec = IrohRPCMessageCodec
typealias JSONCanonicalizer = IrohCanonicalRecordCodec
