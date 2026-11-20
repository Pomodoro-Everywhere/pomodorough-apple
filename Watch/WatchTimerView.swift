import SwiftUI

/// The phone owns timer transitions; the watch only displays and controls them.
struct WatchTimerView: View {
    @EnvironmentObject private var sync: WatchSyncService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmingFinish = false

    private let timerYellow = Color(red: 245 / 255, green: 208 / 255, blue: 91 / 255)

    var body: some View {
        Group {
            if let snapshot = sync.snapshot {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibleTimer(snapshot)
                } else {
                    VStack(spacing: 4) {
                        if !sync.isReachable { WatchConnectionNotice() }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            dial(snapshot, at: context.date)
                        }
                        controls(snapshot)
                    }
                }
            } else {
                phoneUnavailable
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onAppear { sync.requestSync() }
        .alert("Timer control", isPresented: Binding(
            get: { sync.commandError != nil },
            set: { if !$0 { sync.commandError = nil } }
        )) {
            Button("OK") { sync.commandError = nil }
        } message: {
            Text(sync.commandError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sync.requestSync() }
        }
    }

    /// Scrolls, so the button can always be reached: at the largest text
    /// sizes the text and buttons can be taller than the screen.
    private var phoneUnavailable: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(timerYellow)
                    .accessibilityHidden(true)
                WatchPhoneUnavailableMessage()
                Button("Try again") { sync.requestSync() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    /// WCH-02: at accessibility sizes the dial and the controls scroll. The
    /// dial is a square as wide as the screen, and the controls stack, so
    /// no label shares its line with another control.
    private func accessibleTimer(_ snapshot: WatchTimerSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                if !sync.isReachable { WatchConnectionNotice() }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    dial(snapshot, at: context.date)
                }
                .aspectRatio(1, contentMode: .fit)
                controls(snapshot)
            }
        }
    }

    private func dial(_ snapshot: WatchTimerSnapshot, at date: Date) -> some View {
        let remaining = snapshot.remaining(at: date)
        let duration = Double(snapshot.plannedDurationMs) / 1_000
        let progress = duration > 0 ? min(1, max(0, 1 - remaining / duration)) : 0
        let phase = snapshot.status == "idle" ? snapshot.selectedPhase : snapshot.phase
        let phaseTitle = switch phase {
        case "short_break": "Short break"
        case "long_break": "Long break"
        default: "Focus"
        }
        let status = snapshot.isPaused ? "Paused" : snapshot.isRunning ? "" : "Ready"

        return GeometryReader { geometry in
            let layout = WatchDialLayout(available: geometry.size)
            ZStack {
                ring(progress: progress)
                VStack(spacing: 0) {
                    dialCaption(phaseTitle, font: .caption.weight(.medium), in: layout.caption)
                    Text(formatted(remaining))
                        // The ring bounds the digits at every text size, so
                        // their size comes from the ring, not from Dynamic
                        // Type. Long countdowns shrink to stay whole.
                        .font(.system(size: layout.countdown.height, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timerYellow)
                        // WCH-03: an unreachable phone dims the cached countdown.
                        .opacity(sync.isReachable ? 1 : 0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.2)
                        .frame(width: layout.countdown.width, height: layout.countdown.height)
                    dialCaption(status, font: .caption2, in: layout.caption)
                }
            }
            .frame(width: layout.diameter, height: layout.diameter)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phaseTitle), \(status.isEmpty ? "Running" : status)")
        .accessibilityValue("\(formatted(remaining)) remaining")
    }

    /// Both strokes sit inside the dial's frame, so WatchDialLayout's inner
    /// diameter is the space the text may use.
    private func ring(progress: Double) -> some View {
        ZStack {
            Circle()
                .inset(by: WatchDialLayout.ringLineWidth / 2)
                .stroke(timerYellow.opacity(0.12), lineWidth: 4)
            Circle()
                .inset(by: WatchDialLayout.ringLineWidth / 2)
                .trim(from: 0, to: progress)
                .stroke(Color(red: 0.88, green: 0.29, blue: 0.24).opacity(0.8),
                        style: StrokeStyle(lineWidth: WatchDialLayout.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private func dialCaption(_ text: String, font: Font, in size: CGSize) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func controls(_ snapshot: WatchTimerSnapshot) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button {
                if snapshot.isRunning {
                    sync.send(.pause(timerId: snapshot.timerId))
                } else if snapshot.isPaused {
                    sync.send(.resume(timerId: snapshot.timerId))
                } else {
                    sync.send(.start())
                }
            } label: {
                Label(snapshot.isRunning ? "Pause" : snapshot.isPaused ? "Resume" : "Start",
                      systemImage: snapshot.isRunning ? "pause.fill" : "play.fill")
                    .font(.callout.weight(.semibold))
                    // One word per label: shrink it rather than break it.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WatchControlButtonStyle(shape: Capsule(), fill: timerYellow.opacity(0.15)))
            .foregroundStyle(timerYellow)

            if snapshot.isRunning || snapshot.isPaused {
                Button("Finish timer", systemImage: "checkmark") {
                    confirmingFinish = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(WatchControlButtonStyle(shape: Circle(), fill: .white.opacity(0.12)))
                .confirmationDialog("Finish this timer?", isPresented: $confirmingFinish, titleVisibility: .visible) {
                    Button("Finish timer") { sync.send(.finish(timerId: snapshot.timerId)) }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(.horizontal, 4)
        .opacity(isLuminanceReduced ? 0 : 1)
        .allowsHitTesting(!isLuminanceReduced)
        .accessibilityHidden(isLuminanceReduced)
    }

    private func formatted(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
