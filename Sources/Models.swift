import CryptoKit
import Foundation

enum WireBounds {
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991
    static let maxClockSkewMs: Int64 = 300_000
    static let maxServerTimeUncertaintyMs: Int64 = 30_000

    static func containsUnsigned(_ value: Int64) -> Bool {
        (0...maxSafeInteger).contains(value)
    }

    static func physicalMilliseconds(for date: Date) -> Int64? {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              let value = Int64(exactly: milliseconds.rounded(.towardZero)),
              (1...maxSafeInteger).contains(value) else { return nil }
        return value
    }

    static func date(milliseconds: Int64) -> Date? {
        guard (1...maxSafeInteger).contains(milliseconds) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    static func adding(milliseconds offset: Int64, to date: Date) -> Date? {
        guard (-maxSafeInteger...maxSafeInteger).contains(offset),
              let dateMs = physicalMilliseconds(for: date) else { return nil }
        let (result, overflow) = dateMs.addingReportingOverflow(offset)
        guard !overflow else { return nil }
        return self.date(milliseconds: result)
    }

    static func nonnegativeMilliseconds(for interval: TimeInterval) -> Int64? {
        let milliseconds = interval * 1_000
        guard milliseconds.isFinite,
              let value = Int64(exactly: milliseconds.rounded(.towardZero)),
              (0...maxSafeInteger).contains(value) else { return nil }
        return value
    }

    static func isValidClock(wallMs: Int64, counter: Int64, allowsLegacySentinel: Bool = false) -> Bool {
        if allowsLegacySentinel, wallMs == 0, counter == 0 { return true }
        return (1...maxSafeInteger).contains(wallMs) && containsUnsigned(counter)
    }

    static func isWithinClockSkew(wallMs: Int64, occurredAt: Date) -> Bool {
        guard let occurredAtMs = physicalMilliseconds(for: occurredAt) else { return false }
        let skew = wallMs >= occurredAtMs ? wallMs - occurredAtMs : occurredAtMs - wallMs
        return skew <= maxClockSkewMs
    }

    static func isLegacySentinel(wallMs: Int64, counter: Int64, occurredAt: Date) -> Bool {
        wallMs == 0 && counter == 0 && occurredAt == Date(timeIntervalSince1970: 0)
    }
}

enum UUIDv7 {
    static let maxTimestampMs: Int64 = 281_474_976_710_655
    static let maxRandomHigh: UInt16 = 0x0fff
    static let maxRandomLow: UInt64 = 0x3fff_ffff_ffff_ffff

    struct Parts: Equatable, Sendable {
        let timestampMs: Int64
        let randomHigh: UInt16
        let randomLow: UInt64
    }

    static func parts(of uuid: UUID) throws -> Parts {
        let bytes = bytes(of: uuid)
        guard bytes[6] >> 4 == 7, bytes[8] >> 6 == 2 else {
            throw AppError.invalidLocalClock
        }
        let timestampMs = bytes[0...5].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        guard (1...maxTimestampMs).contains(timestampMs) else {
            throw AppError.invalidLocalClock
        }
        let randomHigh = (UInt16(bytes[6] & 0x0f) << 8) | UInt16(bytes[7])
        let randomLow = bytes[8...15].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        } & maxRandomLow
        return Parts(
            timestampMs: timestampMs,
            randomHigh: randomHigh,
            randomLow: randomLow
        )
    }

    static func make(
        timestampMs: Int64,
        randomHigh: UInt16,
        randomLow: UInt64
    ) throws -> UUID {
        guard (1...maxTimestampMs).contains(timestampMs),
              randomHigh <= maxRandomHigh,
              randomLow <= maxRandomLow else {
            throw AppError.invalidLocalClock
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        var timestamp = UInt64(timestampMs)
        for index in (0...5).reversed() {
            bytes[index] = UInt8(timestamp & 0xff)
            timestamp >>= 8
        }
        bytes[6] = 0x70 | UInt8(randomHigh >> 8)
        bytes[7] = UInt8(randomHigh & 0xff)
        bytes[8] = 0x80 | UInt8((randomLow >> 56) & 0x3f)
        for index in 9...15 {
            bytes[index] = UInt8((randomLow >> UInt64((15 - index) * 8)) & 0xff)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func reserve(
        timestampMs: Int64,
        count: Int = 1,
        previous: UUID?,
        entropy: () throws -> [UInt8] = secureEntropy
    ) throws -> [UUID] {
        guard (1...maxTimestampMs).contains(timestampMs), count > 0 else {
            throw AppError.invalidLocalClock
        }
        if let previous {
            let previousParts = try parts(of: previous)
            if timestampMs <= previousParts.timestampMs {
                return try sequential(
                    timestampMs: previousParts.timestampMs,
                    count: count,
                    afterHigh: previousParts.randomHigh,
                    afterLow: previousParts.randomLow
                )
            }
        }
        for _ in 0..<16 {
            let random = try entropy()
            guard random.count == 10 else { throw AppError.invalidLocalClock }
            let randomHigh = (
                UInt16(random[0]) << 8 | UInt16(random[1])
            ) & maxRandomHigh
            let randomLow = random[2...9].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            } & maxRandomLow
            if let reserved = try? sequence(
                timestampMs: timestampMs,
                count: count,
                firstHigh: randomHigh,
                firstLow: randomLow
            ) {
                return reserved
            }
        }
        throw AppError.invalidLocalClock
    }

    static func payload(from identifier: String) -> UUID? {
        let prefixes = ["command-", "task-operation-", "duration-operation-"]
        let payload = prefixes.first(where: identifier.hasPrefix)
            .map { String(identifier.dropFirst($0.count)) } ?? identifier
        guard let uuid = UUID(uuidString: payload), (try? parts(of: uuid)) != nil else {
            return nil
        }
        return uuid
    }

    static func isLess(_ lhs: UUID, than rhs: UUID) -> Bool {
        bytes(of: lhs).lexicographicallyPrecedes(bytes(of: rhs))
    }

    private static func sequential(
        timestampMs: Int64,
        count: Int,
        afterHigh: UInt16,
        afterLow: UInt64
    ) throws -> [UUID] {
        var high = afterHigh
        var low = afterLow
        var result: [UUID] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            (high, low) = try increment(high: high, low: low)
            result.append(try make(
                timestampMs: timestampMs,
                randomHigh: high,
                randomLow: low
            ))
        }
        return result
    }

    private static func sequence(
        timestampMs: Int64,
        count: Int,
        firstHigh: UInt16,
        firstLow: UInt64
    ) throws -> [UUID] {
        var high = firstHigh
        var low = firstLow
        var result = [try make(
            timestampMs: timestampMs,
            randomHigh: high,
            randomLow: low
        )]
        result.reserveCapacity(count)
        for _ in 1..<count {
            (high, low) = try increment(high: high, low: low)
            result.append(try make(
                timestampMs: timestampMs,
                randomHigh: high,
                randomLow: low
            ))
        }
        return result
    }

    private static func increment(high: UInt16, low: UInt64) throws -> (UInt16, UInt64) {
        if low < maxRandomLow { return (high, low + 1) }
        guard high < maxRandomHigh else { throw AppError.invalidLocalClock }
        return (high + 1, 0)
    }

    static func secureEntropy() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<10).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        let value = uuid.uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15
        ]
    }
}

struct SSERevisionParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> Int64? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            guard eventName == nil || eventName == "message" || eventName == "revision" else { return nil }
            let data = dataLines.joined(separator: "\n")
            guard !data.isEmpty else { return nil }
            if let raw = Int64(data.trimmingCharacters(in: .whitespacesAndNewlines)) { return raw }
            return (try? JSONDecoder().decode(RevisionEnvelope.self, from: Data(data.utf8)))?.revision
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = Self.fieldValue(line, prefixLength: 6)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.fieldValue(line, prefixLength: 5))
        }
        return nil
    }

    private static func fieldValue(_ line: String, prefixLength: Int) -> String {
        var value = String(line.dropFirst(prefixLength))
        if value.first == " " { value.removeFirst() }
        return value
    }
}

struct RevisionHintCoalescer: Sendable {
    private var latestPendingRevision: Int64?

    mutating func receive(_ revision: Int64, localRevision: Int64, isSyncing: Bool) -> Bool {
        guard revision > localRevision else { return false }
        guard isSyncing else { return true }
        latestPendingRevision = max(latestPendingRevision ?? revision, revision)
        return false
    }

    mutating func consumeFollowUp(localRevision: Int64) -> Bool {
        defer { latestPendingRevision = nil }
        return latestPendingRevision.map { $0 > localRevision } ?? false
    }
}

struct RevisionStreamLifecycle: Sendable {
    private(set) var isActive = false
    private var currentID: UUID?

    mutating func setActive(_ active: Bool) {
        isActive = active
        if !active { currentID = nil }
    }

    mutating func begin() -> UUID? {
        guard isActive, currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func owns(_ id: UUID?) -> Bool {
        isActive && id != nil && currentID == id
    }

    mutating func end(_ id: UUID) {
        if currentID == id { currentID = nil }
    }

    mutating func cancelCurrent() {
        currentID = nil
    }
}

struct SessionVerification: Sendable {
    private var generation: Int?

    mutating func markVerified(generation: Int) {
        self.generation = generation
    }

    mutating func invalidate() {
        generation = nil
    }

    func allows(generation: Int) -> Bool {
        self.generation == generation
    }
}

struct SyncOwnership: Sendable {
    private var ownerID: UUID?
    private var requestedGeneration: Int?

    mutating func begin(generation: Int) -> UUID? {
        guard ownerID == nil else {
            requestedGeneration = max(requestedGeneration ?? generation, generation)
            return nil
        }
        let id = UUID()
        ownerID = id
        return id
    }

    mutating func invalidate() {
        ownerID = nil
        requestedGeneration = nil
    }

    mutating func finish(_ id: UUID, currentGeneration: Int) -> Bool? {
        guard ownerID == id else { return nil }
        ownerID = nil
        defer { requestedGeneration = nil }
        return requestedGeneration == currentGeneration
    }

    func isOwned(by id: UUID?) -> Bool {
        id != nil && ownerID == id
    }
}

enum RemotePolling {
    static func interval(isTimerActive: Bool) -> TimeInterval {
        isTimerActive ? 2 : 5
    }
}

enum RevisionStreamResponse {
    static func isValid(statusCode: Int, contentType: String?) -> Bool {
        guard statusCode == 200, let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType.caseInsensitiveCompare("text/event-stream") == .orderedSame
    }
}

private struct RevisionEnvelope: Decodable {
    let revision: Int64
}

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let name: String
    let avatarUrl: String
}

struct MeResponse: Codable, Sendable {
    let user: User
    let csrfToken: String
}

struct NativeChallenge: Codable, Sendable {
    let challenge: String
    let nonce: String
    let expiresAt: Date
}

