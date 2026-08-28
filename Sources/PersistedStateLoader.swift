import Foundation

enum PersistedStateMigration: Hashable, Sendable {
    case durationSettings
    case autoStartBreaks
    case selectedTask
    case timerOwnership
    case tasks
}

struct PersistedStateLoad: Sendable {
    let storedData: Data?
    let decodedState: PersistedTimerState?
    let localState: PersistedTimerState
}

struct PersistedStateTransition: Sendable {
    let state: PersistedTimerState
    let migrations: Set<PersistedStateMigration>
    let removesLegacyTasksAfterProjection: Bool
    let migrationFailed: Bool
    let stagedStateWasValid: Bool

    var shouldReportInvalidLocalClock: Bool {
        migrationFailed || !state.hasValidPendingWireOperations
    }

    func shouldPersist(projectionSucceeded: Bool) -> Bool {
        !migrationFailed
            && stagedStateWasValid
            && projectionSucceeded
            && !migrations.isEmpty
    }
}

struct PersistedStateLoader {
    static let storageKey = "timer-state-v2"
    static let legacyStorageKey = "timer-state"
    static let localTaskStorageKey = "local-tasks-v1"

    let defaults: UserDefaults

    func load(preferredStoredData: Data? = nil) -> PersistedStateLoad {
        let storedData = preferredStoredData
            ?? defaults.data(forKey: Self.storageKey)
            ?? defaults.data(forKey: Self.legacyStorageKey)
        let decodedState = storedData.flatMap {
            try? JSONDecoder.api.decode(PersistedTimerState.self, from: $0)
        }
        return PersistedStateLoad(
            storedData: storedData,
            decodedState: decodedState,
            localState: decodedState ?? .fresh()
        )
    }

    func migrating(
        _ stagedState: PersistedTimerState,
        from load: PersistedStateLoad,
        replicationMode: ReplicationMode,
        wallDate: Date,
        uptime: TimeInterval
    ) -> PersistedStateTransition {
        let persisted = migratePersistedFields(
            in: stagedState,
            from: load,
            wallDate: wallDate,
            uptime: uptime
        )
        let tasks = migrateLegacyTasks(in: persisted, wallDate: wallDate, uptime: uptime)
        let hasPersistedSelectedTaskOperations = load.storedData.map(
            Self.hasPersistedSelectedTaskOperations(in:)
        ) ?? false
        let selectedTask = migrateLegacySelectedTask(
            in: tasks,
            shouldMigrate: replicationMode != .iroh && !hasPersistedSelectedTaskOperations,
            wallDate: wallDate,
            uptime: uptime
        )
        let stagedStateWasValid = selectedTask.state.hasValidPendingWireOperations
        return PersistedStateTransition(
            state: !selectedTask.failed && stagedStateWasValid ? selectedTask.state : load.localState,
            migrations: selectedTask.migrations,
            removesLegacyTasksAfterProjection: selectedTask.removesLegacyTasksAfterProjection,
            migrationFailed: selectedTask.failed,
            stagedStateWasValid: stagedStateWasValid
        )
    }

    private struct MigrationProgress {
        var state: PersistedTimerState
        var migrations: Set<PersistedStateMigration> = []
        var removesLegacyTasksAfterProjection = false
        var failed = false
    }

    private func migratePersistedFields(
        in state: PersistedTimerState,
        from load: PersistedStateLoad,
        wallDate: Date,
        uptime: TimeInterval
    ) -> MigrationProgress {
        var progress = MigrationProgress(state: state)
        guard let data = load.storedData, load.decodedState != nil else { return progress }
        if !Self.hasPersistedDurationOperations(in: data) {
            progress.state.migrateLegacyDurationSettings()
            progress.migrations.insert(.durationSettings)
        }
        if !Self.hasPersistedAutoStartOperations(in: data) {
            do {
                let migrationDate = try progress.state.trustedOccurrenceDate(for: wallDate, uptime: uptime)
                try progress.state.migrateLegacyAutoStartBreaks(
                    explicitlySet: Self.hasExplicitLegacyAutoStartBreaks(in: data),
                    at: migrationDate
                )
                progress.migrations.insert(.autoStartBreaks)
            } catch {
                progress.failed = true
            }
        }
        if progress.state.migrateLegacyTimerOwnership() {
            progress.migrations.insert(.timerOwnership)
        }
        return progress
    }

    private func migrateLegacyTasks(
        in progress: MigrationProgress,
        wallDate: Date,
        uptime: TimeInterval
    ) -> MigrationProgress {
        guard let data = defaults.data(forKey: Self.localTaskStorageKey),
              let legacyState = try? JSONDecoder.api.decode(LocalTaskState.self, from: data) else {
            return progress
        }
        var progress = progress
        do {
            let migrationDate = try progress.state.trustedOccurrenceDate(for: wallDate, uptime: uptime)
            try progress.state.migrateLegacyTasks(legacyState, at: migrationDate)
            progress.migrations.insert(.tasks)
            progress.removesLegacyTasksAfterProjection = true
        } catch {
            progress.failed = true
        }
        return progress
    }

    private func migrateLegacySelectedTask(
        in progress: MigrationProgress,
        shouldMigrate: Bool,
        wallDate: Date,
        uptime: TimeInterval
    ) -> MigrationProgress {
        guard shouldMigrate else { return progress }
        var progress = progress
        do {
            let migrationDate = try progress.state.trustedOccurrenceDate(for: wallDate, uptime: uptime)
            if try progress.state.migrateLegacySelectedTask(at: migrationDate) {
                progress.migrations.insert(.selectedTask)
            }
        } catch {
            progress.failed = true
        }
        return progress
    }

    private static func hasPersistedDurationOperations(in data: Data) -> Bool {
        topLevelObject(in: data)?.keys.contains("pendingDurationOperations") == true
    }

    private static func hasPersistedAutoStartOperations(in data: Data) -> Bool {
        topLevelObject(in: data)?.keys.contains("pendingAutoStartOperations") == true
    }

    private static func hasPersistedSelectedTaskOperations(in data: Data) -> Bool {
        topLevelObject(in: data)?.keys.contains("pendingSelectedTaskOperations") == true
    }

    private static func hasExplicitLegacyAutoStartBreaks(in data: Data) -> Bool {
        guard let settings = topLevelObject(in: data)?["settings"] as? [String: Any] else {
            return false
        }
        return settings["autoStartBreaksExplicitlySet"] as? Bool == true
    }

    private static func topLevelObject(in data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
