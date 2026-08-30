import Foundation

enum AccountDeletionOutcome: Equatable, Sendable {
    case committed
    case rejected(String)
    case unknown(String)
}

actor APIClient: LogoutRevoking, LogoutSessionDetaching {
    private let baseURL: URL
    private let session: URLSession
    private let keychain: any TokenStoring
    nonisolated let logoutRevocationStore: any LogoutRevocationStoring
    private let wallNow: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var tokens: TokenPair?
    private var refreshTask: Task<TokenPair, Error>?
    private var tokenGeneration = 0

    init(
        baseURL: URL = URL(string: "https://pomodorough.egigoka.me")!,
        session: URLSession = .shared,
        keychain: any TokenStoring = KeychainStore(),
        logoutRevocationStore: (any LogoutRevocationStoring)? = nil,
        wallNow: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.keychain = keychain
        self.logoutRevocationStore = logoutRevocationStore
            ?? (keychain as? any LogoutRevocationStoring)
            ?? KeychainLogoutRevocationStore()
        self.wallNow = wallNow
        self.uptime = uptime
    }

    func restoreTokens() throws -> Bool {
        try installRestoredTokens(keychain.load())
    }

    func restoreTokens(excluding store: any LogoutRevocationStoring) throws -> Bool {
        let loaded = try keychain.load()
        let obligations = try store.load()
        let retiredRefreshTokens = Set(obligations.flatMap {
            [$0.activeCredentialRefreshToken, $0.tokens.refreshToken]
        })
        guard let loaded else { return installRestoredTokens(nil) }
        guard !retiredRefreshTokens.contains(loaded.refreshToken) else {
            _ = installRestoredTokens(nil)
            _ = deleteDetachedCredential(refreshToken: loaded.refreshToken)
            return false
        }
        return installRestoredTokens(loaded)
    }

    private func installRestoredTokens(_ restored: TokenPair?) -> Bool {
        tokens = restored
        tokenGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        return restored != nil
    }

    func challenge() async throws -> NativeChallenge {
        try await send("/api/v1/auth/google/challenge", method: "POST", authenticated: false)
    }

    func exchange(_ request: NativeExchangeRequest) async throws -> MeResponse {
        let pair: TokenPair = try await send(
            "/api/v1/auth/google/exchange",
            method: "POST",
            body: request,
            authenticated: false
        )
        tokenGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        try keychain.save(pair)
        tokens = pair
        return try await me()
    }

    func me() async throws -> MeResponse {
        try await send("/api/v1/me", authenticated: true)
    }

    func sync(_ request: SyncRequest) async throws -> TimedHTTPResponse<SyncResponse> {
        do {
            return try await sendTimed(
                "/api/v1/sync",
                method: "POST",
                body: SyncAPIRequest(request),
                authenticated: true
            )
        } catch is DecodingError {
            throw AppError.invalidResponse
        }
    }

    func bootstrap(_: SyncRequest) async throws -> TimedHTTPResponse<BootstrapResponse> {
        do {
            let response: TimedHTTPResponse<BootstrapResponse> = try await sendTimed(
                "/api/v1/bootstrap",
                authenticated: true,
                reportsMissingRoute: true
            )
            return try response.map { try $0.validatingEmptyAcknowledgements() }
        } catch is MissingRouteError {
            throw AppError.historyReplacementUnavailable
        } catch is DecodingError {
            throw AppError.invalidResponse
        }
    }

    func resolveBootstrap(_ request: BootstrapResolveRequest) async throws -> TimedHTTPResponse<BootstrapResponse> {
        do {
            return try await sendTimed(
                "/api/v1/bootstrap/resolve",
                method: "POST",
                body: BootstrapResolveAPIRequest(request),
                authenticated: true,
                reportsMissingRoute: true
            )
        } catch is MissingRouteError {
            throw AppError.historyReplacementUnavailable
        } catch is DecodingError {
            throw AppError.invalidResponse
        }
    }

    func revisionEvents() async throws -> AsyncThrowingStream<Int64, Error> {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/stream"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let streamRequest = request
        let session = self.session

        return AsyncThrowingStream<Int64, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: streamRequest)
                    guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
                    if http.statusCode == 401 { throw AppError.unauthorized }
                    guard RevisionStreamResponse.isValid(
                        statusCode: http.statusCode,
                        contentType: http.value(forHTTPHeaderField: "Content-Type")
                    ) else {
                        throw AppError.server("Invalid revision stream response (\(http.statusCode)).")
                    }

                    var parser = SSERevisionParser()
                    var lineBytes = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard byte == 0x0A else {
                            lineBytes.append(byte)
                            continue
                        }
                        if lineBytes.last == 0x0D {
                            lineBytes.removeLast()
                        }
                        let line = String(decoding: lineBytes, as: UTF8.self)
                        lineBytes.removeAll(keepingCapacity: true)
                        if let revision = parser.consume(line: line) {
                            continuation.yield(revision)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func logout() async throws {
        _ = try await perform(
            "/api/v1/auth/logout",
            method: "POST",
            body: Optional<String>.none,
            authenticated: true
        )
        try clearTokens()
    }

    func detachLogoutObligation(
        into store: any LogoutRevocationStoring
    ) throws -> LogoutRevocationObligation? {
        guard let tokens else { return nil }
        let obligation = LogoutRevocationObligation(tokens: tokens)
        try store.append(obligation)
        clearInMemoryTokens()
        try? keychain.delete()
        return obligation
    }

    func deleteDetachedCredential(refreshToken: String) -> Bool {
        do {
            guard let stored = try keychain.load() else { return true }
            guard stored.refreshToken == refreshToken else { return true }
            try keychain.delete()
            return true
        } catch {
            return false
        }
    }

    func revoke(_ obligation: LogoutRevocationObligation) async -> LogoutRevocationResult {
        if obligation.requiresRefresh {
            do {
                let tokens = try await refreshForRevocation(obligation.tokens.refreshToken)
                return .refreshed(tokens)
            } catch AppError.unauthorized {
                return .refreshUnauthorized
            } catch {
                return .retry
            }
        }
        return await submitRevocation(accessToken: obligation.tokens.accessToken)
    }

    func deleteAccount(confirmation: String) async -> AccountDeletionOutcome {
        do {
            var request = URLRequest(url: baseURL.appending(path: "/api/v1/account"))
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder.api.encode(DeleteAccountRequest(confirmation: confirmation))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unknown(String(localized: "Account deletion returned an invalid response."))
            }
            if (200..<300).contains(http.statusCode) { return .committed }
            let message = (try? JSONDecoder.api.decode(APIError.self, from: data).error)
                ?? "Request failed (\(http.statusCode))."
            if (400..<500).contains(http.statusCode) { return .rejected(message) }
            return .unknown(message)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    func clearTokens() throws {
        clearInMemoryTokens()
        try keychain.delete()
    }

    private func clearInMemoryTokens() {
        tokenGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
    }

    private func validAccessToken() async throws -> String {
        guard let tokens else { throw AppError.unauthorized }
        if tokens.accessTokenExpiresAt.timeIntervalSinceNow > 30 {
            return tokens.accessToken
        }
        let generation = tokenGeneration
        if let refreshTask {
            let pair = try await refreshTask.value
            guard generation == tokenGeneration else { throw AppError.unauthorized }
            return pair.accessToken
        }

        let task = Task { try await refresh(tokens.refreshToken, generation: generation) }
        refreshTask = task
        defer {
            if generation == tokenGeneration { refreshTask = nil }
        }
        let pair = try await task.value
        guard generation == tokenGeneration else { throw AppError.unauthorized }
        return pair.accessToken
    }

    private func refresh(_ refreshToken: String, generation: Int) async throws -> TokenPair {
        let pair: TokenPair = try await send(
            "/api/v1/auth/refresh",
            method: "POST",
            body: RefreshRequest(refreshToken: refreshToken),
            authenticated: false
        )
        try Task.checkCancellation()
        guard generation == tokenGeneration else { throw AppError.unauthorized }
        try keychain.save(pair)
        tokens = pair
        return pair
    }

    private func refreshForRevocation(_ refreshToken: String) async throws -> TokenPair {
        try await send(
            "/api/v1/auth/refresh",
            method: "POST",
            body: RefreshRequest(refreshToken: refreshToken),
            authenticated: false
        )
    }

    private func submitRevocation(accessToken: String) async -> LogoutRevocationResult {
        do {
            _ = try await perform(
                "/api/v1/auth/logout",
                method: "POST",
                body: Optional<String>.none,
                authenticated: false,
                bearerToken: accessToken
            )
            return .revoked
        } catch AppError.unauthorized {
            return .accessUnauthorized
        } catch {
            return .retry
        }
    }

    private func send<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> Response {
        try await send(
            path,
            method: method,
            body: Optional<String>.none,
            authenticated: authenticated,
            reportsMissingRoute: reportsMissingRoute
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Body?,
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> Response {
        let result = try await perform(
            path,
            method: method,
            body: body,
            authenticated: authenticated,
            reportsMissingRoute: reportsMissingRoute
        )
        return try JSONDecoder.api.decode(Response.self, from: result.data)
    }

    private func sendTimed<Response: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> TimedHTTPResponse<Response> {
        try await sendTimed(
            path,
            method: method,
            body: Optional<String>.none,
            authenticated: authenticated,
            reportsMissingRoute: reportsMissingRoute
        )
    }

    private func sendTimed<Body: Encodable, Response: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        body: Body?,
        authenticated: Bool,
        reportsMissingRoute: Bool = false
    ) async throws -> TimedHTTPResponse<Response> {
        let result = try await perform(
            path,
            method: method,
            body: body,
            authenticated: authenticated,
            reportsMissingRoute: reportsMissingRoute,
            capturesTiming: true
        )
        guard let requestWall = result.requestWall,
              let requestUptime = result.requestUptime,
              let responseUptime = result.responseUptime else {
            throw AppError.invalidResponse
        }
        return TimedHTTPResponse(
            value: try JSONDecoder.api.decode(Response.self, from: result.data),
            requestWall: requestWall,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        )
    }

    private func perform<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        authenticated: Bool,
        reportsMissingRoute: Bool = false,
        capturesTiming: Bool = false,
        bearerToken: String? = nil
    ) async throws -> HTTPResult {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder.api.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        } else if authenticated {
            request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        }

        let requestWall = capturesTiming ? wallNow() : nil
        let requestUptime = capturesTiming ? uptime() : nil
        let (data, response) = try await session.data(for: request)
        let responseUptime = capturesTiming ? uptime() : nil
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AppError.unauthorized }
            if http.statusCode == 404, reportsMissingRoute { throw MissingRouteError() }
            let message = (try? JSONDecoder.api.decode(APIError.self, from: data).error) ?? "Request failed (\(http.statusCode))."
            if http.statusCode == 409 { throw AppError.conflict(message) }
            throw AppError.server(message)
        }
        return HTTPResult(
            data: data,
            requestWall: requestWall,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        )
    }
}

