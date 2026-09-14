import Foundation

extension PersistedTimerState {
    mutating func recordNeverSentCommand(id: String) {
        neverSentCommandIDs.insert(id)
    }

    mutating func recordNeverSentTaskOperation(id: String) {
        neverSentTaskOperationIDs.insert(id)
    }

    mutating func recordNeverSentDurationOperation(id: String) {
        neverSentDurationOperationIDs.insert(id)
    }

    mutating func recordNeverSentAutoStartOperation(id: UUID) {
        neverSentAutoStartOperationIDs.insert(id.uuidString.lowercased())
    }

    mutating func recordNeverSentSelectedTaskOperation(id: UUID) {
        neverSentSelectedTaskOperationIDs.insert(id.uuidString.lowercased())
    }

    mutating func retireNeverSentProof(
        commands: [String],
        taskOperations: [String],
        durationOperations: [String],
        autoStartOperations: [String],
        selectedTaskOperations: [String]
    ) {
        neverSentCommandIDs.subtract(commands)
        neverSentTaskOperationIDs.subtract(taskOperations)
        neverSentDurationOperationIDs.subtract(durationOperations)
        neverSentAutoStartOperationIDs.subtract(autoStartOperations.map { $0.lowercased() })
        neverSentSelectedTaskOperationIDs.subtract(selectedTaskOperations.map { $0.lowercased() })
    }

    mutating func pruneNeverSentProofToPending() {
        neverSentCommandIDs.formIntersection(pendingCommands.map(\.id))
        neverSentTaskOperationIDs.formIntersection(pendingTaskOperations.map(\.id))
        neverSentDurationOperationIDs.formIntersection(pendingDurationOperations.map(\.id))
        let autoStartIDs = Set(pendingAutoStartOperations.map { $0.id.uuidString.lowercased() })
        neverSentAutoStartOperationIDs.formIntersection(autoStartIDs)
        let selectedIDs = Set(pendingSelectedTaskOperations.map { $0.id.uuidString.lowercased() })
        neverSentSelectedTaskOperationIDs.formIntersection(selectedIDs)
    }

    mutating func storeCanonicalHead(wallMs: Int64, counter: Int64) {
        canonicalHeadWallMs = wallMs
        canonicalHeadCounter = counter
    }

    var canonicalHead: (wallMs: Int64, counter: Int64) {
        ((canonicalHeadWallMs ?? 0), (canonicalHeadCounter ?? 0))
    }

    func neverSentProof() -> CoreReconcileNeverSent {
        CoreReconcileNeverSent(state: self)
    }
}

extension PersistedTimerState {
    func safeProjectionCommands() -> [TimerCommand] {
        let head = canonicalHead
        guard pendingCommands.allSatisfy({ neverSentCommandIDs.contains($0.id) }) else { return [] }
        guard pendingCommands.allSatisfy({ ($0.hlcWallMs, $0.hlcCounter) > (head.wallMs, head.counter) }) else { return [] }
        return pendingCommands
    }

    func safeProjectionTaskOperations() -> [TaskOperation] {
        let head = canonicalHead
        guard pendingTaskOperations.allSatisfy({ neverSentTaskOperationIDs.contains($0.id) }) else { return [] }
        guard pendingTaskOperations.allSatisfy({ ($0.hlcWallMs, $0.hlcCounter) > (head.wallMs, head.counter) }) else { return [] }
        return pendingTaskOperations
    }

    func safeProjectionDurationOperations() -> [DurationOperation] {
        let head = canonicalHead
        guard pendingDurationOperations.allSatisfy({ neverSentDurationOperationIDs.contains($0.id) }) else { return [] }
        guard pendingDurationOperations.allSatisfy({ ($0.hlcWallMs, $0.hlcCounter) > (head.wallMs, head.counter) }) else { return [] }
        return pendingDurationOperations
    }

    func safeProjectionAutoStartOperations() -> [AutoStartOperation] {
        let head = canonicalHead
        let ids = pendingAutoStartOperations.map { $0.id.uuidString.lowercased() }
        guard ids.allSatisfy({ neverSentAutoStartOperationIDs.contains($0) }) else { return [] }
        guard pendingAutoStartOperations.allSatisfy({ ($0.hlcWallMs, $0.hlcCounter) > (head.wallMs, head.counter) }) else { return [] }
        return pendingAutoStartOperations
    }

    func safeProjectionSelectedTaskOperations() -> [SelectedTaskOperation] {
        let head = canonicalHead
        let ids = pendingSelectedTaskOperations.map { $0.id.uuidString.lowercased() }
        guard ids.allSatisfy({ neverSentSelectedTaskOperationIDs.contains($0) }) else { return [] }
        guard pendingSelectedTaskOperations.allSatisfy({ ($0.hlcWallMs, $0.hlcCounter) > (head.wallMs, head.counter) }) else { return [] }
        return pendingSelectedTaskOperations
    }

    func safeProjectionPending() -> CoreProjectionPending {
        CoreProjectionPending(
            commands: safeProjectionCommands().map { CoreTimerCommand($0, deviceId: deviceId) },
            taskOperations: safeProjectionTaskOperations().map { CoreTaskOperation($0, deviceId: deviceId) },
            durationOperations: safeProjectionDurationOperations().map { CoreDurationOperation($0, deviceId: deviceId) },
            autoStartOperations: safeProjectionAutoStartOperations().map(CoreAutoStartOperation.init),
            selectedTaskOperations: safeProjectionSelectedTaskOperations().map(CoreSelectedTaskOperation.init)
        )
    }
}
