import CoreFoundation
import Foundation
import IrohLib

struct IrohRoomInvite: Equatable, Sendable {
    let roomID: String
    let roomName: String?
    let endpointTicket: String
    let endpointID: String
    let roomSecret: Data

    init(roomID: String, roomName: String?, endpointTicket: String, roomSecret: Data) throws {
        guard try IrohProtocolV1.roomID(for: roomSecret) == roomID else {
            throw IrohProtocolError.invalidInvite("room ID does not match room secret")
        }
        guard IrohProtocolV1.isValidDisplayName(roomName) else {
            throw IrohProtocolError.invalidInvite("room name must contain 1 through 64 Unicode scalars")
        }
        guard !endpointTicket.isEmpty,
              endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes else {
            throw IrohProtocolError.invalidInvite("endpoint ticket exceeds 16 KiB")
        }
        let endpointID = try IrohEndpointIdentity.endpointID(from: endpointTicket)
        self.roomID = roomID
        self.roomName = roomName
        self.endpointTicket = endpointTicket
        self.endpointID = endpointID
        self.roomSecret = roomSecret
    }

    func encoded() throws -> String {
        var object: [String: Any] = [
            "v": IrohProtocolV1.version,
            "roomId": roomID,
            "endpointTicket": endpointTicket,
            "roomSecret": Base64URL.encode(roomSecret)
        ]
        if let roomName { object["roomName"] = roomName }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return IrohProtocolV1.invitePrefix + Base64URL.encode(data)
    }

    static func decode(_ text: String) throws -> Self {
        guard text.hasPrefix(IrohProtocolV1.invitePrefix) else {
            throw IrohProtocolError.invalidInvite("expected \(IrohProtocolV1.invitePrefix) prefix")
        }
        let encoded = String(text.dropFirst(IrohProtocolV1.invitePrefix.count))
        let data = try Base64URL.decode(encoded)
        guard let object = try StrictJSON.object(from: data) else {
            throw IrohProtocolError.invalidInvite("payload must be a JSON object")
        }
        let required = Set(["v", "roomId", "endpointTicket", "roomSecret"])
        let allowed = required.union(["roomName"])
        guard required.isSubset(of: object.keys), Set(object.keys).isSubset(of: allowed) else {
            throw IrohProtocolError.invalidInvite("payload has missing or unknown fields")
        }
        guard let version = object["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == IrohProtocolV1.version,
              version.doubleValue == Double(version.intValue) else {
            throw IrohProtocolError.invalidInvite("unsupported version")
        }
        guard let roomID = object["roomId"] as? String,
              IrohProtocolV1.isValidRoomID(roomID),
              let endpointTicket = object["endpointTicket"] as? String,
              let secretText = object["roomSecret"] as? String else {
            throw IrohProtocolError.invalidInvite("payload field types are invalid")
        }
        if object.keys.contains("roomName"), object["roomName"] is NSNull {
            throw IrohProtocolError.invalidInvite("roomName must be omitted instead of null")
        }
        let roomName = object["roomName"] as? String
        let secret = try Base64URL.decode(secretText)
        guard secret.count == 32 else {
            throw IrohProtocolError.invalidInvite("room secret must be 32 bytes")
        }
        return try Self(
            roomID: roomID,
            roomName: roomName,
            endpointTicket: endpointTicket,
            roomSecret: secret
        )
    }
}
