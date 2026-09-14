import SwiftUI
import WidgetKit
import OSLog

struct TimerWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TimerWidgetSnapshot
}

struct TimerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimerWidgetEntry {
        TimerWidgetEntry(date: .now, snapshot: TimerWidgetSnapshot(timer: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (TimerWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimerWidgetEntry>) -> Void) {
        let current = entry()
        var entries = [current]
        if let timer = current.snapshot.timer, !timer.isPaused, timer.endsAt > current.date {
            entries.append(TimerWidgetEntry(date: timer.endsAt, snapshot: current.snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entry() -> TimerWidgetEntry {
        var snapshot = TimerWidgetSnapshot(timer: nil)
        if let data = UserDefaults(suiteName: TimerWidgetSnapshot.appGroup)?.data(forKey: TimerWidgetSnapshot.storageKey) {
            do {
                snapshot = try JSONDecoder().decode(TimerWidgetSnapshot.self, from: data)
            } catch {
                Logger(subsystem: "me.egigoka.pomodorough", category: "Widget").error("Invalid timer snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
        return TimerWidgetEntry(date: .now, snapshot: snapshot)
    }
}

struct TimerStandByWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TimerWidgetSnapshot.kind, provider: TimerWidgetProvider()) { entry in
            TimerWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.06, green: 0.08, blue: 0.11) }
                .widgetURL(URL(string: "pomodorough://timer"))
        }
        .configurationDisplayName("Pomodorough Timer")
        .description("Your current focus or break timer, on your Home Screen or in StandBy.")
        .supportedFamilies([.systemSmall])
    }
}

private struct TimerWidgetView: View {
    let entry: TimerWidgetEntry

    var body: some View {
        VStack {
            Text(title).font(.headline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            countdown.font(.largeTitle.bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.4)
                .foregroundStyle(Color(red: 0.97, green: 0.82, blue: 0.34))
            Spacer(minLength: 0)
            Text(status).font(.caption.weight(.semibold))
            if let task = entry.snapshot.timer?.taskTitle {
                Text(verbatim: task).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch entry.snapshot.timer?.phase {
        case "focus": "Focus"
        case "short_break": "Short break"
        case "long_break": "Long break"
        default: "Pomodorough"
        }
    }

    private var status: LocalizedStringKey {
        guard let timer = entry.snapshot.timer else { return "Open to start" }
        if entry.snapshot.isComplete(at: entry.date) { return "Complete" }
        return timer.isPaused ? "Paused" : "Running"
    }

    private var countdown: Text {
        guard let timer = entry.snapshot.timer else { return Text("Ready") }
        if entry.snapshot.isComplete(at: entry.date) { return Text("0:00") }
        if timer.isPaused {
            let seconds = max(0, Int(timer.remaining.rounded(.up)))
            return Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        return Text(timerInterval: min(timer.startedAt, timer.endsAt)...timer.endsAt, countsDown: true)
    }
}
