import Foundation
import IrohLib
import Testing
@testable import Pomodorough

@Suite("Iroh protocol compatibility")
struct IrohProtocolCompatibilityTests {
    @Test func wireConstantsAndCanonicalBase64StayStable() throws {
        #expect(IrohProtocolV1.version == 1)
        #expect(IrohProtocolV1.alpn == Data("me.egigoka.pomodorough/sync/1".utf8))
        #expect(IrohProtocolV1.invitePrefix == "pomodorough1.")
        #expect(IrohProtocolV1.maxFrameBodyBytes == 16 * 1_024 * 1_024)
        #expect(IrohProtocolV1.maxOperationBytes == 64 * 1_024)
        #expect(IrohProtocolV1.maxEndpointTicketBytes == 16 * 1_024)
        #expect(IrohProtocolV1.maxInventoryEntries == 1_024)
        #expect(IrohProtocolV1.maxOperationReferences == 255)
        #expect(IrohProtocolV1.maxPeers == 64)

        let bytes = Data([0, 255, 128, 127, 255])
        #expect(Base64URL.encode(bytes) == "AP-Af_8")
        #expect(try Base64URL.decode("AP-Af_8") == bytes)
    }

    @Test func invitePreservesExactSortedJSONBytesAndEndpointIdentity() async throws {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            secretKey: Data(repeating: 7, count: 32),
            relayMode: RelayMode.disabled()
        ))
        let ticket = try EndpointTicket.fromAddr(addr: endpoint.addr()).description
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        let invite = try IrohRoomInvite(
            roomID: roomID,
            roomName: "Protocol Room",
            endpointTicket: ticket,
            roomSecret: secret
        )
        let expectedJSONString = "{\"endpointTicket\":\"\(ticket)\",\"roomId\":\"\(roomID)\"," +
            "\"roomName\":\"Protocol Room\",\"roomSecret\":" +
            "\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8\",\"v\":1}"
        let expectedJSON = Data(expectedJSONString.utf8) // gitleaks:allow -- public protocol vector

        let encoded = try invite.encoded()
        #expect(encoded == IrohProtocolV1.invitePrefix + Base64URL.encode(expectedJSON))
        #expect(try IrohRoomInvite.decode(encoded) == invite)
        #expect(invite.endpointID == endpoint.id().description)
        #expect(try IrohEndpointIdentity.endpointID(from: ticket) == invite.endpointID)
        #expect(try IrohEndpointIdentity.ticket(ticket, identifies: invite.endpointID))

        try await endpoint.close()
    }

    @Test func RPCRequestMessagesPreserveEnvelopeAndPayloadKeys() throws {
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        try assertMessageKeys(.hello(IrohHello(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "hello",
            deviceId: "device-test0001",
            endpointTicket: "endpoint-ticket",
            platform: "ios",
            displayName: nil
        )), ["protocolVersion", "roomId", "requestId", "kind", "deviceId", "endpointTicket", "platform"])
        try assertMessageKeys(.inventory(IrohInventoryRequest(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "inventory",
            after: nil,
            limit: 1
        )), ["protocolVersion", "roomId", "requestId", "kind", "after", "limit"])
        try assertMessageKeys(.operations(IrohOperationsRequest(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "operations",
            refs: [.init(domain: .genesis, id: "genesis")]
        )), ["protocolVersion", "roomId", "requestId", "kind", "refs"])
    }

    @Test func RPCResponseMessagesPreserveEnvelopeAndPayloadKeys() throws {
        let roomID = try IrohProtocolV1.roomID(for: Data(0...31))
        let requestID = try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000))
        try assertMessageKeys(.inventoryResult(IrohInventoryResult(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "inventoryResult",
            entries: [],
            next: nil
        )), ["protocolVersion", "roomId", "requestId", "kind", "entries", "next"])
        try assertMessageKeys(.operationsResult(IrohOperationsResult(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "operationsResult",
            records: []
        )), ["protocolVersion", "roomId", "requestId", "kind", "records"])
        try assertMessageKeys(.error(IrohErrorResponse(
            protocolVersion: 1,
            roomId: roomID,
            requestId: requestID,
            kind: "error",
            code: .notFound,
            message: "missing",
            retryable: false
        )), ["protocolVersion", "roomId", "requestId", "kind", "code", "message", "retryable"])
    }

    @Test func canonicalJSONPreservesUTF16KeyOrderAndGenesisNormalization() throws {
        let canonical = try JSONCanonicalizer.encodeJSONObject([
            "\u{E000}": 2,
            "\u{10000}": 1
        ])
        #expect(canonical == Data("{\"\u{10000}\":1,\"\u{E000}\":2}".utf8))
        #expect(try IrohCanonicalRecordCodec.encodeJSONObject([
            "\u{E000}": 2,
            "\u{10000}": 1
        ]) == canonical)

        let timer = CanonicalTimer(
            id: "timer-genesis0001",
            taskId: nil,
            phase: .focus,
            status: .running,
            plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 0,
            anchorAt: Date(timeIntervalSince1970: 1_000),
            startedByDeviceId: "device-start0001",
            lastIntent: TimerIntent(
                type: .start,
                commandId: "command-start0001",
                occurredAt: Date(timeIntervalSince1970: 1_000),
                deviceId: "device-intent0001"
            )
        )
        let record = IrohOperationRecord(
            domain: .genesis,
            deviceId: "device-wrapper0001",
            payload: .genesis(IrohGenesis(
                canonicalTimer: timer,
                history: [],
                tasks: [],
                durationsMs: .defaults,
                autoStartBreaks: false,
                hlcWallMs: 0,
                hlcCounter: 0
            ))
        )
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(record)) as? [String: Any]
        )
        let canonicalObject = try #require(
            JSONSerialization.jsonObject(with: record.canonicalBytes()) as? [String: Any]
        )

        #expect(intentDeviceID(in: encoded) == "device-intent0001")
        #expect(intentDeviceID(in: canonicalObject) == nil)
        #expect(canonicalObject["deviceId"] as? String == "device-wrapper0001")
    }

    @Test func endpointLifecycleKeepsIdempotentGenerationSemantics() {
        var lifecycle = IrohEndpointLifecycle()
        #expect(lifecycle.setActive(false) == 0)
        #expect(!lifecycle.owns(0))
        #expect(lifecycle.setActive(true) == 1)
        #expect(lifecycle.setActive(true) == 1)
        #expect(lifecycle.owns(1))
        #expect(lifecycle.setActive(false) == 2)
        #expect(lifecycle.setActive(false) == 2)
        #expect(!lifecycle.owns(1))
        #expect(!lifecycle.owns(2))
    }

    private func assertMessageKeys(_ message: IrohRPCMessage, _ expectedKeys: Set<String>) throws {
        let data = try message.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == expectedKeys)
        #expect(try IrohMessageCodec.decode(data) == message)
        #expect(try IrohRPCMessageCodec.decode(data) == message)
    }

    private func intentDeviceID(in record: [String: Any]) -> String? {
        let operation = record["operation"] as? [String: Any]
        let timer = operation?["canonicalTimer"] as? [String: Any]
        let intent = timer?["lastIntent"] as? [String: Any]
        return intent?["deviceId"] as? String
    }

}
