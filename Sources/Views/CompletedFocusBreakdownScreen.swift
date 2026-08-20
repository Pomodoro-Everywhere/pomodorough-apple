import Charts
import SwiftUI

struct CompletedFocusBreakdownScreen: View {
    let model: AppModel

    private let chartColors = [
        PomodoroughTheme.platform,
        PomodoroughTheme.signal,
        PomodoroughTheme.ticket,
        PomodoroughTheme.mint,
        PomodoroughTheme.steel,
        PomodoroughTheme.danger
    ]

    var body: some View {
        let summaries = model.completedFocusSummaries()
        Group {
            if summaries.isEmpty {
                ContentUnavailableView(
                    "No completed focus yet",
                    systemImage: "chart.pie",
                    description: Text("Finish a focus timer to see its time here.")
                )
                .accessibilityRepresentation {
                    Text("No completed focus yet")
                        .accessibilityValue("Finish a focus timer to see its time here.")
                }
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        totals(summaries)
                        chart(summaries)
                        taskList(summaries)
                    }
                    .padding()
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Completed focus")
        .inlineNavigationTitleIfSupported()
    }

    private func totalPomodoros(in summaries: [CompletedFocusSummary]) -> Int {
        summaries.reduce(0) { $0 + $1.completedPomodoros }
    }

    private func totalTimeMs(in summaries: [CompletedFocusSummary]) -> Int64 {
        summaries.reduce(0) { $0 + $1.timeSpentMs }
    }

    private func totals(_ summaries: [CompletedFocusSummary]) -> some View {
        let totalPomodoros = totalPomodoros(in: summaries)
        let totalTimeMs = totalTimeMs(in: summaries)
        return HStack(spacing: 0) {
            focusMetric(value: "\(totalPomodoros)", label: "COMPLETED")
            Divider()
                .overlay(PomodoroughTheme.steel.opacity(0.5))
                .padding(.horizontal, 18)
            focusMetric(value: TaskTimeText.compact(totalTimeMs), label: "FOCUS TIME")
        }
        .padding(18)
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 20))
        .accessibilityRepresentation {
            Text("Completed focus summary")
                .accessibilityValue(
                    "\(totalPomodoros) completed pomodoros, \(TaskTimeText.spoken(totalTimeMs)) total"
                )
        }
    }

    private func chart(_ summaries: [CompletedFocusSummary]) -> some View {
        Chart(Array(summaries.enumerated()), id: \.element.id) { entry in
            SectorMark(
                angle: .value("Completed focus minutes", Double(entry.element.timeSpentMs) / 60_000),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Task", entry.element.id))
            .annotation(position: .overlay) {
                Text("\(entry.offset + 1)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(chartLabelColor(at: entry.offset))
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(entry.element.taskTitle)
            .accessibilityValue(
                "\(entry.element.completedPomodoros) completed pomodoros, \(TaskTimeText.spoken(entry.element.timeSpentMs))"
            )
        }
        .chartForegroundStyleScale(
            domain: summaries.map(\.id),
            range: summaries.indices.map { chartColors[$0 % chartColors.count] }
        )
        .chartLegend(.hidden)
        .frame(height: 280)
        .accessibilityLabel("Completed focus time by task")
    }

    private func taskList(_ summaries: [CompletedFocusSummary]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                if index > 0 {
                    Divider()
                }
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(chartLabelColor(at: index))
                        .frame(width: 22, height: 22)
                        .background(chartColors[index % chartColors.count], in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.taskTitle)
                            .font(.body.weight(.semibold))
                        Text("\(summary.completedPomodoros) completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(TaskTimeText.compact(summary.timeSpentMs))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.steel.opacity(0.45), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func focusMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.sky)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .black))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartLabelColor(at index: Int) -> Color {
        switch index % chartColors.count {
        case 0, 5: PomodoroughTheme.porcelain
        default: PomodoroughTheme.platformDeep
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        CompletedFocusBreakdownScreen(model: AppModel.preview(.populated))
    }
}
#endif
