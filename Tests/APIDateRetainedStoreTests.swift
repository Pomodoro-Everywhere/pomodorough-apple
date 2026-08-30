import Foundation
import Testing
@testable import Pomodorough

@Suite("API dates in retained room storage")
struct APIDateRetainedStoreTests {
    @Test(arguments: [
        "2026-08-30T17:32:56.578Z", "2026-08-30T17:33:04.836Z",
        "1969-12-31T23:59:59.578Z", "2000-12-31T23:59:59.002Z"
    ])
    func reopenAndRewritePreservesRetainedMetadata(timestamp: String) throws {
        let fixture = try DateStoreFixture()
        defer { fixture.removeDirectory() }
        try fixture.retainRooms()
        try fixture.seedMetadata(timestamp)
        let original = try fixture.persisted()
        let untouched = try fixture.roomBytes(at: 1)
        let originalCreatedAt = original.rooms[0].createdAt
        for _ in 0..<8 {
            let reopened = fixture.reopen()
            let joined = try reopened.activateExistingRoom(roomID: fixture.roomIDs[0], returnState: fixture.local)
            #expect(try fixture.persisted().rooms[0].createdAt == originalCreatedAt)
            #expect(try fixture.roomBytes(at: 1) == untouched)
            #expect(try fixture.creationTimestamp() == timestamp)
            #expect(try reopened.captureAndSuspendActiveRoom(from: joined) == fixture.local)
            let retained = try fixture.persisted()
            #expect(retained == original)
            #expect(retained.rooms[0].records == original.rooms[0].records)
            #expect(try fixture.roomBytes(at: 1) == untouched)
            #expect(fixture.reopen().activeRoomID == nil)
        }
    }
}

private final class DateStoreFixture {
    static let now = Date(timeIntervalSince1970: 1_720_123_400)
    let directory: URL
    let fileURL: URL
    let vault = DateStoreVault()
    let secrets = [Data(repeating: 43, count: 32), Data(repeating: 59, count: 32)]
    let roomIDs: [String]
    let local: PersistedTimerState

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("api-date-store-\(UUID())")
        fileURL = directory.appendingPathComponent("rooms.json")
        roomIDs = try secrets.map { try IrohProtocolV1.roomID(for: $0) }
        var state = PersistedTimerState.fresh()
        state.deviceId = "date-codec-device01"
        local = state
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func removeDirectory() {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Could not remove private date fixture: \(error)") }
    }

    func reopen() -> IrohRoomStore {
        IrohRoomStore(fileURL: fileURL, secretStore: vault, now: { Self.now })
    }

    func retainRooms() throws {
        let store = reopen()
        for index in roomIDs.indices {
            let active = try store.createRoom(roomID: roomIDs[index], roomSecret: secrets[index],
                name: "Date room \(index)", returnState: local, genesis: genesis(), now: Self.now)
            try store.upsertPeer(IrohPeer(endpointID: "date-codec-peer01", endpointTicket: "date-codec-ticket01",
                deviceID: "date-peer-device01", displayName: "Retained peer", lastSeenAt: Self.now),
                roomID: roomIDs[index])
            _ = try store.captureAndSuspendActiveRoom(from: active)
        }
        let active = try store.activateExistingRoom(roomID: roomIDs[0], returnState: local)
        _ = try store.captureAndSuspendActiveRoom(from: active)
    }

    func genesis() throws -> IrohGenesis {
        let task = try #require(FocusTask(title: "Retained date task"))
        let history = HistoryItem(id: "date-history01", timerId: "date-timer01", commandId: nil,
            taskId: task.id.uuidString.lowercased(), phase: .focus, status: "completed",
            plannedDurationMs: 120_000, completedAt: Self.now.addingTimeInterval(-60),
            endedAt: Self.now.addingTimeInterval(-60))
        return IrohGenesis(canonicalTimer: nil, history: [history], tasks: [task], durationsMs: .defaults,
            autoStartBreaks: false, selectedTaskId: task.id.uuidString.lowercased(),
            hlcWallMs: 1_720_123_400_000, hlcCounter: 1)
    }

    func persisted() throws -> IrohReplicationState {
        try JSONDecoder.api.decode(IrohReplicationState.self, from: Data(contentsOf: fileURL))
    }

    func object() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    }

    func seedMetadata(_ timestamp: String) throws {
        var document = try object()
        var rooms = try #require(document["rooms"] as? [[String: Any]])
        for index in rooms.indices {
            rooms[index]["createdAt"] = timestamp
            var peers = try #require(rooms[index]["peers"] as? [[String: Any]])
            peers[0]["lastSeenAt"] = timestamp
            rooms[index]["peers"] = peers
        }
        document["rooms"] = rooms
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: fileURL)
    }

    func roomBytes(at index: Int) throws -> Data {
        let rooms = try #require(object()["rooms"] as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: rooms[index], options: [.sortedKeys])
    }

    func creationTimestamp() throws -> String {
        let rooms = try #require(object()["rooms"] as? [[String: Any]])
        return try #require(rooms[0]["createdAt"] as? String)
    }
}

private final class DateStoreVault: IrohRoomSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    func load(roomID: String) throws -> Data? { lock.withLock { secrets[roomID] } }
    func save(_ secret: Data, roomID: String) throws { lock.withLock { secrets[roomID] = secret } }
    func delete(roomID: String) throws { lock.withLock { secrets[roomID] = nil } }
    func accountDeletionAccounts() throws -> [String] { throw CocoaError(.featureUnsupported) }
    func deleteAccount(named account: String) throws { throw CocoaError(.featureUnsupported) }
}
