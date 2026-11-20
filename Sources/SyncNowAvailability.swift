import Foundation

/// Whether Account's "Sync now" can run and, if not, the reason shown
/// under it (IOS27-11). The gating matches the earlier boolean check; the
/// cases only name which condition blocks the action.
enum SyncNowAvailability: Equatable {
    case available
    case onDevice
    case signedOut
    case resolvingHistory
    case syncing

    init(
        replicationMode: ReplicationMode,
        isSignedIn: Bool,
        isSyncing: Bool,
        isHistoryResolutionBlocking: Bool
    ) {
        if replicationMode == .offline {
            self = .onDevice
        } else if replicationMode == .centralized && !isSignedIn {
            self = .signedOut
        } else if isHistoryResolutionBlocking {
            self = .resolvingHistory
        } else if isSyncing {
            self = .syncing
        } else {
            self = .available
        }
    }

    var isAvailable: Bool { self == .available }

    var unavailableReason: String? {
        switch self {
        case .available: nil
        case .onDevice: String(localized: "This device keeps the timer on its own. Choose a network to sync.")
        case .signedOut: String(localized: "Sign in with Google to sync.")
        case .resolvingHistory: String(localized: "Resolve the history choice first.")
        case .syncing: String(localized: "Sync is already running.")
        }
    }
}
