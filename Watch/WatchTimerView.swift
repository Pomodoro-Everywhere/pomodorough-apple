import SwiftUI

/// The phone owns timer transitions; the watch only displays and controls them.
struct WatchTimerView: View {
    @EnvironmentObject private var sync: WatchSyncService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var confirmingFinish = false
    @ScaledMetric(relativeTo: .body) private var countdownSize: CGFloat = 58

    private let timerYellow = Color(red: 245 / 255, green: 208 / 255, blue: 91 / 255)

    var body: some View {
        Group {
            if let snapshot = sync.snapshot {
                VStack(spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        dial(snapshot, at: context.date)
                    }
                    controls(snapshot)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.title2)
                        .foregroundStyle(timerYellow)
                    Text("Open Pomodorough on iPhone")
                        .font(.headline)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                    Button("Try again") { sync.requestSync() }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(sync.isReachable ? Color.green : Color.gray)
                .frame(width: 5, height: 5)
                .padding(.leading, 10)
                .padding(.top, 4)
                .accessibilityLabel(sync.isReachable ? "iPhone connected" : "iPhone unreachable, showing last synced timer")
        }
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
            ZStack {
                Circle()
                    .stroke(timerYellow.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color(red: 0.88, green: 0.29, blue: 0.24).opacity(0.8),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 3) {
                    Text(phaseTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(formatted(remaining))
                        .font(.system(size: countdownSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timerYellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .layoutPriority(1)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            .padding(6)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phaseTitle), \(status.isEmpty ? "Running" : status)")
        .accessibilityValue("\(formatted(remaining)) remaining")
    }

    private func controls(_ snapshot: WatchTimerSnapshot) -> some View {
        HStack(spacing: 10) {
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
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(timerYellow)
            .background(timerYellow.opacity(0.15), in: Capsule())

            if snapshot.isRunning || snapshot.isPaused {
                Button("Finish timer", systemImage: "checkmark") {
                    confirmingFinish = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
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
