import Foundation

enum TimerPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus
    case shortBreak = "short_break"
    case longBreak = "long_break"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: String(localized: "Focus")
        case .shortBreak: String(localized: "Short break")
        case .longBreak: String(localized: "Long break")
        }
    }

    var routeLabel: String {
        switch self {
        case .focus: String(localized: "Work")
        case .shortBreak: String(localized: "Reset")
        case .longBreak: String(localized: "Recover")
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
