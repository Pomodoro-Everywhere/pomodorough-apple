import Foundation
import Testing
@testable import Pomodorough

@Suite("SSE revision stream limits")
struct SSERevisionStreamLimitsTests {
    @Test
    func defaultLimitsRemainFrozen() {
        #expect(SSERevisionStreamDecoder.maximumLineBytes == 65_536)
        #expect(SSERevisionStreamDecoder.maximumEventBytes == 262_144)
    }

    @Test
    func normalEventsDecodeAcrossSupportedForms() throws {
        let source = ": keepalive\r\nevent: revision\r\ndata: 41\r\n\r\ndata: {\"revision\":42}\n\n"

        #expect(try decode(source) == [41, 42])
    }

    @Test
    func lineLimitAcceptsExactBoundaryIncludingCRLF() throws {
        #expect(try decode("data: 1\r\n\r\n", lineLimit: 7) == [1])
    }

    @Test
    func oversizedLineFailsBeforeAdditionalByteIsBuffered() {
        var decoder = SSERevisionStreamDecoder(lineLimit: 7, eventLimit: 64)

        #expect(decodingError("data: 12", decoder: &decoder) == .lineLimitExceeded)
    }

    @Test
    func carriageReturnCountsTowardLimitWithoutLineFeed() {
        var decoder = SSERevisionStreamDecoder(lineLimit: 7, eventLimit: 64)

        #expect(decodingError("data: 1\rx", decoder: &decoder) == .lineLimitExceeded)
    }

    @Test
    func accumulatedEventAcceptsExactBoundary() throws {
        let first = "{\"revision\":"
        let second = "42}"
        let source = "data: \(first)\ndata: \(second)\n\n"
        let boundary = "data: \(first)".utf8.count + "data: \(second)".utf8.count

        #expect(try decode(source, eventLimit: boundary) == [42])
    }

    @Test
    func eventLimitRejectsFirstIllegalByte() {
        var decoder = SSERevisionStreamDecoder(lineLimit: 64, eventLimit: 10)

        #expect(decodingError(": a\ndata: 1", decoder: &decoder) == nil)
        #expect(decodingError("x", decoder: &decoder) == .eventLimitExceeded)
    }

    @Test
    func oversizedEventWithoutFinalNewlineFailsBeforeEOF() {
        var decoder = SSERevisionStreamDecoder(lineLimit: 64, eventLimit: 7)

        #expect(decodingError("data: 12", decoder: &decoder) == .eventLimitExceeded)
    }

    @Test
    func eventLimitTracksIncrementalChunkSplits() {
        var decoder = SSERevisionStreamDecoder(lineLimit: 64, eventLimit: 11)

        for chunk in [": ", "ok\n", "da", "ta: ", "1"] {
            #expect(decodingError(chunk, decoder: &decoder) == nil)
        }
        #expect(decodingError("x", decoder: &decoder) == .eventLimitExceeded)
    }

    @Test
    func exactEventBoundaryExcludesSplitCRLFBytes() throws {
        var decoder = SSERevisionStreamDecoder(lineLimit: 64, eventLimit: 10)

        #expect(try decode(": a\r", decoder: &decoder).isEmpty)
        #expect(try decode("\ndata: 1\r", decoder: &decoder).isEmpty)
        #expect(try decode("\n\r", decoder: &decoder).isEmpty)
        #expect(try decode("\n", decoder: &decoder) == [1])
    }

    @Test
    func multibytePayloadDecodesAtExactByteLimitsAcrossScalarChunks() throws {
        let comment = ": café"
        let dataLine = "data: {\"revision\":43,\"label\":\"café 🍅\"}"
        let source = Data("\(comment)\n\(dataLine)\n\n".utf8)
        let chunks = try chunksSplittingScalar(source, scalar: "🍅")
        var decoder = SSERevisionStreamDecoder(
            lineLimit: dataLine.utf8.count,
            eventLimit: comment.utf8.count + dataLine.utf8.count
        )

        #expect(try decode(chunks, decoder: &decoder) == [43])
    }

