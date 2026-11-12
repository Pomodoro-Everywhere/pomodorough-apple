import SwiftUI

struct TaskSummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    let summary: TaskDailySummary
    var isFocusTask = false
    /// macOS double-click rename; nil hides the affordance.
    var rename: (() -> Void)? = nil
    let delete: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityRow
            } else if usesStackedLayout {
                stackedRow
            } else {
                columnRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .monospacedDigit()
        .accessibilityElement(children: .contain)
    }

    private var stackedRow: some View {
        HStack(spacing: TaskBoardColumns.spacing) {
            VStack(alignment: .leading, spacing: 6) {
                titleRow(lineLimit: nil)
                Text("\(summary.finishedPomodoros) pomodoros · \(TaskTimeText.shortMinutes(spentMinutes))")
                    .accessibilityLabel(summaryAccessibilityLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            deleteButton
        }
    }

    /// IOS27-13: at accessibility sizes the title takes the full row width.
    /// The badge, the summary and the trash button follow it on their own
    /// lines, so the trash button sits at the end of the row, not halfway
    /// down a long title.
    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.task.title)
                .font(.body.weight(.semibold))
#if os(macOS)
                .onTapGesture(count: 2) { rename?() }
#endif
            if isFocusTask {
                focusBadge
            }
            Text("\(summary.finishedPomodoros) pomodoros · \(TaskTimeText.shortMinutes(spentMinutes))")
                .accessibilityLabel(summaryAccessibilityLabel)
            deleteControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnRow: some View {
        HStack(spacing: TaskBoardColumns.spacing) {
            titleRow(lineLimit: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: TaskBoardColumns.spacing) {
                Text("\(summary.finishedPomodoros)")
                    .containerRelativeFrame(
                        .horizontal,
                        count: TaskBoardColumns.totalSpans,
                        span: TaskBoardColumns.finishedSpan,
                        spacing: TaskBoardColumns.spacing,
                        alignment: .center
                    )
                Text(TaskTimeText.compact(summary.timeSpentMs))
                    .containerRelativeFrame(
                        .horizontal,
                        count: TaskBoardColumns.totalSpans,
                        span: TaskBoardColumns.timeSpan,
                        spacing: TaskBoardColumns.spacing,
                        alignment: .center
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summaryAccessibilityLabel)
            deleteButton
        }
    }

    private func titleRow(lineLimit: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(summary.task.title)
                .font(.body.weight(.semibold))
                .lineLimit(lineLimit)
#if os(macOS)
                .onTapGesture(count: 2) { rename?() }
#endif
            if isFocusTask {
                focusBadge
            }
        }
    }

    /// Marks the task the timer attributes focus runs to.
    private var focusBadge: some View {
        Label("Focus", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(PomodoroughTheme.signalText)
            .accessibilityLabel("Focus task")
    }

    private var spentMinutes: Int {
        Int(summary.timeSpentMs / 60_000)
    }

    private var summaryAccessibilityLabel: String {
        Self.accessibilityLabel(for: summary)
    }

    /// Composed from single-count strings so the pomodoro count pluralizes
    /// ("1 finished pomodoro, 25 minutes spent").
    static func accessibilityLabel(for summary: TaskDailySummary) -> String {
        let finished = String(localized: "\(summary.finishedPomodoros) finished pomodoros")
        let spoken = TaskTimeText.spoken(summary.timeSpentMs)
        return String(localized: "\(finished), \(spoken) spent")
    }

    private var usesStackedLayout: Bool {
#if os(iOS)
        dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact
#else
        dynamicTypeSize.isAccessibilitySize
#endif
    }

    @ViewBuilder
    private var deleteButton: some View {
        if usesStackedLayout {
            deleteControl
        } else {
            deleteControl
                .containerRelativeFrame(
                    .horizontal,
                    count: TaskBoardColumns.totalSpans,
                    span: TaskBoardColumns.actionSpan,
                    spacing: TaskBoardColumns.spacing,
                    alignment: .center
                )
        }
    }

    private var deleteControl: some View {
        Button(role: .destructive, action: delete) {
            Label("Delete \(summary.task.title)", systemImage: "trash")
                .labelStyle(.iconOnly)
                // The system minimum touch target must belong to the label.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .foregroundStyle(PomodoroughTheme.danger)
    }
}

#if DEBUG
#Preview {
    TaskSummaryRow(summary: PreviewFixtures.taskSummary, delete: {})
        .padding()
}
#endif
