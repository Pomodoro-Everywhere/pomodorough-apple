import CoreFoundation
import Foundation

enum IrohRPCMessageCodec {
    static func decode(_ data: Data) throws -> IrohRPCMessage {
        guard data.count <= IrohProtocolV1.maxFrameBodyBytes,
              let object = try StrictJSON.object(from: data),
              let kind = object["kind"] as? String else {
            throw IrohProtocolError.invalidMessage("body must be a JSON object with a kind")
        }
        try IrohRPCMessageValidation.validateEnvelope(object)
        switch kind {
        case "hello": return try decodeHello(data, object: object)
        case "inventory": return try decodeInventory(data, object: object)
        case "inventoryResult": return try decodeInventoryResult(data, object: object)
        case "operations": return try decodeOperations(data, object: object)
        case "operationsResult": return try decodeOperationsResult(data, object: object)
        case "error": return try decodeError(data, object: object)
        default:
            throw IrohProtocolError.invalidMessage("unknown message kind")
        }
    }

    private static func decodeHello(_ data: Data, object: [String: Any]) throws -> IrohRPCMessage {
        try IrohRPCMessageValidation.exactKeys(object, required: [
            "protocolVersion", "roomId", "requestId", "kind", "deviceId",
            "endpointTicket", "platform"
        ], optional: ["displayName"])
        let value = try JSONDecoder.api.decode(IrohHello.self, from: data)
        guard value.kind == "hello",
              IrohProtocolV1.isValidIdentifier(value.deviceId),
              value.endpointTicket.utf8.count <= IrohProtocolV1.maxEndpointTicketBytes,
              ["ios", "macos", "android", "linux", "windows"].contains(value.platform),
              IrohProtocolV1.isValidDisplayName(value.displayName) else {
            throw IrohProtocolError.invalidMessage("hello fields are invalid")
        }
        return .hello(value)
    }

    private static func decodeInventory(_ data: Data, object: [String: Any]) throws -> IrohRPCMessage {
        try IrohRPCMessageValidation.exactKeys(object, required: [
            "protocolVersion", "roomId", "requestId", "kind", "after", "limit"
        ])
        let value = try JSONDecoder.api.decode(IrohInventoryRequest.self, from: data)
        guard value.kind == "inventory", (1...IrohProtocolV1.maxInventoryEntries).contains(value.limit),
              value.after.map(IrohRPCMessageValidation.validCursor) ?? true else {
            throw IrohProtocolError.invalidMessage("inventory fields are invalid")
        }
        return .inventory(value)
    }

    private static func decodeInventoryResult(
        _ data: Data,
        object: [String: Any]
    ) throws -> IrohRPCMessage {
        try IrohRPCMessageValidation.exactKeys(object, required: [
            "protocolVersion", "roomId", "requestId", "kind", "entries", "next"
        ])
        try IrohRPCMessageValidation.validateInventoryEntries(object["entries"])
        let value = try JSONDecoder.api.decode(IrohInventoryResult.self, from: data)
        guard value.kind == "inventoryResult",
              value.entries.count <= IrohProtocolV1.maxInventoryEntries,
              value.next.map(IrohRPCMessageValidation.validCursor) ?? true,
              IrohRPCMessageValidation.entriesAreStrictlyOrdered(value.entries) else {
            throw IrohProtocolError.invalidMessage("inventory result is invalid")
        }
        return .inventoryResult(value)
    }

    private static func decodeOperations(_ data: Data, object: [String: Any]) throws -> IrohRPCMessage {
        try IrohRPCMessageValidation.exactKeys(object, required: [
            "protocolVersion", "roomId", "requestId", "kind", "refs"
        ])
        try IrohRPCMessageValidation.validateReferences(object["refs"])
        let value = try JSONDecoder.api.decode(IrohOperationsRequest.self, from: data)
        guard value.kind == "operations", !value.refs.isEmpty,
              value.refs.count <= IrohProtocolV1.maxOperationReferences,
              Set(value.refs).count == value.refs.count else {
            throw IrohProtocolError.invalidMessage("operation references are invalid")
        }
        return .operations(value)
    }

    private static func decodeOperationsResult(
        _ data: Data,
        object: [String: Any]
    ) throws -> IrohRPCMessage {
        try IrohRPCMessageValidation.exactKeys(object, required: [
            "protocolVersion", "roomId", "requestId", "kind", "records"
        ])
        try IrohRPCMessageValidation.validateRecordObjects(object["records"])
        let decoded = try JSONDecoder.api.decode(IrohOperationsResult.self, from: data)
        let rawRecords = try (object["records"] as? [Any] ?? []).map(IrohCanonicalRecordCodec.encodeJSONObject)
        guard rawRecords.count == decoded.records.count else {
            throw IrohProtocolError.invalidMessage("operations result records are invalid")
        }
        let value = IrohOperationsResult(
            protocolVersion: decoded.protocolVersion,
            roomId: decoded.roomId,
            requestId: decoded.requestId,
            kind: decoded.kind,
            records: zip(decoded.records, rawRecords).map { $0.preservingCanonicalBytes($1) }
        )
        guard value.kind == "operationsResult",
              value.records.count <= IrohProtocolV1.maxOperationReferences,
              value.records.allSatisfy(\.isValid) else {
            throw IrohProtocolError.invalidMessage("operation records are invalid")
        }
        for record in value.records where try record.operationByteCount() > IrohProtocolV1.maxOperationBytes {
            throw IrohProtocolError.limit("operation exceeds 64 KiB")
        }
        return .operationsResult(value)
    }

    private static func decodeError(_ data: Data, object: [String: Any]) throws -> IrohRPCMessage {
        try IrohRPCMessageValidation.exactKeys(object, required: [
            "protocolVersion", "roomId", "requestId", "kind", "code", "message", "retryable"
        ])
        let value = try JSONDecoder.api.decode(IrohErrorResponse.self, from: data)
        guard value.kind == "error", value.message.utf8.count <= 1_024 else {
            throw IrohProtocolError.invalidMessage("error response is invalid")
        }
        return .error(value)
    }

}
