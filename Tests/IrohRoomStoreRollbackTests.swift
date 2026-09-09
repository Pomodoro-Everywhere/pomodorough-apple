import Foundation
import Testing
@testable import Pomodorough

// AP54: a failed createRoom must not orphan its keychain secret silently.
@Suite("Room store create rollback")
struct IrohRoomStoreRollbackTests {
    @Test
    func rollbackDeleteFailureCapturesAndLeavesOrphanVisible() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("block".utf8).write(to: blocker)
        let secrets = MemoryIrohRoomSecretStore()
        let store = IrohRoomStore(
            fileURL: blocker.appendingPathComponent("rooms.json"),
            secretStore: secrets
        )
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        secrets.setDeleteFailure(true, roomID: roomID)
        #expect(throws: (any Error).self) {
            try store.createRoom(
                roomID: roomID,
                roomSecret: secret,
                name: "Rollback room",
                returnState: .fresh(),
                genesis: Self.genesis()
            )
        }
        #expect(secrets.contains(roomID: roomID))
        #expect(recorded.value.count == 1)
    }

    @Test
    func rollbackDeleteSuccessLeavesNoOrphanAndNoCapture() throws {
        let recorded = LockedTestValue<[String]>([])
        SentryCapture.setTestBackend { error in
            var current = recorded.value
            current.append(error.localizedDescription)
            recorded.value = current
        }
        defer { SentryCapture.resetForTesting() }
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("block".utf8).write(to: blocker)
        let secrets = MemoryIrohRoomSecretStore()
        let store = IrohRoomStore(
            fileURL: blocker.appendingPathComponent("rooms.json"),
            secretStore: secrets
        )
        let secret = Data(0...31)
        let roomID = try IrohProtocolV1.roomID(for: secret)
        #expect(throws: (any Error).self) {
            try store.createRoom(
                roomID: roomID,
                roomSecret: secret,
                name: "Rollback room",
                returnState: .fresh(),
                genesis: Self.genesis()
            )
        }
        #expect(!secrets.contains(roomID: roomID))
        #expect(recorded.value.isEmpty)
    }

    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IrohRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func genesis() -> IrohGenesis {
        IrohGenesis(
            canonicalTimer: nil,
            history: [],
            tasks: [],
            durationsMs: .defaults,
            autoStartBreaks: false,
            hlcWallMs: 0,
            hlcCounter: 0
        )
    }
}
