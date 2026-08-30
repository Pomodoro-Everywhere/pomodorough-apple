import Foundation

struct IrohLegacyTaskMigration: Codable, Equatable, Sendable {
    let roomID: String
    let source: Data
    let deviceID: String
    let records: [IrohOperationRecord]

    init(roomID: String, source: Data, state: PersistedTimerState) {
        self.roomID = roomID
        self.source = source
        deviceID = state.deviceId
        records = state.pendingTaskOperations.map {
            IrohOperationRecord(domain: .task, deviceId: state.deviceId, payload: .task($0))
        } + state.pendingSelectedTaskOperations.map {
            IrohOperationRecord(
                domain: .selectedTask, deviceId: state.deviceId,
                payload: .selectedTask(IrohSelectedTaskOperation($0))
            )
        }
    }

    func validate(in workspace: IrohRoomWorkspace) throws {
        let legacy = try JSONDecoder.api.decode(LocalTaskState.self, from: source)
        guard workspace.roomID == roomID, workspace.roomState.deviceId == deviceID,
              workspace.conflict == nil,
              (legacy.tasks + Array(legacy.assignments.values)).allSatisfy(\.isValid),
              records.allSatisfy({ record in
                  record.deviceId == deviceID && record.isValid
                      && workspace.records.contains(where: { $0.record == record })
              }),
              legacy.tasks.allSatisfy(hasTaskEvidence),
              hasSelectionEvidence(for: legacy) else {
            throw IrohProtocolError.invalidMessage("legacy task migration evidence does not match its room")
        }
    }

    func restoreMetadata(to state: inout PersistedTimerState) throws {
        let legacy = try JSONDecoder.api.decode(LocalTaskState.self, from: source)
        PersistedLegacyMigration.restoreTaskMetadata(legacy, state: &state)
    }

    private func hasTaskEvidence(_ task: FocusTask) -> Bool {
        records.contains { record in
            guard case .task(let operation) = record.payload else { return false }
            return operation.type == .upsert && UUID(uuidString: operation.taskId) == task.id
                && operation.title == task.title
        }
    }

    private func hasSelectionEvidence(for legacy: LocalTaskState) -> Bool {
        guard let selected = legacy.selectedTaskID,
              legacy.tasks.contains(where: { $0.id == selected }) else { return true }
        return records.contains { record in
            guard case .selectedTask(let operation) = record.payload else { return false }
            return operation.taskId.flatMap(UUID.init(uuidString:)) == selected
        }
    }
}
