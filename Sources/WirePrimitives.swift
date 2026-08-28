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
