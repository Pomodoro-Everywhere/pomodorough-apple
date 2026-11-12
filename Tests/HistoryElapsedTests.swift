import Foundation
import Testing
@testable import Pomodorough

/// UX round 2 batch C: history rows carry the time Core counted (`elapsedMs`,
/// pauses excluded). The client reads it and never derives or defaults it.
/// The tests read `elapsedMs` through JSON so they also build on the batch B
/// tree, where they fail on their assertions.
@Suite("History elapsed time", .serialized)
@MainActor
struct HistoryElapsedTests {
    @Test func pausedFinishKeepsTheElapsedTimeCoreStoredAtThePause() throws {
        let fixture = try ElapsedModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(model.start())
        fixture.clock.elapsed = 1
        #expect(model.pause())
        fixture.clock.elapsed = 59
        #expect(model.finish())

        let timer = try #require(model.canonicalTimer)
        #expect(timer.status == .completed)
        #expect(timer.elapsedAtAnchorMs == 1_000)
        let row = try #require(try ElapsedJSON.rows(model.history).first)
        #expect(row["status"] as? String == "completed")
        #expect(ElapsedJSON.elapsed(row) == 1_000)
    }

    @Test func irohPausedFinishKeepsTheElapsedTimeCoreStoredAtThePause() throws {
        let fixture = try ElapsedModelFixture()
        defer { fixture.cleanUp() }
        try fixture.seedIrohRunningTimer()
        let model = fixture.makeModel()
        fixture.clock.elapsed = 1
        #expect(model.pause())
        fixture.clock.elapsed = 59
        #expect(model.finish())

        let roomTimer = try #require(fixture.roomStore.activeRoomState?.canonicalTimer)
        #expect(roomTimer.status == .completed)
        #expect(roomTimer.elapsedAtAnchorMs == 1_000)
        #expect(model.canonicalTimer?.elapsedAtAnchorMs == 1_000)
        let row = try #require(try ElapsedJSON.rows(model.history).first)
        #expect(ElapsedJSON.elapsed(row) == 1_000)
    }

    @Test func earlyFinishShowsItsRealTimeInHistoryAndTotals() throws {
        let fixture = try ElapsedModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        let planned = DurationValues.defaults.focus
        #expect(model.start())
        fixture.clock.elapsed = 7 * 60
        #expect(model.finish())

        let item = try #require(model.history.first)
        #expect(ElapsedJSON.elapsed(try #require(try ElapsedJSON.rows(model.history).first)) == 420_000)
        #expect(item.plannedDurationMs == planned)
        #expect(item.statusText == String(localized: "Finished early"))
        #expect(item.durationText == TaskTimeText.shortMinutes(7))
        #expect(item.spokenDurationText == String(localized: "\(7) minutes"))
        let totals = model.dayFocusTotals(for: fixture.clock.now, calendar: ElapsedModelFixture.calendar)
        #expect(totals.finishedPomodoros == 1)
        #expect(totals.timeSpentMs == 420_000)
    }

    @Test func earlyFinishedTimerShowsAsEndedWithoutCountdown() throws {
        let fixture = try ElapsedModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(model.start())
        fixture.clock.elapsed = 7 * 60
        #expect(model.finish())

        let timer = try #require(model.canonicalTimer)
        #expect(timer.status == .completed)
        #expect(timer.elapsedAtAnchorMs == 420_000)
        #expect(model.history.first?.timerId == timer.id)
        #expect(model.history.first?.isFinishedEarly == true)
        #expect(model.activeTimer == nil)
        let snapshot = model.makeWatchSnapshot()
        #expect(snapshot.status == "idle")
        #expect(snapshot.timerId == nil)
        #expect(snapshot.elapsedAtAnchorMs == 0)
    }

