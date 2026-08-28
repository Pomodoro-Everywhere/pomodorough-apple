import Foundation

enum IrohRPCMessage: Equatable, Sendable {
    case hello(IrohHello)
    case inventory(IrohInventoryRequest)
    case inventoryResult(IrohInventoryResult)
    case operations(IrohOperationsRequest)
    case operationsResult(IrohOperationsResult)
    case error(IrohErrorResponse)

    var requestID: String {
        switch self {
        case .hello(let value): value.requestId
        case .inventory(let value): value.requestId
        case .inventoryResult(let value): value.requestId
        case .operations(let value): value.requestId
        case .operationsResult(let value): value.requestId
        case .error(let value): value.requestId
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .hello(let value): try JSONEncoder.api.encode(value)
        case .inventory(let value): try JSONEncoder.api.encode(value)
        case .inventoryResult(let value): try JSONEncoder.api.encode(value)
        case .operations(let value): try JSONEncoder.api.encode(value)
        case .operationsResult(let value):
            try JSONSerialization.data(withJSONObject: [
                "protocolVersion": value.protocolVersion,
                "roomId": value.roomId,
                "requestId": value.requestId,
                "kind": value.kind,
                "records": try value.records.map {
                    try JSONSerialization.jsonObject(with: $0.canonicalBytes())
                }
            ])
        case .error(let value): try JSONEncoder.api.encode(value)
        }
    }
}
