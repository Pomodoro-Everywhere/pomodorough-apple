import Foundation

extension PersistedTimerState {
    mutating func prepare(for authenticatedUser: User) {
        if let previousUser = cachedUser, previousUser.id != authenticatedUser.id {
            let existingDeviceID = deviceId
            let existingSelectedPhase = settings.selectedPhase
            let existingHLC = (hlcWallMs, hlcCounter)
            let existingClock = trustedClockState
            let existingLastUuidV7 = lastUuidV7
            self = .fresh()
            deviceId = existingDeviceID
            settings.selectedPhase = existingSelectedPhase
            hlcWallMs = existingHLC.0
            hlcCounter = existingHLC.1
            trustedClockState = existingClock
            lastUuidV7 = existingLastUuidV7
        }
        cachedUser = authenticatedUser
        pendingAccountSwitchUser = nil
        bootstrapUser = nil
        pendingBootstrapResolution = nil
    }
}

extension PersistedTimerState {
    mutating func migrateLegacyTasks(_ legacy: LocalTaskState, at date: Date = .now) throws {
        _ = try PersistedLegacyMigration.migrateTasks(legacy, state: &self, at: date)
    }

    mutating func migrateLegacyDurationSettings() {
        _ = PersistedLegacyMigration.migrateDurationSettings(state: &self)
    }

    @discardableResult
    mutating func migrateLegacyAutoStartBreaks(
        explicitlySet: Bool = false,
        at date: Date = .now
    ) throws -> Bool {
        try PersistedLegacyMigration.migrateAutoStartBreaks(
            explicitlySet: explicitlySet,
            state: &self,
            at: date
        ).didMigrate
    }

    @discardableResult
    mutating func migrateLegacySelectedTask(at date: Date = .now) throws -> Bool {
        try PersistedLegacyMigration.migrateSelectedTask(state: &self, at: date).didMigrate
    }

    @discardableResult
    mutating func migrateLegacyTimerOwnership() -> Bool {
        PersistedLegacyMigration.migrateTimerOwnership(state: &self).didMigrate
    }

    mutating func applyDurationSync(
        canonicalDurations: DurationValues,
        sentOperations: [DurationOperation],
        acknowledgements: [DurationAcknowledgement]
    ) throws {
        let result = try PersistedQueueReconciliation.reconcileDurations(
            canonical: canonicalDurations,
            pending: pendingDurationOperations,
            sent: sentOperations,
            acknowledgements: acknowledgements
        )
        pendingDurationOperations = result.pendingOperations
        settings.durationsMs = result.durations
    }

    mutating func applyAutoStartSync(
        canonicalValue: Bool,
        sentOperations: [AutoStartOperation],
        acknowledgements: [AutoStartAcknowledgement]
    ) throws {
        let result = try PersistedQueueReconciliation.reconcileAutoStart(
            canonical: canonicalValue,
            deviceID: deviceId,
            pending: pendingAutoStartOperations,
            sent: sentOperations,
            acknowledgements: acknowledgements
        )
        pendingAutoStartOperations = result.pendingOperations
        autoStartBreaks = result.value
    }

    mutating func applySelectedTaskSync(
        canonicalTaskId: String?,
        canonicalTasks: [FocusTask],
        sentOperations: [SelectedTaskOperation],
        acknowledgements: [SelectedTaskAcknowledgement]
    ) throws {
        let result = try PersistedQueueReconciliation.reconcileSelectedTask(
            canonicalTaskID: canonicalTaskId,
            canonicalTasks: canonicalTasks,
            deviceID: deviceId,
            pending: pendingSelectedTaskOperations,
            sent: sentOperations,
            acknowledgements: acknowledgements
        )
        pendingSelectedTaskOperations = result.pendingOperations
        selectedTaskID = result.selectedTaskID
    }

}

extension PersistedTimerState {
    var hasValidGeneratorState: Bool {
        hasValidGeneratorCore && trustedClockState.hasValidSamplePersistence
    }

