import Foundation

enum SSERevisionStreamError: Error, Equatable {
    case lineLimitExceeded
    case eventLimitExceeded
}

struct SSERevisionStreamDecoder: Sendable {
    // Limits count raw stream bytes, excluding CRLF framing; events include every nonblank field line.
    static let maximumLineBytes = 64 * 1_024
    static let maximumEventBytes = 256 * 1_024

    private let lineLimit: Int
    private let eventLimit: Int
    private var lineBytes = Data()
    private var hasPendingCarriageReturn = false
    private var eventBytes = 0
    private var parser = SSERevisionParser()

    init(
        lineLimit: Int = Self.maximumLineBytes,
        eventLimit: Int = Self.maximumEventBytes
    ) {
        precondition(lineLimit > 0 && eventLimit > 0)
        self.lineLimit = lineLimit
        self.eventLimit = eventLimit
    }

    mutating func consume(byte: UInt8) throws -> Int64? {
        if byte != 0x0A {
            if hasPendingCarriageReturn { try appendLineByte(0x0D) }
            hasPendingCarriageReturn = byte == 0x0D
            if !hasPendingCarriageReturn { try appendLineByte(byte) }
            return nil
        }
        hasPendingCarriageReturn = false
        let byteCount = lineBytes.count
        let isEventBoundary = lineBytes.isEmpty
        if !isEventBoundary {
            eventBytes += byteCount
        }
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        let revision = parser.consume(line: line)
        if isEventBoundary { eventBytes = 0 }
        return revision
    }

    private mutating func appendLineByte(_ byte: UInt8) throws {
        guard lineBytes.count < lineLimit else {
            throw SSERevisionStreamError.lineLimitExceeded
        }
        guard lineBytes.count < eventLimit - eventBytes else {
            throw SSERevisionStreamError.eventLimitExceeded
        }
        lineBytes.append(byte)
    }
}

struct SSERevisionParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> Int64? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
            }
            guard eventName == nil || eventName == "message" || eventName == "revision" else { return nil }
            let data = dataLines.joined(separator: "\n")
            guard !data.isEmpty else { return nil }
            if let raw = Int64(data.trimmingCharacters(in: .whitespacesAndNewlines)) { return raw }
            return (try? JSONDecoder().decode(RevisionEnvelope.self, from: Data(data.utf8)))?.revision
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = Self.fieldValue(line, prefixLength: 6)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.fieldValue(line, prefixLength: 5))
        }
        return nil
    }

    private static func fieldValue(_ line: String, prefixLength: Int) -> String {
        var value = String(line.dropFirst(prefixLength))
        if value.first == " " { value.removeFirst() }
        return value
    }
}

struct RevisionHintCoalescer: Sendable {
    private var latestPendingRevision: Int64?

    mutating func receive(_ revision: Int64, localRevision: Int64, isSyncing: Bool) -> Bool {
        guard revision > localRevision else { return false }
        guard isSyncing else { return true }
        latestPendingRevision = max(latestPendingRevision ?? revision, revision)
        return false
    }

    mutating func consumeFollowUp(localRevision: Int64) -> Bool {
        defer { latestPendingRevision = nil }
        return latestPendingRevision.map { $0 > localRevision } ?? false
    }
}

struct RevisionStreamLifecycle: Sendable {
    private(set) var isActive = false
    private var currentID: UUID?

    mutating func setActive(_ active: Bool) {
        isActive = active
        if !active { currentID = nil }
    }

    mutating func begin() -> UUID? {
        guard isActive, currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func owns(_ id: UUID?) -> Bool {
        isActive && id != nil && currentID == id
    }

    mutating func end(_ id: UUID) {
        if currentID == id { currentID = nil }
    }

    mutating func cancelCurrent() {
        currentID = nil
    }
}

struct SessionVerification: Sendable {
    private var generation: Int?

    mutating func markVerified(generation: Int) {
        self.generation = generation
    }

    mutating func invalidate() {
        generation = nil
    }

    func allows(generation: Int) -> Bool {
        self.generation == generation
    }
}

struct SyncOwnership: Sendable {
    private var ownerID: UUID?
    private var requestedGeneration: Int?

    mutating func begin(generation: Int) -> UUID? {
        guard ownerID == nil else {
            requestedGeneration = max(requestedGeneration ?? generation, generation)
            return nil
        }
        let id = UUID()
        ownerID = id
        return id
    }

    mutating func invalidate() {
        ownerID = nil
        requestedGeneration = nil
    }

    mutating func finish(_ id: UUID, currentGeneration: Int) -> Bool? {
        guard ownerID == id else { return nil }
        ownerID = nil
        defer { requestedGeneration = nil }
        return requestedGeneration == currentGeneration
    }

    func isOwned(by id: UUID?) -> Bool {
        id != nil && ownerID == id
    }
}

enum RemotePolling {
    static func interval(isTimerActive: Bool) -> TimeInterval {
        isTimerActive ? 2 : 5
    }
}

enum RevisionStreamResponse {
    static func isValid(statusCode: Int, contentType: String?) -> Bool {
        guard statusCode == 200, let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType.caseInsensitiveCompare("text/event-stream") == .orderedSame
    }
}

private struct RevisionEnvelope: Decodable {
    let revision: Int64
}
