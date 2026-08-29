import Foundation
import IrohLib

enum IrohEndpointIdentity {
    static func endpointID(from endpointTicket: String) throws -> String {
        let ticket: EndpointTicket
        do {
            ticket = try EndpointTicket.fromString(str: endpointTicket)
        } catch {
            throw IrohProtocolError.invalidInvite("endpoint ticket is malformed")
        }
        return endpointID(from: ticket)
    }

    static func endpointID(from ticket: EndpointTicket) -> String {
        ticket.endpointAddr().id().description
    }

    static func ticket(_ endpointTicket: String, identifies endpointID: String) throws -> Bool {
        try self.endpointID(from: endpointTicket) == endpointID
    }
}

struct IrohEndpointLifecycle: Sendable {
    private(set) var generation = 0
    private(set) var isActive = false

    mutating func setActive(_ active: Bool) -> Int {
        guard active != isActive else { return generation }
        generation += 1
        isActive = active
        return generation
    }

    func owns(_ candidate: Int) -> Bool {
        isActive && candidate == generation
    }
}