    private var hasValidGeneratorCore: Bool {
        !deviceId.isEmpty
            && (1...WireBounds.maxSafeInteger).contains(nextSequence)
            && (!sequenceExhausted || nextSequence == WireBounds.maxSafeInteger)
            && WireBounds.containsUnsigned(revision)
            && trustedClockState.hasValidLastEmittedTime
            && ((hlcWallMs == 0 && hlcCounter == 0)
                || WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter))
            && localCommandDates.allSatisfy { entry in
                pendingCommands.contains(where: { $0.id == entry.key })
                    && WireBounds.physicalMilliseconds(for: entry.value) != nil
            }
    }

    var hasTrustedTimeSample: Bool {
        trustedClockState.hasSample
    }

    var hasValidPendingWireOperations: Bool {
        !hasCorruptPendingOperations
            && hasValidGeneratorState
            && pendingQueue.hasValidOperationsAndIdentity(deviceID: deviceId)
    }

    var hasValidPendingWireOperationsForResample: Bool {
        !hasCorruptPendingOperations
            && hasValidGeneratorCore
            && pendingQueue.hasValidOperationsAndIdentity(deviceID: deviceId)
    }

    mutating func reserveDeviceSequence() throws -> Int64 {
        guard hasValidGeneratorState, !sequenceExhausted else { throw AppError.invalidLocalClock }
        let sequence = nextSequence
        guard !pendingCommands.contains(where: { $0.deviceSequence == sequence }) else {
            throw AppError.invalidLocalClock
        }
        if sequence == WireBounds.maxSafeInteger {
            sequenceExhausted = true
        } else {
            nextSequence = sequence + 1
        }
        return sequence
    }

    mutating func reserveUuidV7(
        count: Int = 1,
        entropy: () throws -> [UInt8] = UUIDv7.secureEntropy
    ) throws -> [UUID] {
        let latestQueued = pendingQueue.queuedUUIDv7Payloads.max { UUIDv7.isLess($0, than: $1) }
        if let lastUuidV7 {
            _ = try UUIDv7.parts(of: lastUuidV7)
            if let latestQueued, UUIDv7.isLess(lastUuidV7, than: latestQueued) {
                throw AppError.invalidLocalClock
            }
        }
        let previous = lastUuidV7 ?? latestQueued
        let reserved = try UUIDv7.reserve(
            timestampMs: hlcWallMs,
            count: count,
            previous: previous,
            entropy: entropy
        )
        lastUuidV7 = reserved.last
        return reserved
    }

    func trustedOccurrenceDate(for localDate: Date, uptime: TimeInterval) throws -> Date {
        try trustedClockState.occurrenceTransition(for: localDate, uptime: uptime).trustedDate
    }

    func localProjection(of commands: [TimerCommand]) -> [TimerCommand] {
        PersistedQueueReconciliation.localProjection(of: commands, localDates: localCommandDates)
    }

    mutating func pruneLocalCommandDates() {
        localCommandDates = PersistedQueueReconciliation.retainedLocalCommandDates(
            localCommandDates,
            pendingCommands: pendingCommands
        )
    }

    func physicalDate(forTrustedDate date: Date) throws -> Date {
        try trustedClockState.physicalDate(forTrustedDate: date)
    }

    func physicalCanonicalTimer(_ timer: CanonicalTimer?) throws -> CanonicalTimer? {
        guard let timer else { return nil }
        return CanonicalTimer(
            id: timer.id,
            taskId: timer.taskId,
            phase: timer.phase,
            status: timer.status,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
            anchorAt: try physicalDate(forTrustedDate: timer.anchorAt),
            startedByDeviceId: timer.startedByDeviceId,
            lastIntent: timer.lastIntent
        )
    }

    mutating func advanceClock(at date: Date) throws {
        try advanceClock(at: date) { input in
            try SharedCore.bundled().tickHLC(input)
        }
    }

    mutating func advanceClock(
        at date: Date,
        tickingWith tick: (CoreHLCTickInput) throws -> CoreHLCTickOutput
    ) throws {
        guard hasValidPendingWireOperations,
              let nowMs = WireBounds.physicalMilliseconds(for: date) else {
            throw AppError.invalidLocalClock
        }
        let input = CoreHLCTickInput(
            local: CoreHLC(wallMs: hlcWallMs, counter: hlcCounter),
            remote: nil,
            physicalNowMs: nowMs
        )
        guard let nextClock = try? tick(input).validated(for: input),
              WireBounds.isWithinClockSkew(wallMs: nextClock.wallMs, occurredAt: date) else {
            throw AppError.invalidLocalClock
        }
        hlcWallMs = nextClock.wallMs
        hlcCounter = nextClock.counter
        trustedClockState = trustedClockState.recordingTrustedMilliseconds(nowMs)
    }

    mutating func mergeClock(
        serverWallMs: Int64,
        serverCounter: Int64,
        serverTime: Date,
        requestWall: Date,
        requestUptime: TimeInterval,
        responseUptime: TimeInterval
    ) throws {
        try mergeClock(
            serverWallMs: serverWallMs,
            serverCounter: serverCounter,
            serverTime: serverTime,
            requestWall: requestWall,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        ) { input in
            try SharedCore.bundled().headHLC(input)
        }
    }

    mutating func mergeClock(
        serverWallMs: Int64,
        serverCounter: Int64,
        serverTime: Date,
        requestWall: Date,
        requestUptime: TimeInterval,
        responseUptime: TimeInterval,
        headingWith head: (CoreHLCHeadInput) throws -> CoreHLC
    ) throws {
        let serverClock = CoreHLC(wallMs: serverWallMs, counter: serverCounter)
        let sample = try validatedClockSample(
            serverClock: serverClock,
            serverTime: serverTime,
            requestWall: requestWall,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        )
        let resample = try trustedClockState.resampled(
            serverTimeMs: sample.serverTimeMs,
            requestWallMs: sample.requestWallMs,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        )
        let local = WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: serverTime)
            ? CoreHLC(wallMs: hlcWallMs, counter: hlcCounter)
            : CoreHLC(wallMs: 0, counter: 0)
        let input = CoreHLCHeadInput(
            physicalNowMs: sample.serverTimeMs,
            observed: [local, serverClock]
        )
        guard let mergedClock = try? head(input).validatedHead(for: input),
              WireBounds.isWithinClockSkew(
                wallMs: mergedClock.wallMs,
                occurredAt: serverTime
              ) else {
            throw AppError.invalidResponse
        }
        trustedClockState = resample.state
        hlcWallMs = mergedClock.wallMs
        hlcCounter = mergedClock.counter
    }

    mutating func mergeKnownTasks(_ newTasks: [FocusTask]) {
        for task in newTasks {
            if let index = knownTasks.firstIndex(where: { $0.id == task.id }) {
                knownTasks[index] = task
            } else {
                knownTasks.append(task)
            }
        }
    }

    private var pendingQueue: PersistedPendingOperationQueue {
        PersistedPendingOperationQueue(state: self)
    }

    private func validatedClockSample(
        serverClock: CoreHLC,
        serverTime: Date,
        requestWall: Date,
        requestUptime: TimeInterval,
        responseUptime: TimeInterval
    ) throws -> (serverTimeMs: Int64, requestWallMs: Int64) {
        guard hasValidGeneratorCore,
              WireBounds.isValidClock(wallMs: serverClock.wallMs, counter: serverClock.counter),
              WireBounds.isWithinClockSkew(wallMs: serverClock.wallMs, occurredAt: serverTime),
              let serverTimeMs = WireBounds.physicalMilliseconds(for: serverTime),
              let requestWallMs = WireBounds.physicalMilliseconds(for: requestWall),
              requestUptime.isFinite,
              responseUptime.isFinite,
              requestUptime >= 0,
              responseUptime >= requestUptime else {
            throw AppError.invalidResponse
        }
        return (serverTimeMs, requestWallMs)
    }
}
