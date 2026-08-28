import Foundation

enum StrictJSON {
    static func object(from data: Data) throws -> [String: Any]? {
        guard let source = String(data: data, encoding: .utf8) else {
            throw IrohProtocolError.invalidMessage("JSON must be valid UTF-8")
        }
        var scanner = Scanner(source)
        try scanner.validateDocument()
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func isExactUnixEpoch(_ value: String) -> Bool {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let standard = Date.ISO8601FormatStyle()
        let date = (try? fractional.parse(value)) ?? (try? standard.parse(value))
        return date == Date(timeIntervalSince1970: 0)
    }

    private struct Scanner {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ source: String) {
            scalars = Array(source.unicodeScalars)
        }

        mutating func validateDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == scalars.count else { throw invalidJSON }
        }

        private mutating func parseValue() throws {
            guard let scalar = current else { throw invalidJSON }
            switch scalar.value {
            case 0x7b: try parseObject()
            case 0x5b: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try parseLiteral("true")
            case 0x66: try parseLiteral("false")
            case 0x6e: try parseLiteral("null")
            case 0x2d, 0x30...0x39: try parseNumber()
            default: throw invalidJSON
            }
        }

        private mutating func parseObject() throws {
            try consume(0x7b)
            skipWhitespace()
            if consumeIfPresent(0x7d) { return }
            var keys = Set<String>()
            while true {
                guard current?.value == 0x22 else { throw invalidJSON }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw IrohProtocolError.invalidMessage("JSON contains a duplicate object key")
                }
                skipWhitespace()
                try consume(0x3a)
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consumeIfPresent(0x7d) { return }
                try consume(0x2c)
                skipWhitespace()
            }
        }

        private mutating func parseArray() throws {
            try consume(0x5b)
            skipWhitespace()
            if consumeIfPresent(0x5d) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consumeIfPresent(0x5d) { return }
                try consume(0x2c)
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            try consume(0x22)
            var result = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                switch scalar.value {
                case 0x22:
                    return String(result)
                case 0x00...0x1f:
                    throw invalidJSON
                case 0x5c:
                    guard let escaped = current else { throw invalidJSON }
                    index += 1
                    switch escaped.value {
                    case 0x22, 0x2f, 0x5c: result.append(escaped)
                    case 0x62: result.append(Unicode.Scalar(0x08)!)
                    case 0x66: result.append(Unicode.Scalar(0x0c)!)
                    case 0x6e: result.append(Unicode.Scalar(0x0a)!)
                    case 0x72: result.append(Unicode.Scalar(0x0d)!)
                    case 0x74: result.append(Unicode.Scalar(0x09)!)
                    case 0x75: try appendUnicodeEscape(to: &result)
                    default: throw invalidJSON
                    }
                default:
                    result.append(scalar)
                }
            }
            throw invalidJSON
        }

        private mutating func appendUnicodeEscape(to result: inout String.UnicodeScalarView) throws {
            let first = try parseHexQuad()
            switch first {
            case 0xd800...0xdbff:
                try consume(0x5c)
                try consume(0x75)
                let second = try parseHexQuad()
                guard (0xdc00...0xdfff).contains(second),
                      let scalar = Unicode.Scalar(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00) else {
                    throw invalidJSON
                }
                result.append(scalar)
            case 0xdc00...0xdfff:
                throw invalidJSON
            default:
                guard let scalar = Unicode.Scalar(first) else { throw invalidJSON }
                result.append(scalar)
            }
        }

        private mutating func parseHexQuad() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let scalar = current, let digit = hexValue(scalar.value) else { throw invalidJSON }
                index += 1
                value = (value << 4) | digit
            }
            return value
        }

        private mutating func parseNumber() throws {
            _ = consumeIfPresent(0x2d)
            guard let scalar = current else { throw invalidJSON }
            if scalar.value == 0x30 {
                index += 1
                if let next = current, (0x30...0x39).contains(next.value) { throw invalidJSON }
            } else {
                guard (0x31...0x39).contains(scalar.value) else { throw invalidJSON }
                repeat { index += 1 } while current.map { (0x30...0x39).contains($0.value) } == true
            }
            if consumeIfPresent(0x2e) {
                guard current.map({ (0x30...0x39).contains($0.value) }) == true else { throw invalidJSON }
                repeat { index += 1 } while current.map { (0x30...0x39).contains($0.value) } == true
            }
            if current?.value == 0x65 || current?.value == 0x45 {
                index += 1
                if current?.value == 0x2b || current?.value == 0x2d { index += 1 }
                guard current.map({ (0x30...0x39).contains($0.value) }) == true else { throw invalidJSON }
                repeat { index += 1 } while current.map { (0x30...0x39).contains($0.value) } == true
            }
        }

        private mutating func parseLiteral(_ literal: StaticString) throws {
            for byte in literal.withUTF8Buffer({ Array($0) }) {
                try consume(UInt32(byte))
            }
        }

        private mutating func consume(_ value: UInt32) throws {
            guard current?.value == value else { throw invalidJSON }
            index += 1
        }

        private mutating func consumeIfPresent(_ value: UInt32) -> Bool {
            guard current?.value == value else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while let value = current?.value, value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d {
                index += 1
            }
        }

        private var current: Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        private func hexValue(_ value: UInt32) -> UInt32? {
            switch value {
            case 0x30...0x39: value - 0x30
            case 0x41...0x46: value - 0x41 + 10
            case 0x61...0x66: value - 0x61 + 10
            default: nil
            }
        }

        private var invalidJSON: IrohProtocolError {
            .invalidMessage("body is not strict JSON")
        }
    }
}