    @Test
    func multibyteLineLimitRejectsContinuationByteBeyondBoundary() {
        let line = ": 🍅"
        let bytes = Data(line.utf8)
        let byteLimit = line.count
        var decoder = SSERevisionStreamDecoder(lineLimit: byteLimit, eventLimit: 64)

        #expect(bytes.count == 6)
        #expect(decodingError(Data(bytes.prefix(byteLimit)), decoder: &decoder) == nil)
        #expect(decodingError(nextByte(bytes, after: byteLimit), decoder: &decoder) == .lineLimitExceeded)
    }

    @Test
    func multibyteEventLimitRejectsContinuationByteBeyondBoundary() {
        let firstLine = ": café"
        let secondLine = "data: 🍅"
        let secondLineBytes = Data(secondLine.utf8)
        let permittedSecondLineBytes = secondLine.count
        let eventLimit = firstLine.utf8.count + permittedSecondLineBytes
        var decoder = SSERevisionStreamDecoder(lineLimit: 64, eventLimit: eventLimit)

        #expect(secondLineBytes.count > permittedSecondLineBytes)
        #expect(decodingError("\(firstLine)\n", decoder: &decoder) == nil)
        #expect(decodingError(Data(secondLineBytes.prefix(permittedSecondLineBytes)), decoder: &decoder) == nil)
        #expect(decodingError(
            nextByte(secondLineBytes, after: permittedSecondLineBytes), decoder: &decoder
        ) == .eventLimitExceeded)
    }

    @Test
    func pendingCarriageReturnCountsWhenNotFollowedByLineFeed() {
        var decoder = SSERevisionStreamDecoder(lineLimit: 64, eventLimit: 7)

        #expect(decodingError("data: 1\r", decoder: &decoder) == nil)
        #expect(decodingError("x", decoder: &decoder) == .eventLimitExceeded)
    }

    @Test
    func maximumEventRejectsByteAfterExactDefaultBoundary() {
        var decoder = SSERevisionStreamDecoder()
        var commentLine = Data(repeating: 0x61, count: SSERevisionStreamDecoder.maximumLineBytes)
        commentLine[0] = 0x3A

        for _ in 0..<4 {
            #expect(decodingError(commentLine, decoder: &decoder) == nil)
            #expect(decodingError("\r\n", decoder: &decoder) == nil)
        }
        #expect(decodingError("x", decoder: &decoder) == .eventLimitExceeded)
    }

    @Test @MainActor
    func oversizedStreamFailureUsesExistingRetryWithoutUnauthorizedOperation() async {
        let sleeps = LockedTestValue<[Duration]>([])
        let requests = LockedTestValue(0)
        let operations = LockedTestValue<[RoomReplicationOperation]>([])
        let controller = makeController(sleeps: sleeps, requests: requests, operations: operations)
        controller.setSceneActive(true, environment: .init(
            deviceID: "sse-limit-device", displayName: nil, platform: "macos"
        ))

        controller.startRevisionStream()
        await waitUntil { !sleeps.value.isEmpty }

        #expect(requests.value == 1)
        #expect(sleeps.value == [.seconds(1)])
        #expect(operations.value.isEmpty)
    }

    private func decode(
        _ source: String,
        lineLimit: Int = SSERevisionStreamDecoder.maximumLineBytes,
        eventLimit: Int = SSERevisionStreamDecoder.maximumEventBytes
    ) throws -> [Int64] {
        var decoder = SSERevisionStreamDecoder(lineLimit: lineLimit, eventLimit: eventLimit)
        return try decode(source, decoder: &decoder)
    }

    private func decode(
        _ source: String,
        decoder: inout SSERevisionStreamDecoder
    ) throws -> [Int64] {
        try decode([Data(source.utf8)], decoder: &decoder)
    }

    private func decode(
        _ chunks: [Data],
        decoder: inout SSERevisionStreamDecoder
    ) throws -> [Int64] {
        var revisions: [Int64] = []
        for chunk in chunks {
            for byte in chunk {
                if let revision = try decoder.consume(byte: byte) { revisions.append(revision) }
            }
        }
        return revisions
    }

    private func chunksSplittingScalar(_ source: Data, scalar: String) throws -> [Data] {
        let scalarBytes = Data(scalar.utf8)
        let range = try #require(source.range(of: scalarBytes))
        let firstBoundary = range.lowerBound + 1
        let secondBoundary = range.upperBound - 1
        return [
            Data(source[..<firstBoundary]),
            Data(source[firstBoundary..<secondBoundary]),
            Data(source[secondBoundary...])
        ]
    }

    private func nextByte(_ source: Data, after prefixCount: Int) -> Data {
        Data(source.dropFirst(prefixCount).prefix(1))
    }

    private func decodingError(
        _ source: String,
        decoder: inout SSERevisionStreamDecoder
    ) -> SSERevisionStreamError? {
        decodingError(Data(source.utf8), decoder: &decoder)
    }

    private func decodingError(
        _ source: Data,
        decoder: inout SSERevisionStreamDecoder
    ) -> SSERevisionStreamError? {
        do {
            for byte in source { _ = try decoder.consume(byte: byte) }
            return nil
        } catch let error as SSERevisionStreamError {
            return error
        } catch {
            return nil
        }
    }

    @MainActor
    private func makeController(
        sleeps: LockedTestValue<[Duration]>,
        requests: LockedTestValue<Int>,
        operations: LockedTestValue<[RoomReplicationOperation]>
    ) -> RoomReplicationController {
        let store = IrohRoomStore(
            fileURL: temporaryURL(), secretStore: MemoryIrohRoomSecretStore()
        )
        let service = SSELimitRoomService()
        return RoomReplicationController(mode: .centralized, dependencies: .init(
            roomStore: store, retryDelay: .seconds(5),
            centralizedState: { Self.centralizedState },
            workspaceSnapshot: { Self.workspace },
            revisionEvents: {
                requests.value += 1
                return AsyncThrowingStream { $0.finish(throwing: SSERevisionStreamError.lineLimitExceeded) }
            },
            sleep: { duration in sleeps.value.append(duration); throw CancellationError() },
            secureRandomBytes: { Data(repeating: 0, count: $0) },
            encodeInvite: { _, _, _, _ in "unused" },
            makeService: { _ in service }
        ), eventHandler: { _ in }, operationHandler: { operations.value.append($0) })
    }

    private static var centralizedState: RoomReplicationCentralizedState {
        .init(sessionGeneration: 7, isSignedIn: true, isWorkspaceMutationBlocked: false,
            isSessionVerified: true, localRevision: 0, isSyncing: false,
            isTimerActive: false, isHistoryResolutionBlocking: false)
    }

    private static var workspace: RoomReplicationWorkspaceSnapshot {
        let state = PersistedTimerState.fresh()
        return .init(state: state, genesis: .init(
            canonicalTimer: state.canonicalTimer, history: state.history, tasks: state.tasks,
            durationsMs: state.settings.durationsMs, autoStartBreaks: state.autoStartBreaks,
            selectedTaskId: state.selectedTaskID?.uuidString.lowercased(),
            hlcWallMs: state.hlcWallMs, hlcCounter: state.hlcCounter
        ))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SSERevisionStreamLimits-\(UUID().uuidString)")
            .appendingPathComponent("rooms.json")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }
}

private actor SSELimitRoomService: RoomReplicationServing {
    func start(_ context: IrohServiceContext) async throws -> String { "unused" }
    func stop() async {}
    func currentEndpointTicket() async throws -> String { "unused" }
    func syncNow() async {}
    func markConflict(roomID: String?) async {}
    func join(invite: IrohRoomInvite) async throws {}
}
