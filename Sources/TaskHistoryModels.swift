import CryptoKit
import Foundation

struct HistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let timerId: String
    let commandId: String?
    let taskId: String?
    let phase: TimerPhase
    let status: String
    let plannedDurationMs: Int64
    let completedAt: Date?
    let endedAt: Date?

    var date: Date? { completedAt ?? endedAt }
    var minutes: Int { max(1, Int((plannedDurationMs + 59_999) / 60_000)) }

    var isValid: Bool {
        let validTerminalDate: Bool
        switch status {
        case CanonicalTimer.Status.completed.rawValue:
            validTerminalDate = completedAt != nil
        case CanonicalTimer.Status.cancelled.rawValue,
             CanonicalTimer.Status.superseded.rawValue:
            validTerminalDate = completedAt == nil && endedAt != nil
        default:
            validTerminalDate = false
        }
        return !id.isEmpty
            && !timerId.isEmpty
            && (commandId == nil || commandId?.isEmpty == false)
            && (taskId == nil || taskId.flatMap(UUID.init(uuidString:)) != nil)
            && DurationValues.isValidWireDuration(plannedDurationMs)
            && validTerminalDate
            && date.flatMap(WireBounds.physicalMilliseconds(for:)) != nil
            && (endedAt == nil || endedAt.flatMap(WireBounds.physicalMilliseconds(for:)) != nil)
    }
}

struct FocusTask: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let title: String

    private enum CodingKeys: String, CodingKey { case id, title }

    init?(title rawTitle: String) {
        let title = Self.normalizedTitle(rawTitle)
        guard !title.isEmpty, Data(title.utf8).count <= 512 else { return nil }
        self.id = Self.deterministicID(for: title)
        self.title = title
    }

    var isValid: Bool {
        Self(title: title)?.id == id
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(title, forKey: .title)
    }

    static func normalizedTitle(_ title: String) -> String {
        let scalars = Array(title.precomposedStringWithCanonicalMapping.unicodeScalars)
        var lowerBound = 0
        var upperBound = scalars.count
        while lowerBound < upperBound, !isPrintable(scalars[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound, !isPrintable(scalars[upperBound - 1]) {
            upperBound -= 1
        }
        return scalars[lowerBound..<upperBound].reduce(into: "") { result, scalar in
            result.unicodeScalars.append(scalar)
        }
    }

    private static func deterministicID(for title: String) -> UUID {
        let digest = SHA256.hash(data: Data("pomodorough.task.v1\0\(title)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }
}

struct LocalTaskState: Codable, Equatable, Sendable {
    var tasks: [FocusTask]
    var selectedTaskID: UUID?
    var assignments: [String: FocusTask]

    static let empty = Self(tasks: [], selectedTaskID: nil, assignments: [:])
}

struct TaskDailySummary: Identifiable, Equatable, Sendable {
    let task: FocusTask
    let finishedPomodoros: Int
    let timeSpentMs: Int64

    var id: UUID { task.id }
}

struct CompletedFocusSummary: Identifiable, Equatable, Sendable {
    let id: String
    let taskTitle: String
    let completedPomodoros: Int
    let timeSpentMs: Int64
}

enum HistoryAnalytics {
    static func taskContext(
        for item: HistoryItem,
        taskForItem: (HistoryItem) -> FocusTask?
    ) -> String {
        if let task = taskForItem(item) { return task.title }
        let taskID = item.taskId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return taskID?.isEmpty == false ? String(localized: "Deleted task") : String(localized: "Unassigned")
    }

    static func completedFocusSummaries(
        from history: [HistoryItem],
        taskIDForItem: (HistoryItem) -> String? = { $0.taskId },
        taskForItem: (HistoryItem) -> FocusTask?
    ) -> [CompletedFocusSummary] {
        var totals: [String: (title: String, count: Int, timeMs: Int64)] = [:]
        for item in history {
            guard item.phase == .focus, item.status == CanonicalTimer.Status.completed.rawValue else { continue }
            let task = taskForItem(item)
            let unresolvedTaskID = taskIDForItem(item)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = task?.id.uuidString.lowercased()
                ?? unresolvedTaskID.flatMap { $0.isEmpty ? nil : "task:\($0.lowercased())" }
                ?? "unassigned"
            let title = task?.title ?? (id == "unassigned"
                ? String(localized: "Unassigned")
                : String(localized: "Deleted task"))
            let current = totals[id] ?? (title, 0, 0)
            totals[id] = (current.title, current.count + 1, current.timeMs + item.plannedDurationMs)
        }
        return totals.map { id, total in
            CompletedFocusSummary(
                id: id,
                taskTitle: total.title,
                completedPomodoros: total.count,
                timeSpentMs: total.timeMs
            )
        }
        .sorted {
            if $0.timeSpentMs != $1.timeSpentMs { return $0.timeSpentMs > $1.timeSpentMs }
            if $0.completedPomodoros != $1.completedPomodoros {
                return $0.completedPomodoros > $1.completedPomodoros
            }
            let titleOrder = $0.taskTitle.localizedCaseInsensitiveCompare($1.taskTitle)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
