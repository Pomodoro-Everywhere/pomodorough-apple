import Foundation
import Testing
@testable import Pomodorough

/// IOS27-23: `AppModel.timerControlUsedInProcess` reports that the person
/// used a timer control in this process. A launch, a sync, an automatic
/// completion and a settings edit must leave it false.
@Suite("IOS27-23 timer control use")
struct TimerControlUseTests {
    @Test(arguments: TimerControlPath.allCases)
    @MainActor
    func timerControlReportsItsUse(_ path: TimerControlPath) throws {
        let fixture = try TimerControlFixture(seededTimerStatus: path.seededTimerStatus)
        defer { fixture.cleanUp() }
        try #require(fixture.model.canonicalTimer?.status == path.seededTimerStatus)
        try #require(!fixture.model.timerControlUsedInProcess)

        try path.use(on: fixture.model)

        #expect(fixture.model.timerControlUsedInProcess)
    }

    @Test(arguments: [CanonicalTimer.Status.paused, .running])
    @MainActor
    func launchOnStoredTimerReportsNoTimerControlUse(status: CanonicalTimer.Status) throws {
        let fixture = try TimerControlFixture(seededTimerStatus: status)
        defer { fixture.cleanUp() }

        #expect(fixture.model.canonicalTimer?.status == status)
        #expect(!fixture.model.timerControlUsedInProcess)
    }

    @Test @MainActor
    func timerArrivingThroughSyncIsNotTimerControlUse() async throws {
        let fixture = try TimerControlFixture(
            state: TestFixtures.syncContractState(includesPendingOperations: false),
            scenarioPrefix: "sync-contract-revision-timer-control-",
            now: nil
        )
        defer { fixture.cleanUp() }
        try #require(fixture.model.canonicalTimer?.id == "local-canonical-timer")

        await fixture.model.restore()

        try #require(fixture.model.canonicalTimer?.id == "remote-associated-timer")
        #expect(!fixture.model.timerControlUsedInProcess)
    }

    @Test(arguments: [false, true])
    @MainActor
    func automaticCompletionIsNotTimerControlUse(autoStartBreaks: Bool) throws {
        var state = TimerControlFixture.state(seededTimerStatus: .running)
        state.autoStartBreaks = autoStartBreaks
        let deadline = TestFixtures.anchor.addingTimeInterval(60)
        let fixture = try TimerControlFixture(state: state, now: deadline)
        defer { fixture.cleanUp() }

        fixture.model.completeIfNeeded(timerID: TimerControlFixture.timerID, at: deadline)

        let timer = try #require(fixture.model.canonicalTimer)
        if autoStartBreaks {
            try #require(timer.phase == .shortBreak && timer.status == .running)
        } else {
            try #require(timer.phase == .focus && timer.status == .completed)
        }
        #expect(!fixture.model.timerControlUsedInProcess)
    }

    @Test @MainActor
    func settingsAndTaskBoardEditsAreNotTimerControlUse() async throws {
        let fixture = try TimerControlFixture(seededTimerStatus: nil)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.setDurationMinutes(42, for: .focus)
        model.autoStartBreaks = true
        let added = await model.addTask("Write report")

        try #require(model.durationMinutes(for: .focus) == 42)
        try #require(model.autoStartBreaks)
        try #require(added)
        #expect(!model.timerControlUsedInProcess)
    }

    @Test @MainActor
    func rejectedAndSettingsWatchCommandsAreNotTimerControlUse() throws {
        let fixture = try TimerControlFixture(seededTimerStatus: .running)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let stalePause = WatchTimerCommand(
            timerId: "timer-replaced",
            expectedTimerRevision: model.makeWatchSnapshot().timerRevision,
            name: "pause", sentAt: .now
        )
        let deferredStart = WatchTimerCommand(name: "start", sentAt: .now)
        let setDuration = WatchTimerCommand(
            name: "setDuration", phase: TimerPhase.shortBreak.rawValue, minutes: 7, sentAt: .now
        )

        #expect(!model.applyWatchCommand(stalePause))
        #expect(!model.applyWatchCommand(deferredStart, isDeferred: true))
        model.applyWatchCommand(setDuration)

        try #require(model.durationMinutes(for: .shortBreak) == 7)
        #expect(model.canonicalTimer?.status == .running)
        #expect(!model.timerControlUsedInProcess)
    }

    @Test(arguments: [
        "pomodorough://timer", "pomodorough://timer?action=unknown",
        "pomodorough://other?action=finish", "https://timer?toggle=1"
    ])
    @MainActor
    func linkWithoutTimerActionIsNotTimerControlUse(rawURL: String) throws {
        let fixture = try TimerControlFixture(seededTimerStatus: .paused)
        defer { fixture.cleanUp() }
        let url = try #require(URL(string: rawURL))

        MainContainer.handleTimerURL(url, model: fixture.model)

        #expect(fixture.model.canonicalTimer?.status == .paused)
        #expect(!fixture.model.timerControlUsedInProcess)
    }

