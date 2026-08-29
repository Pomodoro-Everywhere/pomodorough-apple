import Foundation

@MainActor
struct AppStatePersistenceCoordinator {
    enum Destination: Equatable, Sendable {
        case local
        case iroh(RoomReplicationTransition)
    }

    struct LoadTransition: Sendable {
        let replicationMode: ReplicationMode
        let state: PersistedTimerState
        let removesLegacyTasksAfterProjection: Bool
        let shouldPersistAfterProjection: Bool
        let shouldReportInvalidLocalClock: Bool
    }

    enum LoadCompletionEffect: Equatable, Sendable {
        case none
        case removeLegacyTasks
        case persist
        case removeLegacyTasksAndPersist
        case reportInvalidLocalClock
    }

    enum PersistenceTransition: Equatable, Sendable {
        case stored(PersistedTimerState, bytes: Data?)
        case captureFailed(durable: PersistedTimerState?, message: String, quarantined: Bool)
        case failed

        var succeeded: Bool {
            if case .stored = self { return true }
            return false
        }
    }

    struct AtomicTransition: Equatable, Sendable {
        let state: PersistedTimerState
        let persistence: PersistenceTransition

        var committed: Bool { persistence.succeeded }
    }

    struct ApplicationTransition: Equatable, Sendable {
        let state: PersistedTimerState
        let succeeded: Bool
        let rebuildsProjection: Bool
        let conflictMessage: String?
        let marksIrohConflict: Bool
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(
        replicationMode: ReplicationMode,
        roomStore: IrohRoomStore,
        wallDate: Date,
        uptime: TimeInterval
    ) -> LoadTransition {
        let loader = PersistedStateLoader(defaults: defaults)
        let loaded = loader.load()
        let roomBootstrap = RoomReplicationController.bootstrapRoomState(
            mode: replicationMode,
            localState: loaded.localState,
            roomStore: roomStore
        )
        let migrated = loader.migrating(
            roomBootstrap.state,
            from: loaded,
            replicationMode: roomBootstrap.mode,
            wallDate: wallDate,
            uptime: uptime
        )
        return LoadTransition(
            replicationMode: roomBootstrap.mode,
            state: migrated.state,
            removesLegacyTasksAfterProjection: !migrated.migrationFailed
                && migrated.stagedStateWasValid
                && migrated.removesLegacyTasksAfterProjection,
            shouldPersistAfterProjection: migrated.shouldPersist(projectionSucceeded: true),
            shouldReportInvalidLocalClock: migrated.shouldReportInvalidLocalClock
        )
    }

    func completionEffect(
        for transition: LoadTransition,
        projectionSucceeded: Bool
    ) -> LoadCompletionEffect {
        let removesTasks = projectionSucceeded && transition.removesLegacyTasksAfterProjection
        let persists = projectionSucceeded && transition.shouldPersistAfterProjection
        if removesTasks && persists { return .removeLegacyTasksAndPersist }
        if removesTasks { return .removeLegacyTasks }
        if persists { return .persist }
        if transition.shouldReportInvalidLocalClock { return .reportInvalidLocalClock }
        return .none
    }

    func removeLegacyTasks() {
        defaults.removeObject(forKey: PersistedStateLoader.localTaskStorageKey)
    }

    func persist(
        _ state: PersistedTimerState,
        replicationMode: ReplicationMode,
        captureIrohState: (PersistedTimerState) -> RoomReplicationTransition
    ) -> PersistenceTransition {
        persist(
            state,
            to: replicationMode == .iroh ? .iroh(captureIrohState(state)) : .local
        )
    }

    func persist(
        _ state: PersistedTimerState,
        to destination: Destination
    ) -> PersistenceTransition {
        switch destination {
        case .iroh(let capture):
            switch capture {
            case .captured(let captured):
                return .stored(captured, bytes: nil)
            case .captureFailed(let durable, let message, let quarantined):
                return .captureFailed(
                    durable: durable,
                    message: message,
                    quarantined: quarantined
                )
            default:
                return .failed
            }
        case .local:
            do {
                let data = try JSONEncoder.api.encode(state)
                defaults.set(data, forKey: PersistedStateLoader.storageKey)
                return .stored(state, bytes: data)
            } catch {
                return .failed
            }
        }
    }

    func persistAtomically(
        previous: PersistedTimerState,
        proposed: PersistedTimerState,
        replicationMode: ReplicationMode,
        captureIrohState: (PersistedTimerState) -> RoomReplicationTransition
    ) -> AtomicTransition {
        let persistence = persist(
            proposed,
            replicationMode: replicationMode,
            captureIrohState: captureIrohState
        )
        switch persistence {
        case .stored(let stored, _):
            return AtomicTransition(state: stored, persistence: persistence)
        case .captureFailed, .failed:
            return AtomicTransition(state: previous, persistence: persistence)
        }
    }

    func persistAtomically(
        previous: PersistedTimerState,
        proposed: PersistedTimerState,
        to destination: Destination
    ) -> AtomicTransition {
        let persistence = persist(proposed, to: destination)
        switch persistence {
        case .stored(let stored, _):
            return AtomicTransition(state: stored, persistence: persistence)
        case .captureFailed, .failed:
            return AtomicTransition(state: previous, persistence: persistence)
        }
    }
}

extension AppStatePersistenceCoordinator {
    func application(
        for transition: PersistenceTransition,
        current: PersistedTimerState,
        rebuildsOnFailure: Bool
    ) -> ApplicationTransition {
        switch transition {
        case .stored(let stored, _):
            return ApplicationTransition(
                state: stored, succeeded: true, rebuildsProjection: false,
                conflictMessage: nil, marksIrohConflict: false
            )
        case .captureFailed(let durable, let message, let quarantined):
            return ApplicationTransition(
                state: durable ?? current, succeeded: false,
                rebuildsProjection: rebuildsOnFailure && durable != nil,
                conflictMessage: message, marksIrohConflict: quarantined
            )
        case .failed:
            return ApplicationTransition(
                state: current, succeeded: false, rebuildsProjection: false,
                conflictMessage: nil, marksIrohConflict: false
            )
        }
    }

    func application(
        for transition: AtomicTransition,
        rebuildsOnRollback: Bool
    ) -> ApplicationTransition {
        application(
            for: transition.persistence,
            current: transition.state,
            rebuildsOnFailure: rebuildsOnRollback
        )
    }
}