struct TokenPair: Codable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String
    let refreshTokenExpiresAt: Date
}

struct NativeExchangeRequest: Encodable, Sendable {
    let idToken: String
    let challenge: String
    let deviceId: String
    let platform: String
}

struct RefreshRequest: Encodable, Sendable { let refreshToken: String }

enum TimerPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus
    case shortBreak = "short_break"
    case longBreak = "long_break"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var routeLabel: String {
        switch self {
        case .focus: "Work"
        case .shortBreak: "Reset"
        case .longBreak: "Recover"
        }
    }

    var abbreviation: String {
        switch self {
        case .focus: "F"
        case .shortBreak: "SB"
        case .longBreak: "LB"
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .focus: 25
        case .shortBreak: 5
        case .longBreak: 15
        }
    }
}

struct DurationValues: Codable, Equatable, Sendable {
    static let wireUnitMs: Int64 = 60_000
    static let validRange: ClosedRange<Int64> = 60_000...10_800_000
    static let defaults = Self(
        focus: Int64(TimerPhase.focus.defaultMinutes) * 60_000,
        shortBreak: Int64(TimerPhase.shortBreak.defaultMinutes) * 60_000,
        longBreak: Int64(TimerPhase.longBreak.defaultMinutes) * 60_000
    )

    var focus: Int64
    var shortBreak: Int64
    var longBreak: Int64

    var isValid: Bool {
        Self.isValidWireDuration(focus)
            && Self.isValidWireDuration(shortBreak)
            && Self.isValidWireDuration(longBreak)
    }

    static func isValidWireDuration(_ durationMs: Int64) -> Bool {
        validRange.contains(durationMs) && durationMs.isMultiple(of: wireUnitMs)
    }

    func durationMs(for phase: TimerPhase) -> Int64 {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }

    mutating func setDurationMs(_ durationMs: Int64, for phase: TimerPhase) {
        switch phase {
        case .focus: focus = durationMs
        case .shortBreak: shortBreak = durationMs
        case .longBreak: longBreak = durationMs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case focus
        case shortBreak = "short_break"
        case longBreak = "long_break"
    }
}

struct TimerSettings: Codable, Equatable, Sendable {
    var selectedPhase: TimerPhase = .focus
    var autoStartBreaks = false
    private var focusDurationMs = DurationValues.defaults.focus
    private var shortBreakDurationMs = DurationValues.defaults.shortBreak
    private var longBreakDurationMs = DurationValues.defaults.longBreak

    var focusMinutes: Int {
        get { minutes(for: .focus) }
        set { setMinutes(newValue, for: .focus) }
    }

    var shortBreakMinutes: Int {
        get { minutes(for: .shortBreak) }
        set { setMinutes(newValue, for: .shortBreak) }
    }

    var longBreakMinutes: Int {
        get { minutes(for: .longBreak) }
        set { setMinutes(newValue, for: .longBreak) }
    }

    init() {}

    func minutes(for phase: TimerPhase) -> Int {
        Int(durationMs(for: phase) / DurationValues.wireUnitMs)
    }

    func durationMs(for phase: TimerPhase) -> Int64 {
        durationsMs.durationMs(for: phase)
    }

    mutating func setMinutes(_ minutes: Int, for phase: TimerPhase) {
        let clamped = min(180, max(1, minutes))
        var durations = durationsMs
        durations.setDurationMs(Int64(clamped) * 60_000, for: phase)
        durationsMs = durations
    }

    var durationsMs: DurationValues {
        get {
            DurationValues(
                focus: focusDurationMs,
                shortBreak: shortBreakDurationMs,
                longBreak: longBreakDurationMs
            )
        }
        set {
            focusDurationMs = Self.normalizedDuration(newValue.focus)
            shortBreakDurationMs = Self.normalizedDuration(newValue.shortBreak)
            longBreakDurationMs = Self.normalizedDuration(newValue.longBreak)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPhase, autoStartBreaks
        case focusDurationMs, shortBreakDurationMs, longBreakDurationMs
        case focusMinutes, shortBreakMinutes, longBreakMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedPhase = try values.decodeIfPresent(TimerPhase.self, forKey: .selectedPhase) ?? .focus
        autoStartBreaks = try values.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? false
        focusDurationMs = Self.decodedDuration(
            from: values,
            durationKey: .focusDurationMs,
            legacyMinutesKey: .focusMinutes,
            defaultValue: DurationValues.defaults.focus
        )
        shortBreakDurationMs = Self.decodedDuration(
            from: values,
            durationKey: .shortBreakDurationMs,
            legacyMinutesKey: .shortBreakMinutes,
            defaultValue: DurationValues.defaults.shortBreak
        )
        longBreakDurationMs = Self.decodedDuration(
            from: values,
            durationKey: .longBreakDurationMs,
            legacyMinutesKey: .longBreakMinutes,
            defaultValue: DurationValues.defaults.longBreak
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(selectedPhase, forKey: .selectedPhase)
        try values.encode(autoStartBreaks, forKey: .autoStartBreaks)
        try values.encode(focusDurationMs, forKey: .focusDurationMs)
        try values.encode(shortBreakDurationMs, forKey: .shortBreakDurationMs)
        try values.encode(longBreakDurationMs, forKey: .longBreakDurationMs)
    }

    private static func decodedDuration(
        from values: KeyedDecodingContainer<CodingKeys>,
        durationKey: CodingKeys,
        legacyMinutesKey: CodingKeys,
        defaultValue: Int64
    ) -> Int64 {
        let duration = (try? values.decodeIfPresent(Int64.self, forKey: durationKey)) ?? nil
        let legacyMinutes = (try? values.decodeIfPresent(Int.self, forKey: legacyMinutesKey)) ?? nil
        if let duration {
            return normalizedDuration(duration)
        }
        if let legacyMinutes {
            return Int64(min(180, max(1, legacyMinutes))) * DurationValues.wireUnitMs
        }
        return defaultValue
    }

    private static func normalizedDuration(_ durationMs: Int64) -> Int64 {
        let clamped = min(DurationValues.validRange.upperBound, max(DurationValues.validRange.lowerBound, durationMs))
        return ((clamped + DurationValues.wireUnitMs / 2) / DurationValues.wireUnitMs) * DurationValues.wireUnitMs
    }
}

enum CommandType: String, Codable, Sendable {
    case start, pause, resume, finish, cancel, clear
}

struct TimerCommand: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let deviceSequence: Int64
    let timerId: String
    let taskId: String?
    let type: CommandType
    let phase: TimerPhase
    let plannedDurationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64
    let observedElapsedMs: Int64

    var isValid: Bool {
        !id.isEmpty
            && !timerId.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && (1...WireBounds.maxSafeInteger).contains(deviceSequence)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && (0...plannedDurationMs).contains(observedElapsedMs)
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter)
            && WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt)
    }
}

struct SyncRequest: Encodable, Sendable {
    let deviceId: String
    let lastRevision: Int64
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]?
    let selectedTaskOperations: [SelectedTaskOperation]

    init(
        deviceId: String,
        lastRevision: Int64,
        commands: [TimerCommand],
        taskOperations: [TaskOperation],
        durationOperations: [DurationOperation],
        autoStartOperations: [AutoStartOperation]?,
        selectedTaskOperations: [SelectedTaskOperation] = []
    ) {
        self.deviceId = deviceId
        self.lastRevision = lastRevision
        self.commands = commands
        self.taskOperations = taskOperations
        self.durationOperations = durationOperations
        self.autoStartOperations = autoStartOperations
        self.selectedTaskOperations = selectedTaskOperations
    }
}

enum BootstrapResolutionStrategy: String, Codable, Equatable, Sendable {
    case keepRemote = "keep_remote"
    case replaceRemote = "replace_remote"
    case merge

    var title: String {
        switch self {
        case .keepRemote: "Keep Remote"
        case .replaceRemote: "Keep Local"
        case .merge: "Keep Both"
        }
    }
}

struct BootstrapResolveRequest: Codable, Equatable, Sendable {
    let requestId: String
    let deviceId: String
    let expectedRevision: Int64
    let strategy: BootstrapResolutionStrategy
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartOperation]?
    let selectedTaskOperations: [SelectedTaskOperation]?

    init(
        requestId: String,
        deviceId: String,
        expectedRevision: Int64,
        strategy: BootstrapResolutionStrategy,
        commands: [TimerCommand],
        taskOperations: [TaskOperation],
        durationOperations: [DurationOperation],
        autoStartOperations: [AutoStartOperation]?,
        selectedTaskOperations: [SelectedTaskOperation]? = nil
    ) {
        self.requestId = requestId
        self.deviceId = deviceId
        self.expectedRevision = expectedRevision
        self.strategy = strategy
        self.commands = commands
        self.taskOperations = taskOperations
        self.durationOperations = durationOperations
        self.autoStartOperations = autoStartOperations
        self.selectedTaskOperations = selectedTaskOperations
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, deviceId, expectedRevision, strategy, commands, taskOperations
        case durationOperations, autoStartOperations, selectedTaskOperations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try values.decode(String.self, forKey: .requestId)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        expectedRevision = try values.decode(Int64.self, forKey: .expectedRevision)
        strategy = try values.decode(BootstrapResolutionStrategy.self, forKey: .strategy)
        commands = try values.decode([TimerCommand].self, forKey: .commands)
        taskOperations = try values.decode([TaskOperation].self, forKey: .taskOperations)
        durationOperations = try values.decode([DurationOperation].self, forKey: .durationOperations)
        autoStartOperations = try values.decodeIfPresent(
            [AutoStartOperation].self,
            forKey: .autoStartOperations
        )
        selectedTaskOperations = try values.decodeIfPresent(
            [SelectedTaskOperation].self,
            forKey: .selectedTaskOperations
        )
    }
}

struct Acknowledgement: Codable, Equatable, Sendable {
    let commandId: String
    let outcome: AcknowledgementOutcome
    let reason: String
}

enum TaskOperationType: String, Codable, Sendable {
    case upsert, delete
}

struct TaskOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let taskId: String
    let type: TaskOperationType
    let title: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !id.isEmpty
            && UUID(uuidString: taskId) != nil
            && ((type == .delete && title == nil)
                || (type == .upsert
                    && title.flatMap(FocusTask.init(title:))?.id == UUID(uuidString: taskId)))
            && WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter)
            && WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt)
    }
}

struct TaskAcknowledgement: Codable, Equatable, Sendable {
    let operationId: String
    let outcome: AcknowledgementOutcome
    let reason: String
}

struct DurationOperation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let phase: TimerPhase
    let durationMs: Int64
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !id.isEmpty
            && DurationValues.isValidWireDuration(durationMs)
            && WireBounds.isValidClock(
                wallMs: hlcWallMs,
                counter: hlcCounter,
                allowsLegacySentinel: true
            )
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(
                    wallMs: hlcWallMs,
                    counter: hlcCounter,
                    occurredAt: occurredAt
                )
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

