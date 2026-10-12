import Foundation
import Testing
@testable import Pomodorough

enum R48AP04Mode: Sendable {
    case failFirst
    case timeoutFirst
    case staleFirst
    case blockFirst
    case succeed
}

final class R48AP04StubState: @unchecked Sendable {
    static let shared = R48AP04StubState()
    private let lock = NSLock()
    private var modes: [String: R48AP04Mode] = [:]
    private var counts: [String: Int] = [:]

    func configure(scenario: String, mode: R48AP04Mode) {
        lock.withLock {
            modes[scenario] = mode
            counts[scenario] = 0
        }
        StubScenarioGate.shared.reset(scenario: scenario)
    }

    func setMode(scenario: String, mode: R48AP04Mode) {
        lock.withLock { modes[scenario] = mode }
    }

    func mode(for scenario: String) -> R48AP04Mode {
        lock.withLock { modes[scenario] ?? .succeed }
    }

    func recordPost(scenario: String) -> Int {
        lock.withLock {
            counts[scenario, default: 0] += 1
            return counts[scenario] ?? 0
        }
    }

    func postCount(for scenario: String) -> Int {
        lock.withLock { counts[scenario] ?? 0 }
    }

    func release(_ scenario: String) {
        StubScenarioGate.shared.release(scenario: scenario)
    }
}

