import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct PomodoroughActivityBundle: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
        if #available(iOS 26.0, *) {
            TimerAlarmLiveActivity()
        }
    }
}

private struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            ActivityLockScreen(display: ActivityDisplay(context.state, stale: context.isStale))
        } dynamicIsland: { context in
            timerIsland(ActivityDisplay(context.state, stale: context.isStale))
        }
    }
}

@available(iOS 26.0, *)
private struct TimerAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TimerAlarmMetadata>.self) { context in
            ActivityLockScreen(display: ActivityDisplay(context))
        } dynamicIsland: { context in
            timerIsland(ActivityDisplay(context))
        }
    }
}

private struct ActivityDisplay {
    let phase: String
    let taskTitle: String?
    let interval: ClosedRange<Date>?
    let remaining: TimeInterval
    let progress: Double
    let paused: Bool
    let complete: Bool

    var title: LocalizedStringKey {
        switch phase {
        case "short_break": "Short break"
        case "long_break": "Long break"
        default: "Focus"
        }
    }

    var symbol: String {
        if complete { return "checkmark.circle.fill" }
        if paused { return "pause.circle.fill" }
        return phase == "focus" ? "timer" : "cup.and.saucer.fill"
    }

    var tint: Color {
        phase == "focus" ? Color(red: 1, green: 0.38, blue: 0.31) : Color(red: 0.36, green: 0.8, blue: 0.68)
    }

    init(_ state: TimerActivityAttributes.ContentState, stale: Bool) {
        phase = state.phase
        taskTitle = state.taskTitle
        paused = state.isPaused
        complete = !paused && stale
        interval = paused || complete ? nil : min(state.startedAt, state.endsAt)...state.endsAt
        remaining = complete ? 0 : state.remaining
        let duration = state.endsAt.timeIntervalSince(state.startedAt)
        progress = !complete && duration > 0 ? min(1, max(0, state.remaining / duration)) : 0
    }

    @available(iOS 26.0, *)
    init(_ context: ActivityViewContext<AlarmAttributes<TimerAlarmMetadata>>) {
        phase = context.attributes.metadata?.phase ?? "focus"
        taskTitle = nil
        switch context.state.mode {
        case .countdown(let countdown):
            let start = countdown.startDate.addingTimeInterval(-countdown.previouslyElapsedDuration)
            interval = min(start, countdown.fireDate)...countdown.fireDate
            remaining = max(0, countdown.totalCountdownDuration - countdown.previouslyElapsedDuration)
            progress = 1
            paused = false
            complete = false
        case .paused(let pause):
            interval = nil
            remaining = max(0, pause.totalCountdownDuration - pause.previouslyElapsedDuration)
            progress = pause.totalCountdownDuration > 0 ? remaining / pause.totalCountdownDuration : 0
            paused = true
            complete = false
        case .alert:
            interval = nil
            remaining = 0
            progress = 0
            paused = false
            complete = true
        @unknown default:
            interval = nil
            remaining = 0
            progress = 0
            paused = false
            complete = true
        }
    }
}

private let timerURL = URL(string: "pomodorough://timer")!

@MainActor
private func timerIsland(_ display: ActivityDisplay) -> DynamicIsland {
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            Label(display.title, systemImage: display.symbol)
                .font(.headline)
                .foregroundStyle(display.tint)
                .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
            ActivityCountdown(display: display)
                .font(.title2.bold())
                .frame(maxWidth: 130, alignment: .trailing)
        }
        DynamicIslandExpandedRegion(.bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ActivityStatus(display: display)
                ActivityProgress(display: display)
                Link(destination: timerURL) {
                    Label("Open timer", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .tint(display.tint)
            }
        }
    } compactLeading: {
        Image(systemName: display.symbol)
            .foregroundStyle(display.tint)
            .accessibilityLabel(display.title)
    } compactTrailing: {
        ActivityCountdown(display: display)
            .font(.caption.monospacedDigit())
            .frame(width: display.remaining >= 3600 ? 64 : 48)
    } minimal: {
        Image(systemName: display.symbol)
            .foregroundStyle(display.tint)
            .accessibilityLabel(display.title)
    }
    .widgetURL(timerURL)
    .keylineTint(display.tint)
}

private struct ActivityLockScreen: View {
    let display: ActivityDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pomodorough")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label(display.title, systemImage: display.symbol)
                        .font(.headline)
                        .foregroundStyle(display.tint)
                    ActivityStatus(display: display)
                }
                Spacer(minLength: 0)
                ActivityCountdown(display: display)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            ActivityProgress(display: display)
        }
        .padding(16)
        .activityBackgroundTint(Color(red: 0.08, green: 0.1, blue: 0.11))
        .activitySystemActionForegroundColor(.white)
        .foregroundStyle(.white)
        .widgetURL(timerURL)
    }
}

private struct ActivityCountdown: View {
    let display: ActivityDisplay

    var body: some View {
        Group {
            if let interval = display.interval {
                Text(timerInterval: interval, countsDown: true)
            } else {
                let seconds = max(0, Int(display.remaining.rounded(.up)))
                Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .foregroundStyle(display.tint)
        .accessibilityHint(display.paused ? "Time remaining, paused" : "Time remaining")
    }
}

private struct ActivityStatus: View {
    let display: ActivityDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if display.paused {
                Text("Paused").font(.caption.weight(.semibold))
            } else if display.complete {
                Text("Complete").font(.caption.weight(.semibold))
            }
            if let taskTitle = display.taskTitle, !taskTitle.isEmpty {
                Text(verbatim: taskTitle).font(.caption).lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct ActivityProgress: View {
    let display: ActivityDisplay

    var body: some View {
        Group {
            if let interval = display.interval {
                ProgressView(timerInterval: interval, countsDown: true) {
                    Text("Time remaining")
                } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: display.progress) { Text("Time remaining") }
            }
        }
        .labelsHidden()
        .tint(display.tint)
    }
}

#Preview("Focus", as: .dynamicIsland(.expanded), using: TimerActivityAttributes(timerID: "preview")) {
    TimerLiveActivity()
} contentStates: {
    TimerActivityAttributes.ContentState(phase: "focus", taskTitle: "Write the next chapter", startedAt: .now, endsAt: .now.addingTimeInterval(1500), remaining: 1500, isPaused: false)
    TimerActivityAttributes.ContentState(phase: "short_break", taskTitle: nil, startedAt: .now, endsAt: .now.addingTimeInterval(300), remaining: 180, isPaused: true)
}