struct DurationAcknowledgement: Codable, Equatable, Sendable {
    let operationId: String
    let outcome: AcknowledgementOutcome
    let reason: String
}

struct AutoStartOperation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceId: String
    let enabled: Bool
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !deviceId.isEmpty
            && WireBounds.isValidClock(
                wallMs: hlcWallMs,
                counter: hlcCounter,
                allowsLegacySentinel: true
            )
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(
                    wallMs: hlcWallMs,
                    counter: hlcCounter,
                    occurredAt: occurredAt
                )
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

enum AcknowledgementOutcome: String, Codable, Equatable, Sendable {
    case applied, ignored, rejected
}

struct AutoStartAcknowledgement: Codable, Equatable, Sendable {
    let operationId: UUID
    let outcome: AcknowledgementOutcome
    let reason: String
}

struct SelectedTaskOperation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceId: String
    let taskId: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    var isValid: Bool {
        !deviceId.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && WireBounds.isValidClock(
                wallMs: hlcWallMs,
                counter: hlcCounter,
                allowsLegacySentinel: true
            )
            && (hlcWallMs == 0
                ? WireBounds.isLegacySentinel(
                    wallMs: hlcWallMs,
                    counter: hlcCounter,
                    occurredAt: occurredAt
                )
                : WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: occurredAt))
    }
}

struct SelectedTaskAcknowledgement: Codable, Equatable, Sendable {
    let operationId: UUID
    let outcome: AcknowledgementOutcome
    let reason: String
}

struct ProvisionalBreak: Codable, Equatable, Sendable {
    let focusTimerId: String
    let finishCommandId: String
    let breakTimerId: String
    let startCommandId: String
}

enum AcknowledgementSet {
    static func exactlyMatches<ID: Hashable>(sent: [ID], acknowledged: [ID]) -> Bool {
        guard sent.count == acknowledged.count else { return false }
        let sentSet = Set(sent)
        let acknowledgedSet = Set(acknowledged)
        return sentSet.count == sent.count
            && acknowledgedSet.count == acknowledged.count
            && sentSet == acknowledgedSet
    }
}

struct TimerIntent: Codable, Equatable, Sendable {
    let type: CommandType
    let commandId: String
    let occurredAt: Date
    let deviceId: String?

    var isValid: Bool {
        !commandId.isEmpty
            && WireBounds.physicalMilliseconds(for: occurredAt) != nil
            && (deviceId == nil || deviceId?.isEmpty == false)
    }

}

struct CanonicalTimer: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, paused, completed, cancelled, superseded
    }

    let id: String
    let taskId: String?
    let phase: TimerPhase
    let status: Status
    let plannedDurationMs: Int64
    let elapsedAtAnchorMs: Int64
    let anchorAt: Date
    var startedByDeviceId: String? = nil
    let lastIntent: TimerIntent?

    var plannedDuration: TimeInterval { TimeInterval(plannedDurationMs) / 1_000 }

    var isValid: Bool {
        !id.isEmpty
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && (0...plannedDurationMs).contains(elapsedAtAnchorMs)
            && WireBounds.physicalMilliseconds(for: anchorAt) != nil
            && (startedByDeviceId == nil || startedByDeviceId?.isEmpty == false)
            && (lastIntent?.isValid ?? true)
    }

    func elapsed(at date: Date) -> TimeInterval {
        let anchored = TimeInterval(elapsedAtAnchorMs) / 1_000
        guard status == .running else { return min(plannedDuration, anchored) }
        return min(plannedDuration, anchored + max(0, date.timeIntervalSince(anchorAt)))
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, plannedDuration - elapsed(at: date))
    }
}

struct HistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let timerId: String
    let commandId: String?
    let taskId: String?
    let phase: TimerPhase
    let status: String
    let plannedDurationMs: Int64
    let completedAt: Date?
    let endedAt: Date?

    var date: Date? { completedAt ?? endedAt }
    var minutes: Int { max(1, Int((plannedDurationMs + 59_999) / 60_000)) }

    var isValid: Bool {
        let validTerminalDate: Bool
        switch status {
        case CanonicalTimer.Status.completed.rawValue:
            validTerminalDate = completedAt != nil
        case CanonicalTimer.Status.cancelled.rawValue,
             CanonicalTimer.Status.superseded.rawValue:
            validTerminalDate = completedAt == nil && endedAt != nil
        default:
            validTerminalDate = false
        }
        return !id.isEmpty
            && !timerId.isEmpty
            && (commandId == nil || commandId?.isEmpty == false)
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && validTerminalDate
            && date.flatMap(WireBounds.physicalMilliseconds(for:)) != nil
            && (endedAt == nil || endedAt.flatMap(WireBounds.physicalMilliseconds(for:)) != nil)
    }
}

