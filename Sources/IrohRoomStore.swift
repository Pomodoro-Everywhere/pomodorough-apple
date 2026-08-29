import Foundation

final class IrohRoomStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let secretStore: any IrohRoomSecretStoring
    private let now: () -> Date
    private var state: IrohReplicationState
    private var loadError: String?

    init(
        fileURL: URL = IrohRoomStore.defaultFileURL(),
        secretStore: any IrohRoomSecretStoring = IrohRoomSecretKeychainStore(),
        now: @escaping () -> Date = { .now }
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        self.now = now
        state = .empty
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                state = try JSONDecoder.api.decode(IrohReplicationState.self, from: data)
                var migratedLegacySecret = false
                for index in state.rooms.indices {
                    let roomID = state.rooms[index].roomID
                    let legacySecret = state.rooms[index].roomSecret
                    let storedSecret = try secretStore.load(roomID: roomID)
                    let secret: Data
                    if let storedSecret {
                        guard legacySecret == nil || legacySecret == storedSecret else {
                            throw IrohProtocolError.immutableConflict
                        }
                        secret = storedSecret
                        migratedLegacySecret = legacySecret != nil
                    } else if let legacySecret {
                        try secretStore.save(legacySecret, roomID: roomID)
                        secret = legacySecret
                        migratedLegacySecret = true
                    } else {
                        throw IrohProtocolError.unavailable("Saved room secret is missing from this device.")
                    }
                    guard try IrohProtocolV1.roomID(for: secret) == roomID else {
                        throw IrohProtocolError.invalidMessage("saved room secret does not match its room")
                    }
                    state.rooms[index].roomSecret = secret
                }
                if migratedLegacySecret { try persistLocked() }
            } else {
                state = .empty
            }
        } catch {
            state = .empty
            loadError = "Saved Iroh room data could not be decoded. Original file was left unchanged."
        }
    }

    var activeSnapshot: IrohRoomSnapshot? {
        lock.withLock {
            guard let room = activeWorkspaceLocked else { return nil }
            return snapshot(of: room)
        }
    }

    var activeRoomID: String? {
        lock.withLock { state.activeRoomID }
    }

    var activeRoomState: PersistedTimerState? {
        lock.withLock { activeWorkspaceLocked?.roomState }
    }

    var activeReturnState: PersistedTimerState? {
        lock.withLock { activeWorkspaceLocked?.returnState }
    }

    var activeRoomSecret: Data? {
        lock.withLock { activeWorkspaceLocked?.roomSecret }
    }

    var preferredRoomID: String? {
        lock.withLock {
            state.activeRoomID ?? state.rooms.max(by: { $0.createdAt < $1.createdAt })?.roomID
        }
    }

    func roomSnapshot(roomID: String) -> IrohRoomSnapshot? {
        lock.withLock {
            state.rooms.first(where: { $0.roomID == roomID }).map(snapshot)
        }
    }

    func createRoom(
        roomID: String,
        roomSecret: Data,
        name: String?,
        returnState: PersistedTimerState,
        genesis: IrohGenesis,
        now: Date = .now
    ) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard try validRoomMetadata(roomID: roomID, secret: roomSecret, name: name),
                  genesis.isValid else {
                throw IrohProtocolError.invalidMessage("room genesis is invalid")
            }
            guard state.rooms.first(where: { $0.roomID == roomID }) == nil else {
                throw IrohProtocolError.immutableConflict
            }
            let workspace = try makeNewWorkspace(
                roomID: roomID,
                roomSecret: roomSecret,
                name: name,
                returnState: returnState,
                genesis: genesis,
                now: now
            )
            let installedSecret = try installSecretLocked(roomID: roomID, secret: roomSecret)
            do {
                return try committingLocked {
                    state.rooms.append(workspace)
                    state.activeRoomID = roomID
                    return workspace.roomState
                }
            } catch {
                if installedSecret { try? secretStore.delete(roomID: roomID) }
                throw error
            }
        }
    }

    private func validRoomMetadata(roomID: String, secret: Data, name: String?) throws -> Bool {
        try IrohProtocolV1.isValidRoomID(roomID)
            && IrohProtocolV1.roomID(for: secret) == roomID
            && IrohProtocolV1.isValidDisplayName(name)
    }

    private func makeNewWorkspace(
        roomID: String,
        roomSecret: Data,
        name: String?,
        returnState: PersistedTimerState,
        genesis: IrohGenesis,
        now: Date
    ) throws -> IrohRoomWorkspace {
        let storedGenesis = try storedGenesis(genesis, deviceID: returnState.deviceId)
        var roomState = Self.makeRoomDeviceState(from: returnState)
        if let timer = genesis.canonicalTimer,
           timer.status == .running || timer.status == .paused,
           timer.startedByDeviceId == returnState.deviceId {
            roomState.localTimerOwners[timer.id] = returnState.deviceId
        }
        var workspace = IrohRoomWorkspace(
            roomID: roomID,
            roomSecret: roomSecret,
            roomName: name,
            returnState: returnState,
            roomState: roomState,
            peers: [],
            records: [storedGenesis],
            conflict: nil,
            createdAt: now
        )
        workspace.roomState = try IrohRoomProjection.project(workspace, at: self.now())
        return workspace
    }

    private func storedGenesis(_ genesis: IrohGenesis, deviceID: String) throws -> IrohStoredRecord {
        let record = IrohOperationRecord(
            domain: .genesis,
            deviceId: deviceID,
            payload: .genesis(genesis)
        )
        guard record.isValid,
              try record.operationByteCount() <= IrohProtocolV1.maxOperationBytes else {
            throw IrohProtocolError.invalidMessage("room genesis exceeds operation limits")
        }
        return try IrohStoredRecord(
            record: record,
            digest: try record.digest(),
            canonicalData: try record.canonicalBytes()
        )
    }

    func prepareJoinedRoom(
        roomID: String,
        roomSecret: Data,
        name: String?,
        returnState: PersistedTimerState,
        initialPeer: IrohPeer,
        now: Date = .now
    ) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard IrohProtocolV1.isValidRoomID(roomID),
                  try IrohProtocolV1.roomID(for: roomSecret) == roomID,
                  IrohProtocolV1.isValidDisplayName(name) else {
                throw IrohProtocolError.invalidInvite("room metadata is invalid")
            }
            let installedSecret = try installSecretLocked(roomID: roomID, secret: roomSecret)
            do {
                try committingLocked {
                    if let existingIndex = roomIndexLocked(roomID) {
                        guard state.activeRoomID != roomID,
                              state.rooms[existingIndex].genesis == nil,
                              state.rooms[existingIndex].conflict == nil,
                              state.rooms[existingIndex].roomSecret == roomSecret else {
                            throw IrohProtocolError.immutableConflict
                        }
                        state.rooms.remove(at: existingIndex)
                    }
                    state.rooms.append(IrohRoomWorkspace(
                        roomID: roomID,
                        roomSecret: roomSecret,
                        roomName: name,
                        returnState: returnState,
                        roomState: Self.makeRoomDeviceState(from: returnState),
                        peers: [initialPeer],
                        records: [],
                        conflict: nil,
                        createdAt: now
                    ))
                }
            } catch {
                if installedSecret { try? secretStore.delete(roomID: roomID) }
                throw error
            }
        }
    }

    func activateJoinedRoom(
        roomID: String,
        returnState: PersistedTimerState
    ) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let index = roomIndexLocked(roomID),
                  state.rooms[index].genesis != nil,
                  state.rooms[index].conflict == nil else {
                throw IrohProtocolError.invalidMessage("joined room has no valid genesis")
            }
            let projected = try IrohRoomProjection.project(state.rooms[index], at: self.now())
            return try committingLocked {
                state.rooms[index].returnState = returnState
                state.rooms[index].roomState = projected
                state.activeRoomID = roomID
                return projected
            }
        }
    }

    func activateExistingRoom(roomID: String, returnState: PersistedTimerState) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let index = roomIndexLocked(roomID), state.rooms[index].conflict == nil else {
                throw IrohProtocolError.invalidMessage("room is unavailable or requires repair")
            }
            return try committingLocked {
                state.rooms[index].returnState = returnState
                state.activeRoomID = roomID
                let projected = try IrohRoomProjection.project(state.rooms[index], at: self.now())
                state.rooms[index].roomState = projected
                return projected
            }
        }
    }

    func discardUnconflictedInactiveRoom(roomID: String) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard state.activeRoomID != roomID else {
                throw IrohProtocolError.invalidMessage("active room cannot be discarded")
            }
            guard let index = roomIndexLocked(roomID), state.rooms[index].conflict == nil else { return }
            try committingLocked { _ = state.rooms.remove(at: index) }
            try secretStore.delete(roomID: roomID)
        }
    }

    func captureLocalOperations(from stateToCapture: PersistedTimerState) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let roomID = state.activeRoomID, let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.unavailable("No Iroh room is active.")
            }
            let workspace = try capturedWorkspaceLocked(from: stateToCapture, index: index)
            return try committingLocked {
                state.rooms[index] = workspace
                return workspace.roomState
            }
        }
    }

    func captureAndSuspendActiveRoom(from stateToCapture: PersistedTimerState) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let roomID = state.activeRoomID, let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.unavailable("No Iroh room is active.")
            }
            let returnState = state.rooms[index].returnState
            let workspace = try capturedWorkspaceLocked(from: stateToCapture, index: index)
            return try committingLocked {
                state.rooms[index] = workspace
                state.activeRoomID = nil
                return returnState
            }
        }
    }

    @discardableResult
    func insertRemoteRecords(
        _ records: [IrohOperationRecord],
        roomID: String,
        now: Date = .now
    ) throws -> PersistedTimerState {
        try lock.withLock {
            try ensureAvailableLocked()
            guard !records.isEmpty,
                  records.count <= IrohProtocolV1.maxOperationReferences,
                  let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.invalidMessage("operation batch is invalid")
            }
            guard state.rooms[index].conflict == nil else { throw IrohProtocolError.immutableConflict }

            let original = state.rooms[index]
            let incoming = try storedRecords(from: records)
            try validateUniqueReferences(incoming)
            try detectImmutableConflict(incoming, original: original, index: index, at: now)
            var staged = try inserting(records, into: original)
            if staged.genesis != nil {
                staged.roomState = try IrohRoomProjection.project(staged, at: self.now())
            }
            return try committingLocked {
                state.rooms[index] = staged
                return staged.roomState
            }
        }
    }

    func inventory(
        roomID: String,
        after: String?,
        limit: Int
    ) throws -> (entries: [IrohInventoryEntry], next: String?) {
        try lock.withLock {
            try ensureAvailableLocked()
            guard (1...IrohProtocolV1.maxInventoryEntries).contains(limit),
                  let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.invalidMessage("inventory request is invalid")
            }
            let ordered = room.records.map {
                IrohInventoryEntry(domain: $0.record.domain, id: $0.record.id, digest: $0.digest)
            }.sorted(by: Self.inventoryPrecedes)
            let start: Int
            if let after {
                guard let separator = after.firstIndex(of: "\0"),
                      let domain = IrohDomain(rawValue: String(after[..<separator])) else {
                    throw IrohProtocolError.invalidMessage("inventory cursor is invalid")
                }
                let id = String(after[after.index(after: separator)...])
                let cursor = IrohInventoryReference(domain: domain, id: id)
                start = ordered.firstIndex { entry in
                    Self.referencePrecedes(cursor, entry.reference)
                } ?? ordered.endIndex
            } else {
                start = ordered.startIndex
            }
            let end = min(ordered.endIndex, start + limit)
            let page = Array(ordered[start..<end])
            let next = end < ordered.endIndex ? page.last.map(Self.cursor) : nil
            return (page, next)
        }
    }

    func operations(
        roomID: String,
        references: [IrohInventoryReference]
    ) throws -> [IrohOperationRecord] {
        try lock.withLock {
            try ensureAvailableLocked()
            guard !references.isEmpty,
                  references.count <= IrohProtocolV1.maxOperationReferences,
                  Set(references).count == references.count,
                  let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.invalidMessage("operation request is invalid")
            }
            let records = try references.map { reference in
                guard let stored = room.records.first(where: {
                    $0.record.domain == reference.domain && $0.record.id == reference.id
                }) else { throw IrohProtocolError.notFound }
                return stored.record
            }
            guard records.count == references.count else { throw IrohProtocolError.notFound }
            return records
        }
    }

    func missingReferences(
        roomID: String,
        remoteEntries: [IrohInventoryEntry]
    ) throws -> [IrohInventoryReference] {
        try lock.withLock {
            try ensureAvailableLocked()
            guard remoteEntries.count <= IrohProtocolV1.maxInventoryEntries,
                  let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.invalidMessage("inventory result is invalid")
            }
            var missing: [IrohInventoryReference] = []
            for entry in remoteEntries {
                if let local = room.records.first(where: {
                    $0.record.domain == entry.domain && $0.record.id == entry.id
                }) {
                    guard local.digest == entry.digest else {
                        guard let index = roomIndexLocked(roomID) else {
                            throw IrohProtocolError.immutableConflict
                        }
                        try committingLocked {
                            state.rooms[index].conflict = IrohConflictEvidence(
                                domain: entry.domain,
                                id: entry.id,
                                localDigest: local.digest,
                                receivedDigest: entry.digest,
                                detectedAt: .now
                            )
                        }
                        throw IrohProtocolError.immutableConflict
                    }
                } else {
                    missing.append(entry.reference)
                }
            }
            return missing
        }
    }

    func upsertPeer(_ peer: IrohPeer, roomID: String) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard peer.endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes,
                  IrohProtocolV1.isValidDisplayName(peer.displayName),
                  let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.invalidMessage("peer metadata is invalid")
            }
            var workspace = state.rooms[index]
            if let peerIndex = workspace.peers.firstIndex(where: { $0.endpointID == peer.endpointID }) {
                workspace.peers[peerIndex] = peer
            } else {
                guard workspace.peers.count < IrohProtocolV1.maxPeers else {
                    throw IrohProtocolError.limit("room address book contains 64 peers")
                }
                workspace.peers.append(peer)
            }
            try committingLocked { state.rooms[index] = workspace }
        }
    }

    func replaceActiveReturnState(_ returnState: PersistedTimerState) throws {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let roomID = state.activeRoomID, let index = roomIndexLocked(roomID) else {
                throw IrohProtocolError.notFound
            }
            try committingLocked { state.rooms[index].returnState = returnState }
        }
    }

    func peers(roomID: String) throws -> [IrohPeer] {
        try lock.withLock {
            try ensureAvailableLocked()
            guard let room = state.rooms.first(where: { $0.roomID == roomID }) else {
                throw IrohProtocolError.notFound
            }
            return room.peers
        }
    }

    private func inserting(
        _ records: [IrohOperationRecord],
        into original: IrohRoomWorkspace
    ) throws -> IrohRoomWorkspace {
        var workspace = original
        for record in records {
            guard record.isValid else {
                throw IrohProtocolError.invalidMessage("operation record failed validation")
            }
            let digest = try record.digest()
            if let existing = workspace.records.first(where: {
                $0.record.domain == record.domain && $0.record.id == record.id
            }) {
                guard existing.digest == digest else { throw IrohProtocolError.immutableConflict }
                continue
            }
            workspace.records.append(try IrohStoredRecord(
                record: record,
                digest: digest,
                canonicalData: try record.canonicalBytes()
            ))
        }
        try Self.validateRecordSet(workspace.records)
        return workspace
    }

    private func storedRecords(from records: [IrohOperationRecord]) throws -> [IrohStoredRecord] {
        try records.map { record in
            guard record.isValid,
                  try record.operationByteCount() <= IrohProtocolV1.maxOperationBytes else {
                throw IrohProtocolError.invalidMessage("operation record failed validation")
            }
            return try IrohStoredRecord(
                record: record,
                digest: try record.digest(),
                canonicalData: try record.canonicalBytes()
            )
        }
    }

    private func validateUniqueReferences(_ records: [IrohStoredRecord]) throws {
        let references = records.map { $0.record.domain.rawValue + "\0" + $0.record.id }
        guard Set(references).count == records.count else {
            throw IrohProtocolError.invalidMessage("operation batch contains duplicate references")
        }
    }

    private func detectImmutableConflict(
        _ incoming: [IrohStoredRecord],
        original: IrohRoomWorkspace,
        index: Int,
        at date: Date
    ) throws {
        for candidate in incoming {
            guard let existing = original.records.first(where: {
                $0.record.domain == candidate.record.domain && $0.record.id == candidate.record.id
            }) else { continue }
            guard existing.digest == candidate.digest else {
                var conflicted = original
                conflicted.conflict = IrohConflictEvidence(
                    domain: candidate.record.domain,
                    id: candidate.record.id,
                    localDigest: existing.digest,
                    receivedDigest: candidate.digest,
                    detectedAt: date
                )
                try committingLocked { state.rooms[index] = conflicted }
                throw IrohProtocolError.immutableConflict
            }
        }
    }

    private func pendingRecords(from timerState: PersistedTimerState) -> [IrohOperationRecord] {
        var records = timerState.pendingCommands.map {
            IrohOperationRecord(domain: .timer, deviceId: timerState.deviceId, payload: .timer($0))
        }
        records += timerState.pendingTaskOperations.map {
            IrohOperationRecord(domain: .task, deviceId: timerState.deviceId, payload: .task($0))
        }
        records += timerState.pendingDurationOperations.map {
            IrohOperationRecord(domain: .duration, deviceId: timerState.deviceId, payload: .duration($0))
        }
        records += timerState.pendingAutoStartOperations.map {
            IrohOperationRecord(
                domain: .autoStart,
                deviceId: timerState.deviceId,
                payload: .autoStart(IrohAutoStartOperation($0))
            )
        }
        records += timerState.pendingSelectedTaskOperations.map {
            IrohOperationRecord(
                domain: .selectedTask,
                deviceId: timerState.deviceId,
                payload: .selectedTask(IrohSelectedTaskOperation($0))
            )
        }
        return records
    }

    private func stateWithoutPendingOperations(
        _ captured: PersistedTimerState
    ) -> PersistedTimerState {
        var state = captured
        state.pendingCommands = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        state.pendingAutoStartOperations = []
        state.pendingSelectedTaskOperations = []
        state.provisionalBreaks = []
        return state
    }

    private func capturedWorkspaceLocked(
        from stateToCapture: PersistedTimerState,
        index: Int
    ) throws -> IrohRoomWorkspace {
        guard state.rooms[index].conflict == nil else { throw IrohProtocolError.immutableConflict }
        let records = pendingRecords(from: stateToCapture)
        let existingWorkspace = state.rooms[index]
        try detectCapturedConflict(records, existing: existingWorkspace, index: index)
        var workspace = existingWorkspace
        workspace.roomState = stateWithoutPendingOperations(stateToCapture)
        workspace = try inserting(records, into: workspace)
        if workspace.genesis != nil {
            workspace.roomState = try IrohRoomProjection.project(workspace, at: self.now())
        }
        return workspace
    }

    private func detectCapturedConflict(
        _ records: [IrohOperationRecord],
        existing: IrohRoomWorkspace,
        index: Int
    ) throws {
        for record in records {
            guard let stored = existing.records.first(where: {
                $0.record.domain == record.domain && $0.record.id == record.id
            }) else { continue }
            let receivedDigest = try record.digest()
            guard stored.digest == receivedDigest else {
                let evidence = IrohConflictEvidence(
                    domain: record.domain,
                    id: record.id,
                    localDigest: stored.digest,
                    receivedDigest: receivedDigest,
                    detectedAt: .now
                )
                try committingLocked { state.rooms[index].conflict = evidence }
                throw IrohProtocolError.immutableConflict
            }
        }
    }

    static func validateRecordSet(_ records: [IrohStoredRecord]) throws {
        let genesis = records.filter { $0.record.domain == .genesis && $0.record.id == "genesis" }
        guard genesis.count <= 1,
              records.allSatisfy({ $0.record.isValid }),
              records.allSatisfy({ stored in
                  guard let decoded = try? JSONDecoder.api.decode(
                      IrohOperationRecord.self,
                      from: stored.canonicalData
                  ) else { return false }
                  return decoded == stored.record
              }),
              records.allSatisfy({ (try? $0.record.digest()) == $0.digest }),
              records.allSatisfy({ (try? $0.record.operationByteCount()) ?? .max <= IrohProtocolV1.maxOperationBytes }),
              Set(records.map { $0.record.domain.rawValue + "\0" + $0.record.id }).count == records.count else {
            throw IrohProtocolError.invalidMessage("room operation set is invalid")
        }
        var sequences: [String: String] = [:]
        for stored in records {
            guard case .timer(let command) = stored.record.payload else { continue }
            let key = stored.record.deviceId + "\0" + String(command.deviceSequence)
            if let existing = sequences[key], existing != command.id {
                throw IrohProtocolError.invalidMessage("device sequence is reused")
            }
            sequences[key] = command.id
        }
    }

    private func ensureAvailableLocked() throws {
        if let loadError { throw IrohProtocolError.unavailable(loadError) }
    }

    private func installSecretLocked(roomID: String, secret: Data) throws -> Bool {
        if let existing = try secretStore.load(roomID: roomID) {
            guard existing == secret else { throw IrohProtocolError.immutableConflict }
            return false
        }
        try secretStore.save(secret, roomID: roomID)
        return true
    }

    private func persistLocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.api.encode(state)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private func committingLocked<Value>(_ mutation: () throws -> Value) throws -> Value {
        let original = state
        do {
            let value = try mutation()
            try persistLocked()
            return value
        } catch {
            state = original
            throw error
        }
    }

    private var activeWorkspaceLocked: IrohRoomWorkspace? {
        guard let activeRoomID = state.activeRoomID else { return nil }
        return state.rooms.first(where: { $0.roomID == activeRoomID })
    }

    private func roomIndexLocked(_ roomID: String) -> Int? {
        state.rooms.firstIndex(where: { $0.roomID == roomID })
    }

    private func snapshot(of room: IrohRoomWorkspace) -> IrohRoomSnapshot {
        IrohRoomSnapshot(
            roomID: room.roomID,
            roomName: room.roomName,
            peerCount: room.peers.count,
            operationCount: room.records.count,
            conflict: room.conflict
        )
    }

    private static func makeRoomDeviceState(from local: PersistedTimerState) -> PersistedTimerState {
        var state = local
        state.revision = 0
        state.serverTimeOffsetMs = nil
        state.serverTimeUncertaintyMs = nil
        state.serverTimeAnchorMs = nil
        state.serverTimeAnchorUptime = nil
        state.lastTrustedTimeMs = nil
        state.pendingCommands = []
        state.localCommandDates = [:]
        state.pendingTaskOperations = []
        state.pendingDurationOperations = []
        state.pendingAutoStartOperations = []
        state.pendingSelectedTaskOperations = []
        state.localTimerOwners = [:]
        state.provisionalBreaks = []
        state.bootstrapUser = nil
        state.pendingBootstrapResolution = nil
        return state
    }

    private static func cursor(_ entry: IrohInventoryEntry) -> String {
        entry.domain.rawValue + "\0" + entry.id
    }

    private static func inventoryPrecedes(_ lhs: IrohInventoryEntry, _ rhs: IrohInventoryEntry) -> Bool {
        referencePrecedes(lhs.reference, rhs.reference)
    }

    private static func referencePrecedes(
        _ lhs: IrohInventoryReference,
        _ rhs: IrohInventoryReference
    ) -> Bool {
        if lhs.domain != rhs.domain {
            return IrohProtocolV1.utf8Precedes(lhs.domain.rawValue, rhs.domain.rawValue)
        }
        return IrohProtocolV1.utf8Precedes(lhs.id, rhs.id)
    }

    static func referencePrecedesForProtocol(
        _ lhs: IrohInventoryReference,
        _ rhs: IrohInventoryReference
    ) -> Bool {
        referencePrecedes(lhs, rhs)
    }

    static func resetDefaultStorage() throws {
        let url = defaultFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Pomodorough", isDirectory: true)
            .appendingPathComponent("iroh-rooms-v1.json")
    }
}
