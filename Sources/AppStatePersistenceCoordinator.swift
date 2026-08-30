import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct AtomicDurableFileStore: Sendable {
    struct ReplacementFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    let fileURL: URL
    private let afterReplacement: @Sendable () throws -> Void
    private let beforeSynchronization: @Sendable () throws -> Void

    init(
        fileURL: URL,
        afterReplacement: @escaping @Sendable () throws -> Void = {}
    ) {
        self.init(fileURL: fileURL, beforeSynchronization: {}, afterReplacement: afterReplacement)
    }

    init(
        fileURL: URL,
        beforeSynchronization: @escaping @Sendable () throws -> Void,
        afterReplacement: @escaping @Sendable () throws -> Void
    ) {
        self.fileURL = fileURL
        self.afterReplacement = afterReplacement
        self.beforeSynchronization = beforeSynchronization
    }

    func read() throws -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let replacement = directory.appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: replacement) }
#if os(iOS)
        try data.write(to: replacement, options: [.withoutOverwriting, .completeFileProtection])
#else
        try data.write(to: replacement, options: .withoutOverwriting)
#endif
        let handle = try FileHandle(forWritingTo: replacement)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(replacement.path, fileURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        do {
            try afterReplacement()
            try synchronize(expectedContents: data)
        } catch {
            throw ReplacementFailure(reason: error.localizedDescription)
        }
    }

    func synchronize(expectedContents: Data) throws {
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        guard try handle.readToEnd() == expectedContents else { throw POSIXError(.EBUSY) }
        try beforeSynchronization()
        try handle.synchronize()
        try synchronizeDirectory(fileURL.deletingLastPathComponent())
        try handle.seek(toOffset: 0)
        guard try handle.readToEnd() == expectedContents,
              try stillReferences(handle) else { throw POSIXError(.EBUSY) }
    }

    private func stillReferences(_ handle: FileHandle) throws -> Bool {
        let current = try FileHandle(forReadingFrom: fileURL)
        defer { try? current.close() }
        var originalIdentity = stat()
        var currentIdentity = stat()
        guard fstat(handle.fileDescriptor, &originalIdentity) == 0,
              fstat(current.fileDescriptor, &currentIdentity) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return originalIdentity.st_dev == currentIdentity.st_dev
            && originalIdentity.st_ino == currentIdentity.st_ino
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
final class AppStatePersistenceCoordinator {
    enum SnapshotLoadFailure: LocalizedError, Equatable, Sendable {
        case unreadable(String)
        case corrupt
        case durabilityUncertain(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                String(localized: "The saved workspace could not be read. Nothing was overwritten. Restore file access, then retry. \(reason)")
            case .corrupt:
                String(localized: "The saved workspace could not be decoded. Nothing was overwritten. Restore a valid snapshot, then retry.")
            case .durabilityUncertain(let reason):
                String(localized: "The workspace may have been replaced, but its durability is unconfirmed. Changes are blocked until the saved snapshot can be read and synchronized. Retry recovery. \(reason)")
            }
        }
    }

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
        var snapshotLoadFailure: SnapshotLoadFailure? = nil
        var legacyTaskSource: Data? = nil
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
        case recoveryRequired(PersistedTimerState, message: String)
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
    private(set) var snapshotLoadFailure: SnapshotLoadFailure?
    private var snapshotRecoveryState: PersistedTimerState?

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
        let loaded: PersistedStateLoad
        do {
            loaded = try loadSnapshot(using: loader)
            snapshotLoadFailure = nil
            snapshotRecoveryState = nil
        } catch {
            let failure = error as? SnapshotLoadFailure ?? (snapshotRecoveryState == nil
                ? .unreadable(error.localizedDescription) : .durabilityUncertain(error.localizedDescription))
            snapshotLoadFailure = failure
            return LoadTransition(
                replicationMode: replicationMode, state: snapshotRecoveryState ?? .fresh(),
                removesLegacyTasksAfterProjection: false,
                shouldPersistAfterProjection: false, shouldReportInvalidLocalClock: false,
                snapshotLoadFailure: failure
            )
        }
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
            uptime: uptime,
            roomStore: roomStore
        )
        return LoadTransition(
            replicationMode: roomBootstrap.mode,
            state: migrated.state,
            removesLegacyTasksAfterProjection: !migrated.migrationFailed
                && migrated.stagedStateWasValid
                && migrated.removesLegacyTasksAfterProjection,
            shouldPersistAfterProjection: migrated.shouldPersist(projectionSucceeded: true),
            shouldReportInvalidLocalClock: migrated.shouldReportInvalidLocalClock,
            legacyTaskSource: migrated.legacyTaskSource
        )
    }

    private func loadSnapshot(using loader: PersistedStateLoader) throws -> PersistedStateLoad {
        let durableData = try durableLocalStore?.read()
        if let snapshotLoadFailure, durableLocalStore != nil, durableData == nil {
            throw snapshotLoadFailure
        }
        let loaded = loader.load(preferredStoredData: durableData)
        guard loaded.storedData == nil || loaded.decodedState != nil else {
            throw SnapshotLoadFailure.corrupt
        }
        if let snapshotLoadFailure, loaded.storedData == nil {
            throw snapshotLoadFailure
        }
        if let durableData {
            do {
                try durableLocalStore?.synchronize(expectedContents: durableData)
            } catch {
                snapshotRecoveryState = loaded.decodedState
                throw SnapshotLoadFailure.durabilityUncertain(error.localizedDescription)
            }
            if defaults.data(forKey: PersistedStateLoader.storageKey) != durableData {
                defaults.set(durableData, forKey: PersistedStateLoader.storageKey)
            }
        }
        return loaded
    }

    func completionEffect(
        for transition: LoadTransition,
        projectionSucceeded: Bool
    ) -> LoadCompletionEffect {
        guard snapshotLoadFailure == nil, transition.snapshotLoadFailure == nil else { return .none }
        let removesTasks = projectionSucceeded && transition.removesLegacyTasksAfterProjection
        let persists = projectionSucceeded && transition.shouldPersistAfterProjection
        if removesTasks && persists { return .removeLegacyTasksAndPersist }
        if removesTasks { return .removeLegacyTasks }
        if persists { return .persist }
        if transition.shouldReportInvalidLocalClock { return .reportInvalidLocalClock }
        return .none
    }

    func removeLegacyTasks() {
        guard snapshotLoadFailure == nil else { return }
        defaults.removeObject(forKey: PersistedStateLoader.localTaskStorageKey)
    }

    func matchesLegacyTaskSource(_ source: Data?) -> Bool {
        source != nil && defaults.data(forKey: PersistedStateLoader.localTaskStorageKey) == source
    }

    func persist(
        _ state: PersistedTimerState,
        replicationMode: ReplicationMode,
        captureIrohState: (PersistedTimerState) -> RoomReplicationTransition
    ) -> PersistenceTransition {
        guard snapshotLoadFailure == nil else { return blockedPersistence }
        return persist(
            state,
            to: replicationMode == .iroh ? .iroh(captureIrohState(state)) : .local
        )
    }

    func persist(
        _ state: PersistedTimerState,
        to destination: Destination
    ) -> PersistenceTransition {
        guard snapshotLoadFailure == nil else { return blockedPersistence }
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
            } catch let failure as AtomicDurableFileStore.ReplacementFailure {
                return reconcileReplacementFailure(failure, proposed: state)
            } catch {
                return .failed
            }
        }
    }

    private var blockedPersistence: PersistenceTransition {
        guard let snapshotRecoveryState, let snapshotLoadFailure else { return .failed }
        return .recoveryRequired(snapshotRecoveryState, message: snapshotLoadFailure.localizedDescription)
    }

    private func reconcileReplacementFailure(
        _ failure: AtomicDurableFileStore.ReplacementFailure,
        proposed: PersistedTimerState
    ) -> PersistenceTransition {
        snapshotRecoveryState = proposed
        var reason = failure.reason
        do {
            guard let bytes = try durableLocalStore?.read() else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            snapshotRecoveryState = try JSONDecoder.api.decode(PersistedTimerState.self, from: bytes)
        } catch {
            reason += " " + error.localizedDescription
        }
        snapshotLoadFailure = .durabilityUncertain(reason)
        return blockedPersistence
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
        case .stored(let stored, _), .recoveryRequired(let stored, _):
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
        case .stored(let stored, _), .recoveryRequired(let stored, _):
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
        case .recoveryRequired(let observed, let message):
            return ApplicationTransition(
                state: observed, succeeded: false, rebuildsProjection: false,
                conflictMessage: message, marksIrohConflict: false
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
