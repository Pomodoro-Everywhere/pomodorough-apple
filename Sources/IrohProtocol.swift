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

    var errorDescription: String? {
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
        }
    }
}

typealias IrohFrameCodec = IrohAuthenticatedFrameCodec
typealias IrohMessageCodec = IrohRPCMessageCodec
typealias JSONCanonicalizer = IrohCanonicalRecordCodec
