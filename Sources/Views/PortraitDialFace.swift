import SwiftUI

struct PortraitDialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String

    var body: some View {
        ZStack {
            Circle().fill(PomodoroughTheme.sky)
            Circle().stroke(PomodoroughTheme.porcelain, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(PomodoroughTheme.danger, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .padding(16)
            TickMarks().stroke(PomodoroughTheme.track, lineWidth: 1)
            VStack(spacing: 7) {
                Text("NOW TIMING")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.steel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(phase.title.uppercased())
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.signal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(timeText)
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.48)
                    .lineLimit(1)
                    .foregroundStyle(PomodoroughTheme.ticket)
                Text(status.uppercased())
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.sky)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .digitalReadoutPanel(cornerRadius: 18)
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(PomodoroughTheme.porcelain.opacity(0.8), lineWidth: 2) }
            .padding(42)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 500)
        .accessibilityRepresentation {
            TimerAccessibilityElement(phase: phase, status: status, timeText: timeText)
        }
    }
}

#if DEBUG
#Preview {
    PortraitDialFace(progress: 0.42, phase: .focus, status: "Running", timeText: "17:00")
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