final class R48AP04StubProtocol: URLProtocol, @unchecked Sendable {
    private let loadingLock = NSRecursiveLock()
    private var loadingStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-R48AP04-Scenario") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let scenario = request.value(forHTTPHeaderField: "X-R48AP04-Scenario") else { return }
        let path = request.url?.path ?? ""
        if path == "/api/v1/me" {
            respond(data: Self.meBody, status: 200)
            return
        }
        guard request.httpMethod == "POST", path == "/api/v1/sync" else {
            respond(data: Data(#"{"error":"Unexpected"}"#.utf8), status: 400)
            return
        }
        let attempt = R48AP04StubState.shared.recordPost(scenario: scenario)
        let mode = R48AP04StubState.shared.mode(for: scenario)
        switch (mode, attempt) {
        case (.failFirst, 1):
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case (.timeoutFirst, 1):
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        case (.staleFirst, 1):
            respond(data: Self.pausedResponse(revision: 9), status: 200)
            return
        case (.blockFirst, 1):
            DispatchQueue.global().async { self.loadBlocked(scenario: scenario) }
            return
        default:
            respond(data: Self.pausedResponse(revision: 11), status: 200)
            return
        }
    }

    override func stopLoading() {
        loadingLock.withLock { loadingStopped = true }
        StubScenarioGate.shared.wakeWaiters()
    }

    private func loadBlocked(scenario: String) {
        guard StubScenarioGate.shared.wait(scenario: scenario, isCancelled: {
            self.loadingLock.withLock { self.loadingStopped }
        }) else { return }
        guard !loadingLock.withLock({ loadingStopped }) else { return }
        deliver {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: self.request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Self.pausedResponse(revision: 11))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func deliver(_ work: @escaping () -> Void) {
        var cancelled: Bool { loadingLock.withLock { loadingStopped } }
        guard !cancelled else { return }
        work()
    }

    private func respond(data: Data, status: Int) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static var meBody: Data {
        Data(#"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8)
    }

    static func pausedResponse(revision: Int64) -> Data {
        let object: [String: Any] = [
            "acknowledgements": [],
            "taskAcknowledgements": [],
            "durationAcknowledgements": [],
            "autoStartAcknowledgements": [],
            "selectedTaskAcknowledgements": [],
            "durationsMs": ["focus": 1_500_000, "short_break": 300_000, "long_break": 900_000],
            "autoStartBreaks": false,
            "selectedTaskId": NSNull(),
            "revision": revision,
            "canonicalTimer": [
                "id": "alarm-correction-timer",
                "taskId": NSNull(),
                "phase": "focus",
                "status": "paused",
                "plannedDurationMs": 60_000,
                "elapsedAtAnchorMs": 10_000,
                "anchorAt": "2026-07-21T08:00:00.000Z",
                "lastIntent": NSNull()
            ],
            "history": [],
            "tasks": [],
            "serverTime": "2026-07-21T08:00:00.000Z",
            "serverHlcWallMs": 1_784_620_800_000,
            "serverHlcCounter": 4
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

@MainActor
private final class R48AP04Clock {
    let anchor = Date(timeIntervalSince1970: 1_784_620_800)
    var elapsed: TimeInterval = 0
    var now: Date { anchor.addingTimeInterval(elapsed) }
}

@MainActor
private final class R48AP04Sleeper {
    private var continuations: [CheckedContinuation<Void, any Error>?] = []
    private(set) var count = 0
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { c in
            count += 1
            continuations.append(c)
        }
    }
    func releaseAll() {
        for i in continuations.indices {
            continuations[i]?.resume()
            continuations[i] = nil
        }
    }
}

@MainActor
private struct R48AP04Fixture {
    let scenario: String
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let clock = R48AP04Clock()
    let sleeper = R48AP04Sleeper()
    let roomStore: IrohRoomStore

    init(mode: R48AP04Mode) throws {
        scenario = "R48AP04.\(UUID().uuidString)"
        R48AP04StubState.shared.configure(scenario: scenario, mode: mode)
        suiteName = "PomodoroughTests.R48AP04.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let clock = clock
        roomStore = IrohRoomStore(
            fileURL: directory.appendingPathComponent("iroh-rooms.json"),
            secretStore: MemoryIrohRoomSecretStore(),
            now: { clock.now }
        )
    }

    func seedRunningTimer() throws {
        var initial = TestFixtures.syncContractState(includesPendingOperations: false)
        initial.history = []
        initial.canonicalTimer = CanonicalTimer(
            id: "alarm-correction-timer", taskId: nil, phase: .focus,
            status: .running, plannedDurationMs: 60_000,
            elapsedAtAnchorMs: 10_000, anchorAt: clock.anchor, lastIntent: nil
        )
        initial.localTimerOwners["alarm-correction-timer"] = initial.deviceId
        defaults.set(try JSONEncoder.api.encode(initial), forKey: "timer-state-v2")
    }

    func makeModel(alarms: RecordingAlarmScheduler) -> AppModel {
        let clock = clock
        let sleeper = sleeper
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [R48AP04StubProtocol.self]
        config.httpAdditionalHeaders = ["X-R48AP04-Scenario": scenario]
        let session = URLSession(configuration: config)
        return AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults, roomStore: roomStore,
            alarmScheduler: alarms,
            completionScheduler: TimerCompletionScheduler(sleep: { try await sleeper.sleep($0) }),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { clock.now }, uptime: { clock.elapsed }
        )
    }

    func cleanUp() {
        R48AP04StubState.shared.release(scenario)
        sleeper.releaseAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        sessionInvalidate()
    }

    private func sessionInvalidate() {}
}

private func r48ap04HasSchedule(_ ops: [RecordedAlarmOperation]) -> Bool {
    ops.contains { if case .schedule = $0 { return true }; return false }
}

@Suite("R48-AP04 foreground gate")
struct R48AP04ForegroundGateTests {
    @Test @MainActor
    func failedPreservesGateThenRecoversOnce() async throws {
        let fixture = try R48AP04Fixture(mode: .failFirst)
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let alarms = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarms: alarms)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.restore()
        // Restore resumeCached sync consumes first scripted failure
        // without installing; re-arm for measured foreground phase.
        R48AP04StubState.shared.configure(scenario: fixture.scenario, mode: .failFirst)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == true)
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .running)
        #expect(!r48ap04HasSchedule(alarms.operations))
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 1)
        R48AP04StubState.shared.setMode(scenario: fixture.scenario, mode: .succeed)
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.testForegroundSyncPending == false)
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 2)
    }

    @Test @MainActor
    func stalePreservesGateThenRecoversOnce() async throws {
        let fixture = try R48AP04Fixture(mode: .staleFirst)
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let alarms = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarms: alarms)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.restore()
        // Restore resumeCached sync consumes first scripted stale
        // without installing; re-arm for measured foreground phase.
        R48AP04StubState.shared.configure(scenario: fixture.scenario, mode: .staleFirst)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == true)
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .running)
        #expect(!r48ap04HasSchedule(alarms.operations))
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 1)
        R48AP04StubState.shared.setMode(scenario: fixture.scenario, mode: .succeed)
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.testForegroundSyncPending == false)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 2)
    }

    @Test @MainActor
    func timeoutPreservesGateThenRecoversOnce() async throws {
        let fixture = try R48AP04Fixture(mode: .timeoutFirst)
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let alarms = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarms: alarms)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.restore()
        // Restore resumeCached sync consumes first scripted timeout
        // without installing; re-arm for measured foreground phase.
        R48AP04StubState.shared.configure(scenario: fixture.scenario, mode: .timeoutFirst)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == true)
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .running)
        #expect(!r48ap04HasSchedule(alarms.operations))
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 1)
        R48AP04StubState.shared.setMode(scenario: fixture.scenario, mode: .succeed)
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.testForegroundSyncPending == false)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 2)
    }

    @Test @MainActor
    func coalescedSecondPostsZeroThenRecoversOnce() async throws {
        let fixture = try R48AP04Fixture(mode: .failFirst)
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let alarms = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarms: alarms)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.restore()
        // Restore with fail preserves running timer; then arm block
        // so only measured foreground sync posts and blocks.
        R48AP04StubState.shared.configure(scenario: fixture.scenario, mode: .blockFirst)
        let first = Task { await model.refreshAfterForeground() }
        try await Task.sleep(for: .milliseconds(50))
        await model.refreshAfterForeground()
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 1)
        #expect(model.testForegroundSyncPending == true)
        #expect(model.completedFocusCount == 0)
        R48AP04StubState.shared.release(fixture.scenario)
        await first.value
        await model.waitForAlarmOperations()
        #expect(model.testForegroundSyncPending == false)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 1)
        #expect(!r48ap04HasSchedule(alarms.operations))
    }

    @Test @MainActor
    func cancelledPreservesGateThenRecoversOnce() async throws {
        let fixture = try R48AP04Fixture(mode: .failFirst)
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let alarms = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarms: alarms)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        model.setSceneActive(true)
        await model.restore()
        // Restore with fail preserves running timer; then arm block
        // so only measured foreground sync posts and blocks.
        R48AP04StubState.shared.configure(scenario: fixture.scenario, mode: .blockFirst)
        let task = Task { await model.refreshAfterForeground() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(model.testForegroundSyncPending == true)
        #expect(model.completedFocusCount == 0)
        #expect(model.canonicalTimer?.status == .running)
        #expect(!r48ap04HasSchedule(alarms.operations))
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 1)
        R48AP04StubState.shared.release(fixture.scenario)
        await model.refreshAfterForeground()
        await model.waitForAlarmOperations()
        #expect(model.testForegroundSyncPending == false)
        #expect(model.canonicalTimer?.status == .paused)
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 2)
    }

    @Test @MainActor
    func explicitOfflineReleasesGateWithoutPosts() async throws {
        let fixture = try R48AP04Fixture(mode: .succeed)
        defer { fixture.cleanUp() }
        try fixture.seedRunningTimer()
        let alarms = RecordingAlarmScheduler()
        let model = fixture.makeModel(alarms: alarms)
        model.setSceneActive(false)
        fixture.clock.elapsed = 90
        await model.restore()
        // Restore sync posts once; reset baseline so offline
        // refresh must post zero.
        R48AP04StubState.shared.configure(scenario: fixture.scenario, mode: .succeed)
        await model.setReplicationMode(.offline)
        await model.refreshAfterForeground()
        #expect(model.testForegroundSyncPending == false)
        #expect(R48AP04StubState.shared.postCount(for: fixture.scenario) == 0)
    }
}
