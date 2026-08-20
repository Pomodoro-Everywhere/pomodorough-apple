import SwiftUI

struct TaskSummaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let summary: TaskDailySummary
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            summaryContent
                .frame(maxWidth: .infinity, alignment: .leading)
            deleteButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .monospacedDigit()
        .accessibilityRepresentation {
            Text(summary.task.title)
                .accessibilityValue(summaryAccessibilityValue)
                .accessibilityAction(named: "Delete task", delete)
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.task.title)
                    .font(.body.weight(.semibold))
                Text("\(summary.finishedPomodoros) finished pomodoros")
                Text(TaskTimeText.spoken(summary.timeSpentMs))
            }
        } else {
            HStack(spacing: 10) {
                Text(summary.task.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(summary.finishedPomodoros)")
                    .frame(width: 68, alignment: .center)
                Text(TaskTimeText.compact(summary.timeSpentMs))
                    .frame(width: 70, alignment: .center)
            }
        }
    }

    private var summaryAccessibilityValue: String {
        "\(summary.finishedPomodoros) finished pomodoros today, \(TaskTimeText.spoken(summary.timeSpentMs)) spent"
    }

    @ViewBuilder
    private var deleteButton: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Button("Delete \(summary.task.title)", systemImage: "trash", role: .destructive, action: delete)
                .foregroundStyle(PomodoroughTheme.danger)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        } else {
            Button("Delete \(summary.task.title)", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .foregroundStyle(PomodoroughTheme.danger)
                .frame(width: 52, height: 44)
        }
    }
}

#if DEBUG
#Preview {
    TaskSummaryRow(summary: PreviewFixtures.taskSummary, delete: {})
        .padding()
}
#endif
