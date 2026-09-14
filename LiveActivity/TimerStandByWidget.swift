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
        let now = Date()
        let current = entry()
        var entries = [TimerWidgetEntry(date: now, snapshot: current.snapshot)]
        // Precompute one entry per minute so the dial ring stays fresh without
        // burning timeline-reload budget; digits tick live via Text(timerInterval:).
        if let timer = current.snapshot.timer, !timer.isPaused, timer.endsAt > now {
            var tick = now.addingTimeInterval(60)
            while tick < timer.endsAt, entries.count < 90 {
                entries.append(TimerWidgetEntry(date: tick, snapshot: current.snapshot))
                tick = tick.addingTimeInterval(60)
            }
            entries.append(TimerWidgetEntry(date: timer.endsAt, snapshot: current.snapshot))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
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

private enum WidgetURLs {
    static let open = URL(string: "pomodorough://timer")!
    static let toggle = URL(string: "pomodorough://timer?toggle=1")!
}

private struct WidgetTimerDisplay {
    let phase: String?
    let taskTitle: String?
    /// Live count-up range while running; nil when paused/complete/idle.
    let countUpInterval: ClosedRange<Date>?
    /// Seconds passed since the phase started. The dial fills with elapsed
    /// time, starting empty, instead of draining the time left.
    let elapsed: TimeInterval
    let duration: TimeInterval
    let progress: Double
    let paused: Bool
    let complete: Bool
    let hasTimer: Bool

    init(timer: TimerActivityAttributes.ContentState?, at date: Date) {
        hasTimer = timer != nil
        phase = timer?.phase
        taskTitle = timer?.taskTitle
        paused = timer?.isPaused ?? false
        complete = timer.map { !$0.isPaused && $0.endsAt <= date } ?? false
        if let timer {
            duration = max(0, timer.endsAt.timeIntervalSince(timer.startedAt))
            if timer.isPaused {
                elapsed = max(0, min(duration, duration - timer.remaining))
            } else if timer.endsAt <= date {
                elapsed = duration
            } else {
                elapsed = max(0, min(duration, date.timeIntervalSince(timer.startedAt)))
            }
            progress = duration > 0 ? elapsed / duration : 0
            countUpInterval = !timer.isPaused && !complete ? timer.startedAt...timer.endsAt : nil
        } else {
            duration = 0
            elapsed = 0
            progress = 0
            countUpInterval = nil
        }
    }

    var title: LocalizedStringKey {
        switch phase {
        case "short_break": "Short break"
        case "long_break": "Long break"
        case "focus": "Focus"
        case nil: "Pomodorough"
        default: "Focus"
        }
    }

    var tint: Color {
        switch phase {
        case "short_break": Color(red: 168 / 255, green: 217 / 255, blue: 203 / 255)
        case "long_break": Color(red: 245 / 255, green: 208 / 255, blue: 91 / 255)
        default: Color(red: 255 / 255, green: 96 / 255, blue: 79 / 255)
        }
    }

    var buttonTitle: LocalizedStringKey {
        if !hasTimer || complete { "Start" }
        else if paused { "Resume" } else { "Pause" }
    }

    var buttonSymbol: String {
        paused || !hasTimer || complete ? "play.fill" : "pause.fill"
    }

    var statusLine: LocalizedStringKey? {
        guard hasTimer else { return nil }
        if complete { return "Complete" }
        if paused { return "Paused" }
        return nil
    }
}

struct TimerStandByWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TimerWidgetSnapshot.kind, provider: TimerWidgetProvider()) { entry in
            TimerWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.06, green: 0.08, blue: 0.11) }
                .widgetURL(WidgetURLs.open)
        }
        .configurationDisplayName("Pomodorough Timer")
        .description("Your current focus or break timer, on your Home Screen or in StandBy.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

private struct TimerWidgetView: View {
    let entry: TimerWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var display: WidgetTimerDisplay {
        WidgetTimerDisplay(timer: entry.snapshot.timer, at: entry.date)
    }

    var body: some View {
        switch family {
        case .systemMedium:
            mediumLayout
        case .systemLarge:
            largeLayout
        case .systemExtraLarge:
            extraLargeLayout
        default:
            smallLayout
        }
    }

    private var smallLayout: some View {
        GeometryReader { geometry in
            let gap = max(6, geometry.size.height * 0.05)
            let diameter = min(geometry.size.width, max(0, geometry.size.height - 44 - gap))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TimerDialView(display: display)
                    .frame(width: diameter, height: diameter)
                Spacer(minLength: gap)
                WidgetToggleButton(display: display, compact: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(display.title))
    }

    private var mediumLayout: some View {
        HStack(spacing: 12) {
            TimerDialView(display: display)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(display.title)
                    .font(.headline)
                    .foregroundStyle(display.tint)
                    .lineLimit(1)
                WidgetStatusLines(display: display)
                Spacer(minLength: 0)
                WidgetToggleButton(display: display, compact: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var largeLayout: some View {
        VStack(spacing: 8) {
            Text(display.title)
                .font(.headline)
                .foregroundStyle(display.tint)
                .lineLimit(1)
            TimerDialView(display: display)
            WidgetStatusLines(display: display, centered: true)
            WidgetToggleButton(display: display, compact: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var extraLargeLayout: some View {
        HStack(spacing: 20) {
            TimerDialView(display: display)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text(display.title)
                    .font(.title2.bold())
                    .foregroundStyle(display.tint)
                    .lineLimit(1)
                WidgetStatusLines(display: display)
                Spacer(minLength: 0)
                WidgetToggleButton(display: display, compact: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TimerDialView: View {
    let display: WidgetTimerDisplay

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: max(4, diameter * 0.07))
                WidgetTickMarks(count: max(1, Int((display.duration / 60).rounded())))
                    .stroke(.white.opacity(0.3), lineWidth: max(1, diameter * 0.008))
                Circle()
                    .trim(from: 0, to: display.progress)
                    .stroke(display.tint, style: StrokeStyle(lineWidth: max(4, diameter * 0.07), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: max(1, diameter * 0.02)) {
                    WidgetCountdown(display: display)
                        .font(.system(size: diameter * 0.24, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(Color(red: 0.97, green: 0.82, blue: 0.34))
                    Text(display.title)
                        .font(.system(size: max(8, diameter * 0.085), weight: .semibold))
                        .foregroundStyle(display.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(max(4, diameter * 0.14))
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
    }
}

/// Minute notches inside the widget ring, mirroring the app dial's
/// TickMarks. All lengths derive from the rect; every fifth notch runs
/// longer. The widget extension cannot see app-target views, hence the copy.
private struct WidgetTickMarks: Shape {
    var count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let diameter = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = diameter * 0.44
        let total = max(1, count)
        for index in 0..<total {
            let angle = Double(index) * .pi * 2 / Double(total) - .pi / 2
            let inner = outer - (index.isMultiple(of: 5) ? diameter * 0.07 : diameter * 0.035)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}

private struct WidgetCountdown: View {
    let display: WidgetTimerDisplay

    var body: some View {
        Group {
            if let interval = display.countUpInterval {
                Text(timerInterval: interval, countsDown: false)
            } else if !display.hasTimer {
                Text("Ready")
            } else {
                Text(Duration.seconds(max(0, Int(display.elapsed.rounded(.down)))).formatted(.time(pattern: display.elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
        }
    }
}

private struct WidgetStatusLines: View {
    let display: WidgetTimerDisplay
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 2) {
            if let status = display.statusLine {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let task = display.taskTitle, !task.isEmpty {
                Text(verbatim: task)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

private struct WidgetToggleButton: View {
    let display: WidgetTimerDisplay
    var compact = false

    var body: some View {
        Link(destination: WidgetURLs.toggle) {
            Label(display.buttonTitle, systemImage: display.buttonSymbol)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity, minHeight: compact ? 30 : 40)
                .background(display.tint, in: Capsule())
        }
        .accessibilityHint("Opens the app and toggles the timer")
    }
}

private func widgetPreviewEntry(
    phase: String = "focus",
    task: String? = "Write the next chapter",
    elapsed: TimeInterval = 300,
    duration: TimeInterval = 1500,
    paused: Bool = false
) -> TimerWidgetEntry {
    let now = Date()
    let remaining = duration - elapsed
    return TimerWidgetEntry(
        date: now,
        snapshot: TimerWidgetSnapshot(timer: TimerActivityAttributes.ContentState(
            phase: phase,
            taskTitle: task,
            startedAt: now.addingTimeInterval(-elapsed),
            endsAt: now.addingTimeInterval(remaining),
            remaining: remaining,
            isPaused: paused
        ))
    )
}

#Preview(as: .systemSmall) {
    TimerStandByWidget()
} timeline: {
    widgetPreviewEntry()
}

#Preview(as: .systemMedium) {
    TimerStandByWidget()
} timeline: {
    widgetPreviewEntry()
    widgetPreviewEntry(phase: "short_break", task: nil, elapsed: 120, duration: 300, paused: true)
}

#Preview(as: .systemLarge) {
    TimerStandByWidget()
} timeline: {
    widgetPreviewEntry()
}

#Preview(as: .systemExtraLarge) {
    TimerStandByWidget()
} timeline: {
    widgetPreviewEntry()
}