    /// A 29 s run is real time spent: the row and the day total both show
    /// 1 minute, by the same rounding.
    @Test func shortEarlyFinishShowsOneMinuteInTheRowAndTheTotal() throws {
        let fixture = try ElapsedModelFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        #expect(model.start())
        fixture.clock.elapsed = 29
        #expect(model.finish())

        let item = try #require(model.history.first)
        #expect(item.elapsedMs == 29_000)
        #expect(item.statusText == String(localized: "Finished early"))
        #expect(item.durationText == TaskTimeText.shortMinutes(1))
        let totals = model.dayFocusTotals(for: fixture.clock.now, calendar: ElapsedModelFixture.calendar)
        #expect(totals.timeSpentMs == 29_000)
        #expect(TaskTimeText.compact(totals.timeSpentMs) == "1m")
    }

    /// Rows and totals round recorded time the same way: half a minute rounds
    /// up, and any time above 0 shows at least 1 minute.
    @Test(arguments: [
        (Int64(0), 0), (1, 1), (29_000, 1), (30_000, 1), (89_999, 1),
        (90_000, 2), (1_470_000, 25), (1_500_000, 25),
    ])
    func rowsAndTotalsRoundRecordedMinutesTheSameWay(elapsedMs: Int64, minutes: Int) throws {
        var row = try ElapsedJSON.row(id: "history-round0001", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = elapsedMs
        let item = try ElapsedJSON.decodeItem(row)
        #expect(item.elapsedMinutes == minutes)
        #expect(item.durationText == TaskTimeText.shortMinutes(minutes))
        #expect(TaskTimeText.compact(elapsedMs) == "\(minutes)m")
        #expect(TaskTimeText.spoken(elapsedMs) == TaskTimeText.spoken(Int64(minutes) * 60_000))
    }

    /// Core's startup projection applies its rule for rows stored before the
    /// field: a completed row counts its plan and any other row counts 0. The
    /// client only shows that result and does not write it back on load.
    @Test func storedRowsWithoutElapsedLoadWithCoreRuleAndAreNotWrittenBack() throws {
        let fixture = try ElapsedModelFixture()
        defer { fixture.cleanUp() }
        let completedAt = fixture.clock.anchor.addingTimeInterval(-60)
        let completed = try ElapsedJSON.row(id: "history-old0001", status: "completed", at: completedAt)
        let cancelled = try ElapsedJSON.row(id: "history-old0002", status: "cancelled", at: completedAt)
        try fixture.seedStoredHistory([completed, cancelled])
        let model = fixture.makeModel()

        #expect(model.history.count == 2)
        let loadedCompleted = try #require(model.history.first { $0.id == "history-old0001" })
        let loadedCancelled = try #require(model.history.first { $0.id == "history-old0002" })
        #expect(loadedCompleted.elapsedMs == DurationValues.defaults.focus)
        #expect(loadedCancelled.elapsedMs == 0)
        #expect(loadedCompleted.statusText == CanonicalTimer.Status.completed.localizedText)
        #expect(loadedCompleted.durationText == TaskTimeText.shortMinutes(25))
        #expect(loadedCancelled.durationText == TaskTimeText.shortMinutes(0))
        let totals = model.dayFocusTotals(for: completedAt, calendar: ElapsedModelFixture.calendar)
        #expect(totals.timeSpentMs == DurationValues.defaults.focus)
        #expect(model.completedFocusSummaries().map(\.timeSpentMs) == [DurationValues.defaults.focus])
        #expect(try fixture.storedHistoryRows().allSatisfy { $0["elapsedMs"] == nil })
    }

    /// A row that did not pass through Core still has no value; it keeps the
    /// plan-only wording instead of a client-made elapsed time.
    @Test func rowWithoutElapsedKeepsPlanOnlyWording() throws {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let cancelled = try ElapsedJSON.decodeItem(try ElapsedJSON.row(id: "history-old0003", status: "cancelled", at: at))
        let superseded = try ElapsedJSON.decodeItem(try ElapsedJSON.row(id: "history-old0004", status: "superseded", at: at))
        let completed = try ElapsedJSON.decodeItem(try ElapsedJSON.row(id: "history-old0005", status: "completed", at: at))
        #expect(cancelled.elapsedMs == nil)
        #expect(cancelled.durationText == String(localized: "\(25) min planned"))
        #expect(cancelled.spokenDurationText == String(localized: "\(25) minutes planned"))
        #expect(superseded.durationText == String(localized: "\(25) min planned"))
        // A completed row ran its plan, so its minutes are not worded as planned.
        #expect(completed.durationText == TaskTimeText.shortMinutes(25))
    }

    /// Totals add only the time Core recorded. The client has no rule of its
    /// own for a row without it, so such a row adds nothing.
    @Test func rowsWithoutElapsedAddNothingToTotals() throws {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let task = try #require(FocusTask(title: "Totals without elapsed"))
        var completed = try ElapsedJSON.row(id: "history-old0006", status: "completed", at: at)
        completed["taskId"] = task.id.uuidString.lowercased()
        var recorded = try ElapsedJSON.row(id: "history-old0007", status: "completed", at: at)
        recorded["taskId"] = task.id.uuidString.lowercased()
        recorded["elapsedMs"] = 420_000
        let snapshot = AppStatePublisher.Snapshot(
            canonicalTimer: nil,
            history: [try ElapsedJSON.decodeItem(completed), try ElapsedJSON.decodeItem(recorded)],
            tasks: [task],
            state: .fresh()
        )
        let publisher = AppStatePublisher()
        let calendar = ElapsedModelFixture.calendar
        let day = publisher.dayFocusTotals(for: at, calendar: calendar, snapshot: snapshot)
        #expect(day.finishedPomodoros == 2)
        #expect(day.timeSpentMs == 420_000)
        let summary = try #require(publisher.taskSummaries(for: at, calendar: calendar, snapshot: snapshot).first)
        #expect(summary.finishedPomodoros == 2)
        #expect(summary.timeSpentMs == 420_000)
    }

    @Test func historyRowCodecKeepsElapsedAndLeavesAMissingValueOut() throws {
        let base = try ElapsedJSON.row(id: "history-codec0001", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        var present = base
        present["elapsedMs"] = 420_000
        var explicitNull = base
        explicitNull["elapsedMs"] = NSNull()

        let kept = try ElapsedJSON.roundTrip(present)
        #expect(ElapsedJSON.elapsed(kept) == 420_000)
        #expect(try ElapsedJSON.roundTrip(base)["elapsedMs"] == nil)
        #expect(try ElapsedJSON.roundTrip(explicitNull)["elapsedMs"] == nil)
    }

    @Test(arguments: ["completed", "cancelled", "superseded"], [Int64(-1), Int64(1_500_001)])
    func elapsedOutsideZeroToPlanFailsClosedInLocalValidation(status: String, elapsed: Int64) throws {
        var row = try ElapsedJSON.row(id: "history-range0001", status: status, at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = elapsed
        let item = try ElapsedJSON.decodeItem(row)
        #expect(!item.isValid)
        #expect(!CanonicalSnapshotValidation.isValid(
            timer: nil, history: [item], tasks: [], durations: .defaults, selectedTaskId: nil
        ))
        var inRange = row
        inRange["elapsedMs"] = 1_500_000
        #expect(try ElapsedJSON.decodeItem(inRange).isValid)
    }

    /// Only a whole number of milliseconds decodes; a string, a fraction or a
    /// value past Int64 fails closed instead of being coerced.
    @Test(arguments: ElapsedJSON.malformedValues)
    func malformedElapsedFailsToDecode(value: ElapsedJSON.Malformed) throws {
        var row = try ElapsedJSON.row(id: "history-type0001", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = value.json
        #expect(throws: DecodingError.self) { try ElapsedJSON.decodeItem(row) }
    }

    /// The REST sync response carries the same rows. Its snapshot check
    /// rejects an elapsed time outside 0 through the plan on any status.
    @Test(arguments: ["completed", "cancelled", "superseded"], [Int64(-1), Int64(1_500_001)])
    func syncResponseRejectsElapsedOutsideZeroToPlan(status: String, elapsed: Int64) throws {
        var row = try ElapsedJSON.row(id: "history-rest0001", status: status, at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = elapsed
        #expect(try !ElapsedJSON.syncResponse(history: [row]).hasValidCanonicalSnapshot)
        row["elapsedMs"] = 1_500_000
        #expect(try ElapsedJSON.syncResponse(history: [row]).hasValidCanonicalSnapshot)
    }

    @Test(arguments: ElapsedJSON.malformedValues)
    func syncResponseWithMalformedElapsedFailsToDecode(value: ElapsedJSON.Malformed) throws {
        var row = try ElapsedJSON.row(id: "history-rest0002", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = value.json
        #expect(throws: DecodingError.self) { try ElapsedJSON.syncResponse(history: [row]) }
    }
}

@Suite("Iroh history elapsed codec", .serialized)
struct IrohHistoryElapsedCodecTests {
    @Test func genesisHistoryRoundTripsElapsed() throws {
        var row = try ElapsedJSON.row(id: "history-genesis0001", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = 420_000
        let message = try IrohElapsedMessage.operationsResult(historyRow: row)

        let decoded = try IrohRPCMessageCodec.decode(message)
        guard case .operationsResult(let result) = decoded else {
            Issue.record("expected an operations result")
            return
        }
        let record = try #require(result.records.first)
        guard case .genesis(let genesis) = record.payload else {
            Issue.record("expected a genesis record")
            return
        }
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(record)) as? [String: Any])
        let operation = try #require(encoded["operation"] as? [String: Any])
        let history = try #require(operation["history"] as? [[String: Any]])
        #expect(genesis.history.count == 1)
        #expect(history.first.flatMap(ElapsedJSON.elapsed) == 420_000)
    }

    @Test func genesisHistoryWithoutElapsedStillDecodes() throws {
        let row = try ElapsedJSON.row(id: "history-genesis0002", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        let message = try IrohElapsedMessage.operationsResult(historyRow: row)
        let decoded = try IrohRPCMessageCodec.decode(message)
        guard case .operationsResult(let result) = decoded else {
            Issue.record("expected an operations result")
            return
        }
        let record = try #require(result.records.first)
        guard case .genesis(let genesis) = record.payload else {
            Issue.record("expected a genesis record")
            return
        }
        #expect(genesis.history.count == 1)
        #expect(genesis.history.first?.id == "history-genesis0002")
        #expect(genesis.history.first?.elapsedMs == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(record)) as? [String: Any])
        let history = try #require((encoded["operation"] as? [String: Any])?["history"] as? [[String: Any]])
        #expect(history.first?.keys.contains("elapsedMs") == false)
    }

    /// The range check of `IrohSnapshotValidation` (not the field allow-list)
    /// rejects the record, so the message names the record set.
    @Test(arguments: ["completed", "cancelled", "superseded"], [Int64(-1), Int64(1_500_001)])
    func genesisHistoryElapsedOutsideZeroToPlanFailsClosed(status: String, elapsed: Int64) throws {
        var row = try ElapsedJSON.row(id: "history-genesis0003", status: status, at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = elapsed
        let message = try IrohElapsedMessage.operationsResult(historyRow: row)
        #expect(IrohElapsedMessage.rejection(of: message) == "operation records are invalid")
        row["elapsedMs"] = 1_500_000
        #expect(IrohElapsedMessage.rejection(of: try IrohElapsedMessage.operationsResult(historyRow: row)) == nil)
    }

    @Test(arguments: ElapsedJSON.malformedValues)
    func genesisHistoryMalformedElapsedFailsClosed(value: ElapsedJSON.Malformed) throws {
        var row = try ElapsedJSON.row(id: "history-genesis0005", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = value.json
        let message = try IrohElapsedMessage.operationsResult(historyRow: row)
        #expect(throws: (any Error).self) { try IrohRPCMessageCodec.decode(message) }
    }

    @Test func genesisHistoryExplicitNullElapsedFailsClosed() throws {
        var row = try ElapsedJSON.row(id: "history-genesis0004", status: "completed", at: Date(timeIntervalSince1970: 1_780_000_000))
        row["elapsedMs"] = NSNull()
        let message = try IrohElapsedMessage.operationsResult(historyRow: row)
        #expect(throws: IrohProtocolError.self) { try IrohRPCMessageCodec.decode(message) }
    }
}

enum ElapsedJSON {
    /// A JSON value that is not a whole number of milliseconds.
    struct Malformed: Sendable, CustomTestStringConvertible {
        let name: String
        let literal: String
        var testDescription: String { name }
        var json: Any { (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) ?? literal }
    }

    static let malformedValues = [
        Malformed(name: "string", literal: "\"420000\""),
        Malformed(name: "fraction", literal: "420000.5"),
        Malformed(name: "past Int64", literal: "9223372036854775808"),
    ]

    /// A focus row planned for the default 25 minutes, without `elapsedMs`.
    static func row(id: String, status: String, at date: Date) throws -> [String: Any] {
        let item = HistoryItem(
            id: id,
            timerId: "timer-\(id)",
            commandId: "command-\(id)",
            taskId: nil,
            phase: .focus,
            status: status,
            plannedDurationMs: DurationValues.defaults.focus,
            completedAt: status == "completed" ? date : nil,
            endedAt: date
        )
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(item)) as? [String: Any])
    }

    static func rows(_ history: [HistoryItem]) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(history)) as? [[String: Any]])
    }

    static func elapsed(_ row: [String: Any]) -> Int64? {
        (row["elapsedMs"] as? NSNumber)?.int64Value
    }

    static func decodeItem(_ row: [String: Any]) throws -> HistoryItem {
        try JSONDecoder.api.decode(HistoryItem.self, from: JSONSerialization.data(withJSONObject: row))
    }

    static func syncResponse(history: [[String: Any]]) throws -> SyncResponse {
        let body: [String: Any] = [
            "acknowledgements": [], "durationAcknowledgements": [], "autoStartAcknowledgements": [],
            "selectedTaskAcknowledgements": [], "selectedTaskId": NSNull(),
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false, "revision": 1, "canonicalTimer": NSNull(),
            "history": history, "tasks": [], "serverTime": "2026-07-21T08:00:00.000Z",
            "serverHlcWallMs": 1_784_620_800_000, "serverHlcCounter": 0,
        ]
        return try JSONDecoder.api.decode(SyncResponse.self, from: JSONSerialization.data(withJSONObject: body))
    }

    static func roundTrip(_ row: [String: Any]) throws -> [String: Any] {
        let data = try JSONEncoder.api.encode(decodeItem(row))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum IrohElapsedMessage {
    /// An `operationsResult` frame body whose one genesis record carries `row`.
    static func operationsResult(historyRow row: [String: Any]) throws -> Data {
        let record = IrohOperationRecord(
            domain: .genesis,
            deviceId: "device-elapsed0001",
            payload: .genesis(IrohGenesis(
                canonicalTimer: nil, history: [], tasks: [], durationsMs: .defaults,
                autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0
            ))
        )
        var recordObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.api.encode(record)) as? [String: Any]
        )
        var operation = try #require(recordObject["operation"] as? [String: Any])
        operation["history"] = [row]
        recordObject["operation"] = operation
        let message: [String: Any] = [
            "protocolVersion": 1,
            "roomId": try IrohProtocolV1.roomID(for: Data(0...31)),
            "requestId": try IrohProtocolV1.makeRequestID(at: Date(timeIntervalSince1970: 1_000)),
            "kind": "operationsResult",
            "records": [recordObject]
        ]
        return try JSONSerialization.data(withJSONObject: message)
    }

    /// The `invalidMessage` text a decode fails with, or nil if it decodes.
    static func rejection(of message: Data) -> String? {
        do {
            _ = try IrohRPCMessageCodec.decode(message)
            return nil
        } catch IrohProtocolError.invalidMessage(let text) {
            return text
        } catch {
            return "unexpected \(error)"
        }
    }
}

@MainActor
private final class ElapsedClock {
    let anchor = Date(timeIntervalSince1970: 1_780_000_000)
    var elapsed: TimeInterval = 0
    var now: Date { anchor.addingTimeInterval(elapsed) }
}

private struct ElapsedEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { nil }
    func save(_ secret: Data) throws {}
}

