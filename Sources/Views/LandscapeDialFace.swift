import SwiftUI

struct LandscapeDialFace: View {
    let progress: Double
    let phase: TimerPhase
    let status: String
    let timeText: String

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 2) {
                HStack {
                    Text(phase.routeLabel.uppercased())
                    Text(phase.title.uppercased())
                        .foregroundStyle(PomodoroughTheme.signal)
                    Spacer()
                    Text(status.uppercased())
                        .foregroundStyle(PomodoroughTheme.sky)
                }
                .font(.caption.monospaced().bold())
                .tracking(1.5)

                Text(timeText)
                    .font(.system(
                        size: min(156, max(72, geometry.size.height * 0.5)),
                        weight: .black,
                        design: .rounded
                    ))
                    .monospacedDigit()
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .foregroundStyle(PomodoroughTheme.ticket)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ProgressView(value: max(0, min(1, progress)))
                    .progressViewStyle(.linear)
                    .tint(PomodoroughTheme.signal)
                    .background(PomodoroughTheme.porcelain.opacity(0.18), in: .capsule)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .digitalReadoutPanel(cornerRadius: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(PomodoroughTheme.porcelain.opacity(0.55), lineWidth: 1.5)
        }
        .accessibilityRepresentation {
            TimerAccessibilityElement(phase: phase, status: status, timeText: timeText)
        }
    }
}

#if DEBUG
#Preview {
    LandscapeDialFace(progress: 0.42, phase: .focus, status: "Running", timeText: "17:00")
        .frame(width: 700, height: 300)
        .padding()
        .background(PomodoroughTheme.platform)
}
#endif
