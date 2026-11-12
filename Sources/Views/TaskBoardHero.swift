import SwiftUI

struct TaskBoardHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let finishedPomodoros: Int
    let timeSpentMs: Int64
    let date: Date

    init(finishedPomodoros: Int, timeSpentMs: Int64, date: Date = .now) {
        self.finishedPomodoros = finishedPomodoros
        self.timeSpentMs = timeSpentMs
        self.date = date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                // IOS27-16: no decorative clock mark at accessibility sizes,
                // and the metrics share a line whenever they fit, so the
                // card leaves the task list on the first screen.
                VStack(alignment: .leading, spacing: 8) { heroTitle }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { metrics }
                    VStack(alignment: .leading, spacing: 14) { metrics }
                }
            } else {
                HStack(spacing: 12) {
                    RouteClockMark(compact: true)
                    heroTitle
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    TaskBoardMetric(label: "FINISHED", value: "\(finishedPomodoros)")
                    Divider()
                        .overlay(PomodoroughTheme.steel.opacity(0.5))
                        .padding(.horizontal, 18)
                    TaskBoardMetric(label: "FOCUS TIME", value: TaskTimeText.compact(timeSpentMs))
                }
            }
        }
        .padding(18)
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(PomodoroughTheme.platform)
                .shadow(color: PomodoroughTheme.signal.opacity(0.9), radius: 0, x: 6, y: 6)
        }
        .accessibilityRepresentation {
            Text("Task board")
                .accessibilityValue(Self.accessibilityValue(
                    finishedPomodoros: finishedPomodoros, timeSpentMs: timeSpentMs, date: date
                ))
        }
    }

    @ViewBuilder
    private var metrics: some View {
        TaskBoardMetric(label: "FINISHED", value: "\(finishedPomodoros)")
            .fixedSize()
        TaskBoardMetric(label: "FOCUS TIME", value: TaskTimeText.compact(timeSpentMs))
            .fixedSize()
    }

    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TASK BOARD")
                .font(.caption.monospaced().bold())
                .tracking(1.4)
                .foregroundStyle(PomodoroughTheme.ticket)
            Text(date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.title3.weight(.bold))
        }
    }

    /// Composed from single-count strings so the pomodoro count pluralizes
    /// ("1 finished pomodoro", "3 finished pomodoros").
    static func accessibilityValue(finishedPomodoros: Int, timeSpentMs: Int64, date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let finished = String(localized: "\(finishedPomodoros) finished pomodoros")
        let spoken = TaskTimeText.spoken(timeSpentMs)
        return String(localized: "\(day), \(finished), \(spoken) focus time")
    }
}

#if DEBUG
#Preview {
    TaskBoardHero(finishedPomodoros: 3, timeSpentMs: 75 * 60_000)
        .padding()
}
#endif
