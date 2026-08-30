import Foundation

enum APIDateCodec {
    private static let standard = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ value: String) -> Date? {
        guard let parsed = try? fractional.parse(value) else { return try? standard.parse(value) }
        guard let separator = value.firstIndex(of: ".") else { return parsed }
        let start = value.index(after: separator)
        let digits = value[start...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let numerator = Int(digits) else { return parsed }
        let end = value.index(start, offsetBy: digits.count)
        guard let whole = try? standard.parse(String(value[..<separator]) + value[end...]),
              let seconds = Int64(exactly: whole.timeIntervalSinceReferenceDate) else { return parsed }
        guard numerator != 0 else { return whole }
        let divisor = Int(pow(10.0, Double(digits.count)))
        let integral = seconds >= 0 ? String(seconds) : "-" + String(-(seconds + 1))
        let remainder = seconds >= 0 ? String(digits) : String(divisor - numerator)
        let padding = String(repeating: "0", count: digits.count - remainder.count)
        // One decimal conversion avoids cancellation and double rounding around the reference epoch.
        guard let interval = Double(integral + "." + padding + remainder) else { return parsed }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    static func string(from date: Date) -> String? {
        let interval = date.timeIntervalSinceReferenceDate
        // Foundation's four-digit ISO8601 years, measured from its 2001 reference epoch.
        guard interval.isFinite, (-63_145_699_200..<252_423_993_600).contains(interval) else { return nil }
        let nearest = (interval * 1_000).rounded()
        // Floor against representable millisecond boundaries, not arbitrary submillisecond rounding.
        let milliseconds = Int64(interval < nearest / 1_000 ? nearest - 1 : nearest)
        let seconds = (Double(milliseconds) / 1_000).rounded(.down)
        let remainder = Int(milliseconds - Int64(seconds) * 1_000)
        let prefix = standard.format(Date(timeIntervalSinceReferenceDate: seconds)).dropLast()
        return prefix + String(format: ".%03dZ", remainder)
    }
}
