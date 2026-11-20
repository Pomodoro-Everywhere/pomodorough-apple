#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Pomodorough

// IOS27-21: the wide task table (open Duo, iPad) capped the title at two
// lines, so a long focus task title was cut off with free row width left
// and no other screen in that layout showed the whole title.
@MainActor
@Suite("Task row title wrapping")
struct TaskSummaryRowTitleWrapTests {
    // About 420 characters: more than three lines even if the title had
    // the whole 900 pt row, and inside the 512-byte title limit.
    private static let longTitle = Array(
        repeating: "Prepare the quarterly infrastructure review with the platform team and collect every open incident report",
        count: 4
    ).joined(separator: " ")

    @Test(arguments: [false, true])
    func wideTableRowShowsTheWholeLongTitle(isFocusTask: Bool) throws {
        let width: CGFloat = 900
        let oneLine = try rowHeight(title: "Deep work", isFocusTask: isFocusTask, width: width)
        let long = try rowHeight(title: Self.longTitle, isFocusTask: isFocusTask, width: width)
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        // The long title needs at least four lines at this width; the old
        // two-line cap added only one line to a one-line row.
        #expect(long - oneLine >= lineHeight * 1.5, "one line \(oneLine) pt, long title \(long) pt")
    }

    private func rowHeight(title: String, isFocusTask: Bool, width: CGFloat) throws -> CGFloat {
        let task = try #require(FocusTask(title: title))
        let summary = TaskDailySummary(task: task, finishedPomodoros: 2, timeSpentMs: 50 * 60_000)
        let row = TaskSummaryRow(summary: summary, isFocusTask: isFocusTask, delete: {})
            .environment(\.horizontalSizeClass, .regular)
            .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: row)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
#endif
