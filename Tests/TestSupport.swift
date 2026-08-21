import Foundation
import Network
import Security
@testable import Pomodorough

enum TestFixtures {
    static let anchor = Date(timeIntervalSince1970: 1_000)
    static let user = User(id: "user-duration-sync", email: "sync@example.com", name: "Sync", avatarUrl: "")

    static func timer(
        status: CanonicalTimer.Status,
        elapsed: Int64,
        phase: TimerPhase = .focus,
        timerID: String = "timer-test0001",
        taskID: String? = nil,
        durationMs: Int64 = 60_000
    ) -> CanonicalTimer {
        CanonicalTimer(
            id: timerID,
            taskId: taskID,
            phase: phase,
            status: status,
            plannedDurationMs: durationMs,
            elapsedAtAnchorMs: elapsed,
            anchorAt: anchor,
            lastIntent: nil
        )
    }

    static func command(
        _ type: CommandType,
        sequence: Int64,
        elapsed: Int64,
        timerID: String = "timer-test0001",
        taskID: String? = nil
    ) -> TimerCommand {
        TimerCommand(
            id: "command-test\(sequence)",
            deviceSequence: sequence,
            timerId: timerID,
            taskId: taskID,
            type: type,
            phase: .focus,
            plannedDurationMs: 60_000,
            occurredAt: anchor.addingTimeInterval(Double(sequence)),
            hlcWallMs: Int64(anchor.timeIntervalSince1970 * 1_000) + sequence,
            hlcCounter: 0,
            observedElapsedMs: elapsed
        )
    }

    static func history(
        id: String,
        phase: TimerPhase = .focus,
        status: String = "completed",
        durationMs: Int64,
        date: Date,
        taskID: String? = nil
    ) -> HistoryItem {
        HistoryItem(
            id: id,
            timerId: id,
            commandId: "command-\(id)",
            taskId: taskID,
            phase: phase,
            status: status,
            plannedDurationMs: durationMs,
            completedAt: status == "completed" ? date : nil,
            endedAt: status == "completed" ? nil : date
        )
    }

    static func durationOperation(
        id: String,
        phase: TimerPhase,
        durationMs: Int64,
        wallMs: Int64,
        counter: Int64 = 0,
        occurredAt: Date? = nil
    ) -> DurationOperation {
        let defaultOccurredAt = wallMs == 0 && counter == 0
            ? Date(timeIntervalSince1970: 0)
            : Date(timeIntervalSince1970: TimeInterval(max(1, wallMs / 1_000)))
        return DurationOperation(
            id: id,
            phase: phase,
            durationMs: durationMs,
            occurredAt: occurredAt ?? defaultOccurredAt,
            hlcWallMs: wallMs,
            hlcCounter: counter
        )
    }

    static func autoStartOperation(
        id: UUID = UUID(),
        deviceID: String = "device-test",
        enabled: Bool,
        wallMs: Int64,
        counter: Int64 = 0,
        occurredAt: Date? = nil
    ) -> AutoStartOperation {
        let defaultOccurredAt = wallMs == 0 && counter == 0
            ? Date(timeIntervalSince1970: 0)
            : Date(timeIntervalSince1970: TimeInterval(max(1, wallMs / 1_000)))
        return AutoStartOperation(
            id: id,
            deviceId: deviceID,
            enabled: enabled,
            occurredAt: occurredAt ?? defaultOccurredAt,
            hlcWallMs: wallMs,
            hlcCounter: counter
        )
    }

    static func selectedTaskOperation(
        id: UUID = UUID(),
        deviceID: String = "device-test",
        taskID: UUID?,
        wallMs: Int64,
        counter: Int64 = 0,
        occurredAt: Date? = nil
    ) -> SelectedTaskOperation {
        let defaultOccurredAt = wallMs == 0 && counter == 0
            ? Date(timeIntervalSince1970: 0)
            : Date(timeIntervalSince1970: TimeInterval(max(1, wallMs / 1_000)))
        return SelectedTaskOperation(
            id: id,
            deviceId: deviceID,
            taskId: taskID?.uuidString.lowercased(),
            occurredAt: occurredAt ?? defaultOccurredAt,
            hlcWallMs: wallMs,
            hlcCounter: counter
        )
    }

    static func permutations<Value>(of values: [Value]) -> [[Value]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values
            let value = remaining.remove(at: index)
            return permutations(of: remaining).map { [value] + $0 }
        }
    }

    static func syncContractState(revision: Int64 = 10, includesPendingOperations: Bool) -> PersistedTimerState {
        var state = PersistedTimerState.fresh()
        state.cachedUser = user
        state.revision = revision
        let localTask = FocusTask(title: "Local canonical task")!
        state.tasks = [localTask]
        state.knownTasks = [localTask]
        state.canonicalTimer = timer(status: .completed, elapsed: 60_000, timerID: "local-canonical-timer")
        state.history = [history(
            id: "local-canonical-history",
            durationMs: 60_000,
            date: anchor
        )]
        guard includesPendingOperations else { return state }

        state.pendingCommands = [
            command(.start, sequence: 1, elapsed: 0, timerID: "pending-timer"),
            command(.pause, sequence: 2, elapsed: 10_000, timerID: "pending-timer"),
            command(.finish, sequence: 3, elapsed: 10_000, timerID: "pending-timer")
        ]
        let pendingTasks = (0..<3).map { FocusTask(title: "Pending task \($0)")! }
        state.knownTasks.append(contentsOf: pendingTasks)
        state.pendingTaskOperations = pendingTasks.enumerated().map { index, task in
            return TaskOperation(
                id: "pending-task-operation-\(index)",
                taskId: task.id.uuidString.lowercased(),
                type: .upsert,
                title: task.title,
                occurredAt: anchor,
                hlcWallMs: Int64(anchor.timeIntervalSince1970 * 1_000) + Int64(index + 1),
                hlcCounter: 0
            )
        }
        state.pendingDurationOperations = zip(TimerPhase.allCases, [30, 10, 20]).enumerated().map { index, value in
            durationOperation(
                id: "pending-duration-operation-\(index)",
                phase: value.0,
                durationMs: Int64(value.1 * 60_000),
                wallMs: Int64(index + 4)
            )
        }
        state.settings.durationsMs = DurationReducer.applying(
            state.pendingDurationOperations,
            to: state.settings.durationsMs
        )
        state.pendingAutoStartOperations = (0..<3).map { index in
            autoStartOperation(
                deviceID: state.deviceId,
                enabled: index.isMultiple(of: 2),
                wallMs: Int64(index + 7)
            )
        }
        return state
    }

    static func session(for scenario: String, resetsRecorder: Bool = true) -> URLSession {
        if resetsRecorder {
            StubRequestRecorder.shared.reset(scenario: scenario)
            StubScenarioGate.shared.reset(scenario: scenario)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Pomodorough-Test-Scenario": scenario]
        return URLSession(configuration: configuration)
    }

    static func recordedRequests(for scenario: String) -> [RecordedRequest] {
        StubRequestRecorder.shared.requests(for: scenario)
    }

    static func waitForRequest(
        in scenario: String,
        path: String,
        count: Int = 1,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        await StubRequestRecorder.shared.waitForRequest(
            in: scenario,
            path: path,
            count: count,
            timeout: timeout
        )
    }

    static func releaseScenario(_ scenario: String) {
        StubScenarioGate.shared.release(scenario: scenario)
    }
}

final class LockedTestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

final class ScriptedWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        precondition(!dates.isEmpty)
        self.dates = dates
    }

    func now() -> Date {
        lock.withLock {
            guard dates.count > 1 else { return dates[0] }
            return dates.removeFirst()
        }
    }
}

final class ScriptedUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func now() -> TimeInterval {
        lock.withLock {
            guard values.count > 1 else { return values[0] }
            return values.removeFirst()
        }
    }
}

struct EmptyTokenStore: TokenStoring {
    func load() throws -> TokenPair? { nil }
    func save(_ tokens: TokenPair) throws {}
    func delete() throws {}
}

struct StaticTokenStore: TokenStoring {
    let tokens = TokenPair(
        accessToken: "access-token",
        accessTokenExpiresAt: Date.distantFuture,
        refreshToken: "refresh-token",
        refreshTokenExpiresAt: Date.distantFuture
    )

    func load() throws -> TokenPair? { tokens }
    func save(_ tokens: TokenPair) throws {}
    func delete() throws {}
}

enum RecordingTokenStoreFailure: Error, Equatable, Hashable, Sendable {
    case load
    case save
    case delete
}

enum RecordedTokenStoreOperation: Equatable, Sendable {
    case load
    case save(accessToken: String, refreshToken: String)
    case delete
}

final class RecordingTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let failures: Set<RecordingTokenStoreFailure>
    private var storedTokens: TokenPair?
    private var recordedOperations: [RecordedTokenStoreOperation] = []

    init(
        tokens: TokenPair? = nil,
        failures: Set<RecordingTokenStoreFailure> = []
    ) {
        storedTokens = tokens
        self.failures = failures
    }

    var tokens: TokenPair? {
        lock.withLock { storedTokens }
    }

    var operations: [RecordedTokenStoreOperation] {
        lock.withLock { recordedOperations }
    }

    func replaceTokens(_ tokens: TokenPair?) {
        lock.withLock { storedTokens = tokens }
    }

    func load() throws -> TokenPair? {
        try lock.withLock {
            recordedOperations.append(.load)
            if failures.contains(.load) { throw RecordingTokenStoreFailure.load }
            return storedTokens
        }
    }

    func save(_ tokens: TokenPair) throws {
        try lock.withLock {
            recordedOperations.append(.save(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            ))
            if failures.contains(.save) { throw RecordingTokenStoreFailure.save }
            storedTokens = tokens
        }
    }

    func delete() throws {
        try lock.withLock {
            recordedOperations.append(.delete)
            if failures.contains(.delete) { throw RecordingTokenStoreFailure.delete }
            storedTokens = nil
        }
    }
}

struct KeychainQuerySnapshot: Equatable, Sendable {
    let itemClass: String?
    let service: String?
    let account: String?
    let accessible: String?
    let returnsData: Bool?
    let matchLimit: String?
    let valueData: Data?

    init(_ query: [String: Any]) {
        itemClass = query[kSecClass as String] as? String
        service = query[kSecAttrService as String] as? String
        account = query[kSecAttrAccount as String] as? String
        accessible = query[kSecAttrAccessible as String] as? String
        returnsData = query[kSecReturnData as String] as? Bool
        matchLimit = query[kSecMatchLimit as String] as? String
        valueData = query[kSecValueData as String] as? Data
    }
}

