import Foundation

/// A response that may carry the R55-C14 canonical HLC pair.
protocol CarriesCanonicalHeadPair: Decodable {}

/// R55-C14 receiver rule, lexical half. `JSONDecoder` reads `5.0`, `1e0` and `-0`
/// as `Int64`, so the raw response body is checked before decoding: each present
/// canonical field must be a plain JSON integer literal in 0...2^53-1, written
/// once. `null`, quoted numbers, floats, exponents, signs, booleans, objects and
/// arrays fail closed. Presence, pairing and the server bound stay with
/// `CanonicalHeadReceiverRule`, which runs during decoding.
enum CanonicalHeadLiteralRule {
    static let fieldNames: Set<String> = ["canonicalHlcWallMs", "canonicalHlcCounter"]

    static func validate(_ body: Data) throws {
        var scanner = TopLevelJSONMemberScanner(body)
        var seen: Set<String> = []
        while let member = try scanner.nextMember() {
            guard fieldNames.contains(member.name) else { continue }
            // Decoders disagree on which duplicate wins, so a repeated field fails closed.
            guard seen.insert(member.name).inserted else {
                throw rejection("\(member.name) must appear at most once.")
            }
            guard isSafeIntegerLiteral(member.rawValue) else {
                throw rejection("\(member.name) must be a JSON integer literal in 0...2^53-1.")
            }
        }
    }

    static func isSafeIntegerLiteral(_ raw: ArraySlice<UInt8>) -> Bool {
        guard let first = raw.first,
              raw.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              first != UInt8(ascii: "0") || raw.count == 1,
              let value = Int64(String(decoding: raw, as: UTF8.self)) else {
            return false
        }
        return WireBounds.containsUnsigned(value)
    }

    private static func rejection(_ description: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
    }
}

extension JSONDecoder {
    /// Decodes an API response body. Responses that may carry the canonical HLC
    /// pair pass the lexical receiver rule first.
    static func apiResponse<Response: Decodable>(_ type: Response.Type, from body: Data) throws -> Response {
        if type is CarriesCanonicalHeadPair.Type {
            try CanonicalHeadLiteralRule.validate(body)
        }
        return try api.decode(type, from: body)
    }
}