private struct SyncAPIRequest: Encodable {
    let deviceId: String
    let lastRevision: Int64
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartAPIRequest]?
    let selectedTaskOperations: [SelectedTaskAPIRequest]

    init(_ request: SyncRequest) {
        deviceId = request.deviceId
        lastRevision = request.lastRevision
        commands = request.commands
        taskOperations = request.taskOperations
        durationOperations = request.durationOperations
        autoStartOperations = request.autoStartOperations?.map(AutoStartAPIRequest.init)
        selectedTaskOperations = request.selectedTaskOperations.map(SelectedTaskAPIRequest.init)
    }
}

private struct BootstrapResolveAPIRequest: Encodable {
    let requestId: String
    let deviceId: String
    let expectedRevision: Int64
    let strategy: BootstrapResolutionStrategy
    let commands: [TimerCommand]
    let taskOperations: [TaskOperation]
    let durationOperations: [DurationOperation]
    let autoStartOperations: [AutoStartAPIRequest]?
    let selectedTaskOperations: [SelectedTaskAPIRequest]?

    init(_ request: BootstrapResolveRequest) {
        requestId = request.requestId
        deviceId = request.deviceId
        expectedRevision = request.expectedRevision
        strategy = request.strategy
        commands = request.commands
        taskOperations = request.taskOperations
        durationOperations = request.durationOperations
        autoStartOperations = request.autoStartOperations?.map(AutoStartAPIRequest.init)
        selectedTaskOperations = request.selectedTaskOperations?.map(SelectedTaskAPIRequest.init)
    }
}