struct RecordedKeychainUpdate: Equatable, Sendable {
    let query: KeychainQuerySnapshot
    let attributes: KeychainQuerySnapshot
}

final class RecordingKeychainSecurity: KeychainSecurityOperating, @unchecked Sendable {
    private let lock = NSLock()
    private let copyStatus: OSStatus
    private let copyData: Data?
    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus
    private var storedCopyQueries: [KeychainQuerySnapshot] = []
    private var storedUpdates: [RecordedKeychainUpdate] = []
    private var storedAddQueries: [KeychainQuerySnapshot] = []
    private var storedDeleteQueries: [KeychainQuerySnapshot] = []

    init(
        copyStatus: OSStatus = errSecItemNotFound,
        copyData: Data? = nil,
        updateStatus: OSStatus = errSecSuccess,
        addStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.copyStatus = copyStatus
        self.copyData = copyData
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    var copyQueries: [KeychainQuerySnapshot] { lock.withLock { storedCopyQueries } }
    var updates: [RecordedKeychainUpdate] { lock.withLock { storedUpdates } }
    var addQueries: [KeychainQuerySnapshot] { lock.withLock { storedAddQueries } }
    var deleteQueries: [KeychainQuerySnapshot] { lock.withLock { storedDeleteQueries } }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock { storedCopyQueries.append(KeychainQuerySnapshot(query)) }
        return (copyStatus, copyData)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            storedUpdates.append(RecordedKeychainUpdate(
                query: KeychainQuerySnapshot(query),
                attributes: KeychainQuerySnapshot(attributes)
            ))
        }
        return updateStatus
    }

    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock { storedAddQueries.append(KeychainQuerySnapshot(query)) }
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { storedDeleteQueries.append(KeychainQuerySnapshot(query)) }
        return deleteStatus
    }

    func errorMessage(for status: OSStatus) -> String? { "test status \(status)" }
}

final class MemoryIrohRoomSecretStore: IrohRoomSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data]

    init(secrets: [String: Data] = [:]) {
        self.secrets = secrets
    }

    func load(roomID: String) throws -> Data? {
        lock.withLock { secrets[roomID] }
    }

    func save(_ secret: Data, roomID: String) throws {
        lock.withLock { secrets[roomID] = secret }
    }

    func delete(roomID: String) throws {
        lock.withLock { secrets[roomID] = nil }
    }
}

#if os(macOS)
final class RecordingGoogleOAuthTransport: GoogleOAuthTokenExchangeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let response: URLResponse
    private var storedRequests: [URLRequest] = []

    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }

    var requests: [URLRequest] { lock.withLock { storedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { storedRequests.append(request) }
        return (data, response)
    }
}
#endif

final class RecordingUserDefaults: UserDefaults {
    private(set) var timerStateWrites: [Data] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        if defaultName == "timer-state-v2", let data = value as? Data {
            timerStateWrites.append(data)
        }
    }

    func resetTimerStateWrites() {
        timerStateWrites = []
    }
}

enum RecordedAlarmOperation: Equatable {
    case requestAuthorization
    case schedule(timerID: String, phase: TimerPhase, duration: TimeInterval)
    case pause(timerID: String)
    case resume(timerID: String, phase: TimerPhase, duration: TimeInterval)
    case cancel(timerID: String)
}

@MainActor
final class RecordingAlarmScheduler: TimerAlarmScheduling {
    var operations: [RecordedAlarmOperation] = []
    var authorizationError: Error?
    var schedulingError: Error?
    var cancellationError: Error?

    func requestAuthorization() async throws {
        operations.append(.requestAuthorization)
        if let authorizationError { throw authorizationError }
    }

    func schedule(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        operations.append(.schedule(timerID: timerID, phase: phase, duration: duration))
        if let schedulingError { throw schedulingError }
    }

    func pause(timerID: String) async throws {
        operations.append(.pause(timerID: timerID))
    }

    func resume(timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        operations.append(.resume(timerID: timerID, phase: phase, duration: duration))
    }

    func cancel(timerID: String) async throws {
        operations.append(.cancel(timerID: timerID))
        if let cancellationError { throw cancellationError }
    }
}

@MainActor
final class RecordingGoogleIdentityProvider: GoogleIdentityProviding {
    var identityTokenResult: Result<String, Error> = .success("google-identity-token")
    var handledURLs: [URL] = []
    private(set) var nonces: [String] = []
    private(set) var signOutCount = 0

    func identityToken(nonce: String) async throws -> String {
        nonces.append(nonce)
        return try identityTokenResult.get()
    }

    func handle(_ url: URL) -> Bool {
        handledURLs.append(url)
        return true
    }

    func signOut() {
        signOutCount += 1
    }
}

enum RecordedNotificationBackendOperation: Equatable {
    case requestAuthorization
    case canSchedule
    case schedule(identifier: String, phase: TimerPhase, duration: TimeInterval)
    case remove(identifier: String)
}

@MainActor
final class RecordingNotificationBackend: TimerNotificationBackend {
    var isSupported = true
    var authorizationResult = false
    var canScheduleResult = false
    var authorizationError: Error?
    var schedulingError: Error?
    var suspendsScheduling = false
    private(set) var operations: [RecordedNotificationBackendOperation] = []
    private var schedulingContinuation: CheckedContinuation<Void, Never>?
    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    func requestAuthorization() async throws -> Bool {
        operations.append(.requestAuthorization)
        if let authorizationError { throw authorizationError }
        return authorizationResult
    }

    func canSchedule() async -> Bool {
        operations.append(.canSchedule)
        return canScheduleResult
    }

    func schedule(identifier: String, phase: TimerPhase, duration: TimeInterval) async throws {
        operations.append(.schedule(identifier: identifier, phase: phase, duration: duration))
        if suspendsScheduling {
            await withCheckedContinuation {
                schedulingContinuation = $0
                suspendedContinuation?.resume()
                suspendedContinuation = nil
            }
        }
        if let schedulingError { throw schedulingError }
    }

    func remove(identifier: String) {
        operations.append(.remove(identifier: identifier))
    }

    func releaseScheduling() {
        schedulingContinuation?.resume()
        schedulingContinuation = nil
    }

    func waitUntilSchedulingSuspends() async {
        guard schedulingContinuation == nil else { return }
        await withCheckedContinuation { suspendedContinuation = $0 }
    }
}

enum RecordedSystemAlarmBackendOperation: Equatable {
    case requestAuthorization
    case schedule(id: UUID, timerID: String, phase: TimerPhase, duration: TimeInterval)
    case pause(id: UUID)
    case resume(id: UUID)
    case cancel(id: UUID)
}

@MainActor
final class RecordingSystemAlarmBackend: TimerSystemAlarmBackend {
    var authorizationState: TimerSystemAlarmAuthorizationState = .unsupported
    var authorizationResult = false
    var authorizationError: Error?
    var operationError: Error?
    private(set) var operations: [RecordedSystemAlarmBackendOperation] = []
    private var scheduledIDs: Set<UUID> = []

    func requestAuthorization() async throws -> Bool {
        operations.append(.requestAuthorization)
        if let authorizationError { throw authorizationError }
        return authorizationResult
    }

    func schedule(id: UUID, timerID: String, phase: TimerPhase, duration: TimeInterval) async throws {
        operations.append(.schedule(id: id, timerID: timerID, phase: phase, duration: duration))
        if let operationError { throw operationError }
        scheduledIDs.insert(id)
    }

    func pause(id: UUID) throws {
        guard scheduledIDs.contains(id) else { return }
        operations.append(.pause(id: id))
        if let operationError { throw operationError }
    }

    func resume(id: UUID) throws -> Bool {
        guard scheduledIDs.contains(id) else { return false }
        operations.append(.resume(id: id))
        if let operationError { throw operationError }
        return true
    }

    func cancel(id: UUID) throws {
        guard scheduledIDs.contains(id) else { return }
        operations.append(.cancel(id: id))
        if let operationError { throw operationError }
        scheduledIDs.remove(id)
    }
}

struct RecordedRequest: Sendable {
    let method: String
    let url: String
    let path: String
    let body: Data?
    let accept: String?
    let contentType: String?
    let authorization: String?
}

struct LoopbackHTTPResponse: Sendable {
    let statusCode: Int
    let contentType: String
    let body: Data

    init(statusCode: Int = 200, contentType: String = "application/json", body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    private final class StartupState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPort: UInt16?
        private var storedError: Error?

        func succeed(port: UInt16?) {
            lock.withLock { storedPort = port }
        }

        func fail(_ error: Error) {
            lock.withLock { storedError = error }
        }

        var result: (port: UInt16?, error: Error?) {
            lock.withLock { (storedPort, storedError) }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "PomodoroughTests.LoopbackHTTPServer")
    private let lock = NSLock()
    private var recordedRequest = Data()

    private(set) var baseURL = URL(string: "http://127.0.0.1")!

    convenience init(statusCode: Int = 200, contentType: String, body: Data) throws {
        try self.init { _ in
            LoopbackHTTPResponse(statusCode: statusCode, contentType: contentType, body: body)
        }
    }

    init(response: @escaping @Sendable (Data) -> LoopbackHTTPResponse) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let started = DispatchSemaphore(value: 0)
        let startup = StartupState()

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.succeed(port: self.listener.port?.rawValue)
                started.signal()
            case .failed(let error):
                startup.fail(error)
                started.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                data, _, _, _ in
                let request = data ?? Data()
                self.lock.withLock { self.recordedRequest.append(request) }
                let response = response(request)
                let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                let headers = Data((
                    "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
                        + "Content-Type: \(response.contentType)\r\n"
                        + "Content-Length: \(response.body.count)\r\n"
                        + "Connection: close\r\n\r\n"
                ).utf8)
                connection.send(
                    content: headers + response.body,
                    completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + 1) {
                            connection.cancel()
                        }
                    }
                )
            }
        }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw URLError(.timedOut)
        }
        let startupResult = startup.result
        if let startupError = startupResult.error {
            listener.cancel()
            throw startupError
        }
        guard let port = startupResult.port,
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        baseURL = url
    }

    deinit {
        listener.cancel()
    }

    var request: String {
        lock.withLock { String(decoding: recordedRequest, as: UTF8.self) }
    }
}

final class StubRequestRecorder: @unchecked Sendable {
    static let shared = StubRequestRecorder()

    private struct Waiter {
        let id: UUID
        let path: String
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var storage: [String: [RecordedRequest]] = [:]
    private var waiters: [String: [Waiter]] = [:]

