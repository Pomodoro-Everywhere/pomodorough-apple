import Charts
import SwiftUI

struct CompletedFocusChartEntry: Identifiable {
    let summary: CompletedFocusSummary
    let index: Int

    var id: String { summary.id }
    var color: Color { CompletedFocusBreakdownScreen.badgeColor(at: index) }
    var labelColor: Color { CompletedFocusBreakdownScreen.badgeLabelColor(at: index) }

    static func entries(for summaries: [CompletedFocusSummary]) -> [Self] {
        summaries.enumerated().map { Self(summary: $0.element, index: $0.offset) }
    }
}

struct CompletedFocusBreakdownScreen: View {
    let model: AppModel

    private static let chartColors = [
        PomodoroughTheme.platform,
        PomodoroughTheme.signal,
        PomodoroughTheme.ticket,
        PomodoroughTheme.mint,
        PomodoroughTheme.steel,
        PomodoroughTheme.danger
    ]

    /// Chart height follows the container width so SE through iPad each
    /// get a proportional pie inside the scrolling parent. Bounded so
    /// narrow phones stay legible and wide screens never stretch the pie.
    static let chartAspectRatio: CGFloat = 1.35
    static let chartMinHeight: CGFloat = 220
    static let chartMaxHeight: CGFloat = 380

    static func chartHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return chartMinHeight }
        return min(max(width / chartAspectRatio, chartMinHeight), chartMaxHeight)
    }

    /// Numbered-slice badge fill per position; the label partner comes
    /// from badgeLabelColor(at:) and every pair clears WCAG AA 4.5:1.
    static func badgeColor(at index: Int) -> Color {
        chartColors[index % chartColors.count]
    }

    var body: some View {
        let summaries = model.completedFocusSummaries()
        let entries = CompletedFocusChartEntry.entries(for: summaries)
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
                        chart(entries)
                        taskList(entries)
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

    private func chart(_ entries: [CompletedFocusChartEntry]) -> some View {
        chartContent(entries)
            .aspectRatio(Self.chartAspectRatio, contentMode: .fit)
            .frame(minHeight: Self.chartMinHeight, maxHeight: Self.chartMaxHeight)
            .accessibilityLabel("Completed focus time by task")
    }

    private func chartContent(_ entries: [CompletedFocusChartEntry]) -> some View {
        Chart(entries) { entry in
            SectorMark(
                angle: .value("Completed focus minutes", Double(entry.summary.timeSpentMs) / 60_000),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Task", entry.id))
            .annotation(position: .overlay) {
                Text("\(entry.index + 1)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(entry.labelColor)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(Self.accessibilityLabel(for: entry.summary))
            .accessibilityValue(Self.accessibilityValue(for: entry.summary))
        }
        .chartForegroundStyleScale(
            domain: entries.map(\.id),
            range: entries.map(\.color)
        )
        // The numbered task list is the legend; duplicate titles retain separate ID-keyed rows.
        .chartLegend(.hidden)
    }

    static func accessibilityLabel(for summary: CompletedFocusSummary) -> String {
        summary.taskTitle
    }

    /// Looks up the catalog plural for `%lld completed pomodoros, %@`; a plain
    /// String literal is verbatim and would speak "1 completed pomodoros".
    static func accessibilityValue(for summary: CompletedFocusSummary) -> String {
        let spoken = TaskTimeText.spoken(summary.timeSpentMs)
        return String(localized: "\(summary.completedPomodoros) completed pomodoros, \(spoken)")
    }

    private func taskList(_ entries: [CompletedFocusChartEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                let summary = entry.summary
                if entry.index > 0 {
                    Divider()
                }
                HStack(spacing: 12) {
                    ChartBadge(entry: entry)
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.accessibilityLabel(for: summary))
                .accessibilityValue(Self.accessibilityValue(for: summary))
            }
        }
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.steel.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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
        Self.badgeLabelColor(at: index)
    }

    /// Numbered-slice badge label per position: porcelain on the dark
    /// platform/danger slices, platformDeep on the bright signal, ticket,
    /// mint, and steel slices. Every pair clears WCAG AA 4.5:1 for small
    /// text (see badge contrast pins); vivid fills stay decorative only.
    static func badgeLabelColor(at index: Int) -> Color {
        switch index % chartColors.count {
        case 0, 5: PomodoroughTheme.porcelain
        default: PomodoroughTheme.platformDeep
        }
    }

    /// sRGB partners of badgeColor(at:) for the contrast audit, sourced
    /// from the same theme tuples as the shipped Colors.
    static func badgeSliceSRGB(at index: Int) -> (red: Double, green: Double, blue: Double) {
        switch index % 6 {
        case 0: PomodoroughTheme.platformSRGB
        case 1: PomodoroughTheme.signalSRGB
        case 2: PomodoroughTheme.ticketSRGB
        case 3: PomodoroughTheme.mintSRGB
        case 4: PomodoroughTheme.steelSRGB
        default: PomodoroughTheme.dangerSRGB
        }
    }

    /// sRGB partner of badgeLabelColor(at:) for the contrast audit.
    static func badgeLabelSRGB(at index: Int) -> (red: Double, green: Double, blue: Double) {
        switch index % 6 {
        case 0, 5: PomodoroughTheme.porcelainSRGB
        default: PomodoroughTheme.platformDeepSRGB
        }
    }
}

/// Contrast-safe numbered-slice badge shared by the chart annotations
/// and the task list. Diameter follows Dynamic Type instead of a fixed
/// 22pt circle so larger text never clips.
struct ChartBadge: View {
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 22

    let entry: CompletedFocusChartEntry

    var body: some View {
        Text("\(entry.index + 1)")
            .font(.caption2.monospacedDigit().bold())
            .foregroundStyle(entry.labelColor)
            .frame(width: diameter, height: diameter)
            .background(entry.color, in: .circle)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        CompletedFocusBreakdownScreen(model: AppModel.preview(.populated))
    }
}
#endif