struct FocusTask: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let title: String

    private enum CodingKeys: String, CodingKey { case id, title }

    init?(title rawTitle: String) {
        let title = Self.normalizedTitle(rawTitle)
        guard !title.isEmpty, Data(title.utf8).count <= 512 else { return nil }
        self.id = Self.deterministicID(for: title)
        self.title = title
    }

    var isValid: Bool {
        Self(title: title)?.id == id
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(title, forKey: .title)
    }

    static func normalizedTitle(_ title: String) -> String {
        let scalars = Array(title.precomposedStringWithCanonicalMapping.unicodeScalars)
        var lowerBound = 0
        var upperBound = scalars.count
        while lowerBound < upperBound, !isPrintable(scalars[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound, !isPrintable(scalars[upperBound - 1]) {
            upperBound -= 1
        }
        return scalars[lowerBound..<upperBound].reduce(into: "") { result, scalar in
            result.unicodeScalars.append(scalar)
        }
    }

    private static func deterministicID(for title: String) -> UUID {
        let digest = SHA256.hash(data: Data("pomodorough.task.v1\0\(title)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }
}

struct LocalTaskState: Codable, Equatable, Sendable {
    var tasks: [FocusTask]
    var selectedTaskID: UUID?
    var assignments: [String: FocusTask]

    static let empty = Self(tasks: [], selectedTaskID: nil, assignments: [:])
}

struct TaskDailySummary: Identifiable, Equatable, Sendable {
    let task: FocusTask
    let finishedPomodoros: Int
    let timeSpentMs: Int64

    var id: UUID { task.id }
}

struct CompletedFocusSummary: Identifiable, Equatable, Sendable {
    let id: String
    let taskTitle: String
    let completedPomodoros: Int
    let timeSpentMs: Int64
}

enum HistoryAnalytics {
    static func completedFocusSummaries(
        from history: [HistoryItem],
        taskIDForItem: (HistoryItem) -> String? = { $0.taskId },
        taskForItem: (HistoryItem) -> FocusTask?
    ) -> [CompletedFocusSummary] {
        var totals: [String: (title: String, count: Int, timeMs: Int64)] = [:]
        for item in history {
            guard item.phase == .focus, item.status == CanonicalTimer.Status.completed.rawValue else { continue }
            let task = taskForItem(item)
            let unresolvedTaskID = taskIDForItem(item)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = task?.id.uuidString.lowercased()
                ?? unresolvedTaskID.flatMap { $0.isEmpty ? nil : "task:\($0.lowercased())" }
                ?? "unassigned"
            let title = task?.title ?? (id == "unassigned" ? "Unassigned" : "Deleted task")
            let current = totals[id] ?? (title, 0, 0)
            totals[id] = (current.title, current.count + 1, current.timeMs + item.plannedDurationMs)
        }
        return totals.map { id, total in
            CompletedFocusSummary(
                id: id,
                taskTitle: total.title,
                completedPomodoros: total.count,
                timeSpentMs: total.timeMs
            )
        }
        .sorted {
            if $0.timeSpentMs != $1.timeSpentMs { return $0.timeSpentMs > $1.timeSpentMs }
            if $0.completedPomodoros != $1.completedPomodoros {
                return $0.completedPomodoros > $1.completedPomodoros
            }
            let titleOrder = $0.taskTitle.localizedCaseInsensitiveCompare($1.taskTitle)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

struct SyncResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let taskAcknowledgements: [TaskAcknowledgement]
    let durationAcknowledgements: [DurationAcknowledgement]
    let autoStartAcknowledgements: [AutoStartAcknowledgement]
    let selectedTaskAcknowledgements: [SelectedTaskAcknowledgement]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements, autoStartAcknowledgements
        case selectedTaskAcknowledgements, durationsMs, autoStartBreaks, selectedTaskId
        case revision, canonicalTimer
        case history, tasks, serverTime, serverHlcWallMs, serverHlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        acknowledgements = try values.decode([Acknowledgement].self, forKey: .acknowledgements)
        taskAcknowledgements = try values.decodeIfPresent([TaskAcknowledgement].self, forKey: .taskAcknowledgements) ?? []
        durationAcknowledgements = try values.decode([DurationAcknowledgement].self, forKey: .durationAcknowledgements)
        autoStartAcknowledgements = try values.decode([AutoStartAcknowledgement].self, forKey: .autoStartAcknowledgements)
        selectedTaskAcknowledgements = try values.decode(
            [SelectedTaskAcknowledgement].self,
            forKey: .selectedTaskAcknowledgements
        )
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        guard values.contains(.selectedTaskId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.selectedTaskId,
                .init(codingPath: values.codingPath, debugDescription: "Sync response requires selectedTaskId.")
            )
        }
        selectedTaskId = try values.decodeIfPresent(String.self, forKey: .selectedTaskId)
        revision = try values.decode(Int64.self, forKey: .revision)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decode([FocusTask].self, forKey: .tasks)
        serverTime = try values.decode(Date.self, forKey: .serverTime)
        serverHlcWallMs = try values.decode(Int64.self, forKey: .serverHlcWallMs)
        serverHlcCounter = try values.decode(Int64.self, forKey: .serverHlcCounter)
    }

    var hasValidCanonicalSnapshot: Bool {
        CanonicalSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs,
            selectedTaskId: selectedTaskId
        )
    }
}

struct BootstrapResponse: Decodable, Sendable {
    let acknowledgements: [Acknowledgement]
    let taskAcknowledgements: [TaskAcknowledgement]
    let durationAcknowledgements: [DurationAcknowledgement]
    let autoStartAcknowledgements: [AutoStartAcknowledgement]
    let selectedTaskAcknowledgements: [SelectedTaskAcknowledgement]
    let durationsMs: DurationValues
    let autoStartBreaks: Bool
    let selectedTaskId: String?
    let revision: Int64
    let canonicalTimer: CanonicalTimer?
    let history: [HistoryItem]
    let tasks: [FocusTask]
    let serverTime: Date
    let serverHlcWallMs: Int64
    let serverHlcCounter: Int64

    private enum CodingKeys: String, CodingKey {
        case acknowledgements, taskAcknowledgements, durationAcknowledgements, autoStartAcknowledgements
        case selectedTaskAcknowledgements, durationsMs, autoStartBreaks, selectedTaskId
        case revision, canonicalTimer
        case history, tasks, serverTime, serverHlcWallMs, serverHlcCounter
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.canonicalTimer), values.contains(.selectedTaskId) else {
            throw DecodingError.keyNotFound(
                values.contains(.canonicalTimer) ? CodingKeys.selectedTaskId : CodingKeys.canonicalTimer,
                DecodingError.Context(
                    codingPath: values.codingPath,
                    debugDescription: "Bootstrap response must include canonicalTimer and selectedTaskId."
                )
            )
        }
        acknowledgements = try values.decode([Acknowledgement].self, forKey: .acknowledgements)
        taskAcknowledgements = try values.decode([TaskAcknowledgement].self, forKey: .taskAcknowledgements)
        durationAcknowledgements = try values.decode([DurationAcknowledgement].self, forKey: .durationAcknowledgements)
        autoStartAcknowledgements = try values.decode([AutoStartAcknowledgement].self, forKey: .autoStartAcknowledgements)
        selectedTaskAcknowledgements = try values.decode(
            [SelectedTaskAcknowledgement].self,
            forKey: .selectedTaskAcknowledgements
        )
        durationsMs = try values.decode(DurationValues.self, forKey: .durationsMs)
        autoStartBreaks = try values.decode(Bool.self, forKey: .autoStartBreaks)
        selectedTaskId = try values.decodeIfPresent(String.self, forKey: .selectedTaskId)
        revision = try values.decode(Int64.self, forKey: .revision)
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decode([FocusTask].self, forKey: .tasks)
        serverTime = try values.decode(Date.self, forKey: .serverTime)
        serverHlcWallMs = try values.decode(Int64.self, forKey: .serverHlcWallMs)
        serverHlcCounter = try values.decode(Int64.self, forKey: .serverHlcCounter)
    }

    var hasValidCanonicalSnapshot: Bool {
        CanonicalSnapshotValidation.isValid(
            timer: canonicalTimer,
            history: history,
            tasks: tasks,
            durations: durationsMs,
            selectedTaskId: selectedTaskId
        )
    }
}

enum CanonicalSnapshotValidation {
    static func isValid(
        timer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        durations: DurationValues,
        selectedTaskId: String?
    ) -> Bool {
        durations.isValid
            && (timer?.isValid ?? true)
            && history.allSatisfy(\.isValid)
            && tasks.allSatisfy(\.isValid)
            && Set(history.map(\.id)).count == history.count
            && Set(history.map(\.timerId)).count == history.count
            && Set(tasks.map(\.id)).count == tasks.count
            && (selectedTaskId == nil || selectedTaskId.flatMap(UUID.init(uuidString:)).map { selected in
                tasks.contains { $0.id == selected }
            } == true)
    }
}

struct HistoryResponse: Decodable, Sendable { let history: [HistoryItem] }

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

struct PersistedTimerState: Codable, Equatable, Sendable {
    var deviceId: String
    var nextSequence: Int64
    var sequenceExhausted: Bool
    var revision: Int64
    var hlcWallMs: Int64
    var hlcCounter: Int64
    var serverTimeOffsetMs: Int64?
    var serverTimeUncertaintyMs: Int64?
    var serverTimeAnchorMs: Int64?
    var serverTimeAnchorUptime: TimeInterval?
    var lastTrustedTimeMs: Int64?
    var lastUuidV7: UUID?
    var pendingCommands: [TimerCommand]
    var localCommandDates: [String: Date]
    var pendingTaskOperations: [TaskOperation]
    var pendingDurationOperations: [DurationOperation]
    var pendingAutoStartOperations: [AutoStartOperation]
    var pendingSelectedTaskOperations: [SelectedTaskOperation]
    var autoStartBreaks: Bool
    var localTimerOwners: [String: String]
    var provisionalBreaks: [ProvisionalBreak]
    var canonicalTimer: CanonicalTimer?
    var history: [HistoryItem]
    var tasks: [FocusTask]
    var knownTasks: [FocusTask]
    var selectedTaskID: UUID?
    var legacyTaskAssignments: [String: UUID]
    var hasCorruptPendingOperations: Bool
    var settings: TimerSettings
    var cachedUser: User?
    var bootstrapUser: User?
    var pendingBootstrapResolution: BootstrapResolveRequest?

    static func fresh() -> Self {
        Self(
            deviceId: "device-\(UUID().uuidString.lowercased())",
            nextSequence: 1,
            sequenceExhausted: false,
            revision: 0,
            hlcWallMs: 0,
            hlcCounter: 0,
            serverTimeOffsetMs: nil,
            serverTimeUncertaintyMs: nil,
            serverTimeAnchorMs: nil,
            serverTimeAnchorUptime: nil,
            lastTrustedTimeMs: nil,
            lastUuidV7: nil,
            pendingCommands: [],
            localCommandDates: [:],
            pendingTaskOperations: [],
            pendingDurationOperations: [],
            pendingAutoStartOperations: [],
            pendingSelectedTaskOperations: [],
            autoStartBreaks: false,
            localTimerOwners: [:],
            provisionalBreaks: [],
            canonicalTimer: nil,
            history: [],
            tasks: [],
            knownTasks: [],
            selectedTaskID: nil,
            legacyTaskAssignments: [:],
            hasCorruptPendingOperations: false,
            settings: TimerSettings(),
            cachedUser: nil,
            bootstrapUser: nil,
            pendingBootstrapResolution: nil
        )
    }

    mutating func prepare(for authenticatedUser: User) {
        if let previousUser = cachedUser, previousUser.id != authenticatedUser.id {
            let existingDeviceID = deviceId
            let existingSelectedPhase = settings.selectedPhase
            let existingHLC = (hlcWallMs, hlcCounter)
            let existingServerTimeOffsetMs = serverTimeOffsetMs
            let existingServerTimeUncertaintyMs = serverTimeUncertaintyMs
            let existingServerTimeAnchorMs = serverTimeAnchorMs
            let existingServerTimeAnchorUptime = serverTimeAnchorUptime
            let existingLastTrustedTimeMs = lastTrustedTimeMs
            let existingLastUuidV7 = lastUuidV7
            self = .fresh()
            deviceId = existingDeviceID
            settings.selectedPhase = existingSelectedPhase
            hlcWallMs = existingHLC.0
            hlcCounter = existingHLC.1
            serverTimeOffsetMs = existingServerTimeOffsetMs
            serverTimeUncertaintyMs = existingServerTimeUncertaintyMs
            serverTimeAnchorMs = existingServerTimeAnchorMs
            serverTimeAnchorUptime = existingServerTimeAnchorUptime
            lastTrustedTimeMs = existingLastTrustedTimeMs
            lastUuidV7 = existingLastUuidV7
        }
        cachedUser = authenticatedUser
        bootstrapUser = nil
        pendingBootstrapResolution = nil
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, nextSequence, sequenceExhausted, revision, hlcWallMs, hlcCounter
        case serverTimeOffsetMs, serverTimeUncertaintyMs, serverTimeAnchorMs
        case serverTimeAnchorUptime, lastTrustedTimeMs, lastUuidV7, localCommandDates
        case pendingCommands, pendingTaskOperations, pendingDurationOperations, pendingAutoStartOperations
        case pendingSelectedTaskOperations
        case autoStartBreaks, localTimerOwners, provisionalBreaks, canonicalTimer, history
        case tasks, knownTasks, selectedTaskID, legacyTaskAssignments, hasCorruptPendingOperations
        case settings, cachedUser
        case bootstrapUser, pendingBootstrapResolution
    }

    init(
        deviceId: String,
        nextSequence: Int64,
        sequenceExhausted: Bool = false,
        revision: Int64,
        hlcWallMs: Int64,
        hlcCounter: Int64,
        serverTimeOffsetMs: Int64? = nil,
        serverTimeUncertaintyMs: Int64? = nil,
        serverTimeAnchorMs: Int64? = nil,
        serverTimeAnchorUptime: TimeInterval? = nil,
        lastTrustedTimeMs: Int64? = nil,
        lastUuidV7: UUID? = nil,
        pendingCommands: [TimerCommand],
        localCommandDates: [String: Date] = [:],
        pendingTaskOperations: [TaskOperation],
        pendingDurationOperations: [DurationOperation],
        pendingAutoStartOperations: [AutoStartOperation],
        pendingSelectedTaskOperations: [SelectedTaskOperation] = [],
        autoStartBreaks: Bool,
        localTimerOwners: [String: String],
        provisionalBreaks: [ProvisionalBreak],
        canonicalTimer: CanonicalTimer?,
        history: [HistoryItem],
        tasks: [FocusTask],
        knownTasks: [FocusTask],
        selectedTaskID: UUID?,
        legacyTaskAssignments: [String: UUID],
        hasCorruptPendingOperations: Bool = false,
        settings: TimerSettings,
        cachedUser: User?,
        bootstrapUser: User?,
        pendingBootstrapResolution: BootstrapResolveRequest?
    ) {
        self.deviceId = deviceId
        self.nextSequence = nextSequence
        self.sequenceExhausted = sequenceExhausted
        self.revision = revision
        self.hlcWallMs = hlcWallMs
        self.hlcCounter = hlcCounter
        self.serverTimeOffsetMs = serverTimeOffsetMs
        self.serverTimeUncertaintyMs = serverTimeUncertaintyMs
        self.serverTimeAnchorMs = serverTimeAnchorMs
        self.serverTimeAnchorUptime = serverTimeAnchorUptime
        self.lastTrustedTimeMs = lastTrustedTimeMs
        self.lastUuidV7 = lastUuidV7
        self.pendingCommands = pendingCommands
        self.localCommandDates = localCommandDates
        self.pendingTaskOperations = pendingTaskOperations
        self.pendingDurationOperations = pendingDurationOperations
        self.pendingAutoStartOperations = pendingAutoStartOperations
        self.pendingSelectedTaskOperations = pendingSelectedTaskOperations
        self.autoStartBreaks = autoStartBreaks
        self.localTimerOwners = localTimerOwners
        self.provisionalBreaks = provisionalBreaks
        self.canonicalTimer = canonicalTimer
        self.history = history
        self.tasks = tasks
        self.knownTasks = knownTasks
        self.selectedTaskID = selectedTaskID
        self.legacyTaskAssignments = legacyTaskAssignments
        self.hasCorruptPendingOperations = hasCorruptPendingOperations
        self.settings = settings
        self.cachedUser = cachedUser
        self.bootstrapUser = bootstrapUser
        self.pendingBootstrapResolution = pendingBootstrapResolution
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        nextSequence = try values.decode(Int64.self, forKey: .nextSequence)
        sequenceExhausted = try values.decodeIfPresent(Bool.self, forKey: .sequenceExhausted) ?? false
        revision = try values.decode(Int64.self, forKey: .revision)
        hlcWallMs = try values.decodeIfPresent(Int64.self, forKey: .hlcWallMs) ?? 0
        hlcCounter = try values.decodeIfPresent(Int64.self, forKey: .hlcCounter) ?? 0
        let decodedServerTimeOffsetMs = try values.decodeIfPresent(Int64.self, forKey: .serverTimeOffsetMs)
        let decodedServerTimeUncertaintyMs = try values.decodeIfPresent(
            Int64.self,
            forKey: .serverTimeUncertaintyMs
        )
        serverTimeOffsetMs = decodedServerTimeOffsetMs
        serverTimeUncertaintyMs = decodedServerTimeUncertaintyMs
        serverTimeAnchorMs = try values.decodeIfPresent(Int64.self, forKey: .serverTimeAnchorMs)
        serverTimeAnchorUptime = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .serverTimeAnchorUptime
        )
        lastTrustedTimeMs = try values.decodeIfPresent(Int64.self, forKey: .lastTrustedTimeMs)
        lastUuidV7 = try values.decodeIfPresent(UUID.self, forKey: .lastUuidV7)
        pendingCommands = try values.decode([TimerCommand].self, forKey: .pendingCommands)
        localCommandDates = try values.decodeIfPresent([String: Date].self, forKey: .localCommandDates) ?? [:]
        pendingTaskOperations = try values.decodeIfPresent([TaskOperation].self, forKey: .pendingTaskOperations) ?? []
        pendingDurationOperations = try values.decodeIfPresent(
            [DurationOperation].self,
            forKey: .pendingDurationOperations
        )?.map(Self.normalizedLegacySentinel) ?? []
        let decodedAutoStartOperations = try values.decodeIfPresent(
            [LossyDecodable<AutoStartOperation>].self,
            forKey: .pendingAutoStartOperations
        ) ?? []
        pendingAutoStartOperations = decodedAutoStartOperations.compactMap(\.value)
            .map(Self.normalizedLegacySentinel)
        let decodedSelectedTaskOperations = try values.decodeIfPresent(
            [LossyDecodable<SelectedTaskOperation>].self,
            forKey: .pendingSelectedTaskOperations
        ) ?? []
        pendingSelectedTaskOperations = decodedSelectedTaskOperations.compactMap(\.value)
            .map(Self.normalizedLegacySentinel)
        let persistedCorruptPendingOperations = try values.decodeIfPresent(
            Bool.self,
            forKey: .hasCorruptPendingOperations
        ) ?? false
        hasCorruptPendingOperations = persistedCorruptPendingOperations
            || decodedAutoStartOperations.contains { $0.value == nil }
            || decodedSelectedTaskOperations.contains { $0.value == nil }
        autoStartBreaks = try values.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? false
        localTimerOwners = try values.decodeIfPresent([String: String].self, forKey: .localTimerOwners) ?? [:]
        provisionalBreaks = try values.decodeIfPresent(
            [ProvisionalBreak].self,
            forKey: .provisionalBreaks
        ) ?? []
        canonicalTimer = try values.decodeIfPresent(CanonicalTimer.self, forKey: .canonicalTimer)
        history = try values.decode([HistoryItem].self, forKey: .history)
        tasks = try values.decodeIfPresent([FocusTask].self, forKey: .tasks) ?? []
        knownTasks = try values.decodeIfPresent([FocusTask].self, forKey: .knownTasks) ?? tasks
        selectedTaskID = try values.decodeIfPresent(UUID.self, forKey: .selectedTaskID)
        legacyTaskAssignments = try values.decodeIfPresent([String: UUID].self, forKey: .legacyTaskAssignments) ?? [:]
        settings = try values.decodeIfPresent(TimerSettings.self, forKey: .settings) ?? TimerSettings()
        cachedUser = try values.decodeIfPresent(User.self, forKey: .cachedUser)
        bootstrapUser = try values.decodeIfPresent(User.self, forKey: .bootstrapUser)
        pendingBootstrapResolution = try values.decodeIfPresent(
            BootstrapResolveRequest.self,
            forKey: .pendingBootstrapResolution
        ).map(Self.normalizedLegacySentinels)
    }

    mutating func migrateLegacyTasks(_ legacy: LocalTaskState, at date: Date = .now) throws {
        mergeKnownTasks(legacy.tasks + Array(legacy.assignments.values))
        legacyTaskAssignments.merge(legacy.assignments.mapValues(\.id)) { _, migrated in migrated }
        for task in legacy.tasks where !tasks.contains(where: { $0.id == task.id }) {
            tasks.append(task)
        }
        if let selected = legacy.selectedTaskID,
           tasks.contains(where: { $0.id == selected }) {
            selectedTaskID = selected
        }

        pendingCommands = pendingCommands.map { command in
            guard command.taskId == nil,
                  command.type == .start,
                  let task = legacy.assignments[command.timerId] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: task.id.uuidString.lowercased(),
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: command.occurredAt,
                hlcWallMs: command.hlcWallMs,
                hlcCounter: command.hlcCounter,
                observedElapsedMs: command.observedElapsedMs
            )
        }
        if let timer = canonicalTimer,
           timer.taskId == nil,
           let task = legacy.assignments[timer.id] {
            canonicalTimer = CanonicalTimer(
                id: timer.id,
                taskId: task.id.uuidString.lowercased(),
                phase: timer.phase,
                status: timer.status,
                plannedDurationMs: timer.plannedDurationMs,
                elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                anchorAt: timer.anchorAt,
                startedByDeviceId: timer.startedByDeviceId,
                lastIntent: timer.lastIntent
            )
        }
        history = history.map { item in
            guard item.taskId == nil,
                  let task = legacy.assignments[item.timerId] else { return item }
            return HistoryItem(
                id: item.id,
                timerId: item.timerId,
                commandId: item.commandId,
                taskId: task.id.uuidString.lowercased(),
                phase: item.phase,
                status: item.status,
                plannedDurationMs: item.plannedDurationMs,
                completedAt: item.completedAt,
                endedAt: item.endedAt
            )
        }

        for task in legacy.tasks where !pendingTaskOperations.contains(where: {
            $0.type == .upsert && UUID(uuidString: $0.taskId) == task.id
        }) {
            try advanceClock(at: date)
            let operationID = try reserveUuidV7()[0]
            pendingTaskOperations.append(TaskOperation(
                id: "task-operation-\(operationID.uuidString.lowercased())",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: date,
                hlcWallMs: hlcWallMs,
                hlcCounter: hlcCounter
            ))
        }
    }

    mutating func migrateLegacyDurationSettings() {
        for phase in TimerPhase.allCases {
            let durationMs = settings.durationMs(for: phase)
            guard durationMs != DurationValues.defaults.durationMs(for: phase) else { continue }
            pendingDurationOperations.append(DurationOperation(
                id: "duration-operation-\(UUID().uuidString.lowercased())",
                phase: phase,
                durationMs: durationMs,
                occurredAt: Date(timeIntervalSince1970: 0),
                hlcWallMs: 0,
                hlcCounter: 0
            ))
        }
    }

    @discardableResult
    mutating func migrateLegacyAutoStartBreaks(
        explicitlySet: Bool = false,
        at date: Date = .now
    ) throws -> Bool {
        guard settings.autoStartBreaks || explicitlySet else { return false }
        try advanceClock(at: date)
        pendingAutoStartOperations.append(AutoStartOperation(
            id: UUID(),
            deviceId: deviceId,
            enabled: settings.autoStartBreaks,
            occurredAt: date,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        ))
        return true
    }

    @discardableResult
    mutating func migrateLegacySelectedTask(at date: Date = .now) throws -> Bool {
        guard let selectedTaskID,
              TaskReducer.applying(pendingTaskOperations, to: tasks)
                .contains(where: { $0.id == selectedTaskID }) else { return false }
        try advanceClock(at: date)
        pendingSelectedTaskOperations.append(SelectedTaskOperation(
            id: try reserveUuidV7()[0],
            deviceId: deviceId,
            taskId: selectedTaskID.uuidString.lowercased(),
            occurredAt: date,
            hlcWallMs: hlcWallMs,
            hlcCounter: hlcCounter
        ))
        return true
    }

    @discardableResult
    mutating func migrateLegacyTimerOwnership() -> Bool {
        guard let timer = canonicalTimer,
              timer.status == .running || timer.status == .paused,
              localTimerOwners[timer.id] == nil,
              !pendingCommands.contains(where: {
                  $0.type == .start && $0.timerId == timer.id
              }) else { return false }
        let owner = timer.startedByDeviceId ?? {
            guard let intent = timer.lastIntent, intent.type == .start else { return nil }
            return intent.deviceId
        }()
        guard owner == deviceId else { return false }
        localTimerOwners[timer.id] = deviceId
        return true
    }

    mutating func applyDurationSync(
        canonicalDurations: DurationValues,
        sentOperations: [DurationOperation],
        acknowledgements: [DurationAcknowledgement]
    ) throws {
        let sentOperationIDs = sentOperations.map(\.id)
        let acknowledgedOperationIDs = acknowledgements.map(\.operationId)
        guard canonicalDurations.isValid,
              sentOperations.allSatisfy(\.isValid),
              AcknowledgementSet.exactlyMatches(
                sent: sentOperationIDs,
                acknowledged: acknowledgedOperationIDs
              ) else {
            throw AppError.invalidResponse
        }
        let sentIDSet = Set(sentOperationIDs)
        let acknowledgedIDSet = Set(acknowledgedOperationIDs)
        pendingDurationOperations.removeAll {
            sentIDSet.contains($0.id) && acknowledgedIDSet.contains($0.id)
        }
        settings.durationsMs = DurationReducer.applying(
            pendingDurationOperations,
            to: canonicalDurations
        )
    }

    mutating func applyAutoStartSync(
        canonicalValue: Bool,
        sentOperations: [AutoStartOperation],
        acknowledgements: [AutoStartAcknowledgement]
    ) throws {
        let sentOperationIDs = sentOperations.map(\.id)
        let acknowledgedOperationIDs = acknowledgements.map(\.operationId)
        guard sentOperations.allSatisfy({ $0.isValid && $0.deviceId == deviceId }),
              AcknowledgementSet.exactlyMatches(
                sent: sentOperationIDs,
                acknowledged: acknowledgedOperationIDs
              ) else {
            throw AppError.invalidResponse
        }
        let acknowledgedIDSet = Set(acknowledgedOperationIDs)
        pendingAutoStartOperations.removeAll { acknowledgedIDSet.contains($0.id) }
        autoStartBreaks = canonicalValue
    }

    mutating func applySelectedTaskSync(
        canonicalTaskId: String?,
        canonicalTasks: [FocusTask],
        sentOperations: [SelectedTaskOperation],
        acknowledgements: [SelectedTaskAcknowledgement]
    ) throws {
        let canonicalTaskID = canonicalTaskId.flatMap(UUID.init(uuidString:))
        let sentOperationIDs = sentOperations.map(\.id)
        let acknowledgedOperationIDs = acknowledgements.map(\.operationId)
        guard canonicalTaskId == nil || canonicalTaskID.map({ selected in
            canonicalTasks.contains { $0.id == selected }
        }) == true,
              sentOperations.allSatisfy({ $0.isValid && $0.deviceId == deviceId }),
              AcknowledgementSet.exactlyMatches(
                sent: sentOperationIDs,
                acknowledged: acknowledgedOperationIDs
              ) else {
            throw AppError.invalidResponse
        }
        let acknowledgedIDSet = Set(acknowledgedOperationIDs)
        pendingSelectedTaskOperations.removeAll { acknowledgedIDSet.contains($0.id) }
        selectedTaskID = SelectedTaskReducer.applying(
            pendingSelectedTaskOperations,
            to: canonicalTaskID
        )
    }

    mutating func rebasePendingOperations(
        afterServerWallMs serverWallMs: Int64,
        serverCounter: Int64,
        serverTime: Date
    ) throws {
        var updated = self
        try updated.rebasePendingOperationsInPlace(
            afterServerWallMs: serverWallMs,
            serverCounter: serverCounter,
            serverTime: serverTime
        )
        self = updated
    }

    private mutating func rebasePendingOperationsInPlace(
        afterServerWallMs serverWallMs: Int64,
        serverCounter: Int64,
        serverTime: Date
    ) throws {
        guard let serverTimeMs = WireBounds.physicalMilliseconds(for: serverTime),
              WireBounds.isValidClock(wallMs: serverWallMs, counter: serverCounter),
              WireBounds.isWithinClockSkew(wallMs: serverWallMs, occurredAt: serverTime) else {
            throw AppError.invalidResponse
        }
        let minimumMs = max(1, serverTimeMs - WireBounds.maxClockSkewMs)
        let maximumMs = min(
            WireBounds.maxSafeInteger,
            serverTimeMs + WireBounds.maxClockSkewMs
        )
        let canonicalClock = (wallMs: serverWallMs, counter: serverCounter)
        func nextClock(after clock: (wallMs: Int64, counter: Int64)) throws
            -> (wallMs: Int64, counter: Int64) {
            if clock.counter < WireBounds.maxSafeInteger {
                return (clock.wallMs, clock.counter + 1)
            }
            guard clock.wallMs < maximumMs else { throw AppError.invalidResponse }
            return (clock.wallMs + 1, 0)
        }

        func replacements(
            for operations: [(id: String, wallMs: Int64, counter: Int64)]
        ) throws -> [String: (wallMs: Int64, counter: Int64)] {
            var cursor = canonicalClock
            var result: [String: (wallMs: Int64, counter: Int64)] = [:]
            for operation in operations where operation.wallMs > 0 {
                let clock = (wallMs: operation.wallMs, counter: operation.counter)
                if (minimumMs...maximumMs).contains(clock.wallMs), clock > cursor {
                    cursor = clock
                } else {
                    cursor = try nextClock(after: cursor)
                    result[operation.id] = cursor
                }
            }
            return result
        }

        func rebasedDate(
            _ original: Date,
            clock: (wallMs: Int64, counter: Int64)
        ) throws -> Date {
            if let originalMs = WireBounds.physicalMilliseconds(for: original),
               (minimumMs...maximumMs).contains(originalMs),
               abs(clock.wallMs - originalMs) <= WireBounds.maxClockSkewMs {
                return original
            }
            guard let date = WireBounds.date(milliseconds: clock.wallMs) else {
                throw AppError.invalidResponse
            }
            return date
        }

        let commandReplacements = try replacements(for: pendingCommands.sorted {
            if $0.deviceSequence != $1.deviceSequence {
                return $0.deviceSequence < $1.deviceSequence
            }
            return $0.id < $1.id
        }.map { ($0.id, $0.hlcWallMs, $0.hlcCounter) })
        pendingCommands = try pendingCommands.map { command in
            guard let clock = commandReplacements[command.id] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: command.taskId,
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: try rebasedDate(command.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter,
                observedElapsedMs: command.observedElapsedMs
            )
        }

        let taskReplacements = try replacements(for: pendingTaskOperations.sorted {
            ($0.hlcWallMs, $0.hlcCounter, $0.id)
                < ($1.hlcWallMs, $1.hlcCounter, $1.id)
        }.map { ($0.id, $0.hlcWallMs, $0.hlcCounter) })
        pendingTaskOperations = try pendingTaskOperations.map { operation in
            guard let clock = taskReplacements[operation.id] else { return operation }
            return TaskOperation(
                id: operation.id,
                taskId: operation.taskId,
                type: operation.type,
                title: operation.title,
                occurredAt: try rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }

        let durationReplacements = try replacements(for: pendingDurationOperations.sorted {
            ($0.hlcWallMs, $0.hlcCounter, $0.id)
                < ($1.hlcWallMs, $1.hlcCounter, $1.id)
        }.map { ($0.id, $0.hlcWallMs, $0.hlcCounter) })
        pendingDurationOperations = try pendingDurationOperations.map { operation in
            guard let clock = durationReplacements[operation.id] else { return operation }
            return DurationOperation(
                id: operation.id,
                phase: operation.phase,
                durationMs: operation.durationMs,
                occurredAt: try rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }

        let autoStartReplacements = try replacements(for: pendingAutoStartOperations.sorted {
            ($0.hlcWallMs, $0.hlcCounter, $0.id.uuidString)
                < ($1.hlcWallMs, $1.hlcCounter, $1.id.uuidString)
        }.map { ($0.id.uuidString, $0.hlcWallMs, $0.hlcCounter) })
        pendingAutoStartOperations = try pendingAutoStartOperations.map { operation in
            guard let clock = autoStartReplacements[operation.id.uuidString] else {
                return operation
            }
            return AutoStartOperation(
                id: operation.id,
                deviceId: operation.deviceId,
                enabled: operation.enabled,
                occurredAt: try rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }

        let selectedTaskReplacements = try replacements(for: pendingSelectedTaskOperations.sorted {
            ($0.hlcWallMs, $0.hlcCounter, $0.id.uuidString)
                < ($1.hlcWallMs, $1.hlcCounter, $1.id.uuidString)
        }.map { ($0.id.uuidString, $0.hlcWallMs, $0.hlcCounter) })
        pendingSelectedTaskOperations = try pendingSelectedTaskOperations.map { operation in
            guard let clock = selectedTaskReplacements[operation.id.uuidString] else {
                return operation
            }
            return SelectedTaskOperation(
                id: operation.id,
                deviceId: operation.deviceId,
                taskId: operation.taskId,
                occurredAt: try rebasedDate(operation.occurredAt, clock: clock),
                hlcWallMs: clock.wallMs,
                hlcCounter: clock.counter
            )
        }

        let retainedMaximum = (
            pendingCommands.map { ($0.hlcWallMs, $0.hlcCounter) }
                + pendingTaskOperations.map { ($0.hlcWallMs, $0.hlcCounter) }
                + pendingDurationOperations.map { ($0.hlcWallMs, $0.hlcCounter) }
                + pendingAutoStartOperations.map { ($0.hlcWallMs, $0.hlcCounter) }
                + pendingSelectedTaskOperations.map { ($0.hlcWallMs, $0.hlcCounter) }
        ).filter { $0.0 > 0 }.max { $0 < $1 }
        let currentClock = (hlcWallMs, hlcCounter)
        let pendingClock = retainedMaximum ?? (serverWallMs, serverCounter)
        let mergedClock = currentClock > pendingClock ? currentClock : pendingClock
        hlcWallMs = mergedClock.0
        hlcCounter = mergedClock.1
    }

    var hasValidGeneratorState: Bool {
        hasValidGeneratorCore
            && hasValidTrustedTimeState
    }

    private var hasValidGeneratorCore: Bool {
        !deviceId.isEmpty
            && (1...WireBounds.maxSafeInteger).contains(nextSequence)
            && (!sequenceExhausted || nextSequence == WireBounds.maxSafeInteger)
            && WireBounds.containsUnsigned(revision)
            && (lastTrustedTimeMs.map {
                (1...WireBounds.maxSafeInteger).contains($0)
            } ?? true)
            && ((hlcWallMs == 0 && hlcCounter == 0)
                || WireBounds.isValidClock(wallMs: hlcWallMs, counter: hlcCounter))
            && localCommandDates.allSatisfy { entry in
                pendingCommands.contains(where: { $0.id == entry.key })
                    && WireBounds.physicalMilliseconds(for: entry.value) != nil
            }
    }

    private var hasValidTrustedTimeState: Bool {
        let fields: [Any?] = [
            serverTimeOffsetMs,
            serverTimeUncertaintyMs,
            serverTimeAnchorMs,
            serverTimeAnchorUptime
        ]
        let hasAnyField = fields.contains { $0 != nil }
        let sampleIsValid = !hasAnyField || (
            serverTimeOffsetMs.map {
                (-WireBounds.maxSafeInteger...WireBounds.maxSafeInteger).contains($0)
            } ?? false
        ) && (serverTimeUncertaintyMs.map {
            (0...WireBounds.maxServerTimeUncertaintyMs).contains($0)
        } ?? false) && (serverTimeAnchorMs.map {
            (1...WireBounds.maxSafeInteger).contains($0)
        } ?? false) && (serverTimeAnchorUptime.map {
            $0.isFinite && $0 >= 0
        } ?? false)
        return sampleIsValid
    }

    var hasTrustedTimeSample: Bool {
        serverTimeOffsetMs != nil
            && serverTimeUncertaintyMs != nil
            && serverTimeAnchorMs != nil
            && serverTimeAnchorUptime != nil
    }


    private var hasAnyTrustedTimeSampleField: Bool {
        serverTimeOffsetMs != nil
            || serverTimeUncertaintyMs != nil
            || serverTimeAnchorMs != nil
            || serverTimeAnchorUptime != nil
            || lastTrustedTimeMs != nil
    }

    var hasValidPendingWireOperations: Bool {
        !hasCorruptPendingOperations
            && hasValidGeneratorState
            && hasValidPendingOperationsAndIdentity
    }

    var hasValidPendingWireOperationsForResample: Bool {
        !hasCorruptPendingOperations
            && hasValidGeneratorCore
            && hasValidPendingOperationsAndIdentity
    }

    private var hasValidPendingOperationsAndIdentity: Bool {
        pendingCommands.allSatisfy(\.isValid)
            && pendingTaskOperations.allSatisfy(\.isValid)
            && pendingDurationOperations.allSatisfy(\.isValid)
            && pendingAutoStartOperations.allSatisfy {
                $0.isValid && $0.deviceId == deviceId
            }
            && pendingSelectedTaskOperations.allSatisfy {
                $0.isValid && $0.deviceId == deviceId
            }
            && Set(pendingCommands.map(\.id)).count == pendingCommands.count
            && Set(pendingCommands.map(\.deviceSequence)).count == pendingCommands.count
            && Set(pendingTaskOperations.map(\.id)).count == pendingTaskOperations.count
            && Set(pendingDurationOperations.map(\.id)).count == pendingDurationOperations.count
            && Set(pendingAutoStartOperations.map(\.id)).count == pendingAutoStartOperations.count
            && Set(pendingSelectedTaskOperations.map(\.id)).count == pendingSelectedTaskOperations.count
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
        let queued = pendingCommands.compactMap { UUIDv7.payload(from: $0.id) }
            + pendingTaskOperations.compactMap { UUIDv7.payload(from: $0.id) }
            + pendingDurationOperations.compactMap { UUIDv7.payload(from: $0.id) }
            + pendingAutoStartOperations.compactMap { UUIDv7.payload(from: $0.id.uuidString) }
            + pendingSelectedTaskOperations.compactMap { UUIDv7.payload(from: $0.id.uuidString) }
        let latestQueued = queued.max { UUIDv7.isLess($0, than: $1) }
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
        let candidateMs: Int64
        if !hasAnyTrustedTimeSampleField {
            guard WireBounds.physicalMilliseconds(for: localDate) != nil else {
                throw AppError.invalidLocalClock
            }
            candidateMs = WireBounds.physicalMilliseconds(for: localDate)!
        } else {
            guard hasValidTrustedTimeState,
                  let serverTimeAnchorMs,
                  let serverTimeAnchorUptime,
                  uptime.isFinite,
                  uptime >= serverTimeAnchorUptime,
                  let elapsedMs = WireBounds.nonnegativeMilliseconds(
                    for: uptime - serverTimeAnchorUptime
                  ) else {
                throw AppError.invalidLocalClock
            }
            let (anchoredMs, overflow) = serverTimeAnchorMs.addingReportingOverflow(elapsedMs)
            guard !overflow, (1...WireBounds.maxSafeInteger).contains(anchoredMs) else {
                throw AppError.invalidLocalClock
            }
            candidateMs = anchoredMs
        }
        let emittedMs: Int64
        if let lastTrustedTimeMs, candidateMs <= lastTrustedTimeMs {
            let (incremented, overflow) = lastTrustedTimeMs.addingReportingOverflow(1)
            guard !overflow, (1...WireBounds.maxSafeInteger).contains(incremented) else {
                throw AppError.invalidLocalClock
            }
            emittedMs = incremented
        } else {
            emittedMs = candidateMs
        }
        guard let candidate = WireBounds.date(milliseconds: emittedMs) else {
            throw AppError.invalidLocalClock
        }
        return candidate
    }

    func localProjection(of commands: [TimerCommand]) -> [TimerCommand] {
        commands.map { command in
            guard let localDate = localCommandDates[command.id] else { return command }
            return TimerCommand(
                id: command.id,
                deviceSequence: command.deviceSequence,
                timerId: command.timerId,
                taskId: command.taskId,
                type: command.type,
                phase: command.phase,
                plannedDurationMs: command.plannedDurationMs,
                occurredAt: localDate,
                hlcWallMs: command.hlcWallMs,
                hlcCounter: command.hlcCounter,
                observedElapsedMs: command.observedElapsedMs
            )
        }
    }

    mutating func pruneLocalCommandDates() {
        let pendingIDs = Set(pendingCommands.map(\.id))
        localCommandDates = localCommandDates.filter { pendingIDs.contains($0.key) }
    }

    func physicalDate(forTrustedDate date: Date) throws -> Date {
        guard serverTimeOffsetMs != nil || serverTimeUncertaintyMs != nil else { return date }
        guard let serverTimeOffsetMs,
              let serverTimeUncertaintyMs,
              (0...WireBounds.maxServerTimeUncertaintyMs).contains(serverTimeUncertaintyMs),
              serverTimeOffsetMs != Int64.min,
              let physical = WireBounds.adding(milliseconds: -serverTimeOffsetMs, to: date) else {
            throw AppError.invalidLocalClock
        }
        return physical
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
        guard hasValidPendingWireOperations,
              let nowMs = WireBounds.physicalMilliseconds(for: date) else {
            throw AppError.invalidLocalClock
        }
        let nextWallMs: Int64
        let nextCounter: Int64
        if nowMs > hlcWallMs {
            nextWallMs = nowMs
            nextCounter = 0
        } else {
            guard hlcCounter < WireBounds.maxSafeInteger else { throw AppError.invalidLocalClock }
            nextWallMs = hlcWallMs
            nextCounter = hlcCounter + 1
        }
        guard WireBounds.isWithinClockSkew(wallMs: nextWallMs, occurredAt: date) else {
            throw AppError.invalidLocalClock
        }
        hlcWallMs = nextWallMs
        hlcCounter = nextCounter
        if hasTrustedTimeSample {
            lastTrustedTimeMs = max(lastTrustedTimeMs ?? nowMs, nowMs)
        }
    }

    mutating func mergeClock(
        serverWallMs: Int64,
        serverCounter: Int64,
        serverTime: Date,
        requestWall: Date,
        requestUptime: TimeInterval,
        responseUptime: TimeInterval
    ) throws {
        guard hasValidGeneratorCore,
              WireBounds.isValidClock(wallMs: serverWallMs, counter: serverCounter),
              WireBounds.isWithinClockSkew(wallMs: serverWallMs, occurredAt: serverTime),
              let serverTimeMs = WireBounds.physicalMilliseconds(for: serverTime),
              let requestWallMs = WireBounds.physicalMilliseconds(for: requestWall),
              requestUptime.isFinite,
              responseUptime.isFinite,
              requestUptime >= 0,
              responseUptime >= requestUptime else {
            throw AppError.invalidResponse
        }
        let halfRoundTripMs = (responseUptime - requestUptime) * 500
        guard halfRoundTripMs.isFinite,
              let midpointDeltaMs = Int64(exactly: halfRoundTripMs.rounded(.towardZero)),
              let uncertaintyMs = Int64(exactly: halfRoundTripMs.rounded(.up)),
              (0...WireBounds.maxSafeInteger).contains(midpointDeltaMs),
              (0...WireBounds.maxServerTimeUncertaintyMs).contains(uncertaintyMs) else {
            throw AppError.invalidResponse
        }
        let (midpointWallMs, midpointOverflow) = requestWallMs.addingReportingOverflow(midpointDeltaMs)
        let (offsetMs, offsetOverflow) = serverTimeMs.subtractingReportingOverflow(midpointWallMs)
        let (anchorMs, anchorOverflow) = serverTimeMs.addingReportingOverflow(midpointDeltaMs)
        guard !midpointOverflow,
              !offsetOverflow,
              !anchorOverflow,
              (-WireBounds.maxSafeInteger...WireBounds.maxSafeInteger).contains(offsetMs),
              (1...WireBounds.maxSafeInteger).contains(anchorMs) else {
            throw AppError.invalidResponse
        }
        let mergedClock: (wallMs: Int64, counter: Int64)
        if hlcWallMs > 0,
           WireBounds.isWithinClockSkew(wallMs: hlcWallMs, occurredAt: serverTime),
           (hlcWallMs, hlcCounter) > (serverWallMs, serverCounter) {
            mergedClock = (hlcWallMs, hlcCounter)
        } else {
            mergedClock = (serverWallMs, serverCounter)
        }
        serverTimeOffsetMs = offsetMs
        serverTimeUncertaintyMs = uncertaintyMs
        serverTimeAnchorMs = anchorMs
        serverTimeAnchorUptime = responseUptime
        hlcWallMs = mergedClock.wallMs
        hlcCounter = mergedClock.counter
    }

    private static func normalizedLegacySentinel(_ operation: DurationOperation) -> DurationOperation {
        guard operation.hlcWallMs == 0, operation.hlcCounter == 0 else { return operation }
        return DurationOperation(
            id: operation.id,
            phase: operation.phase,
            durationMs: operation.durationMs,
            occurredAt: Date(timeIntervalSince1970: 0),
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private static func normalizedLegacySentinel(_ operation: AutoStartOperation) -> AutoStartOperation {
        guard operation.hlcWallMs == 0, operation.hlcCounter == 0 else { return operation }
        return AutoStartOperation(
            id: operation.id,
            deviceId: operation.deviceId,
            enabled: operation.enabled,
            occurredAt: Date(timeIntervalSince1970: 0),
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private static func normalizedLegacySentinel(_ operation: SelectedTaskOperation) -> SelectedTaskOperation {
        guard operation.hlcWallMs == 0, operation.hlcCounter == 0 else { return operation }
        return SelectedTaskOperation(
            id: operation.id,
            deviceId: operation.deviceId,
            taskId: operation.taskId,
            occurredAt: Date(timeIntervalSince1970: 0),
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }

    private static func normalizedLegacySentinels(
        _ request: BootstrapResolveRequest
    ) -> BootstrapResolveRequest {
        BootstrapResolveRequest(
            requestId: request.requestId,
            deviceId: request.deviceId,
            expectedRevision: request.expectedRevision,
            strategy: request.strategy,
            commands: request.commands,
            taskOperations: request.taskOperations,
            durationOperations: request.durationOperations.map(normalizedLegacySentinel),
            autoStartOperations: request.autoStartOperations?.map(normalizedLegacySentinel),
            selectedTaskOperations: request.selectedTaskOperations?.map(normalizedLegacySentinel)
        )
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
}

enum TaskReducer {
    static func applying(_ operations: [TaskOperation], to baseTasks: [FocusTask]) -> [FocusTask] {
        operations.sorted(by: precedes).reduce(into: baseTasks) { tasks, operation in
            guard let taskID = UUID(uuidString: operation.taskId) else { return }
            switch operation.type {
            case .delete:
                tasks.removeAll { $0.id == taskID }
            case .upsert:
                guard let title = operation.title,
                      let task = FocusTask(title: title),
                      task.id == taskID else { return }
                tasks.removeAll { $0.id == taskID }
                tasks.append(task)
            }
        }
    }

    private static func precedes(_ lhs: TaskOperation, _ rhs: TaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }
}

enum DurationReducer {
    static func applying(_ operations: [DurationOperation], to base: DurationValues) -> DurationValues {
        operations.sorted(by: precedes).reduce(into: base) { durations, operation in
            guard operation.isValid else { return }
            durations.setDurationMs(operation.durationMs, for: operation.phase)
        }
    }

    private static func precedes(_ lhs: DurationOperation, _ rhs: DurationOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        return lhs.id < rhs.id
    }
}

enum AutoStartReducer {
    static func applying(_ operations: [AutoStartOperation], to base: Bool) -> Bool {
        operations.sorted(by: precedes).reduce(base) { enabled, operation in
            operation.isValid ? operation.enabled : enabled
        }
    }

    private static func precedes(_ lhs: AutoStartOperation, _ rhs: AutoStartOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum SelectedTaskReducer {
    static func applying(_ operations: [SelectedTaskOperation], to base: UUID?) -> UUID? {
        operations.sorted(by: precedes).reduce(base) { selectedTaskID, operation in
            guard operation.isValid else { return selectedTaskID }
            return operation.taskId.flatMap(UUID.init(uuidString:))
        }
    }

    private static func precedes(_ lhs: SelectedTaskOperation, _ rhs: SelectedTaskOperation) -> Bool {
        if lhs.hlcWallMs != rhs.hlcWallMs { return lhs.hlcWallMs < rhs.hlcWallMs }
        if lhs.hlcCounter != rhs.hlcCounter { return lhs.hlcCounter < rhs.hlcCounter }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum TimerReducer {
    static func projectingTimeCompletion(
        _ timer: CanonicalTimer?,
        history: [HistoryItem],
        at date: Date
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        let projected = autoCompleting(timer, history: history, at: date)
        return (projected.0, projected.1)
    }

    static func breakPhase(afterCompletedFocusCount count: Int) -> TimerPhase {
        count > 0 && count.isMultiple(of: 4) ? .longBreak : .shortBreak
    }

    static func applying(
        _ commands: [TimerCommand],
        to canonical: CanonicalTimer?,
        history canonicalHistory: [HistoryItem]
    ) -> (timer: CanonicalTimer?, history: [HistoryItem]) {
        commands.sorted {
            $0.deviceSequence != $1.deviceSequence
                ? $0.deviceSequence < $1.deviceSequence
                : $0.id < $1.id
        }.reduce(into: (canonical, canonicalHistory)) { result, command in
            result = apply(command, to: result.0, history: result.1)
        }
    }

    static func apply(
        _ command: TimerCommand,
        to timer: CanonicalTimer?,
        history: [HistoryItem]
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let projected = autoCompleting(timer, history: history, at: command.occurredAt)
        return applyTransition(command, to: projected.0, history: projected.1)
    }

    private static func applyTransition(
        _ command: TimerCommand,
        to timer: CanonicalTimer?,
        history: [HistoryItem]
    ) -> (CanonicalTimer?, [HistoryItem]) {
        let intent = TimerIntent(
            type: command.type,
            commandId: command.id,
            occurredAt: command.occurredAt,
            deviceId: nil
        )
        switch command.type {
        case .start:
            guard timer?.id != command.timerId,
                  !history.contains(where: { $0.timerId == command.timerId }) else { return (timer, history) }
            var nextHistory = history
            if let timer, timer.status == .running || timer.status == .paused,
               !nextHistory.contains(where: { $0.commandId == command.id }) {
                nextHistory.insert(HistoryItem(
                    id: timer.id,
                    timerId: timer.id,
                    commandId: command.id,
                    taskId: timer.taskId,
                    phase: timer.phase,
                    status: CanonicalTimer.Status.superseded.rawValue,
                    plannedDurationMs: timer.plannedDurationMs,
                    completedAt: nil,
                    endedAt: command.occurredAt
                ), at: 0)
            }
            return (
                CanonicalTimer(
                    id: command.timerId,
                    taskId: command.taskId,
                    phase: command.phase,
                    status: .running,
                    plannedDurationMs: command.plannedDurationMs,
                    elapsedAtAnchorMs: 0,
                    anchorAt: command.occurredAt,
                    lastIntent: intent
                ),
                nextHistory
            )
        case .pause:
            guard let timer, timer.id == command.timerId, timer.status == .running else { return (timer, history) }
            return (updated(timer, status: .paused, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent), history)
        case .resume:
            if let timer, timer.id == command.timerId,
               timer.status == .paused || timer.status == .superseded {
                let nextHistory = timer.status == .superseded
                    ? history.filter { $0.timerId != timer.id || $0.status != CanonicalTimer.Status.superseded.rawValue }
                    : history
                return (
                    updated(timer, status: .running, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent),
                    nextHistory
                )
            }
            guard let target = history.first(where: {
                $0.timerId == command.timerId && $0.status == CanonicalTimer.Status.superseded.rawValue
            }) else { return (timer, history) }
            var nextHistory = history.filter { $0.id != target.id }
            if let timer, timer.status == .running || timer.status == .paused,
               !nextHistory.contains(where: { $0.commandId == command.id }) {
                nextHistory.insert(HistoryItem(
                    id: timer.id,
                    timerId: timer.id,
                    commandId: command.id,
                    taskId: timer.taskId,
                    phase: timer.phase,
                    status: CanonicalTimer.Status.superseded.rawValue,
                    plannedDurationMs: timer.plannedDurationMs,
                    completedAt: nil,
                    endedAt: command.occurredAt
                ), at: 0)
            }
            return (
                CanonicalTimer(
                    id: target.timerId,
                    taskId: target.taskId,
                    phase: target.phase,
                    status: .running,
                    plannedDurationMs: target.plannedDurationMs,
                    elapsedAtAnchorMs: min(target.plannedDurationMs, max(0, command.observedElapsedMs)),
                    anchorAt: command.occurredAt,
                    lastIntent: intent
                ),
                nextHistory
            )
        case .finish:
            if let timer, timer.id == command.timerId, timer.status == .completed,
               let completionIndex = history.firstIndex(where: {
                   $0.timerId == timer.id
                       && $0.status == CanonicalTimer.Status.completed.rawValue
                       && $0.commandId == nil
               }) {
                var nextHistory = history
                let completion = nextHistory[completionIndex]
                nextHistory[completionIndex] = HistoryItem(
                    id: completion.id,
                    timerId: completion.timerId,
                    commandId: command.id,
                    taskId: completion.taskId,
                    phase: completion.phase,
                    status: completion.status,
                    plannedDurationMs: completion.plannedDurationMs,
                    completedAt: completion.completedAt,
                    endedAt: completion.endedAt
                )
                return (
                    CanonicalTimer(
                        id: timer.id,
                        taskId: timer.taskId,
                        phase: timer.phase,
                        status: timer.status,
                        plannedDurationMs: timer.plannedDurationMs,
                    elapsedAtAnchorMs: timer.elapsedAtAnchorMs,
                    anchorAt: timer.anchorAt,
                    startedByDeviceId: timer.startedByDeviceId,
                    lastIntent: intent
                    ),
                    nextHistory
                )
            }
            guard let timer, timer.id == command.timerId, timer.status == .running || timer.status == .paused else { return (timer, history) }
            let finished = updated(timer, status: .completed, elapsed: timer.plannedDurationMs, at: command.occurredAt, intent: intent)
            guard !history.contains(where: { $0.commandId == command.id }) else { return (finished, history) }
            let item = HistoryItem(
                id: command.timerId,
                timerId: command.timerId,
                commandId: command.id,
                taskId: timer.taskId,
                phase: timer.phase,
                    status: "completed",
                    plannedDurationMs: timer.plannedDurationMs,
                    completedAt: command.occurredAt,
                    endedAt: command.occurredAt
            )
            return (finished, [item] + history)
        case .cancel:
            guard let timer, timer.id == command.timerId, timer.status == .running || timer.status == .paused else { return (timer, history) }
            let cancelled = updated(timer, status: .cancelled, elapsed: command.observedElapsedMs, at: command.occurredAt, intent: intent)
            guard !history.contains(where: { $0.commandId == command.id }) else { return (cancelled, history) }
            let item = HistoryItem(
                id: command.timerId,
                timerId: command.timerId,
                commandId: command.id,
                taskId: timer.taskId,
                phase: timer.phase,
                status: "cancelled",
                plannedDurationMs: timer.plannedDurationMs,
                completedAt: nil,
                endedAt: command.occurredAt
            )
            return (cancelled, [item] + history)
        case .clear:
            guard let timer, timer.id == command.timerId,
                  timer.status == .completed || timer.status == .cancelled else { return (timer, history) }
            return (nil, history)
        }
    }

    private static func autoCompleting(
        _ timer: CanonicalTimer?,
        history: [HistoryItem],
        at date: Date
    ) -> (CanonicalTimer?, [HistoryItem]) {
        guard let timer, timer.status == .running else { return (timer, history) }
        let planned = max(0, timer.plannedDurationMs)
        let stored = min(planned, max(0, timer.elapsedAtAnchorMs))
        let elapsedAtDate = TimeInterval(stored) / 1_000 + max(0, date.timeIntervalSince(timer.anchorAt))
        guard elapsedAtDate >= TimeInterval(planned) / 1_000 else { return (timer, history) }

        let completedAt = timer.anchorAt.addingTimeInterval(TimeInterval(planned - stored) / 1_000)
        let completed = CanonicalTimer(
            id: timer.id,
            taskId: timer.taskId,
            phase: timer.phase,
            status: .completed,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: timer.plannedDurationMs,
            anchorAt: completedAt,
            startedByDeviceId: timer.startedByDeviceId,
            lastIntent: timer.lastIntent
        )
        guard !history.contains(where: { $0.timerId == timer.id }) else { return (completed, history) }
        let completion = HistoryItem(
            id: timer.id,
            timerId: timer.id,
            commandId: nil,
            taskId: timer.taskId,
            phase: timer.phase,
            status: CanonicalTimer.Status.completed.rawValue,
            plannedDurationMs: timer.plannedDurationMs,
            completedAt: completedAt,
            endedAt: completedAt
        )
        return (completed, [completion] + history)
    }

    private static func updated(
        _ timer: CanonicalTimer,
        status: CanonicalTimer.Status,
        elapsed: Int64,
        at date: Date,
        intent: TimerIntent
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: timer.id,
            taskId: timer.taskId,
            phase: timer.phase,
            status: status,
            plannedDurationMs: timer.plannedDurationMs,
            elapsedAtAnchorMs: min(timer.plannedDurationMs, max(0, elapsed)),
            anchorAt: date,
            startedByDeviceId: timer.startedByDeviceId,
            lastIntent: intent
        )
    }
}

enum AppError: LocalizedError {
    case configuration
    case missingPresentationAnchor
    case missingIDToken
    case unauthorized
    case conflict(String)
    case server(String)
    case historyReplacementUnavailable
    case invalidResponse
    case invalidLocalClock

    var errorDescription: String? {
        switch self {
        case .configuration: "Google Sign-In is not configured for this build."
        case .missingPresentationAnchor: "No window is available for Google Sign-In."
        case .missingIDToken: "Google did not return an identity token."
        case .unauthorized: "Session expired. Sign in again."
        case .conflict(let message): message
        case .server(let message): message
        case .historyReplacementUnavailable:
            "Keeping local history requires a server update. Your saved choice and local data remain on this device."
        case .invalidResponse: "Server returned an invalid response."
        case .invalidLocalClock:
            "Change blocked because saved sequence or trusted-time state is invalid. Queued changes were not modified."
        }
    }
}
