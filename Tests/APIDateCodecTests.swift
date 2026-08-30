import Foundation
import Testing
@testable import Pomodorough

@Suite("API RFC3339 date codec")
struct APIDateCodecTests {
    @Test(arguments: ["2026-08-30T17:32:56.578Z", "2026-08-30T17:33:04.836Z"])
    func reportedTimestampsRemainExact(timestamp: String) throws {
        var encoded = try JSONEncoder().encode(timestamp)
        let original = try JSONDecoder.api.decode(Date.self, from: encoded)
        for _ in 0..<32 {
            let decoded = try JSONDecoder.api.decode(Date.self, from: encoded)
            #expect(decoded == original)
            encoded = try JSONEncoder.api.encode(decoded)
            #expect(try JSONDecoder().decode(String.self, from: encoded) == timestamp)
        }
    }

    @Test(arguments: [
        "0000-01-01T00:00:00", "0001-01-01T00:00:00", "1582-10-15T00:00:00",
        "1900-03-01T00:00:00", "1969-12-31T23:59:59", "1970-01-01T00:00:00",
        "2000-12-31T23:59:59", "2001-01-01T00:00:00", "2001-01-01T00:00:01",
        "2001-01-01T00:00:02", "2001-01-01T00:00:03", "2001-01-01T00:00:04",
        "2004-02-29T23:59:59", "2026-08-30T17:32:56", "2026-08-30T17:33:04",
        "2099-12-31T23:59:59", "2100-02-28T23:59:59", "9999-12-31T23:59:59"
    ])
    func everyMillisecondIsStable(prefix: String) throws {
        for millisecond in 0..<1_000 {
            let timestamp = prefix + String(format: ".%03dZ", millisecond)
            var encoded = try JSONEncoder().encode(timestamp)
            let original = try JSONDecoder.api.decode(Date.self, from: encoded)
            for _ in 0..<4 {
                let decoded = try JSONDecoder.api.decode(Date.self, from: encoded)
                #expect(decoded == original)
                encoded = try JSONEncoder.api.encode(decoded)
                #expect(try JSONDecoder().decode(String.self, from: encoded) == timestamp)
            }
        }
    }

    @Test(arguments: [
        ("2026-08-30T23:02:56.578+05:30", "2026-08-30T17:32:56.578Z"),
        ("2026-08-30T13:32:56.578-04:00", "2026-08-30T17:32:56.578Z"),
        ("2026-08-30T17:32:56.578-00:00", "2026-08-30T17:32:56.578Z"),
        ("2026-08-30T17:32:56+00:00", "2026-08-30T17:32:56.000Z"),
        ("2024-03-01T00:00:00.001+00:01", "2024-02-29T23:59:00.001Z"),
        ("2001-01-01T00:59:59.999+01:00", "2000-12-31T23:59:59.999Z"),
        ("2000-12-31T23:59:59.999-00:01", "2001-01-01T00:00:59.999Z"),
        ("2016-12-31T23:59:60.578Z", "2017-01-01T00:00:00.578Z"),
        ("2026-08-30T17:32:56.5Z", "2026-08-30T17:32:56.500Z"),
        ("2026-08-30T17:32:56.57Z", "2026-08-30T17:32:56.570Z"),
        ("2026-08-30T17:32:56.578000000Z", "2026-08-30T17:32:56.578Z")
    ])
    func supportedSpellingsPreserveTheirInstant(input: String, expected: String) throws {
        let decoded = try decode(input)
        #expect(try decoded == decode(expected))
        #expect(try encode(decoded) == expected)
    }

    @Test(arguments: [
        ("2001-01-01T00:00:00.000000001Z", 0.000000001),
        ("2001-01-01T00:00:01.118Z", 1.118),
        ("2000-12-31T23:59:59.999999999Z", -0.000000001),
        ("2000-12-31T23:59:59.876543211Z", -0.123456789),
        ("2026-08-30T17:32:56.578123456Z", 809_803_976.578123456),
        ("1969-12-31T23:59:59.123456789Z", -978_307_200.876543211)
    ])
    func fractionalParsingUsesAvailableDatePrecision(input: String, referenceSeconds: Double) throws {
        #expect(try decode(input).timeIntervalSinceReferenceDate == referenceSeconds)
    }

    @Test(arguments: [
        (-Double.leastNonzeroMagnitude, "2000-12-31T23:59:59.999Z"),
        (-0.001, "2000-12-31T23:59:59.999Z"),
        ((-0.001).nextDown, "2000-12-31T23:59:59.998Z"),
        ((-0.001).nextUp, "2000-12-31T23:59:59.999Z"),
        (0.001, "2001-01-01T00:00:00.001Z"),
        ((0.001).nextDown, "2001-01-01T00:00:00.000Z"),
        ((0.001).nextUp, "2001-01-01T00:00:00.001Z"),
        (0.999999999, "2001-01-01T00:00:00.999Z"),
        (809_803_976.577999, "2026-08-30T17:32:56.577Z"),
        (809_803_976.578001, "2026-08-30T17:32:56.578Z"),
        (809_803_976.578999, "2026-08-30T17:32:56.578Z"),
        (809_803_976.999999, "2026-08-30T17:32:56.999Z"),
        (-978_307_200.0001, "1969-12-31T23:59:59.999Z")
    ])
    func submillisecondsFloorWithoutChangingDate(referenceSeconds: Double, expected: String) throws {
        let date = Date(timeIntervalSinceReferenceDate: referenceSeconds)
        let timestamp = try encode(date)
        #expect(timestamp == expected)
        #expect(date.timeIntervalSinceReferenceDate == referenceSeconds)
        #expect(try encode(decode(timestamp)) == timestamp)
    }

    @Test(arguments: [
        "", "not-a-date", "2026-08-30", "2026-08-30T17:32:56.578",
        "2026-08-30T17:32:56.Z", "2026-08-30T17:32:56.1234567890Z",
        "2026-08-30T17:32:56.12345678901234567890Z", "2026-08-30T17:32:56.nanZ"
    ])
    func invalidSupportedSyntaxThrows(input: String) throws {
        let encoded = try JSONEncoder().encode(input)
        #expect(throws: DecodingError.self) { try JSONDecoder.api.decode(Date.self, from: encoded) }
    }

    @Test(arguments: ["null", "42", "true", "[]", "{}"])
    func nonStringDatesThrow(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder.api.decode(Date.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                      -63_145_699_201, 252_423_993_600])
    func unrepresentableDatesThrow(referenceSeconds: Double) {
        #expect(throws: EncodingError.self) {
            try JSONEncoder.api.encode(Date(timeIntervalSinceReferenceDate: referenceSeconds))
        }
    }

    private func decode(_ timestamp: String) throws -> Date {
        try JSONDecoder.api.decode(Date.self, from: JSONEncoder().encode(timestamp))
    }

    private func encode(_ date: Date) throws -> String {
        try JSONDecoder().decode(String.self, from: JSONEncoder.api.encode(date))
    }
}
