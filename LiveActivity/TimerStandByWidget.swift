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
    static let finish = URL(string: "pomodorough://timer?action=finish")!
    static let cancel = URL(string: "pomodorough://timer?action=cancel")!
    static let skip = URL(string: "pomodorough://timer?action=skip")!
}

private struct WidgetTimerDisplay {
    let phase: String?
    let taskTitle: String?
    /// Live countdown range while running; nil when paused/complete/idle.
    let countdownInterval: ClosedRange<Date>?
    /// Seconds left in the phase. The dial fills with elapsed time,
    /// starting empty, while the digits count down to zero.
    let remaining: TimeInterval
    let duration: TimeInterval
    /// Elapsed fraction (0 = just started, 1 = done).
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
                remaining = max(0, min(duration, timer.remaining))
            } else if timer.endsAt <= date {
                remaining = 0
            } else {
                remaining = max(0, min(duration, timer.endsAt.timeIntervalSince(date)))
            }
            progress = duration > 0 ? 1 - remaining / duration : 0
            countdownInterval = !timer.isPaused && !complete ? timer.startedAt...timer.endsAt : nil
        } else {
            duration = 0
            remaining = 0
            progress = 0
            countdownInterval = nil
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
        .supportedFamilies(TimerStandByWidget.families)
    }

    /// `.systemExtraLargePortrait` is unavailable in iOS in the current
    /// SDK, so only the four classic families ship. `portraitLayout`
    /// below is kept for a future SDK that vends the tall portrait family.
    static var families: [WidgetFamily] {
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    }
}

