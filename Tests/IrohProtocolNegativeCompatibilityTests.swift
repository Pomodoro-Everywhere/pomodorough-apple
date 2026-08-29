import Foundation
import Testing
@testable import Pomodorough

@Suite("Iroh protocol negative compatibility")
struct IrohProtocolNegativeCompatibilityTests {
    @Test func base64RejectsNonCanonicalAlphabetBeforeDecode() {
        #expect(protocolErrorSignature { _ = try Base64URL.decode("AP-Af_8=") }
            == "invalidInvite:malformed base64url")
    }

    @Test func inviteValidationKeepsStructuralErrorsBeforeFieldErrors() throws {
        let missingFields = IrohProtocolV1.invitePrefix
            + Base64URL.encode(Data(#"{"v":false}"#.utf8))
        #expect(protocolErrorSignature { _ = try IrohRoomInvite.decode(missingFields) }
            == "invalidInvite:payload has missing or unknown fields")

        let invalidTypes = IrohProtocolV1.invitePrefix + Base64URL.encode(Data(
            #"{"endpointTicket":"bad","roomId":false,"roomSecret":"not+base64","v":1}"#.utf8
        ))
        #expect(protocolErrorSignature { _ = try IrohRoomInvite.decode(invalidTypes) }
            == "invalidInvite:payload field types are invalid")
        #expect(protocolErrorSignature { _ = try IrohEndpointIdentity.endpointID(from: "bad") }
            == "invalidInvite:endpoint ticket is malformed")
    }

    @Test func authenticatedFrameKeepsErrorOrdering() throws {
        let secret = Data(0...31)
        let frame = try IrohAuthenticatedFrameCodec.encode(body: Data("x".utf8), roomSecret: secret)

        var wrongLength = frame
        wrongLength[3] = 2
        #expect(protocolErrorSignature { _ = try IrohFrameCodec.decode(wrongLength, roomSecret: secret) }
            == "invalidFrame")

        var wrongMAC = frame
        wrongMAC[4] ^= 1
        #expect(protocolErrorSignature { _ = try IrohFrameCodec.decode(wrongMAC, roomSecret: secret) }
            == "authenticationFailed")
        #expect(protocolErrorSignature { _ = try IrohFrameCodec.decode(wrongMAC, roomSecret: Data()) }
            == "invalidFrame")
    }

    @Test func RPCValidationKeepsEnvelopeAndRecordStructureOrdering() throws {
        let invalidEnvelope = Data(
            #"{"kind":"unknown","protocolVersion":false,"requestId":"bad","roomId":"bad"}"#.utf8
        )
        #expect(protocolErrorSignature { _ = try IrohMessageCodec.decode(invalidEnvelope) }
            == "invalidMessage:envelope is invalid")

        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        let missingSelectedTaskID = Data("""
        {
          "protocolVersion": 1,
          "roomId": "\(roomID)",
          "requestId": "\(requestID)",
          "kind": "operationsResult",
          "records": [{
            "domain": "selectedTask",
            "deviceId": "device-test0001",
            "operation": {
              "id": "selected-task-operation-test0001",
              "occurredAt": "1970-01-01T00:00:00Z",
              "hlcWallMs": 0,
              "hlcCounter": 0
            }
          }]
        }
        """.utf8)
        #expect(protocolErrorSignature { _ = try IrohMessageCodec.decode(missingSelectedTaskID) }
            == "invalidMessage:message has missing or unknown fields")
    }

    private func protocolErrorSignature(_ operation: () throws -> Void) -> String {
        do {
            try operation()
            return "none"
        } catch IrohProtocolError.invalidInvite(let reason) {
            return "invalidInvite:\(reason)"
        } catch IrohProtocolError.invalidFrame {
            return "invalidFrame"
        } catch IrohProtocolError.authenticationFailed {
            return "authenticationFailed"
        } catch IrohProtocolError.wrongRoom {
            return "wrongRoom"
        } catch IrohProtocolError.invalidMessage(let reason) {
            return "invalidMessage:\(reason)"
        } catch IrohProtocolError.immutableConflict {
            return "immutableConflict"
        } catch IrohProtocolError.limit(let reason) {
            return "limit:\(reason)"
        } catch IrohProtocolError.notFound {
            return "notFound"
        } catch IrohProtocolError.unavailable(let reason) {
            return "unavailable:\(reason)"
        } catch {
            return "unexpected:\(error)"
        }
    }
}
