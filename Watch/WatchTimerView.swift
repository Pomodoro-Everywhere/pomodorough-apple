import SwiftUI

/// Mirror of the iPhone timer. All state lives on iOS; this view renders the
/// latest snapshot (countdown derived locally from the snapshot anchor) and
/// forwards user intents as commands.
struct WatchTimerView: View {
    @EnvironmentObject private var sync: WatchSyncService
    @State private var now = Date()
    @State private var ticker: Timer?

    var body: some View {
        ScrollView {
            if let snapshot = sync.snapshot {
                syncedView(snapshot)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Open Pomodorough on iPhone to connect")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Pomodorough")
        .onAppear { startTicker(); sync.requestSync() }
        .onDisappear { stopTicker() }
    }

    private func syncedView(_ snapshot: WatchTimerSnapshot) -> some View {
        let phase = WatchPhase(syncRawValue: snapshot.selectedPhase) ?? .focus
        let minutes = Int(snapshot.durationMs(forPhaseRawValue: snapshot.selectedPhase) / 60_000)
        let remaining = snapshot.remaining(at: now)
        return VStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(sync.isReachable ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(sync.isReachable ? "iPhone" : "Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Phase", selection: Binding(
                get: { phase },
                set: { sync.send(.selectPhase($0.syncRawValue)) }
            )) {
                ForEach(WatchPhase.allCases) { item in
                    Text(item.shortLabel).tag(item)
                }
            }
            .labelsHidden()

            Text(formatted(remaining))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()

            Text(activeTitle(snapshot))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Stepper("\(minutes) min", value: Binding(
                get: { minutes },
                set: { sync.send(.setDuration(minutes: $0, forPhaseRawValue: snapshot.selectedPhase)) }
            ), in: 1...180)

            HStack {
                primaryButton(snapshot)
                Button("Done") { sync.send(.finish()) }
                    .disabled(snapshot.status == "idle")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func primaryButton(_ snapshot: WatchTimerSnapshot) -> some View {
        if snapshot.isRunning {
            Button("Pause") { sync.send(.pause()) }.tint(.orange)
        } else if snapshot.isPaused {
            Button("Resume") { sync.send(.resume()) }.tint(.green)
        } else {
            Button("Start") { sync.send(.start()) }.tint(.green)
        }
    }

    private func activeTitle(_ snapshot: WatchTimerSnapshot) -> String {
        let phase = WatchPhase(syncRawValue: snapshot.phase) ?? .focus
        switch snapshot.status {
        case "running": return phase.title
        case "paused": return "\(phase.title) · paused"
        default: return "Ready"
        }
    }

    private func formatted(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func startTicker() {
        stopTicker()
        now = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in now = Date() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

enum WatchPhase: String, CaseIterable, Identifiable {
    case focus
    case shortBreak
    case longBreak

    var id: String { rawValue }

    /// iOS TimerPhase raw values ("focus" | "short_break" | "long_break").
    var syncRawValue: String {
        switch self {
        case .focus: "focus"
        case .shortBreak: "short_break"
        case .longBreak: "long_break"
        }
    }

    init?(syncRawValue: String) {
        switch syncRawValue {
        case "focus": self = .focus
        case "short_break": self = .shortBreak
        case "long_break": self = .longBreak
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    var shortLabel: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short"
        case .longBreak: "Long"
        }
    }
}