    @Test @MainActor
    func onlyTimerControlIntentsReportTimerControlUse() throws {
        typealias Intent = SynchronizedWorkspaceMutationController.Intent
        let date = TestFixtures.anchor
        let task = try #require(FocusTask(title: "Write report"))
        let finish = SynchronizedWorkspaceMutationController.CommandIntent(
            type: .finish, timerID: TimerControlFixture.timerID, taskID: nil,
            phase: .focus, duration: 60, elapsed: 60
        )
        let timerControls: [Intent] = [
            .selectPhase(.shortBreak), .selectTask(nil), .startTimer, .pauseTimer(at: date),
            .resumeTimer(at: date), .cancelTimer(at: date), .clearTimer
        ]
        let otherIntents: [Intent] = [
            .setAutoStartBreaks(true), .setDurationMinutes(42, for: .focus), .task(.upsert, task),
            .renameTask(task, "Write the report"), .command(finish),
            .commit(.init(state: .fresh(), requirements: .init()))
        ]

        #expect(timerControls.filter { !$0.isTimerControl }.isEmpty)
        #expect(otherIntents.filter { $0.isTimerControl }.isEmpty)
    }
}

/// A person's timer control, driven through its real command entry point.
enum TimerControlPath: String, CaseIterable, Sendable {
    case start, pause, resume, toggleFromIdle, toggleFromRunning, toggleFromPaused
    case finish, cancel, clear, skip, phasePicker, taskPicker
    case linkToggle, linkFinish, linkCancel, linkSkip
    case watchStart, watchPause, watchResume, watchFinish, watchSelectPhase

    /// The stored timer the control acts on, or nil for no timer.
    var seededTimerStatus: CanonicalTimer.Status? {
        switch self {
        case .start, .toggleFromIdle, .clear, .skip, .phasePicker, .taskPicker,
             .linkToggle, .linkSkip, .watchStart, .watchSelectPhase:
            nil
        case .pause, .toggleFromRunning, .finish, .cancel, .linkFinish, .linkCancel,
             .watchPause, .watchFinish:
            .running
        case .resume, .toggleFromPaused, .watchResume:
            .paused
        }
    }

    @MainActor
    func use(on model: AppModel) throws {
        switch self {
        case .start: _ = model.start()
        case .pause: model.pause()
        case .resume: model.resume()
        case .toggleFromIdle, .toggleFromRunning, .toggleFromPaused: model.toggleTimer()
        case .finish: model.finish()
        case .cancel: model.cancel()
        case .clear: model.clear()
        case .skip: model.selectPhase(model.skipDestination)
        case .phasePicker: model.selectedPhase = .shortBreak
        case .taskPicker: model.selectedTaskID = nil
        case .linkToggle: try Self.open("pomodorough://timer?toggle=1", in: model)
        case .linkFinish: try Self.open("pomodorough://timer?action=finish", in: model)
        case .linkCancel: try Self.open("pomodorough://timer?action=cancel", in: model)
        case .linkSkip: try Self.open("pomodorough://timer?action=skip", in: model)
        case .watchStart: Self.sendWatchCommand("start", to: model)
        case .watchPause: Self.sendWatchCommand("pause", to: model)
        case .watchResume: Self.sendWatchCommand("resume", to: model)
        case .watchFinish: Self.sendWatchCommand("finish", to: model)
        case .watchSelectPhase: Self.sendWatchCommand("selectPhase", to: model)
        }
    }

    @MainActor
    private static func open(_ rawURL: String, in model: AppModel) throws {
        let url = try #require(URL(string: rawURL))
        #expect(MainContainer.handleTimerURL(url, model: model))
    }

    /// A live command the Watch built from the phone's current snapshot.
    @MainActor
    private static func sendWatchCommand(_ name: String, to model: AppModel) {
        let command = WatchTimerCommand(
            timerId: model.canonicalTimer?.id,
            expectedTimerRevision: model.makeWatchSnapshot().timerRevision,
            name: name, phase: TimerPhase.shortBreak.rawValue, sentAt: .now
        )
        #expect(model.applyWatchCommand(command))
    }
}

/// An offline model on isolated defaults, a stubbed server and fake secret
/// stores. It never reads the system Keychain.
@MainActor
struct TimerControlFixture {
    static let timerID = "timer-control-use"
    /// One second into the seeded timer, so it has time remaining.
    static let launchDate = TestFixtures.anchor.addingTimeInterval(1)

    let model: AppModel
    private let suiteName: String
    private let defaults: UserDefaults
    private let session: URLSession

    init(seededTimerStatus: CanonicalTimer.Status?) throws {
        try self.init(state: Self.state(seededTimerStatus: seededTimerStatus), now: Self.launchDate)
    }

    /// `now` nil keeps the wall clock.
    init(
        state: PersistedTimerState,
        scenarioPrefix: String = "timer-control-use-",
        now: Date?
    ) throws {
        suiteName = scenarioPrefix + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(try JSONEncoder.api.encode(state), forKey: "timer-state-v2")
        session = TestFixtures.session(for: suiteName)
        model = AppModel(
            api: APIClient(session: session, keychain: StaticTokenStore()),
            defaults: defaults,
            roomStore: TestFixtures.emptyIrohRoomStore(),
            endpointKeyStore: TimerControlEndpointKeyStore(),
            alarmScheduler: RecordingAlarmScheduler(),
            googleIdentityProvider: RecordingGoogleIdentityProvider(),
            now: { now ?? .now }
        )
    }

    /// A fresh state whose timer, if any, this device owns.
    static func state(seededTimerStatus: CanonicalTimer.Status?) -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        guard let seededTimerStatus else { return state }
        let timer = TestFixtures.timer(status: seededTimerStatus, elapsed: 0, timerID: timerID)
        state.canonicalTimer = timer
        state.localTimerOwners[timer.id] = state.deviceId
        return state
    }

    func cleanUp() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct TimerControlEndpointKeyStore: IrohEndpointKeyStoring {
    func load() throws -> Data? { nil }
    func save(_ key: Data) throws {}
}
