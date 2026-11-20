import Foundation

/// Walks the members of a top-level JSON object and yields each member name with
/// the raw bytes of its value. Nested values are skipped without being
/// interpreted; full validation stays with `JSONDecoder`, which runs afterwards.
struct TopLevelJSONMemberScanner {
    struct Member {
        let name: String
        let rawValue: ArraySlice<UInt8>
    }

    private let bytes: [UInt8]
    private var index = 0
    private var openedObject = false
    private var finished = false

    init(_ body: Data) {
        bytes = Array(body)
    }

    mutating func nextMember() throws -> Member? {
        guard !finished, try moveToNextName() else {
            finished = true
            return nil
        }
        let name = try readName()
        skipWhitespace()
        try consume(UInt8(ascii: ":"))
        skipWhitespace()
        let start = index
        try skipValue()
        var end = index
        while end > start, Self.isWhitespace(bytes[end - 1]) { end -= 1 }
        return Member(name: name, rawValue: bytes[start..<end])
    }

    /// Returns false at the closing brace of the top-level object.
    private mutating func moveToNextName() throws -> Bool {
        skipWhitespace()
        if !openedObject {
            try consume(UInt8(ascii: "{"))
            openedObject = true
            skipWhitespace()
            return peek != UInt8(ascii: "}")
        }
        guard peek != UInt8(ascii: "}") else { return false }
        try consume(UInt8(ascii: ","))
        skipWhitespace()
        return true
    }

    private mutating func readName() throws -> String {
        let start = index
        try skipString()
        let quoted = bytes[start..<index]
        guard quoted.contains(UInt8(ascii: "\\")) else {
            return String(decoding: quoted.dropFirst().dropLast(), as: UTF8.self)
        }
        // Escaped names are decoded the way JSONDecoder reads keys, so a
        // `\u0057`-style spelling cannot slip past the comparison.
        return try JSONDecoder().decode(String.self, from: Data(quoted))
    }

    private mutating func skipValue() throws {
        switch peek {
        case UInt8(ascii: "\""):
            try skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            try skipComposite()
        default:
            while let byte = peek, !Self.endsScalar(byte) { index += 1 }
        }
    }

    private mutating func skipComposite() throws {
        var depth = 0
        while let byte = peek {
            if byte == UInt8(ascii: "\"") {
                try skipString()
                continue
            }
            index += 1
            depth += Self.depthChange(byte)
            if depth == 0 { return }
        }
        throw Self.malformed("JSON value is not terminated.")
    }

    private mutating func skipString() throws {
        try consume(UInt8(ascii: "\""))
        while let byte = peek {
            index += byte == UInt8(ascii: "\\") ? 2 : 1
            if byte == UInt8(ascii: "\"") { return }
        }
        throw Self.malformed("JSON string is not terminated.")
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard peek == expected else {
            throw Self.malformed("Expected '\(Character(UnicodeScalar(expected)))' in JSON object.")
        }
        index += 1
    }

    private mutating func skipWhitespace() {
        while let byte = peek, Self.isWhitespace(byte) { index += 1 }
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func depthChange(_ byte: UInt8) -> Int {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "["): 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"): -1
        default: 0
        }
    }

    private static func endsScalar(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func malformed(_ description: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
    }
}
