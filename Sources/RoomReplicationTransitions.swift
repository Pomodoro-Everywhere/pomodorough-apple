import Foundation

struct RoomReplicationEnvironment: Equatable, Sendable {
    let deviceID: String
    let displayName: String?
    let platform: String
}

struct RoomReplicationCentralizedState: Equatable, Sendable {
    let sessionGeneration: Int
    let isSignedIn: Bool
    let isWorkspaceMutationBlocked: Bool
    let isSessionVerified: Bool
    var localRevision: Int64
    var isSyncing: Bool
    let isTimerActive: Bool
    let isHistoryResolutionBlocking: Bool
}

struct RoomReplicationWorkspaceSnapshot: Equatable, Sendable {
    let state: PersistedTimerState
    let genesis: IrohGenesis
}

struct RoomReplicationOwnership: Equatable, Sendable {
    let sessionGeneration: Int
    let modeGeneration: Int
}

struct RoomReplicationProjection: Equatable, Sendable {
    let roomID: String
    let state: PersistedTimerState
}

enum RoomReplicationEvent: Equatable, Sendable {
    case centralizedQuiesced
    case statusChanged(IrohConnectionStatus)
    case projectionReceived(RoomReplicationProjection)
}

enum RoomReplicationOperation: Equatable, Sendable {
    case synchronize(force: Bool, showsActivity: Bool)
    case unauthorized(sessionGeneration: Int)
    case retry(sessionGeneration: Int, resolvesHistory: Bool)
}

enum RoomReplicationForegroundAction: Equatable, Sendable {
    case none
    case synchronize
}

enum RoomReplicationTransition: Equatable, Sendable {
    case unchanged
    case modeChanged(ReplicationMode, PersistedTimerState)
    case roomCreated(PersistedTimerState, invite: String, status: IrohConnectionStatus)
    case roomJoined(PersistedTimerState)
    case roomLeft(PersistedTimerState)
    case inviteRefreshed(String)
    case projectionApplied(PersistedTimerState, errorMessage: String?)
    case captured(PersistedTimerState)
    case captureFailed(PersistedTimerState?, message: String, quarantined: Bool)
    case failed(String)
}

protocol RoomReplicationServing: Sendable {
    func start(_ context: IrohServiceContext) async throws -> String
    func stop() async
    func currentEndpointTicket() async throws -> String
    func syncNow() async
    func markConflict(roomID: String?) async
    func join(invite: IrohRoomInvite) async throws
}

extension IrohReplicationService: RoomReplicationServing {}
