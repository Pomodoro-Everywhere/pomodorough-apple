import Foundation

struct TrustedClockTransition: Equatable, Sendable {
    let state: TrustedClockState
    let trustedDate: Date
}

struct TrustedClockResample: Equatable, Sendable {
    let state: TrustedClockState
}

struct TrustedClockState: Equatable, Sendable {
    var offsetMs: Int64?
    var uncertaintyMs: Int64?
    var anchorMs: Int64?
    var anchorUptime: TimeInterval?
    var lastEmittedMs: Int64?

    var hasValidSamplePersistence: Bool {
        let fields: [Any?] = [offsetMs, uncertaintyMs, anchorMs, anchorUptime]
        let hasAnyField = fields.contains { $0 != nil }
        return !hasAnyField || (
            offsetMs.map {
                (-WireBounds.maxSafeInteger...WireBounds.maxSafeInteger).contains($0)
            } ?? false
        ) && (uncertaintyMs.map {
            (0...WireBounds.maxServerTimeUncertaintyMs).contains($0)
        } ?? false) && (anchorMs.map {
            (1...WireBounds.maxSafeInteger).contains($0)
        } ?? false) && (anchorUptime.map {
            $0.isFinite && $0 >= 0
        } ?? false)
    }

    var hasValidLastEmittedTime: Bool {
        lastEmittedMs.map { (1...WireBounds.maxSafeInteger).contains($0) } ?? true
    }

    var hasSample: Bool {
        offsetMs != nil
            && uncertaintyMs != nil
            && anchorMs != nil
            && anchorUptime != nil
    }

    var hasAnyPersistedField: Bool {
        offsetMs != nil
            || uncertaintyMs != nil
            || anchorMs != nil
            || anchorUptime != nil
            || lastEmittedMs != nil
    }

    func occurrenceTransition(
        for localDate: Date,
        uptime: TimeInterval
    ) throws -> TrustedClockTransition {
        let candidateMs = try trustedCandidateMilliseconds(for: localDate, uptime: uptime)
        let emittedMs = try monotonicTrustedMilliseconds(after: candidateMs)
        guard let candidate = WireBounds.date(milliseconds: emittedMs) else {
            throw AppError.invalidLocalClock
        }
        return TrustedClockTransition(state: self, trustedDate: candidate)
    }

    func recordingTrustedMilliseconds(_ milliseconds: Int64) -> Self {
        guard hasSample else { return self }
        var updated = self
        updated.lastEmittedMs = max(lastEmittedMs ?? milliseconds, milliseconds)
        return updated
    }

    func resampled(
        serverTimeMs: Int64,
        requestWallMs: Int64,
        requestUptime: TimeInterval,
        responseUptime: TimeInterval
    ) throws -> TrustedClockResample {
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
        return TrustedClockResample(
            state: TrustedClockState(
                offsetMs: offsetMs,
                uncertaintyMs: uncertaintyMs,
                anchorMs: anchorMs,
                anchorUptime: responseUptime,
                lastEmittedMs: lastEmittedMs
            )
        )
    }

    func physicalDate(forTrustedDate date: Date) throws -> Date {
        guard offsetMs != nil || uncertaintyMs != nil else { return date }
        guard let offsetMs,
              let uncertaintyMs,
              (0...WireBounds.maxServerTimeUncertaintyMs).contains(uncertaintyMs),
              offsetMs != Int64.min,
              let physical = WireBounds.adding(milliseconds: -offsetMs, to: date) else {
            throw AppError.invalidLocalClock
        }
        return physical
    }

    private func trustedCandidateMilliseconds(
        for localDate: Date,
        uptime: TimeInterval
    ) throws -> Int64 {
        if !hasAnyPersistedField {
            guard let milliseconds = WireBounds.physicalMilliseconds(for: localDate) else {
                throw AppError.invalidLocalClock
            }
            return milliseconds
        }
        guard hasValidSamplePersistence,
              let anchorMs,
              let anchorUptime,
              let offsetMs,
              uptime.isFinite else {
            throw AppError.invalidLocalClock
        }
        if uptime >= anchorUptime {
            guard let elapsedMs = WireBounds.nonnegativeMilliseconds(for: uptime - anchorUptime) else {
                throw AppError.invalidLocalClock
            }
            let (anchoredMs, overflow) = anchorMs.addingReportingOverflow(elapsedMs)
            guard !overflow, (1...WireBounds.maxSafeInteger).contains(anchoredMs) else {
                throw AppError.invalidLocalClock
            }
            return anchoredMs
        }
        return try recoveredTrustedMilliseconds(
            for: localDate,
            offsetMs: offsetMs,
            anchorMs: anchorMs
        )
    }

    private func recoveredTrustedMilliseconds(
        for localDate: Date,
        offsetMs: Int64,
        anchorMs: Int64
    ) throws -> Int64 {
        guard let localMs = WireBounds.physicalMilliseconds(for: localDate) else {
            throw AppError.invalidLocalClock
        }
        let (recoveredMs, overflow) = localMs.addingReportingOverflow(offsetMs)
        guard !overflow, (1...WireBounds.maxSafeInteger).contains(recoveredMs) else {
            throw AppError.invalidLocalClock
        }
        // Persisted monotonic uptime may belong to a previous boot. Allow only
        // near-anchor wall-clock recovery until a fresh server sample arrives.
        let rebootReferenceMs = max(anchorMs, lastEmittedMs ?? 0)
        let (maximumRecoveredMs, maximumOverflow) = rebootReferenceMs.addingReportingOverflow(
            WireBounds.maxClockSkewMs
        )
        guard !maximumOverflow, recoveredMs <= maximumRecoveredMs else {
            throw AppError.invalidLocalClock
        }
        return recoveredMs
    }

    private func monotonicTrustedMilliseconds(after candidateMs: Int64) throws -> Int64 {
        if let lastEmittedMs, candidateMs <= lastEmittedMs {
            let (incremented, overflow) = lastEmittedMs.addingReportingOverflow(1)
            guard !overflow, (1...WireBounds.maxSafeInteger).contains(incremented) else {
                throw AppError.invalidLocalClock
            }
            return incremented
        }
        return candidateMs
    }
}
