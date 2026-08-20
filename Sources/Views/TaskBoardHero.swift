import SwiftUI

struct TaskBoardHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let finishedPomodoros: Int
    let timeSpentMs: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { heroHeading }
                } else {
                    HStack(spacing: 12) { heroHeading }
                }
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        TaskBoardMetric(label: "FINISHED", value: "\(finishedPomodoros)")
                        Divider().overlay(PomodoroughTheme.steel.opacity(0.5))
                        TaskBoardMetric(label: "FOCUS TIME", value: TaskTimeText.compact(timeSpentMs))
                    }
                } else {
                    HStack(spacing: 0) {
                        TaskBoardMetric(label: "FINISHED", value: "\(finishedPomodoros)")
                        Divider()
                            .overlay(PomodoroughTheme.steel.opacity(0.5))
                            .padding(.horizontal, 18)
                        TaskBoardMetric(label: "FOCUS TIME", value: TaskTimeText.compact(timeSpentMs))
                    }
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
                .accessibilityValue(heroAccessibilityValue)
        }
    }

    @ViewBuilder
    private var heroHeading: some View {
        RouteClockMark(compact: true)
        VStack(alignment: .leading, spacing: 2) {
            Text("TASK BOARD")
                .font(.caption.monospaced().bold())
                .tracking(1.4)
                .foregroundStyle(PomodoroughTheme.ticket)
            Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.title3.weight(.bold))
        }
        Spacer(minLength: 0)
    }

    private var heroAccessibilityValue: String {
        "\(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())), " +
            "\(finishedPomodoros) finished pomodoros, \(TaskTimeText.spoken(timeSpentMs)) focus time"
    }
}

#if DEBUG
#Preview {
    TaskBoardHero(finishedPomodoros: 3, timeSpentMs: 75 * 60_000)
        .padding()
}
#endif
