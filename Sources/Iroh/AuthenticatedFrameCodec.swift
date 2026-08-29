import CryptoKit
import Foundation

enum IrohAuthenticatedFrameCodec {
    private static let macPrefix = Data("pomodorough-iroh-frame-v1\0".utf8)

    static func encode(body: Data, roomSecret: Data) throws -> Data {
        guard roomSecret.count == 32,
              body.count <= IrohProtocolV1.maxFrameBodyBytes,
              body.count <= Int(UInt32.max) else {
            throw IrohProtocolError.invalidFrame
        }
        var authenticated = macPrefix
        authenticated.append(body)
        let mac = HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: roomSecret)
        )
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(contentsOf: mac)
        frame.append(body)
        return frame
    }

    static func decode(_ frame: Data, roomSecret: Data) throws -> Data {
        guard roomSecret.count == 32, frame.count >= 36 else {
            throw IrohProtocolError.invalidFrame
        }
        let lengthData = frame.prefix(4)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= IrohProtocolV1.maxFrameBodyBytes,
              frame.count == 36 + Int(length) else {
            throw IrohProtocolError.invalidFrame
        }
        let suppliedMAC = frame[4..<36]
        let body = Data(frame.dropFirst(36))
        var authenticated = macPrefix
        authenticated.append(body)
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: roomSecret)
        ))
        guard constantTimeEqual(Data(suppliedMAC), expectedMAC) else {
            throw IrohProtocolError.authenticationFailed
        }
        return body
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