    func reset(scenario: String) {
        let continuations = lock.withLock {
            storage[scenario] = []
            return waiters.removeValue(forKey: scenario)?.map(\.continuation) ?? []
        }
        continuations.forEach { $0.resume(returning: false) }
    }

    func record(_ request: URLRequest, body: Data?, scenario: String) -> Int {
        let result = lock.withLock {
            let recorded = RecordedRequest(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                path: request.url?.path ?? "",
                body: body,
                accept: request.value(forHTTPHeaderField: "Accept"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
            storage[scenario, default: []].append(recorded)
            let pathCount = storage[scenario, default: []].count { $0.path == recorded.path }
            let ready = waiters[scenario, default: []].filter {
                $0.path == recorded.path && pathCount >= $0.count
            }
            waiters[scenario, default: []].removeAll {
                $0.path == recorded.path && pathCount >= $0.count
            }
            return (pathCount, ready.map(\.continuation))
        }
        result.1.forEach { $0.resume(returning: true) }
        return result.0
    }

    func requests(for scenario: String) -> [RecordedRequest] {
        lock.withLock { storage[scenario] ?? [] }
    }

    func waitForRequest(
        in scenario: String,
        path: String,
        count: Int,
        timeout: Duration
    ) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let isReady = lock.withLock {
                if storage[scenario, default: []].count(where: { $0.path == path }) >= count {
                    return true
                }
                waiters[scenario, default: []].append(Waiter(
                    id: id,
                    path: path,
                    count: count,
                    continuation: continuation
                ))
                return false
            }
            if isReady {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let timedOut: CheckedContinuation<Bool, Never>? = self.lock.withLock {
                    guard let index = self.waiters[scenario, default: []].firstIndex(where: {
                        $0.id == id
                    }) else { return nil }
                    return self.waiters[scenario, default: []].remove(at: index).continuation
                }
                timedOut?.resume(returning: false)
            }
        }
    }
}

final class StubScenarioGate: @unchecked Sendable {
    static let shared = StubScenarioGate()

    private let condition = NSCondition()
    private var releasedScenarios = Set<String>()

    func reset(scenario: String) {
        condition.withLock { _ = releasedScenarios.remove(scenario) }
    }

    func wait(scenario: String, isCancelled: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !releasedScenarios.contains(scenario), !isCancelled() {
            condition.wait()
        }
        return !isCancelled()
    }

    func release(scenario: String) {
        condition.withLock {
            releasedScenarios.insert(scenario)
            condition.broadcast()
        }
    }

