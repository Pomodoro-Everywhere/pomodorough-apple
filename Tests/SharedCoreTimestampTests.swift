import Foundation
import Testing
@testable import Pomodorough

/// Stored dates go back to Core through `sharedCoreTimestamp`. A whole
/// millisecond that `APIDateCodec` reads back must reach Core unchanged, or a
/// reloaded model replays its pending commands 1 ms early.
struct SharedCoreTimestampTests {
    /// November 2026 in milliseconds since 1970, the range of the drift report.
    private static let november2026Ms: Int64 = 1_794_000_000_000

    @Test func storedWholeMillisecondsReachCoreExactly() throws {
        var drifted: [String] = []
        for index in 0..<100_000 {
            let stored = Self.wireString(milliseconds: Self.november2026Ms + Int64(index) * 7 + 3)
            let date = try #require(APIDateCodec.parse(stored))
            if try sharedCoreTimestamp(for: date) != stored { drifted.append(stored) }
        }
        #expect(drifted.isEmpty, "\(drifted.count) of 100000 stored dates changed, first \(drifted.first ?? "-")")
    }

    @Test func storedDatesAroundTheEpochsReachCoreExactly() throws {
        let stored = [
            "1969-12-31T23:59:58.500Z", "1969-12-31T23:59:59.999Z", "1970-01-01T00:00:00.000Z",
            "1970-01-01T00:00:00.001Z", "2000-12-31T23:59:59.999Z", "2001-01-01T00:00:00.000Z",
            "2001-01-01T00:00:00.001Z", "2026-11-12T08:15:30.007Z", "2099-12-31T23:59:59.999Z",
        ]
        for value in stored {
            let date = try #require(APIDateCodec.parse(value))
            #expect(try sharedCoreTimestamp(for: date) == value)
        }
    }

    /// Core gets whole milliseconds truncated toward zero, so a server time is
    /// never rounded above the HLC wall that the server truncated.
    @Test func partialMillisecondsTruncateTowardZero() throws {
        #expect(try sharedCoreTimestamp(for: Date(timeIntervalSince1970: 1.000_7)) == "1970-01-01T00:00:01.000Z")
        #expect(try sharedCoreTimestamp(for: Date(timeIntervalSince1970: -0.000_7)) == "1970-01-01T00:00:00.000Z")
        #expect(try sharedCoreTimestamp(for: Date(timeIntervalSince1970: -1.500_4)) == "1969-12-31T23:59:58.500Z")
        let now = Date(timeIntervalSince1970: 1_794_000_000.123_9)
        #expect(try sharedCoreTimestamp(for: now) == Self.wireString(milliseconds: 1_794_000_000_123))
    }

    private static func wireString(milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        let prefix = Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(Date.ISO8601FormatStyle()).dropLast()
        return prefix + String(format: ".%03lldZ", milliseconds - seconds * 1_000)
    }
}