/// An offline `AppModel` with every side effect faked: no Keychain, network,
/// sign-in, or real alarm, and a completion sleep that never fires.
@MainActor
private struct ElapsedModelFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let clock = ElapsedClock()
    let roomStore: IrohRoomStore

    init() throws {
        suiteName = "PomodoroughTests.HistoryElapsed.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(ReplicationMode.offline.rawValue, forKey: "replication-mode-v1")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let clock = clock
        roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("iroh-rooms.json"),
            secretStore: MemoryIrohRoomSecretStore(),
            now: { clock.now }
        )
    }

    func makeModel() -> AppModel {
        let clock = clock
        return AppModel(
            api: APIClient(
                session: TestFixtures.session(for: suiteName),
                keychain: EmptyTokenStore(),
                logoutRevocationStore: TestLogoutRevocationStore()
            ),
            defaults: defaults,
            accountDeletionJournal: AccountDeletionJournal(
                fileURL: directory.appendingPathComponent("account-deletion.json")
            ),
            durableLocalStore: AtomicDurableFileStore(
                fileURL: directory.appendingPathComponent("timer-state.json")
            ),
            roomStore: roomStore,
            endpointKeyStore: ElapsedEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            completionScheduler: TimerCompletionScheduler(sleep: { _ in
                try await Task.sleep(for: .seconds(86_400))
            }),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { clock.now },
            uptime: { clock.elapsed }
        )
    }

    func seedStoredHistory(_ rows: [[String: Any]]) throws {
        let fresh = try JSONEncoder.api.encode(PersistedTimerState.fresh())
        var state = try #require(JSONSerialization.jsonObject(with: fresh) as? [String: Any])
        state["history"] = rows
        defaults.set(try JSONSerialization.data(withJSONObject: state), forKey: "timer-state-v2")
    }

    func storedHistoryRows() throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: "timer-state-v2"))
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return state["history"] as? [[String: Any]] ?? []
    }

    func seedIrohRunningTimer() throws {
        let state = PersistedTimerState.fresh()
        let timer = CanonicalTimer(
            id: "timer-iroh-elapsed", taskId: nil, phase: .focus, status: .running,
            plannedDurationMs: 60_000, elapsedAtAnchorMs: 0, anchorAt: clock.anchor,
            startedByDeviceId: state.deviceId,
            lastIntent: TimerIntent(
                type: .start, commandId: "iroh-elapsed-start", occurredAt: clock.anchor, deviceId: state.deviceId
            )
        )
        let secret = Data(0...31)
        _ = try roomStore.createRoom(
            roomID: IrohProtocolV1.roomID(for: secret), roomSecret: secret, name: nil,
            returnState: state,
            genesis: IrohGenesis(
                canonicalTimer: timer, history: [], tasks: [], durationsMs: .defaults,
                autoStartBreaks: false, hlcWallMs: 0, hlcCounter: 0
            ), now: clock.anchor
        )
        defaults.set(ReplicationMode.iroh.rawValue, forKey: "replication-mode-v1")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
    }
}
