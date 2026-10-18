import Foundation

enum SyncBatchDomain: String, CaseIterable, Sendable {
    case commands
    case taskOperations
    case durationOperations
    case autoStartOperations
    case selectedTaskOperations

    static func isValid(_ raw: String) -> Bool {
        Self(rawValue: raw) != nil
    }
}

struct BatchDescriptor: Encodable, Sendable {
    let id: String
    let deviceId: String
    let hlcWallMs: Int64
    let hlcCounter: Int64
    let deviceSequence: Int64?

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(deviceId, forKey: .deviceId)
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
        try values.encodeIfPresent(deviceSequence, forKey: .deviceSequence)
    }

    private enum CodingKeys: String, CodingKey {
        case id, deviceId, hlcWallMs, hlcCounter, deviceSequence
    }
}

struct BatchQueuesDescriptors: Encodable, Sendable {
    let commands: [BatchDescriptor]
    let taskOperations: [BatchDescriptor]
    let durationOperations: [BatchDescriptor]
    let autoStartOperations: [BatchDescriptor]
    let selectedTaskOperations: [BatchDescriptor]
}

struct BatchDependencyWire: Encodable, Sendable {
    let operationId: String
    let dependsOnOperationId: String
}

struct BatchLimitsWire: Encodable, Sendable {
    let perDomain: Int
    let total: Int
}

struct BatchNewInput: Encodable, Sendable {
    let kind = "new"
    let mode: String
    let limits: BatchLimitsWire
    let nextDomain: String
    let queues: BatchQueuesDescriptors
    let timerDependencies: [BatchDependencyWire]
}

struct BatchQueuesIDs: Encodable, Sendable {
    let commands: [String]
    let taskOperations: [String]
    let durationOperations: [String]
    let autoStartOperations: [String]
    let selectedTaskOperations: [String]
}

struct BatchSavedInput: Encodable, Sendable {
    let kind = "saved"
    let mode: String
    let limits: BatchLimitsWire
    let queues: BatchQueuesIDs
}

struct CoreBatchPlanSelected: Decodable, Equatable, Sendable {
    let commands: [String]
    let taskOperations: [String]
    let durationOperations: [String]
    let autoStartOperations: [String]
    let selectedTaskOperations: [String]

    func total() -> Int {
        commands.count + taskOperations.count + durationOperations.count
            + autoStartOperations.count + selectedTaskOperations.count
    }
}

struct CoreBatchPlanCounts: Decodable, Equatable, Sendable {
    let commands: Int
    let taskOperations: Int
    let durationOperations: Int
    let autoStartOperations: Int
    let selectedTaskOperations: Int
}

struct CoreBatchPlan: Decodable, Equatable, Sendable {
    let status: String
    let selected: CoreBatchPlanSelected
    let nextDomain: String?
    let heldTimerOperationId: String?
    let counts: CoreBatchPlanCounts
    let total: Int
}

extension SyncBatchPlanError {
    // R50-L03: separates malformed plans (diagnostic) from expected
    // limit/dependency outcomes (quiet) without matching the payload.
    var isInvalidResponse: Bool {
        if case .invalidResponse = self { return true }
        return false
    }
}

enum SyncBatchPlanError: LocalizedError, Equatable, Sendable {
    case invalidResponse(String)
    case oversizedSaved
    case oversizedBootstrap
    case blockedBootstrap
    case blockedSync

    var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "Invalid Core batch plan.")
        case .oversizedSaved: String(localized: "Sync paused: the saved request exceeds the server limit. Confirm recovery before creating a new request. Queued changes remain saved.")
        case .oversizedBootstrap: String(localized: "History setup paused: local changes exceed the server limit. Queued changes remain saved.")
        case .blockedBootstrap, .blockedSync: String(localized: "Sync paused: timer actions are waiting for a dependency. Queued changes remain saved.")
        }
    }
}

struct SyncBatchPlanner: Sendable {
    private let core: SharedCore

    init(core: SharedCore) {
        self.core = core
    }