private struct TimerWidgetView: View {
    let entry: TimerWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var display: WidgetTimerDisplay {
        WidgetTimerDisplay(timer: entry.snapshot.timer, at: entry.date)
    }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumLayout
            case .systemLarge:
                // Same full-tile circular dial as the 2x2 small widget.
                smallLayout
            case .systemExtraLarge:
                extraLargeLayout
            default:
                smallLayout
            }
        }
    }

    private var smallLayout: some View {
        GeometryReader { geometry in
            // The dial takes the full widget height; the toggle is a
            // small circular icon button overlapping the bottom corner.
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .bottomTrailing) {
                TimerDialView(display: display)
                    .frame(width: diameter, height: diameter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Link(destination: WidgetURLs.toggle) {
                    Image(systemName: display.buttonSymbol)
                        .font(.system(size: diameter * 0.11, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: diameter * 0.26, height: diameter * 0.26)
                        .background(display.tint, in: Circle())
                }
                .accessibilityLabel(Text(display.buttonTitle))
                .accessibilityHint("Opens the app and toggles the timer")
                .padding(max(2, diameter * 0.02))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(display.title))
    }

    private var mediumLayout: some View {
        GeometryReader { geometry in
            // Compact dial: big digits with the progress stroke running
            // around a rounded-rectangle perimeter; toggle is a small
            // circular icon button in the corner, like the small widget.
            let height = geometry.size.height
            ZStack(alignment: .bottomTrailing) {
                WidgetCompactDial(display: display)
                Link(destination: WidgetURLs.toggle) {
                    Image(systemName: display.buttonSymbol)
                        .font(.system(size: height * 0.13, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: height * 0.3, height: height * 0.3)
                        .background(display.tint, in: Circle())
                }
                .accessibilityLabel(Text(display.buttonTitle))
                .accessibilityHint("Opens the app and toggles the timer")
                .padding(max(2, height * 0.06))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(display.title))
    }

    private var extraLargeLayout: some View {
        VStack {
            TimerDialView(display: display)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WidgetStatusLines(display: display, centered: true)
            WidgetToggleButton(display: display, compact: false)
            HStack(spacing: 8) {
                WidgetSecondaryButton(title: "Finish", symbol: "checkmark", url: WidgetURLs.finish)
                WidgetSecondaryButton(title: "Cancel", symbol: "xmark", url: WidgetURLs.cancel)
                WidgetSecondaryButton(title: "Skip", symbol: "forward.fill", url: WidgetURLs.skip)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tall 4x6 portrait tile: full circular dial up top taking
    /// all leftover height, status lines plus full-width toggle below.
    /// Unused until an iOS SDK vends the tall portrait family.
    private var portraitLayout: some View {
        VStack {
            TimerDialView(display: display)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WidgetStatusLines(display: display, centered: true)
            WidgetToggleButton(display: display, compact: false)
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
                    if let task = display.taskTitle, !task.isEmpty {
                        Text(verbatim: task)
                            .font(.system(size: max(7, diameter * 0.07), weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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

/// Walks a rounded-rectangle perimeter clockwise starting at top-center.
/// Returns the point and inward normal at fraction `t` in 0..<1.
private func roundedRectPoint(at t: CGFloat, width w: CGFloat, height h: CGFloat, radius r: CGFloat) -> (point: CGPoint, normal: CGVector) {
    let a = max(0, w / 2 - r) // top-edge half
    let c = max(0, h - 2 * r) // vertical edge
    let d = max(0, w - 2 * r) // bottom edge
    let b = CGFloat.pi * r / 2 // quarter arc
    let total = max(1, 2 * a + 2 * c + d + 4 * b)
    var dist = (t.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * total
    // Top edge, top-center to top-right corner.
    if dist < a { return (CGPoint(x: w / 2 + dist, y: 0), CGVector(dx: 0, dy: 1)) }
    dist -= a
    let corners: [(center: CGPoint, start: CGFloat)] = [
        (CGPoint(x: w - r, y: r), -.pi / 2), // top-right
        (CGPoint(x: w - r, y: h - r), 0), // bottom-right
        (CGPoint(x: r, y: h - r), .pi / 2), // bottom-left
        (CGPoint(x: r, y: r), .pi), // top-left
    ]
    // Top-right corner, then right edge.
    if dist < b {
        let ang = corners[0].start + dist / max(1, r)
        return (CGPoint(x: corners[0].center.x + cos(ang) * r, y: corners[0].center.y + sin(ang) * r), CGVector(dx: -cos(ang), dy: -sin(ang)))
    }
    dist -= b
    if dist < c { return (CGPoint(x: w, y: r + dist), CGVector(dx: -1, dy: 0)) }
    dist -= c
    // Bottom-right corner, then bottom edge right-to-left.
    if dist < b {
        let ang = corners[1].start + dist / max(1, r)
        return (CGPoint(x: corners[1].center.x + cos(ang) * r, y: corners[1].center.y + sin(ang) * r), CGVector(dx: -cos(ang), dy: -sin(ang)))
    }
    dist -= b
    if dist < d { return (CGPoint(x: w - r - dist, y: h), CGVector(dx: 0, dy: -1)) }
    dist -= d
    // Bottom-left corner, then left edge bottom-up.
    if dist < b {
        let ang = corners[2].start + dist / max(1, r)
        return (CGPoint(x: corners[2].center.x + cos(ang) * r, y: corners[2].center.y + sin(ang) * r), CGVector(dx: -cos(ang), dy: -sin(ang)))
    }
    dist -= b
    if dist < c { return (CGPoint(x: 0, y: h - r - dist), CGVector(dx: 1, dy: 0)) }
    dist -= c
    // Top-left corner, then top edge back to top-center.
    if dist < b {
        let ang = corners[3].start + dist / max(1, r)
        return (CGPoint(x: corners[3].center.x + cos(ang) * r, y: corners[3].center.y + sin(ang) * r), CGVector(dx: -cos(ang), dy: -sin(ang)))
    }
    dist -= b
    // Top edge back to top-center: from (r, 0) to (w / 2, 0).
    return (CGPoint(x: r + min(dist, a), y: 0), CGVector(dx: 0, dy: 1))
}

/// Progress stroke around a rounded rectangle starting at top-center and
/// running clockwise. All sizes derive from the rect.
private struct WidgetTopStartProgress: Shape {
    var cornerRadius: CGFloat
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let p = max(0, min(1, fraction))
        guard p > 0 else { return path }
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let steps = max(8, Int(p * 120))
        let start = roundedRectPoint(at: 0, width: rect.width, height: rect.height, radius: r)
        path.move(to: start.point)
        for i in 1...steps {
            path.addLine(to: roundedRectPoint(at: p * CGFloat(i) / CGFloat(steps), width: rect.width, height: rect.height, radius: r).point)
        }
        return path
    }
}

/// Minute notches around a rounded-rectangle perimeter, mirroring the
/// circular WidgetTickMarks. Every fifth notch runs longer.
private struct WidgetRoundedRectTicks: Shape {
    var cornerRadius: CGFloat
    var count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let total = max(1, count)
        let len = min(rect.width, rect.height)
        for index in 0..<total {
            let (point, normal) = roundedRectPoint(at: CGFloat(index) / CGFloat(total), width: rect.width, height: rect.height, radius: r)
            let inner = index.isMultiple(of: 5) ? len * 0.07 : len * 0.035
            path.move(to: point)
            path.addLine(to: CGPoint(x: point.x + normal.dx * inner, y: point.y + normal.dy * inner))
        }
        return path
    }
}

/// Compact dial for the medium widget: big countdown digits with the
/// elapsed progress stroke running around a rounded-rectangle perimeter.
/// All sizes derive from the rect.
private struct WidgetCompactDial: View {
    let display: WidgetTimerDisplay

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let line = max(4, min(geometry.size.width, height) * 0.09)
            let radius = min(height * 0.3, geometry.size.width / 2, height / 2)
            ZStack {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(.white.opacity(0.12), lineWidth: line)
                WidgetRoundedRectTicks(
                    cornerRadius: radius,
                    count: max(1, Int((display.duration / 60).rounded()))
                )
                .stroke(.white.opacity(0.3), lineWidth: max(1, line * 0.18))
                WidgetTopStartProgress(cornerRadius: radius, fraction: display.progress)
                    .stroke(display.tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                VStack(spacing: max(1, height * 0.03)) {
                    WidgetCountdown(display: display)
                        .font(.system(size: height * 0.38, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(Color(red: 0.97, green: 0.82, blue: 0.34))
                    Text(display.title)
                        .font(.system(size: max(8, height * 0.13), weight: .semibold))
                        .foregroundStyle(display.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let task = display.taskTitle, !task.isEmpty {
                        Text(verbatim: task)
                            .font(.system(size: max(7, height * 0.1), weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(height * 0.16)
            }
            .padding(line / 2)
        }
        .accessibilityHidden(true)
    }
}

private struct WidgetCountdown: View {
    let display: WidgetTimerDisplay

    var body: some View {
        Group {
            if let interval = display.countdownInterval {
                Text(timerInterval: interval)
            } else if !display.hasTimer {
                Text("Ready")
            } else {
                Text(Duration.seconds(max(0, Int(display.remaining.rounded(.up)))).formatted(.time(pattern: display.remaining >= 3600 ? .hourMinuteSecond : .minuteSecond)))
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
                    .foregroundStyle(.white.opacity(0.8))
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

/// Secondary timer actions for the roomy tiles. Each opens the app, which
/// performs the action on arrival; extensions cannot drive the timer engine.
private struct WidgetSecondaryButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(.white.opacity(0.15), in: Capsule())
        }
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
