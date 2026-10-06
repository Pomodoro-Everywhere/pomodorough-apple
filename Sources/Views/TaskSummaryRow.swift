import SwiftUI

struct TaskSummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    let summary: TaskDailySummary
    let delete: () -> Void

    var body: some View {
        Group {
            if usesStackedLayout {
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
                Text(summary.task.title)
                    .font(.body.weight(.semibold))
                Text("\(summary.finishedPomodoros) finished pomodoros")
                Text(TaskTimeText.spoken(summary.timeSpentMs))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            deleteButton
        }
    }

    private var columnRow: some View {
        HStack(spacing: TaskBoardColumns.spacing) {
            Text(summary.task.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
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

    private var summaryAccessibilityLabel: String {
        String(localized: "\(summary.finishedPomodoros) finished pomodoros, \(TaskTimeText.spoken(summary.timeSpentMs)) spent")
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