    func planSync(
        commands: [TimerCommand],
        tasks: [TaskOperation],
        durations: [DurationOperation],
        autoStarts: [AutoStartOperation],
        selectedTasks: [SelectedTaskOperation],
        deviceId: String,
        dependencies: [CoreTimerDependency],
        cursor: String
    ) throws -> CoreBatchPlan {
        let validCursor = SyncBatchDomain.isValid(cursor) ? cursor : "commands"
        let input = BatchNewInput(
            mode: "sync",
            limits: BatchLimitsWire(perDomain: 256, total: 512),
            nextDomain: validCursor,
            queues: Self.descriptors(
                commands: commands, tasks: tasks, durations: durations,
                autoStarts: autoStarts, selectedTasks: selectedTasks, deviceId: deviceId
            ),
            timerDependencies: dependencies.map {
                BatchDependencyWire(
                    operationId: $0.operationId,
                    dependsOnOperationId: $0.dependsOnOperationId
                )
            }
        )
        let plan: CoreBatchPlan = try core.dispatch(
            "sync.batchPlan.v1", input: input, as: CoreBatchPlan.self
        )
        return try Self.validatedNew(
            plan, cursor: validCursor, mode: "sync",
            commandCount: commands.count, taskCount: tasks.count,
            durationCount: durations.count, autoStartCount: autoStarts.count,
            selectedCount: selectedTasks.count,
            commandIDs: Set(commands.map(\.id)),
            taskIDs: Set(tasks.map(\.id)),
            durationIDs: Set(durations.map(\.id)),
            autoStartIDs: Set(autoStarts.map { $0.id.uuidString.lowercased() }),
            selectedIDs: Set(selectedTasks.map { $0.id.uuidString.lowercased() })
        )
    }

    func checkSavedSync(_ request: SyncRequest) throws -> CoreBatchPlan {
        let input = BatchSavedInput(
            mode: "sync",
            limits: BatchLimitsWire(perDomain: 256, total: 512),
            queues: BatchQueuesIDs(
                commands: request.commands.map(\.id),
                taskOperations: request.taskOperations.map(\.id),
                durationOperations: request.durationOperations.map(\.id),
                autoStartOperations: (request.autoStartOperations ?? []).map {
                    $0.id.uuidString.lowercased()
                },
                selectedTaskOperations: request.selectedTaskOperations.map {
                    $0.id.uuidString.lowercased()
                }
            )
        )
        let plan: CoreBatchPlan = try core.dispatch(
            "sync.batchPlan.v1", input: input, as: CoreBatchPlan.self
        )
        return try Self.validatedSaved(plan, ids: Self.planIDs(from: request))
    }

    func planBootstrap(
        commands: [TimerCommand],
        tasks: [TaskOperation],
        durations: [DurationOperation],
        autoStarts: [AutoStartOperation],
        selectedTasks: [SelectedTaskOperation],
        deviceId: String,
        dependencies: [CoreTimerDependency],
        strategy: BootstrapResolutionStrategy
    ) throws -> CoreBatchPlan {
        let mode = Self.bootstrapMode(strategy)
        let queues = strategy == .keepRemote
            ? BatchQueuesDescriptors(
                commands: [], taskOperations: [], durationOperations: [],
                autoStartOperations: [], selectedTaskOperations: []
            )
            : Self.descriptors(
                commands: commands, tasks: tasks, durations: durations,
                autoStarts: autoStarts, selectedTasks: selectedTasks, deviceId: deviceId
            )
        let input = BatchNewInput(
            mode: mode,
            limits: BatchLimitsWire(perDomain: 4096, total: 8192),
            nextDomain: "commands",
            queues: queues,
            timerDependencies: (strategy == .keepRemote ? [] : dependencies).map {
                BatchDependencyWire(
                    operationId: $0.operationId,
                    dependsOnOperationId: $0.dependsOnOperationId
                )
            }
        )
        let plan: CoreBatchPlan = try core.dispatch(
            "sync.batchPlan.v1", input: input, as: CoreBatchPlan.self
        )
        return try Self.validatedNew(
            plan, cursor: "commands", mode: mode,
            commandCount: queues.commands.count, taskCount: queues.taskOperations.count,
            durationCount: queues.durationOperations.count,
            autoStartCount: queues.autoStartOperations.count,
            selectedCount: queues.selectedTaskOperations.count,
            commandIDs: Set(commands.map(\.id)),
            taskIDs: Set(tasks.map(\.id)),
            durationIDs: Set(durations.map(\.id)),
            autoStartIDs: Set(autoStarts.map { $0.id.uuidString.lowercased() }),
            selectedIDs: Set(selectedTasks.map { $0.id.uuidString.lowercased() })
        )
    }

    func checkSavedBootstrap(_ request: BootstrapResolveRequest) throws -> CoreBatchPlan {
        let mode = Self.bootstrapMode(request.strategy)
        let input = BatchSavedInput(
            mode: mode,
            limits: BatchLimitsWire(perDomain: 4096, total: 8192),
            queues: BatchQueuesIDs(
                commands: request.commands.map(\.id),
                taskOperations: request.taskOperations.map(\.id),
                durationOperations: request.durationOperations.map(\.id),
                autoStartOperations: (request.autoStartOperations ?? []).map {
                    $0.id.uuidString.lowercased()
                },
                selectedTaskOperations: (request.selectedTaskOperations ?? []).map {
                    $0.id.uuidString.lowercased()
                }
            )
        )
        let plan: CoreBatchPlan = try core.dispatch(
            "sync.batchPlan.v1", input: input, as: CoreBatchPlan.self
        )
        let ids = CoreBatchPlanSelected(
            commands: request.commands.map(\.id),
            taskOperations: request.taskOperations.map(\.id),
            durationOperations: request.durationOperations.map(\.id),
            autoStartOperations: (request.autoStartOperations ?? []).map {
                $0.id.uuidString.lowercased()
            },
            selectedTaskOperations: (request.selectedTaskOperations ?? []).map {
                $0.id.uuidString.lowercased()
            }
        )
        return try Self.validatedSaved(plan, ids: ids)
    }
}