    func wakeWaiters() {
        condition.withLock { condition.broadcast() }
    }
}

final class StubURLProtocol: URLProtocol {
    private let loadingLock = NSRecursiveLock()
    private var loadingStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Pomodorough-Test-Scenario") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Pomodorough-Test-Scenario")
        let requestBody = Self.bodyData(request)
        let pathAttempt = scenario.map {
            StubRequestRecorder.shared.record(request, body: requestBody, scenario: $0)
        } ?? 0
        if scenario == "non-http-response" {
            let response = URLResponse(
                url: request.url!,
                mimeType: "application/json",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if scenario == "apple-api-coverage-stream-transport" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let statusCode: Int
        let body: Data
        let path = request.url?.path

        if let scenario, scenario.hasPrefix("apple-api-coverage-") {
            loadAPICoverageResponse(
                scenario: scenario,
                path: path,
                pathAttempt: pathAttempt,
                requestBody: requestBody
            )
            return
        }

        switch scenario {
        case "challenge-success"
            where request.httpMethod == "POST"
                && request.url?.path == "/api/v1/auth/google/challenge"
                && request.value(forHTTPHeaderField: "Accept") == "application/json":
            statusCode = 200
            body = Data(#"{"challenge":"challenge-123","nonce":"nonce-456","expiresAt":"2026-07-20T12:34:56.789Z"}"#.utf8)
        case "bootstrap-offline-sign-in"
            where request.httpMethod == "POST" && path == "/api/v1/auth/google/challenge":
            statusCode = 200
            body = Data(#"{"challenge":"offline-challenge","nonce":"offline-nonce","expiresAt":"2099-01-01T00:00:00.000Z"}"#.utf8)
        case "bootstrap-offline-sign-in"
            where request.httpMethod == "POST" && path == "/api/v1/auth/google/exchange":
            statusCode = 200
            body = Self.tokenPairBody(accessToken: "offline-access", refreshToken: "offline-refresh")
        case "server-error":
            statusCode = 422
            body = Data(#"{"error":"Challenge expired."}"#.utf8)
        case "fallback-server-error":
            statusCode = 503
            body = Data("not-json".utf8)
        case "malformed-success":
            statusCode = 200
            body = Data("{".utf8)
        case "standard-date":
            statusCode = 200
            body = Data(#"{"challenge":"challenge-123","nonce":"nonce-456","expiresAt":"2026-07-20T12:34:56Z"}"#.utf8)
        case "duration-sync" where request.url?.path == "/api/v1/me":
            statusCode = 200
            body = Data(#"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8)
        case "duration-invalid-ack" where request.url?.path == "/api/v1/me":
            statusCode = 200
            body = Data(#"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8)
        case "bootstrap-delayed-me" where path == "/api/v1/me":
            Thread.sleep(forTimeInterval: 0.5)
            statusCode = 200
            body = Self.meBody
        case "bootstrap-reauth-different-user" where path == "/api/v1/me":
            Thread.sleep(forTimeInterval: 0.5)
            statusCode = 200
            body = Self.differentUserMeBody
        case _ where Self.usesBootstrapStub(scenario) && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "bootstrap-get-404"
            where request.httpMethod == "GET"
                && path == "/api/v1/bootstrap":
            statusCode = 404
            body = Data(#"{"error":"Not found"}"#.utf8)
        case _ where Self.usesBootstrapStub(scenario)
            && request.httpMethod == "GET"
            && path == "/api/v1/bootstrap":
            statusCode = 200
            let history = Self.bootstrapHistory(for: scenario)
            body = Self.syncResponse(
                revision: history.isEmpty ? 5 : 8,
                history: history,
                autoStartBreaks: scenario?.contains("auto-start-remote-true") == true,
                tasks: scenario == "bootstrap-local-history-remote-task" ? [Self.remoteTask] : []
            )
        case "bootstrap-network-retry"
            where request.httpMethod == "POST"
                && path == "/api/v1/bootstrap/resolve"
                && pathAttempt == 1:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case "bootstrap-cas-conflict"
            where request.httpMethod == "POST"
                && path == "/api/v1/bootstrap/resolve":
            statusCode = 409
            body = Data(#"{"error":"revision conflict"}"#.utf8)
        case "bootstrap-resolve-unauthorized"
            where request.httpMethod == "POST"
                && path == "/api/v1/bootstrap/resolve"
                && pathAttempt == 1:
            statusCode = 401
            body = Data(#"{"error":"Unauthorized"}"#.utf8)
        case _ where (scenario == "bootstrap-resolve-404" || scenario == "bootstrap-resolve-race-404")
            && request.httpMethod == "POST"
            && path == "/api/v1/bootstrap/resolve":
            statusCode = 404
            body = Data(#"{"error":"Not found"}"#.utf8)
        case _ where Self.usesBootstrapStub(scenario)
            && request.httpMethod == "POST"
            && path == "/api/v1/bootstrap/resolve":
            statusCode = 200
            let requestObject = Self.requestObject(requestBody)
            let strategy = requestObject?["strategy"] as? String
            body = Self.bootstrapResolveResponse(
                scenario: scenario,
                strategy: strategy,
                request: requestObject
            )
        case "bootstrap-resolve-race-404"
            where request.httpMethod == "POST"
                && path == "/api/v1/sync":
            statusCode = 200
            body = Self.syncResponse(revision: 8, history: [Self.remoteHistory])
        case "bootstrap-auto-start-remote-true-legacy-keep-omitted"
            where request.httpMethod == "POST"
                && path == "/api/v1/sync":
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case _ where Self.usesBootstrapStub(scenario)
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            let requestObject = Self.requestObject(requestBody)
            let resolutionRequest = Self.resolutionRequestObject(for: scenario)
            body = Self.syncResponse(
                revision: 10,
                history: Self.resolvedHistory(
                    for: resolutionRequest?["strategy"] as? String,
                    scenario: scenario
                ),
                acknowledgements: Self.acknowledgements(from: requestObject, key: "commands", idKey: "commandId"),
                taskAcknowledgements: Self.acknowledgements(from: requestObject, key: "taskOperations", idKey: "operationId"),
                durationAcknowledgements: Self.acknowledgements(from: requestObject, key: "durationOperations", idKey: "operationId"),
                autoStartAcknowledgements: Self.acknowledgements(
                    from: requestObject,
                    key: "autoStartOperations",
                    idKey: "operationId"
                ),
                selectedTaskAcknowledgements: Self.acknowledgements(
                    from: requestObject,
                    key: "selectedTaskOperations",
                    idKey: "operationId"
                ),
                autoStartBreaks: Self.bootstrapAutoStartValue(
                    strategy: resolutionRequest?["strategy"] as? String,
                    request: resolutionRequest,
                    remoteValue: scenario?.contains("auto-start-remote-true") == true
                ),
                tasks: Self.tasks(from: resolutionRequest),
                canonicalTimer: Self.bootstrapOwnershipTimer(
                    for: scenario,
                    request: requestObject
                )
            )
        case _ where scenario?.hasPrefix("task-sync") == true && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case _ where scenario?.hasPrefix("selected-task-sync") == true && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case _ where (scenario?.hasPrefix("auto-start-") == true || scenario == "timer-cycle")
            && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case _ where scenario?.hasPrefix("sync-contract-") == true && path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "sync-restart-checkpoints" where path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "sync-restart-checkpoints"
            where request.httpMethod == "POST" && path == "/api/v1/sync":
            if pathAttempt == 1 {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            statusCode = 200
            body = Self.timerCycleResponse(
                scenario: scenario!,
                request: Self.requestObject(requestBody)
            )
        case "sync-account-switch-stale" where path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "sync-account-switch-stale"
            where request.httpMethod == "POST" && path == "/api/v1/sync":
            guard StubScenarioGate.shared.wait(
                scenario: scenario!,
                isCancelled: { self.loadingLock.withLock { self.loadingStopped } }
            ) else { return }
            statusCode = 200
            body = Self.timerCycleResponse(
                scenario: scenario!,
                request: Self.requestObject(requestBody)
            )
        case "sync-account-switch-stale"
            where request.httpMethod == "POST" && path == "/api/v1/auth/logout":
            statusCode = 204
            body = Data()
        case _ where scenario?.hasPrefix("auto-start-matrix-") == true
            && scenario?.contains("-lost-") == true
            && request.httpMethod == "POST"
            && path == "/api/v1/sync"
            && pathAttempt == 1:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case _ where (scenario?.hasPrefix("auto-start-") == true || scenario == "timer-cycle")
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            body = scenario == "timer-cycle"
                ? Self.timerCycleResponse(scenario: scenario!, request: Self.requestObject(requestBody))
                : Self.autoStartSyncResponse(
                    scenario: scenario!,
                    pathAttempt: pathAttempt,
                    request: Self.requestObject(requestBody)
                )
        case _ where scenario?.hasPrefix("task-sync") == true
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            body = Self.taskSyncResponse(
                scenario: scenario,
                pathAttempt: pathAttempt,
                request: Self.requestObject(requestBody)
            )
        case _ where scenario?.hasPrefix("selected-task-sync") == true
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            body = Self.selectedTaskSyncResponse(
                scenario: scenario!,
                request: Self.requestObject(requestBody)
            )
        case _ where scenario?.hasPrefix("sync-contract-") == true
            && request.httpMethod == "POST"
            && path == "/api/v1/sync":
            statusCode = 200
            body = Self.syncContractResponse(
                scenario: scenario!,
                request: Self.requestObject(requestBody)
            )
        case "task-missing-ack" where path == "/api/v1/me":
            statusCode = 200
            body = Self.meBody
        case "task-missing-ack" where request.httpMethod == "POST" && path == "/api/v1/sync":
            statusCode = 200
            body = Self.syncResponse(revision: 12, history: [], tasks: [Self.remoteTask])
        case "duration-sync"
            where request.httpMethod == "POST"
                && request.url?.path == "/api/v1/sync":
            statusCode = 200
            body = Data(#"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[],"autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[],"selectedTaskId":null,"durationsMs":{"focus":2400000,"short_break":360000,"long_break":1200000},"autoStartBreaks":false,"revision":7,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":4}"#.utf8)
        case "duration-invalid-ack"
            where request.httpMethod == "POST"
                && request.url?.path == "/api/v1/sync":
            statusCode = 200
            body = Data(#"{"acknowledgements":[],"taskAcknowledgements":[],"durationAcknowledgements":[{"operationId":"duration-operation-unexpected","outcome":"applied","reason":""}],"autoStartAcknowledgements":[],"selectedTaskAcknowledgements":[],"selectedTaskId":null,"durationsMs":{"focus":1800000,"short_break":300000,"long_break":900000},"autoStartBreaks":false,"revision":7,"canonicalTimer":null,"history":[],"tasks":[],"serverTime":"2026-07-21T08:00:00.000Z","serverHlcWallMs":1784620800000,"serverHlcCounter":4}"#.utf8)
        case "unauthorized":
            statusCode = 401
            body = Data(#"{"error":"Unauthorized"}"#.utf8)
        default:
            statusCode = 400
            body = Data(#"{"error":"Unexpected test request."}"#.utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        loadingLock.withLock { loadingStopped = true }
        StubScenarioGate.shared.wakeWaiters()
    }

    private func loadAPICoverageResponse(
        scenario: String,
        path: String?,
        pathAttempt: Int,
        requestBody: Data?
    ) {
        let statusCode: Int
        let body: Data
        var contentType = "application/json"

        switch (scenario, path) {
        case ("apple-api-coverage-stream-unauthorized", "/api/v1/stream"):
            statusCode = 401
            contentType = "text/event-stream"
            body = Data()
        case ("apple-api-coverage-stream-json", "/api/v1/stream"):
            statusCode = 200
            body = Data(#"{"revision":42}"#.utf8)
        case ("apple-api-coverage-stream-server-error", "/api/v1/stream"):
            statusCode = 503
            contentType = "text/event-stream"
            body = Data()
        case ("apple-api-coverage-expired-refresh-me", "/api/v1/auth/refresh"):
            statusCode = 200
            body = Self.tokenPairBody(accessToken: "refreshed-access", refreshToken: "refreshed-refresh")
        case ("apple-api-coverage-concurrent-refresh-single-flight", "/api/v1/auth/refresh"):
            guard StubScenarioGate.shared.wait(
                scenario: scenario,
                isCancelled: { self.loadingLock.withLock { self.loadingStopped } }
            ) else { return }
            statusCode = 200
            body = Self.tokenPairBody(accessToken: "concurrent-access", refreshToken: "concurrent-refresh")
        case ("apple-api-coverage-stale-refresh-generation", "/api/v1/auth/refresh"):
            if pathAttempt == 1 {
                guard StubScenarioGate.shared.wait(
                    scenario: scenario,
                    isCancelled: { self.loadingLock.withLock { self.loadingStopped } }
                ) else { return }
            }
            let refreshToken = (Self.requestObject(requestBody)?["refreshToken"] as? String) ?? ""
            statusCode = 200
            body = refreshToken == "replacement-expired-refresh"
                ? Self.tokenPairBody(accessToken: "replacement-access", refreshToken: "replacement-refresh")
                : Self.tokenPairBody(accessToken: "stale-access", refreshToken: "stale-refresh")
        case ("apple-api-coverage-expired-refresh-me", "/api/v1/me"),
             ("apple-api-coverage-concurrent-refresh-single-flight", "/api/v1/me"),
             ("apple-api-coverage-stale-refresh-generation", "/api/v1/me"),
             ("apple-api-coverage-exchange-save-me", "/api/v1/me"),
             ("apple-api-coverage-model-sign-in", "/api/v1/me"):
            statusCode = 200
            body = Self.meBody
        case ("apple-api-coverage-model-sign-in", "/api/v1/auth/google/challenge"),
             ("apple-api-coverage-model-identity-failure", "/api/v1/auth/google/challenge"):
            statusCode = 200
            body = Data(#"{"challenge":"model-challenge","nonce":"model-nonce","expiresAt":"2099-01-01T00:00:00.000Z"}"#.utf8)
        case ("apple-api-coverage-model-sign-in", "/api/v1/auth/google/exchange"):
            statusCode = 200
            body = Self.tokenPairBody(accessToken: "model-access", refreshToken: "model-refresh")
        case ("apple-api-coverage-model-sign-in", "/api/v1/sync"):
            statusCode = 200
            body = Self.syncResponse(revision: 0, history: [])
        case ("apple-api-coverage-model-sign-in", "/api/v1/auth/logout"):
            statusCode = 204
            body = Data()
        case ("apple-api-coverage-exchange-save-me", "/api/v1/auth/google/exchange"),
             ("apple-api-coverage-exchange-save-failure", "/api/v1/auth/google/exchange"):
            statusCode = 200
            body = Self.tokenPairBody(accessToken: "exchange-access", refreshToken: "exchange-refresh")
        case ("apple-api-coverage-logout-success", "/api/v1/auth/logout"),
             ("apple-api-coverage-logout-delete-failure", "/api/v1/auth/logout"):
            statusCode = 204
            body = Data()
        case ("apple-api-coverage-logout-server-failure", "/api/v1/auth/logout"):
            statusCode = 503
            body = Data(#"{"error":"Logout unavailable."}"#.utf8)
        case ("apple-api-coverage-account-delete-success", "/api/v1/me"):
            statusCode = 200
            body = Self.meBody
        case ("apple-api-coverage-account-delete-success", "/api/v1/account"):
            statusCode = 204
            body = Data()
        case ("apple-api-coverage-bootstrap-nonempty-timer-ack", "/api/v1/bootstrap"),
             ("apple-api-coverage-bootstrap-nonempty-task-ack", "/api/v1/bootstrap"),
             ("apple-api-coverage-bootstrap-nonempty-duration-ack", "/api/v1/bootstrap"),
             ("apple-api-coverage-bootstrap-nonempty-auto-start-ack", "/api/v1/bootstrap"),
             ("apple-api-coverage-bootstrap-nonempty-selected-task-ack", "/api/v1/bootstrap"):
            statusCode = 200
            body = Self.bootstrapResponseWithAcknowledgement(for: scenario)
        case ("apple-api-coverage-bootstrap-malformed-2xx", "/api/v1/bootstrap"),
             ("apple-api-coverage-bootstrap-resolve-malformed-2xx", "/api/v1/bootstrap/resolve"),
             ("apple-api-coverage-sync-malformed-2xx", "/api/v1/sync"):
            statusCode = 200
            body = Data("{".utf8)
        default:
            statusCode = 400
            body = Data(#"{"error":"Unexpected Apple coverage request."}"#.utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        guard deliverIfLoading({
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }) else { return }
        guard deliverIfLoading({ client?.urlProtocol(self, didLoad: body) }) else { return }
        _ = deliverIfLoading({ client?.urlProtocolDidFinishLoading(self) })
    }

    private func deliverIfLoading(_ callback: () -> Void) -> Bool {
        loadingLock.withLock {
            guard !loadingStopped else { return false }
            callback()
            return true
        }
    }

    private static func tokenPairBody(accessToken: String, refreshToken: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "accessToken": accessToken,
            "accessTokenExpiresAt": "2099-01-01T00:00:00.000Z",
            "refreshToken": refreshToken,
            "refreshTokenExpiresAt": "2099-01-01T00:00:00.000Z"
        ])
    }

    private static func bootstrapResponseWithAcknowledgement(for scenario: String) -> Data {
        var response = syncResponseObject(
            revision: 1,
            history: [],
            acknowledgements: [],
            taskAcknowledgements: [],
            durationAcknowledgements: [],
            autoStartAcknowledgements: [],
            selectedTaskAcknowledgements: [],
            tasks: []
        )
        switch scenario {
        case "apple-api-coverage-bootstrap-nonempty-timer-ack":
            response["acknowledgements"] = [[
                "commandId": "coverage-command",
                "outcome": "applied",
                "reason": ""
            ]]
        case "apple-api-coverage-bootstrap-nonempty-task-ack":
            response["taskAcknowledgements"] = [[
                "operationId": "coverage-task-operation",
                "outcome": "applied",
                "reason": ""
            ]]
        case "apple-api-coverage-bootstrap-nonempty-duration-ack":
            response["durationAcknowledgements"] = [[
                "operationId": "coverage-duration-operation",
                "outcome": "applied",
                "reason": ""
            ]]
        case "apple-api-coverage-bootstrap-nonempty-auto-start-ack":
            response["autoStartAcknowledgements"] = [[
                "operationId": "00000000-0000-4000-8000-000000000001",
                "outcome": "applied",
                "reason": ""
            ]]
        case "apple-api-coverage-bootstrap-nonempty-selected-task-ack":
            response["selectedTaskAcknowledgements"] = [[
                "operationId": "00000000-0000-4000-8000-000000000002",
                "outcome": "applied",
                "reason": ""
            ]]
        default:
            break
        }
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private static let meBody = Data(
        #"{"user":{"id":"user-duration-sync","email":"sync@example.com","name":"Sync","avatarUrl":""},"csrfToken":"csrf"}"#.utf8
    )

    private static let differentUserMeBody = Data(
        #"{"user":{"id":"different-bootstrap-user","email":"different@example.com","name":"Different","avatarUrl":""},"csrfToken":"csrf"}"#.utf8
    )

    private static var localHistory: [String: Any] {
        [
            "id": "local-history",
            "timerId": "local-timer",
            "commandId": "command-test2",
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": 60_000,
            "completedAt": "2026-07-21T08:00:00.000Z"
        ]
    }

    private static var remoteHistory: [String: Any] {
        [
            "id": "remote-history",
            "timerId": "remote-timer",
            "commandId": "remote-command",
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": 1_500_000,
            "completedAt": "2026-07-20T08:00:00.000Z"
        ]
    }

    private static func remoteEndedHistory(id: String, status: String) -> [String: Any] {
        [
            "id": id,
            "timerId": "timer-\(id)",
            "commandId": "command-\(id)",
            "phase": "focus",
            "status": status,
            "plannedDurationMs": 1_500_000,
            "endedAt": "2026-07-20T08:00:00.000Z"
        ]
    }

    private static var remoteTask: [String: Any] {
        [
            "id": "53bef65b-b59f-8614-9a1c-68951ad20089",
            "title": "Remote task"
        ]
    }

    private static var selectedPreferenceTask: [String: Any] {
        let task = FocusTask(title: "Central selection")!
        return ["id": task.id.uuidString.lowercased(), "title": task.title]
    }

    private static var selectedBuildTask: [String: Any] {
        let task = FocusTask(title: "Captured build")!
        return ["id": task.id.uuidString.lowercased(), "title": task.title]
    }

    private static var selectedReviewTask: [String: Any] {
        let task = FocusTask(title: "Next review")!
        return ["id": task.id.uuidString.lowercased(), "title": task.title]
    }

    private static var associatedTimer: [String: Any] {
        [
            "id": "remote-associated-timer",
            "taskId": remoteTask["id"]!,
            "phase": "focus",
            "status": "running",
            "plannedDurationMs": 1_500_000,
            "elapsedAtAnchorMs": 120_000,
            "anchorAt": "2026-07-21T08:00:00.000Z",
            "lastIntent": NSNull()
        ]
    }

    private static var associatedHistory: [String: Any] {
        [
            "id": "remote-associated-history",
            "timerId": "remote-associated-history-timer",
            "commandId": "remote-associated-command",
            "taskId": remoteTask["id"]!,
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": 1_500_000,
            "completedAt": "2026-07-21T07:00:00.000Z"
        ]
    }

    private static func usesBootstrapStub(_ scenario: String?) -> Bool {
        scenario?.hasPrefix("bootstrap-") == true
    }

    private static func hasRemoteBootstrapHistory(_ scenario: String?) -> Bool {
        scenario != "bootstrap-local-only"
            && scenario != "bootstrap-local-history-remote-task"
            && scenario != "bootstrap-resolve-race-404"
            && scenario?.hasPrefix("bootstrap-empty-") != true
    }

    private static func bootstrapHistory(for scenario: String?) -> [[String: Any]] {
        if scenario == "bootstrap-history-counts" {
            return [
                remoteHistory,
                remoteEndedHistory(id: "remote-cancelled", status: "cancelled"),
                remoteEndedHistory(id: "remote-superseded", status: "superseded")
            ]
        }
        return hasRemoteBootstrapHistory(scenario) ? [remoteHistory] : []
    }

    private static func requestObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func resolutionRequestObject(for scenario: String?) -> [String: Any]? {
        guard let scenario,
              let body = StubRequestRecorder.shared.requests(for: scenario).last(where: {
                  $0.path == "/api/v1/bootstrap/resolve"
              })?.body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func acknowledgements(
        from request: [String: Any]?,
        key: String,
        idKey: String
    ) -> [[String: Any]] {
        (request?[key] as? [[String: Any]] ?? []).compactMap { operation in
            guard let id = operation["id"] as? String else { return nil }
            return [idKey: id, "outcome": "applied", "reason": ""]
        }
    }

    private static func tasks(from request: [String: Any]?) -> [[String: Any]] {
        (request?["taskOperations"] as? [[String: Any]] ?? []).compactMap { operation in
            guard operation["type"] as? String == "upsert",
                  let id = operation["taskId"] as? String,
                  let title = operation["title"] as? String else { return nil }
            return ["id": id, "title": title]
        }
    }

    private static func bootstrapAutoStartValue(
        strategy: String?,
        request: [String: Any]?,
        remoteValue: Bool
    ) -> Bool {
        guard let request, request.keys.contains("autoStartOperations") else { return remoteValue }
        let operations = request["autoStartOperations"] as? [[String: Any]] ?? []
        if let enabled = operations.max(by: autoStartPrecedes)?["enabled"] as? Bool {
            return enabled
        }
        return strategy == "replace_remote" ? false : remoteValue
    }

    private static func autoStartPrecedes(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        let lhsWall = (lhs["hlcWallMs"] as? NSNumber)?.int64Value ?? 0
        let rhsWall = (rhs["hlcWallMs"] as? NSNumber)?.int64Value ?? 0
        if lhsWall != rhsWall { return lhsWall < rhsWall }
        let lhsCounter = (lhs["hlcCounter"] as? NSNumber)?.int64Value ?? 0
        let rhsCounter = (rhs["hlcCounter"] as? NSNumber)?.int64Value ?? 0
        if lhsCounter != rhsCounter { return lhsCounter < rhsCounter }
        let lhsDevice = lhs["deviceId"] as? String ?? ""
        let rhsDevice = rhs["deviceId"] as? String ?? ""
        if lhsDevice != rhsDevice { return lhsDevice < rhsDevice }
        return (lhs["id"] as? String ?? "") < (rhs["id"] as? String ?? "")
    }

    private static func cumulativeAutoStartValue(for scenario: String, defaultValue: Bool = false) -> Bool {
        let operations = StubRequestRecorder.shared.requests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap { requestObject($0.body)?["autoStartOperations"] as? [[String: Any]] ?? [] }
        return operations.max(by: autoStartPrecedes)?["enabled"] as? Bool ?? defaultValue
    }

    private static func autoStartSyncResponse(
        scenario: String,
        pathAttempt: Int,
        request: [String: Any]?
    ) -> Data {
        switch scenario {
        case "auto-start-owner-expiry":
            return timerCycleResponse(scenario: scenario, request: request)
        case "auto-start-legacy-ownership-local", "auto-start-legacy-ownership-remote":
            return legacyOwnershipResponse(scenario: scenario, request: request)
        case "auto-start-finish-rejected-no-previous":
            return rejectedFinishRestoreResponse(request: request)
        case "auto-start-provisional-finish-rejected",
             "auto-start-provisional-finish-ignored-exact",
             "auto-start-provisional-finish-ignored-mismatch",
             "auto-start-provisional-start-rejected",
             "auto-start-provisional-superseded",
             "auto-start-stale-fourth",
             "auto-start-dependency-boundary":
            return provisionalBreakResponse(
                scenario: scenario,
                pathAttempt: pathAttempt,
                request: request
            )
        default:
            break
        }
        if scenario.hasPrefix("auto-start-matrix-") {
            return provisionalMatrixResponse(
                scenario: scenario,
                pathAttempt: pathAttempt,
                request: request
            )
        }
        if scenario == "auto-start-in-flight-rebase", pathAttempt == 1 {
            Thread.sleep(forTimeInterval: 0.5)
        }
        var autoStartAcknowledgements = acknowledgements(
            from: request,
            key: "autoStartOperations",
            idKey: "operationId"
        )
        var response = syncResponseObject(
            revision: Int64(20 + pathAttempt),
            history: scenario == "auto-start-remote-completed"
                ? [remoteHistory]
                : [],
            acknowledgements: acknowledgements(from: request, key: "commands", idKey: "commandId"),
            taskAcknowledgements: acknowledgements(from: request, key: "taskOperations", idKey: "operationId"),
            durationAcknowledgements: acknowledgements(
                from: request,
                key: "durationOperations",
                idKey: "operationId"
            ),
            autoStartAcknowledgements: autoStartAcknowledgements,
            autoStartBreaks: scenario == "auto-start-remote-preference"
                || scenario == "auto-start-remote-completed"
                ? true
                : cumulativeAutoStartValue(for: scenario),
            tasks: [],
            canonicalTimer: scenario == "auto-start-remote-completed" ? [
                "id": "remote-timer",
                "taskId": NSNull(),
                "phase": "focus",
                "status": "completed",
                "plannedDurationMs": 1_500_000,
                "elapsedAtAnchorMs": 1_500_000,
                "anchorAt": "2026-07-20T08:00:00.000Z",
                "lastIntent": NSNull()
            ] : NSNull()
        )
        switch scenario {
        case "auto-start-ack-malformed":
            response["autoStartAcknowledgements"] = "invalid"
        case "auto-start-ack-missing":
            response["autoStartAcknowledgements"] = []
        case "auto-start-ack-extra":
            autoStartAcknowledgements.append([
                "operationId": UUID().uuidString.lowercased(),
                "outcome": "applied",
                "reason": ""
            ])
            response["autoStartAcknowledgements"] = autoStartAcknowledgements
        case "auto-start-ack-duplicate":
            if let acknowledgement = autoStartAcknowledgements.first {
                response["autoStartAcknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "auto-start-ack-absent":
            response.removeValue(forKey: "autoStartAcknowledgements")
        default:
            break
        }
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private static func provisionalMatrixResponse(
        scenario: String,
        pathAttempt: Int,
        request: [String: Any]?
    ) -> Data {
        let commands = request?["commands"] as? [[String: Any]] ?? []
        let allCommands = StubRequestRecorder.shared.requests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap { requestObject($0.body)?["commands"] as? [[String: Any]] ?? [] }
        let focusStart = allCommands.first {
            $0["type"] as? String == "start" && $0["phase"] as? String == "focus"
        }
        let focusFinish = allCommands.first {
            $0["type"] as? String == "finish" && $0["phase"] as? String == "focus"
        }
        let breakStart = allCommands.first {
            $0["type"] as? String == "start" && $0["phase"] as? String != "focus"
        }
        let finishOutcome = scenario.contains("-ignored-")
            ? "ignored"
            : scenario.contains("-rejected-") ? "rejected" : "applied"
        let acknowledgements = commands.compactMap { command -> [String: Any]? in
            guard let id = command["id"] as? String else { return nil }
            let outcome = id == focusFinish?["id"] as? String ? finishOutcome : "applied"
            return [
                "commandId": id,
                "outcome": outcome,
                "reason": outcome == "applied" ? "" : "matrix outcome"
            ]
        }
        var history: [[String: Any]] = []
        if scenario.contains("-long-") {
            let completedAt = focusFinish?["occurredAt"] as? String
                ?? "1970-01-01T00:00:00.000Z"
            for index in 1...3 {
                history.append([
                    "id": "matrix-prior-\(index)",
                    "timerId": "matrix-prior-\(index)",
                    "commandId": "matrix-prior-command-\(index)",
                    "phase": "focus",
                    "status": "completed",
                    "plannedDurationMs": 60_000,
                    "completedAt": completionTimestamp(
                        before: completedAt,
                        milliseconds: 4 - index
                    )
                ])
            }
        }
        if let focusFinish {
            history.append(completedHistory(finish: focusFinish, start: focusStart))
        }
        let canonicalTimer: Any
        if let breakStart {
            canonicalTimer = runningTimer(from: breakStart)
        } else if let focusFinish {
            canonicalTimer = completedTimer(finish: focusFinish, start: focusStart)
        } else {
            canonicalTimer = NSNull()
        }
        return syncResponse(
            revision: Int64(100 + pathAttempt),
            history: history,
            acknowledgements: acknowledgements,
            autoStartBreaks: true,
            canonicalTimer: canonicalTimer
        )
    }

    private static func legacyOwnershipResponse(
        scenario: String,
        request: [String: Any]?
    ) -> Data {
        let localDeviceID = request?["deviceId"] as? String ?? ""
        let startDeviceID = scenario == "auto-start-legacy-ownership-local"
            ? localDeviceID
            : "device-remote"
        return syncResponse(
            revision: 24,
            history: [],
            acknowledgements: acknowledgements(from: request, key: "commands", idKey: "commandId"),
            canonicalTimer: ownershipTimer(deviceID: startDeviceID)
        )
    }

    private static func rejectedFinishRestoreResponse(request: [String: Any]?) -> Data {
        let commands = request?["commands"] as? [[String: Any]] ?? []
        let acknowledgements = commands.compactMap { command -> [String: Any]? in
            guard let id = command["id"] as? String else { return nil }
            return ["commandId": id, "outcome": "rejected", "reason": "lost race"]
        }
        let finish = commands.first { $0["type"] as? String == "finish" }
        return syncResponse(
            revision: 25,
            history: [],
            acknowledgements: acknowledgements,
            canonicalTimer: ownershipTimer(
                timerID: finish?["timerId"] as? String ?? "timer-finish-rejected",
                plannedDurationMs: (finish?["plannedDurationMs"] as? NSNumber)?.int64Value ?? 60_000,
                deviceID: request?["deviceId"] as? String ?? ""
            )
        )
    }

    private static func ownershipTimer(
        timerID: String = "timer-legacy-sync-owner",
        plannedDurationMs: Int64 = 60_000,
        deviceID: String
    ) -> [String: Any] {
        [
            "id": timerID,
            "taskId": NSNull(),
            "phase": "focus",
            "status": "running",
            "plannedDurationMs": plannedDurationMs,
            "elapsedAtAnchorMs": 0,
            "anchorAt": "2026-07-21T08:00:00.000Z",
            "lastIntent": [
                "type": "start",
                "commandId": "command-legacy-canonical-start",
                "occurredAt": "2026-07-21T08:00:00.000Z",
                "deviceId": deviceID
            ]
        ]
    }

    private static func bootstrapOwnershipTimer(
        for scenario: String?,
        request: [String: Any]?
    ) -> Any {
        guard scenario == "bootstrap-legacy-ownership-local"
                || scenario == "bootstrap-legacy-ownership-remote" else { return NSNull() }
        let localDeviceID = request?["deviceId"] as? String ?? ""
        return ownershipTimer(
            deviceID: scenario == "bootstrap-legacy-ownership-local"
                ? localDeviceID
                : "device-remote"
        )
    }

    private static func provisionalBreakResponse(
        scenario: String,
        pathAttempt: Int,
        request: [String: Any]?
    ) -> Data {
        let commands = request?["commands"] as? [[String: Any]] ?? []
        let allCommands = StubRequestRecorder.shared.requests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap { requestObject($0.body)?["commands"] as? [[String: Any]] ?? [] }
        let focusStart = allCommands.first {
            $0["type"] as? String == "start" && $0["phase"] as? String == "focus"
        }
        let focusFinish = allCommands.first {
            $0["type"] as? String == "finish" && $0["phase"] as? String == "focus"
        }
        let breakStart = allCommands.first {
            $0["type"] as? String == "start" && $0["phase"] as? String != "focus"
        }
        let rejectsFinish = scenario == "auto-start-provisional-finish-rejected"
        let ignoresFinish = scenario.hasPrefix(
            "auto-start-provisional-finish-ignored-"
        )
        let rejectsBreakStart = scenario == "auto-start-provisional-start-rejected"
        let acknowledgements = commands.compactMap { command -> [String: Any]? in
            guard let id = command["id"] as? String else { return nil }
            let isFinish = command["type"] as? String == "finish"
            let isBreakStart = command["type"] as? String == "start"
                && command["phase"] as? String != "focus"
            let outcome = if ignoresFinish && isFinish {
                "ignored"
            } else if rejectsFinish && isFinish || rejectsBreakStart && isBreakStart {
                "rejected"
            } else {
                "applied"
            }
            return ["commandId": id, "outcome": outcome, "reason": outcome == "applied" ? "" : "lost race"]
        }

        var history: [[String: Any]] = []
        if !rejectsFinish, let focusFinish {
            var completion = completedHistory(finish: focusFinish, start: focusStart)
            if scenario == "auto-start-provisional-finish-ignored-mismatch" {
                completion["timerId"] = "timer-mismatched-completion"
            }
            history.append(completion)
        }
        if scenario == "auto-start-stale-fourth" {
            let completedAt = focusFinish?["occurredAt"] as? String
                ?? "2026-07-20T00:00:00.000Z"
            for index in 1...3 {
                history.append([
                    "id": "remote-focus-\(index)",
                    "timerId": "remote-focus-\(index)",
                    "commandId": "remote-focus-command-\(index)",
                    "phase": "focus",
                    "status": "completed",
                    "plannedDurationMs": 60_000,
                    "completedAt": completionTimestamp(
                        before: completedAt,
                        milliseconds: 4 - index
                    )
                ])
            }
        }

        let canonicalTimer: Any
        if scenario == "auto-start-provisional-superseded" {
            canonicalTimer = [
                "id": "timer-remote-winner",
                "taskId": NSNull(),
                "phase": "focus",
                "status": "running",
                "plannedDurationMs": 1_500_000,
                "elapsedAtAnchorMs": 0,
                "anchorAt": "2026-07-21T08:00:00.000Z",
                "lastIntent": NSNull()
            ]
        } else if let breakStart, !(rejectsBreakStart && pathAttempt > 1) {
            canonicalTimer = runningTimer(from: breakStart)
        } else if rejectsFinish, let focusStart {
            canonicalTimer = runningTimer(from: focusStart)
        } else if let focusFinish {
            canonicalTimer = completedTimer(finish: focusFinish, start: focusStart)
        } else {
            canonicalTimer = NSNull()
        }
        return syncResponse(
            revision: Int64(40 + pathAttempt),
            history: history,
            acknowledgements: acknowledgements,
            autoStartBreaks: true,
            canonicalTimer: canonicalTimer
        )
    }

    private static func runningTimer(from start: [String: Any]) -> [String: Any] {
        [
            "id": start["timerId"]!,
            "taskId": start["taskId"] ?? NSNull(),
            "phase": start["phase"]!,
            "status": "running",
            "plannedDurationMs": start["plannedDurationMs"]!,
            "elapsedAtAnchorMs": 0,
            "anchorAt": start["occurredAt"]!,
            "lastIntent": NSNull()
        ]
    }

    private static func completedTimer(
        finish: [String: Any],
        start: [String: Any]?
    ) -> [String: Any] {
        [
            "id": finish["timerId"]!,
            "taskId": start?["taskId"] ?? NSNull(),
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": finish["plannedDurationMs"]!,
            "elapsedAtAnchorMs": finish["plannedDurationMs"]!,
            "anchorAt": finish["occurredAt"]!,
            "lastIntent": NSNull()
        ]
    }

    private static func completedHistory(
        finish: [String: Any],
        start: [String: Any]?
    ) -> [String: Any] {
        [
            "id": finish["timerId"]!,
            "timerId": finish["timerId"]!,
            "commandId": finish["id"]!,
            "taskId": start?["taskId"] ?? NSNull(),
            "phase": "focus",
            "status": "completed",
            "plannedDurationMs": finish["plannedDurationMs"]!,
            "completedAt": finish["occurredAt"]!
        ]
    }

    private static func completionTimestamp(
        before timestamp: String,
        milliseconds: Int
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        return formatter.string(
            from: date.addingTimeInterval(-Double(milliseconds) / 1_000)
        )
    }

    private static func timerCycleResponse(
        scenario: String,
        request: [String: Any]?
    ) -> Data {
        let state = timerState(for: scenario)
        let syncCount = StubRequestRecorder.shared.requests(for: scenario).count { $0.path == "/api/v1/sync" }
        var response = syncResponseObject(
            revision: Int64(30 + syncCount),
            history: state.history,
            acknowledgements: acknowledgements(from: request, key: "commands", idKey: "commandId"),
            taskAcknowledgements: acknowledgements(from: request, key: "taskOperations", idKey: "operationId"),
            durationAcknowledgements: acknowledgements(
                from: request,
                key: "durationOperations",
                idKey: "operationId"
            ),
            autoStartAcknowledgements: acknowledgements(
                from: request,
                key: "autoStartOperations",
                idKey: "operationId"
            ),
            selectedTaskAcknowledgements: acknowledgements(
                from: request,
                key: "selectedTaskOperations",
                idKey: "operationId"
            ),
            autoStartBreaks: cumulativeAutoStartValue(for: scenario),
            selectedTaskId: cumulativeSelectedTaskID(for: scenario),
            tasks: cumulativeTasks(for: scenario),
            canonicalTimer: state.timer
        )
        response["durationsMs"] = cumulativeDurations(for: scenario)
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private static func cumulativeDurations(for scenario: String) -> [String: Int64] {
        var durations: [String: Int64] = [
            "focus": DurationValues.defaults.focus,
            "short_break": DurationValues.defaults.shortBreak,
            "long_break": DurationValues.defaults.longBreak
        ]
        for request in StubRequestRecorder.shared.requests(for: scenario) where request.path == "/api/v1/sync" {
            let operations = requestObject(request.body)?["durationOperations"] as? [[String: Any]] ?? []
            for operation in operations {
                guard let phase = operation["phase"] as? String,
                      let duration = (operation["durationMs"] as? NSNumber)?.int64Value else { continue }
                durations[phase] = duration
            }
        }
        return durations
    }

    private static func cumulativeSelectedTaskID(for scenario: String) -> String? {
        let operations = StubRequestRecorder.shared.requests(for: scenario)
            .filter { $0.path == "/api/v1/sync" }
            .flatMap { requestObject($0.body)?["selectedTaskOperations"] as? [[String: Any]] ?? [] }
        guard let operation = operations.max(by: autoStartPrecedes) else { return nil }
        return operation["taskId"] is NSNull ? nil : operation["taskId"] as? String
    }

    private static func timerState(for scenario: String) -> (timer: Any, history: [[String: Any]]) {
        var timer: [String: Any]?
        var history: [[String: Any]] = []
        var seenCommandIDs = Set<String>()
        for request in StubRequestRecorder.shared.requests(for: scenario) where request.path == "/api/v1/sync" {
            let commands = requestObject(request.body)?["commands"] as? [[String: Any]] ?? []
            for command in commands {
                guard let commandID = command["id"] as? String,
                      seenCommandIDs.insert(commandID).inserted,
                      let type = command["type"] as? String,
                      let timerID = command["timerId"] as? String,
                      let phase = command["phase"] as? String,
                      let duration = (command["plannedDurationMs"] as? NSNumber)?.int64Value,
                      let occurredAt = command["occurredAt"] as? String else { continue }
                switch type {
                case "start":
                    timer = [
                        "id": timerID,
                        "taskId": command["taskId"] ?? NSNull(),
                        "phase": phase,
                        "status": "running",
                        "plannedDurationMs": duration,
                        "elapsedAtAnchorMs": 0,
                        "anchorAt": occurredAt,
                        "lastIntent": NSNull()
                    ]
                case "finish":
                    guard let current = timer,
                          current["id"] as? String == timerID,
                          current["status"] as? String == "running" || current["status"] as? String == "paused" else {
                        continue
                    }
                    timer?["status"] = "completed"
                    timer?["elapsedAtAnchorMs"] = duration
                    timer?["anchorAt"] = occurredAt
                    history.removeAll { $0["commandId"] as? String == commandID }
                    history.insert([
                        "id": timerID,
                        "timerId": timerID,
                        "commandId": commandID,
                        "taskId": current["taskId"] ?? NSNull(),
                        "phase": phase,
                        "status": "completed",
                        "plannedDurationMs": duration,
                        "completedAt": occurredAt
                    ], at: 0)
                case "clear":
                    guard timer?["id"] as? String == timerID,
                          timer?["status"] as? String != "running",
                          timer?["status"] as? String != "paused" else { continue }
                    timer = nil
                default:
                    break
                }
            }
        }
        return (timer ?? NSNull(), history)
    }

    private static func taskSyncResponse(
        scenario: String?,
        pathAttempt: Int,
        request: [String: Any]?
    ) -> Data {
        let taskAcknowledgements = acknowledgements(
            from: request,
            key: "taskOperations",
            idKey: "operationId"
        )
        let selectedTaskAcknowledgements = acknowledgements(
            from: request,
            key: "selectedTaskOperations",
            idKey: "operationId"
        )
        let requestedSelection = (request?["selectedTaskOperations"] as? [[String: Any]])?.last
        let requestedSelectedTaskID: String? = requestedSelection.flatMap { operation in
            operation["taskId"] is NSNull ? nil : operation["taskId"] as? String
        }
        switch scenario {
        case "task-sync-delete-wire":
            return syncResponse(
                revision: 12,
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                selectedTaskAcknowledgements: selectedTaskAcknowledgements,
                selectedTaskId: requestedSelectedTaskID,
                tasks: []
            )
        case "task-sync-remote-lifecycle":
            return syncResponse(
                revision: Int64(11 + pathAttempt),
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                selectedTaskAcknowledgements: selectedTaskAcknowledgements,
                selectedTaskId: pathAttempt == 1 ? requestedSelectedTaskID : nil,
                tasks: pathAttempt == 1 ? [remoteTask] : []
            )
        case "task-sync-in-flight-rebase":
            if pathAttempt == 1 { Thread.sleep(forTimeInterval: 0.5) }
            return syncResponse(
                revision: Int64(11 + pathAttempt),
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                selectedTaskAcknowledgements: selectedTaskAcknowledgements,
                selectedTaskId: requestedSelectedTaskID,
                tasks: [remoteTask] + cumulativeTasks(for: scenario)
            )
        case _ where scenario?.hasPrefix("task-sync-batching-") == true:
            return syncResponse(
                revision: Int64(11 + pathAttempt),
                history: [],
                taskAcknowledgements: taskAcknowledgements,
                selectedTaskAcknowledgements: selectedTaskAcknowledgements,
                selectedTaskId: requestedSelectedTaskID,
                tasks: cumulativeTasks(for: scenario)
            )
        case "task-sync-associations":
            return syncResponse(
                revision: 12,
                history: [associatedHistory],
                taskAcknowledgements: taskAcknowledgements,
                selectedTaskAcknowledgements: selectedTaskAcknowledgements,
                selectedTaskId: requestedSelectedTaskID,
                tasks: [remoteTask],
                canonicalTimer: associatedTimer
            )
        default:
            return syncResponse(
                revision: 12,
                history: [remoteHistory],
                taskAcknowledgements: taskAcknowledgements,
                selectedTaskAcknowledgements: selectedTaskAcknowledgements,
                selectedTaskId: requestedSelectedTaskID,
                tasks: [remoteTask]
            )
        }
    }

    private static func selectedTaskSyncResponse(
        scenario: String,
        request: [String: Any]?
    ) -> Data {
        let acknowledgements = acknowledgements(
            from: request,
            key: "selectedTaskOperations",
            idKey: "operationId"
        )
        if scenario == "selected-task-sync-active-timer" {
            return syncResponse(
                revision: 12,
                history: [],
                selectedTaskAcknowledgements: acknowledgements,
                selectedTaskId: selectedReviewTask["id"] as? String,
                tasks: [selectedBuildTask, selectedReviewTask],
                canonicalTimer: [
                    "id": "selected-active-timer",
                    "taskId": selectedBuildTask["id"]!,
                    "phase": "focus",
                    "status": "running",
                    "plannedDurationMs": 1_500_000,
                    "elapsedAtAnchorMs": 120_000,
                    "anchorAt": "2026-07-21T08:00:00.000Z",
                    "lastIntent": NSNull()
                ]
            )
        }
        let operations = request?["selectedTaskOperations"] as? [[String: Any]] ?? []
        let selectedTaskId: String? = operations.last.flatMap { operation in
            operation["taskId"] is NSNull ? nil : operation["taskId"] as? String
        }
        return syncResponse(
            revision: 12,
            history: [],
            selectedTaskAcknowledgements: acknowledgements,
            selectedTaskId: selectedTaskId,
            tasks: [selectedPreferenceTask]
        )
    }

    private static func syncContractResponse(
        scenario: String,
        request: [String: Any]?
    ) -> Data {
        if scenario.hasPrefix("sync-contract-alarm-") {
            let status = scenario == "sync-contract-alarm-status"
                ? "paused"
                : "running"
            let elapsed = scenario == "sync-contract-alarm-elapsed"
                ? 20_000
                : 10_000
            return syncResponse(
                revision: 11,
                history: [],
                tasks: [],
                canonicalTimer: [
                    "id": "alarm-correction-timer",
                    "taskId": NSNull(),
                    "phase": "focus",
                    "status": status,
                    "plannedDurationMs": 60_000,
                    "elapsedAtAnchorMs": elapsed,
                    "anchorAt": "2026-07-21T08:00:00.000Z",
                    "lastIntent": NSNull()
                ]
            )
        }
        if scenario == "sync-contract-canonical-invalid" {
            var invalidTimer = associatedTimer
            invalidTimer["elapsedAtAnchorMs"] = 1_500_001
            return syncResponse(
                revision: 11,
                history: [],
                tasks: [remoteTask],
                canonicalTimer: invalidTimer
            )
        }
        if scenario.hasPrefix("sync-contract-revision-") {
            let revision: Int64 = switch scenario {
            case "sync-contract-revision-lower": 9
            case "sync-contract-revision-unsafe": WireBounds.maxSafeInteger + 1
            case "sync-contract-revision-equal": 10
            default: 11
            }
            var response = syncResponseObject(
                revision: revision,
                history: [remoteHistory],
                acknowledgements: [],
                taskAcknowledgements: [],
                durationAcknowledgements: [],
                autoStartAcknowledgements: [],
                autoStartBreaks: true,
                tasks: [remoteTask],
                canonicalTimer: associatedTimer
            )
            response["durationsMs"] = [
                "focus": 40 * 60_000,
                "short_break": 10 * 60_000,
                "long_break": 20 * 60_000
            ]
            return try! JSONSerialization.data(withJSONObject: response)
        }

        var timerAcknowledgements = acknowledgements(from: request, key: "commands", idKey: "commandId")
        var taskAcknowledgements = acknowledgements(from: request, key: "taskOperations", idKey: "operationId")
        var durationAcknowledgements = acknowledgements(from: request, key: "durationOperations", idKey: "operationId")
        var autoStartAcknowledgements = acknowledgements(from: request, key: "autoStartOperations", idKey: "operationId")
        var selectedTaskAcknowledgements = acknowledgements(
            from: request,
            key: "selectedTaskOperations",
            idKey: "operationId"
        )
        let outcome = String(scenario.dropFirst("sync-contract-ack-".count))
        if ["applied", "ignored", "rejected"].contains(outcome) {
            for index in timerAcknowledgements.indices {
                timerAcknowledgements[index]["outcome"] = outcome
                timerAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in taskAcknowledgements.indices {
                taskAcknowledgements[index]["outcome"] = outcome
                taskAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in durationAcknowledgements.indices {
                durationAcknowledgements[index]["outcome"] = outcome
                durationAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in autoStartAcknowledgements.indices {
                autoStartAcknowledgements[index]["outcome"] = outcome
                autoStartAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in selectedTaskAcknowledgements.indices {
                selectedTaskAcknowledgements[index]["outcome"] = outcome
                selectedTaskAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
        } else if scenario == "sync-contract-ack-reordered" {
            timerAcknowledgements.reverse()
            taskAcknowledgements.reverse()
            durationAcknowledgements.reverse()
            autoStartAcknowledgements.reverse()
            selectedTaskAcknowledgements.reverse()
            let outcomes = ["applied", "ignored", "rejected"]
            for index in timerAcknowledgements.indices {
                let outcome = outcomes[index % 3]
                timerAcknowledgements[index]["outcome"] = outcome
                timerAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in taskAcknowledgements.indices {
                let outcome = outcomes[(index + 1) % 3]
                taskAcknowledgements[index]["outcome"] = outcome
                taskAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in durationAcknowledgements.indices {
                let outcome = outcomes[(index + 2) % 3]
                durationAcknowledgements[index]["outcome"] = outcome
                durationAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in autoStartAcknowledgements.indices {
                let outcome = outcomes[index % 3]
                autoStartAcknowledgements[index]["outcome"] = outcome
                autoStartAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
            for index in selectedTaskAcknowledgements.indices {
                let outcome = outcomes[(index + 1) % 3]
                selectedTaskAcknowledgements[index]["outcome"] = outcome
                selectedTaskAcknowledgements[index]["reason"] = outcome == "applied" ? "" : "lost race"
            }
        } else if scenario.hasPrefix("sync-contract-unknown-") {
            switch scenario {
            case "sync-contract-unknown-timer": timerAcknowledgements[0]["outcome"] = "unknown"
            case "sync-contract-unknown-task": taskAcknowledgements[0]["outcome"] = "unknown"
            case "sync-contract-unknown-duration": durationAcknowledgements[0]["outcome"] = "unknown"
            default: break
            }
        }
        return syncResponse(
            revision: 11,
            history: [],
            acknowledgements: timerAcknowledgements,
            taskAcknowledgements: taskAcknowledgements,
            durationAcknowledgements: durationAcknowledgements,
            autoStartAcknowledgements: autoStartAcknowledgements,
            selectedTaskAcknowledgements: selectedTaskAcknowledgements,
            tasks: []
        )
    }

    private static func cumulativeTasks(for scenario: String?) -> [[String: Any]] {
        guard let scenario else { return [] }
        var tasksByID: [String: [String: Any]] = [:]
        for request in StubRequestRecorder.shared.requests(for: scenario) where request.path == "/api/v1/sync" {
            let operations = requestObject(request.body)?["taskOperations"] as? [[String: Any]] ?? []
            for operation in operations {
                guard let id = operation["taskId"] as? String else { continue }
                if operation["type"] as? String == "delete" {
                    tasksByID.removeValue(forKey: id)
                } else if let title = operation["title"] as? String {
                    tasksByID[id] = ["id": id, "title": title]
                }
            }
        }
        return tasksByID.values.sorted {
            ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
    }

    private static func resolvedHistory(for strategy: String?, scenario: String?) -> [[String: Any]] {
        if scenario?.hasPrefix("bootstrap-empty-") == true { return [] }
        return switch strategy {
        case "replace_remote": [localHistory]
        case "merge": [localHistory, remoteHistory]
        default: [remoteHistory]
        }
    }

    private static func bootstrapResolveResponse(
        scenario: String?,
        strategy: String?,
        request: [String: Any]?
    ) -> Data {
        var response = syncResponseObject(
            revision: 9,
            history: resolvedHistory(for: strategy, scenario: scenario),
            acknowledgements: acknowledgements(from: request, key: "commands", idKey: "commandId"),
            taskAcknowledgements: acknowledgements(from: request, key: "taskOperations", idKey: "operationId"),
            durationAcknowledgements: acknowledgements(from: request, key: "durationOperations", idKey: "operationId"),
            autoStartAcknowledgements: acknowledgements(
                from: request,
                key: "autoStartOperations",
                idKey: "operationId"
            ),
            selectedTaskAcknowledgements: acknowledgements(
                from: request,
                key: "selectedTaskOperations",
                idKey: "operationId"
            ),
            autoStartBreaks: bootstrapAutoStartValue(
                strategy: strategy,
                request: request,
                remoteValue: scenario?.contains("auto-start-remote-true") == true
            ),
            tasks: tasks(from: request),
            canonicalTimer: bootstrapOwnershipTimer(for: scenario, request: request)
        )
        switch scenario {
        case "bootstrap-response-missing-tasks":
            response.removeValue(forKey: "tasks")
        case "bootstrap-response-task-ack-malformed":
            response["taskAcknowledgements"] = "invalid"
        case "bootstrap-response-task-ack-missing":
            response["taskAcknowledgements"] = []
        case "bootstrap-response-task-ack-duplicate":
            if let acknowledgement = (response["taskAcknowledgements"] as? [[String: Any]])?.first {
                response["taskAcknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-task-ack-extra":
            var taskAcknowledgements = response["taskAcknowledgements"] as? [[String: Any]] ?? []
            taskAcknowledgements.append([
                "operationId": "task-operation-extra",
                "outcome": "applied",
                "reason": ""
            ])
            response["taskAcknowledgements"] = taskAcknowledgements
        case "bootstrap-response-task-ack-absent":
            response.removeValue(forKey: "taskAcknowledgements")
        case "bootstrap-response-timer-ack-malformed":
            response["acknowledgements"] = "invalid"
        case "bootstrap-response-timer-ack-missing":
            response["acknowledgements"] = []
        case "bootstrap-response-timer-ack-duplicate":
            if let acknowledgement = (response["acknowledgements"] as? [[String: Any]])?.first {
                response["acknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-timer-ack-extra":
            var acknowledgements = response["acknowledgements"] as? [[String: Any]] ?? []
            acknowledgements.append([
                "commandId": "command-extra",
                "outcome": "applied",
                "reason": ""
            ])
            response["acknowledgements"] = acknowledgements
        case "bootstrap-response-timer-ack-absent":
            response.removeValue(forKey: "acknowledgements")
        case "bootstrap-response-duration-ack-malformed":
            response["durationAcknowledgements"] = "invalid"
        case "bootstrap-response-duration-ack-missing":
            response["durationAcknowledgements"] = []
        case "bootstrap-response-duration-ack-duplicate":
            if let acknowledgement = (response["durationAcknowledgements"] as? [[String: Any]])?.first {
                response["durationAcknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-duration-ack-extra":
            var durationAcknowledgements = response["durationAcknowledgements"] as? [[String: Any]] ?? []
            durationAcknowledgements.append([
                "operationId": "duration-operation-extra",
                "outcome": "applied",
                "reason": ""
            ])
            response["durationAcknowledgements"] = durationAcknowledgements
        case "bootstrap-response-duration-ack-absent":
            response.removeValue(forKey: "durationAcknowledgements")
        case "bootstrap-response-auto-start-ack-malformed":
            response["autoStartAcknowledgements"] = "invalid"
        case "bootstrap-response-auto-start-ack-missing":
            response["autoStartAcknowledgements"] = []
        case "bootstrap-response-auto-start-ack-duplicate":
            if let acknowledgement = (response["autoStartAcknowledgements"] as? [[String: Any]])?.first {
                response["autoStartAcknowledgements"] = [acknowledgement, acknowledgement]
            }
        case "bootstrap-response-auto-start-ack-extra":
            var acknowledgements = response["autoStartAcknowledgements"] as? [[String: Any]] ?? []
            acknowledgements.append([
                "operationId": UUID().uuidString.lowercased(),
                "outcome": "applied",
                "reason": ""
            ])
            response["autoStartAcknowledgements"] = acknowledgements
        case "bootstrap-response-auto-start-ack-absent":
            response.removeValue(forKey: "autoStartAcknowledgements")
        default:
            break
        }
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private static func syncResponse(
        revision: Int64,
        history: [[String: Any]],
        acknowledgements: [[String: Any]] = [],
        taskAcknowledgements: [[String: Any]] = [],
        durationAcknowledgements: [[String: Any]] = [],
        autoStartAcknowledgements: [[String: Any]] = [],
        selectedTaskAcknowledgements: [[String: Any]] = [],
        autoStartBreaks: Bool = false,
        selectedTaskId: String? = nil,
        tasks: [[String: Any]] = [],
        canonicalTimer: Any = NSNull()
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: syncResponseObject(
            revision: revision,
            history: history,
            acknowledgements: acknowledgements,
            taskAcknowledgements: taskAcknowledgements,
            durationAcknowledgements: durationAcknowledgements,
            autoStartAcknowledgements: autoStartAcknowledgements,
            selectedTaskAcknowledgements: selectedTaskAcknowledgements,
            autoStartBreaks: autoStartBreaks,
            selectedTaskId: selectedTaskId,
            tasks: tasks,
            canonicalTimer: canonicalTimer
        ))
    }

    private static func syncResponseObject(
        revision: Int64,
        history: [[String: Any]],
        acknowledgements: [[String: Any]],
        taskAcknowledgements: [[String: Any]],
        durationAcknowledgements: [[String: Any]],
        autoStartAcknowledgements: [[String: Any]] = [],
        selectedTaskAcknowledgements: [[String: Any]] = [],
        autoStartBreaks: Bool = false,
        selectedTaskId: String? = nil,
        tasks: [[String: Any]],
        canonicalTimer: Any = NSNull()
    ) -> [String: Any] {
        [
            "acknowledgements": acknowledgements,
            "taskAcknowledgements": taskAcknowledgements,
            "durationAcknowledgements": durationAcknowledgements,
            "autoStartAcknowledgements": autoStartAcknowledgements,
            "selectedTaskAcknowledgements": selectedTaskAcknowledgements,
            "durationsMs": [
                "focus": 1_500_000,
                "short_break": 300_000,
                "long_break": 900_000
            ],
            "autoStartBreaks": autoStartBreaks,
            "selectedTaskId": selectedTaskId ?? NSNull(),
            "revision": revision,
            "canonicalTimer": canonicalTimer,
            "history": history,
            "tasks": tasks,
            "serverTime": "2026-07-21T08:00:00.000Z",
            "serverHlcWallMs": 1_784_620_800_000,
            "serverHlcCounter": 4
        ]
    }
}
