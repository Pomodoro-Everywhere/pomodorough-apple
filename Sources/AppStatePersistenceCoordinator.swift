import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct AtomicDurableFileStore: Sendable {
    let fileURL: URL
    private let afterReplacement: @Sendable () throws -> Void

    init(
        fileURL: URL,
        afterReplacement: @escaping @Sendable () throws -> Void = {}
    ) {
        self.fileURL = fileURL
        self.afterReplacement = afterReplacement
    }

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: fileURL, options: .atomic)
#endif
        try afterReplacement()
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(directory)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
        try synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) throws {
#if canImport(Darwin)
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
#endif
    }
}

struct AccountDeletionJournal: Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case remoteCommitted = "remote_committed"
    }

    struct Record: Codable, Equatable, Sendable {
        let phase: Phase
        let roomIDs: [String]
        let roomSecretAccounts: [String]

        init(
            phase: Phase,
            roomIDs: [String],
            roomSecretAccounts: [String] = []
        ) {
            self.phase = phase
            self.roomIDs = Array(Set(roomIDs)).sorted()
            self.roomSecretAccounts = Array(Set(roomSecretAccounts)).sorted()
        }

        private enum CodingKeys: String, CodingKey {
            case phase
            case roomIDs
            case roomSecretAccounts
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                phase: try values.decode(Phase.self, forKey: .phase),
                roomIDs: try values.decode([String].self, forKey: .roomIDs),
                roomSecretAccounts: try values.decodeIfPresent(
                    [String].self, forKey: .roomSecretAccounts
                ) ?? []
            )
        }
    }

    enum LoadResult: Equatable, Sendable {
        case absent
        case record(Record)
        case corrupt
    }

    private let store: AtomicDurableFileStore
    private let beforeSave: @Sendable (Record) throws -> Void

    init(
        fileURL: URL,
        afterReplacement: @escaping @Sendable () throws -> Void = {},
        beforeSave: @escaping @Sendable (Record) throws -> Void = { _ in }
    ) {
        store = AtomicDurableFileStore(
            fileURL: fileURL, afterReplacement: afterReplacement
        )
        self.beforeSave = beforeSave
    }

    func load() throws -> LoadResult {
        guard let data = try store.read() else { return .absent }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return .corrupt }
        return .record(record)
    }

    func save(_ record: Record) throws {
        try beforeSave(record)
        try store.write(JSONEncoder().encode(record))
    }

    func clear() throws {
        try store.remove()
    }
}

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
    private let durableLocalStore: AtomicDurableFileStore?

    init(defaults: UserDefaults, durableLocalStore: AtomicDurableFileStore? = nil) {
        self.defaults = defaults
        self.durableLocalStore = durableLocalStore
    }

    func load(
        replicationMode: ReplicationMode,
        roomStore: IrohRoomStore,
        wallDate: Date,
        uptime: TimeInterval
    ) -> LoadTransition {
        let loader = PersistedStateLoader(defaults: defaults)
        let durableData: Data?
        if let durableLocalStore {
            do {
                durableData = try durableLocalStore.read()
            } catch {
                durableData = Data()
            }
        } else {
            durableData = nil
        }
        let loaded = loader.load(preferredStoredData: durableData)
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
                try durableLocalStore?.write(data)
                defaults.set(data, forKey: PersistedStateLoader.storageKey)
                guard durableLocalStore != nil
                        || defaults.data(forKey: PersistedStateLoader.storageKey) == data else {
                    return .failed
                }
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