// R50-L03: internal (not private) so regression tests drive the exact
// malformed-plan validators with synthetic Core outputs.
extension SyncBatchPlanner {
    static func descriptors(
        commands: [TimerCommand],
        tasks: [TaskOperation],
        durations: [DurationOperation],
        autoStarts: [AutoStartOperation],
        selectedTasks: [SelectedTaskOperation],
        deviceId: String
    ) -> BatchQueuesDescriptors {
        BatchQueuesDescriptors(
            commands: commands.map {
                BatchDescriptor(
                    id: $0.id, deviceId: deviceId,
                    hlcWallMs: $0.hlcWallMs, hlcCounter: $0.hlcCounter,
                    deviceSequence: $0.deviceSequence
                )
            },
            taskOperations: tasks.map {
                BatchDescriptor(
                    id: $0.id, deviceId: deviceId,
                    hlcWallMs: $0.hlcWallMs, hlcCounter: $0.hlcCounter,
                    deviceSequence: nil
                )
            },
            durationOperations: durations.map {
                BatchDescriptor(
                    id: $0.id, deviceId: deviceId,
                    hlcWallMs: $0.hlcWallMs, hlcCounter: $0.hlcCounter,
                    deviceSequence: nil
                )
            },
            autoStartOperations: autoStarts.map {
                BatchDescriptor(
                    id: $0.id.uuidString.lowercased(), deviceId: $0.deviceId,
                    hlcWallMs: $0.hlcWallMs, hlcCounter: $0.hlcCounter,
                    deviceSequence: nil
                )
            },
            selectedTaskOperations: selectedTasks.map {
                BatchDescriptor(
                    id: $0.id.uuidString.lowercased(), deviceId: $0.deviceId,
                    hlcWallMs: $0.hlcWallMs, hlcCounter: $0.hlcCounter,
                    deviceSequence: nil
                )
            }
        )
    }

    static func bootstrapMode(_ strategy: BootstrapResolutionStrategy) -> String {
        switch strategy {
        case .merge: "merge"
        case .replaceRemote: "replace_remote"
        case .keepRemote: "keep_remote"
        }
    }

    static func planIDs(from request: SyncRequest) -> CoreBatchPlanSelected {
        CoreBatchPlanSelected(
            commands: request.commands.map(\.id),
            taskOperations: request.taskOperations.map(\.id),
            durationOperations: request.durationOperations.map(\.id),
            autoStartOperations: (request.autoStartOperations ?? []).map {
                $0.id.uuidString.lowercased()
            },
            selectedTaskOperations: request.selectedTaskOperations.map {
                $0.id.uuidString.lowercased()
            }
        )
    }

    static func validatedNew(
        _ plan: CoreBatchPlan,
        cursor: String,
        mode: String,
        commandCount: Int,
        taskCount: Int,
        durationCount: Int,
        autoStartCount: Int,
        selectedCount: Int,
        commandIDs: Set<String>,
        taskIDs: Set<String>,
        durationIDs: Set<String>,
        autoStartIDs: Set<String>,
        selectedIDs: Set<String>
    ) throws -> CoreBatchPlan {
        try checkStatus(plan.status)
        try checkCounts(
            plan, commandCount: commandCount, taskCount: taskCount,
            durationCount: durationCount, autoStartCount: autoStartCount,
            selectedCount: selectedCount
        )
        try checkSubset(
            plan, commandIDs: commandIDs, taskIDs: taskIDs,
            durationIDs: durationIDs, autoStartIDs: autoStartIDs,
            selectedIDs: selectedIDs
        )
        if mode == "sync" {
            try checkSyncCursor(plan, cursor: cursor)
        } else {
            try checkBootstrapCursor(plan)
        }
        return plan
    }

    static func checkStatus(_ status: String) throws {
        guard ["planned", "blocked_dependency", "oversized"].contains(status) else {
            throw SyncBatchPlanError.invalidResponse("unknown batch status")
        }
    }