private struct AutoStartAPIRequest: Encodable {
    let id: UUID
    let enabled: Bool
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(_ operation: AutoStartOperation) {
        id = operation.id
        enabled = operation.enabled
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }
}

private struct SelectedTaskAPIRequest: Encodable {
    let id: UUID
    let taskId: String?
    let occurredAt: Date
    let hlcWallMs: Int64
    let hlcCounter: Int64

    init(_ operation: SelectedTaskOperation) {
        id = operation.id
        taskId = operation.taskId
        occurredAt = operation.occurredAt
        hlcWallMs = operation.hlcWallMs
        hlcCounter = operation.hlcCounter
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskId, occurredAt, hlcWallMs, hlcCounter
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        if let taskId {
            try values.encode(taskId, forKey: .taskId)
        } else {
            try values.encodeNil(forKey: .taskId)
        }
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(hlcWallMs, forKey: .hlcWallMs)
        try values.encode(hlcCounter, forKey: .hlcCounter)
    }
}

private struct DeleteAccountRequest: Encodable {
    let confirmation: String
}

struct TimedHTTPResponse<Value: Sendable>: Sendable {
    let value: Value
    let requestWall: Date
    let requestUptime: TimeInterval
    let responseUptime: TimeInterval

    func map<Mapped: Sendable>(_ transform: (Value) throws -> Mapped) rethrows -> TimedHTTPResponse<Mapped> {
        TimedHTTPResponse<Mapped>(
            value: try transform(value),
            requestWall: requestWall,
            requestUptime: requestUptime,
            responseUptime: responseUptime
        )
    }
}

private struct HTTPResult: Sendable {
    let data: Data
    let requestWall: Date?
    let requestUptime: TimeInterval?
    let responseUptime: TimeInterval?
}

private struct APIError: Decodable { let error: String }
private struct MissingRouteError: Error {}

private extension BootstrapResponse {
    func validatingEmptyAcknowledgements() throws -> Self {
        guard acknowledgements.isEmpty,
              taskAcknowledgements.isEmpty,
              durationAcknowledgements.isEmpty,
              autoStartAcknowledgements.isEmpty,
              selectedTaskAcknowledgements.isEmpty else {
            throw AppError.invalidResponse
        }
        return self
    }
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }
}

extension JSONEncoder {
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            let standard = Date.ISO8601FormatStyle()
            if let date = try? fractional.parse(value) {
                return date
            }
            if let date = try? standard.parse(value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid RFC 3339 date")
        }
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
    }
}