    static func checkCounts(
        _ plan: CoreBatchPlan,
        commandCount: Int,
        taskCount: Int,
        durationCount: Int,
        autoStartCount: Int,
        selectedCount: Int
    ) throws {
        guard plan.counts.commands == commandCount,
              plan.counts.taskOperations == taskCount,
              plan.counts.durationOperations == durationCount,
              plan.counts.autoStartOperations == autoStartCount,
              plan.counts.selectedTaskOperations == selectedCount,
              plan.total == commandCount + taskCount + durationCount + autoStartCount + selectedCount
        else {
            throw SyncBatchPlanError.invalidResponse("batch counts disagree")
        }
    }

    static func checkSubset(
        _ plan: CoreBatchPlan,
        commandIDs: Set<String>,
        taskIDs: Set<String>,
        durationIDs: Set<String>,
        autoStartIDs: Set<String>,
        selectedIDs: Set<String>
    ) throws {
        guard Set(plan.selected.commands).count == plan.selected.commands.count,
              Set(plan.selected.commands).isSubset(of: commandIDs),
              Set(plan.selected.taskOperations).count == plan.selected.taskOperations.count,
              Set(plan.selected.taskOperations).isSubset(of: taskIDs),
              Set(plan.selected.durationOperations).count == plan.selected.durationOperations.count,
              Set(plan.selected.durationOperations).isSubset(of: durationIDs)
        else {
            throw SyncBatchPlanError.invalidResponse("selected unknown operation")
        }
        try checkPreferenceSubset(plan, autoStartIDs: autoStartIDs, selectedIDs: selectedIDs)
    }

    static func checkPreferenceSubset(
        _ plan: CoreBatchPlan,
        autoStartIDs: Set<String>,
        selectedIDs: Set<String>
    ) throws {
        let autoLower = Set(autoStartIDs.map { $0.lowercased() })
        let selectedLower = Set(selectedIDs.map { $0.lowercased() })
        guard Set(plan.selected.autoStartOperations).count == plan.selected.autoStartOperations.count,
              Set(plan.selected.autoStartOperations.map { $0.lowercased() }).isSubset(of: autoLower),
              Set(plan.selected.selectedTaskOperations).count == plan.selected.selectedTaskOperations.count,
              Set(plan.selected.selectedTaskOperations.map { $0.lowercased() }).isSubset(of: selectedLower)
        else {
            throw SyncBatchPlanError.invalidResponse("selected unknown operation")
        }
    }

    static func checkSyncCursor(_ plan: CoreBatchPlan, cursor: String) throws {
        guard ["planned", "blocked_dependency"].contains(plan.status) else {
            throw SyncBatchPlanError.invalidResponse("invalid sync status")
        }
        guard let next = plan.nextDomain, SyncBatchDomain.isValid(next) else {
            throw SyncBatchPlanError.invalidResponse("invalid sync cursor")
        }
        guard plan.status != "blocked_dependency" else {
            guard plan.selected.total() == 0, plan.heldTimerOperationId != nil else {
                throw SyncBatchPlanError.invalidResponse("invalid blocked plan")
            }
            guard next == cursor else {
                throw SyncBatchPlanError.invalidResponse("blocked plan moved cursor")
            }
            return
        }
    }

    static func checkBootstrapCursor(_ plan: CoreBatchPlan) throws {
        guard let next = plan.nextDomain, SyncBatchDomain.isValid(next) else {
            throw SyncBatchPlanError.invalidResponse("invalid bootstrap cursor")
        }
        if plan.status != "planned" {
            guard plan.selected.total() == 0 else {
                throw SyncBatchPlanError.invalidResponse("non-planned selected work")
            }
        }
    }

    static func validatedSaved(
        _ plan: CoreBatchPlan,
        ids: CoreBatchPlanSelected
    ) throws -> CoreBatchPlan {
        try checkCounts(
            plan, commandCount: ids.commands.count, taskCount: ids.taskOperations.count,
            durationCount: ids.durationOperations.count,
            autoStartCount: ids.autoStartOperations.count,
            selectedCount: ids.selectedTaskOperations.count
        )
        guard ["replay_saved", "oversized_saved"].contains(plan.status) else {
            throw SyncBatchPlanError.invalidResponse("invalid saved status")
        }
        guard plan.nextDomain == nil, plan.heldTimerOperationId == nil else {
            throw SyncBatchPlanError.invalidResponse("saved plan carries cursor")
        }
        if plan.status == "replay_saved" {
            guard plan.selected == ids else {
                throw SyncBatchPlanError.invalidResponse("saved plan must replay exact claim")
            }
        } else {
            guard plan.selected.total() == 0 else {
                throw SyncBatchPlanError.invalidResponse("oversized saved selected work")
            }
        }
        return plan
    }
}
