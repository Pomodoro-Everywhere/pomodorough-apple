import SwiftUI

struct DurationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let phase: TimerPhase
    let minutes: Int
    let selected: Bool
    let disabled: Bool
    let select: () -> Void
    let changeMinutes: (Int) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    phaseButton
                    durationControls.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 10) {
                    phaseButton
                    durationControls
                }
            }
        }
        .disabled(disabled)
        .accessibilityRepresentation {
            Button(phase.title) {
                guard !disabled else { return }
                select()
            }
            .disabled(disabled)
            .accessibilityValue("\(minutes) minutes")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(
                disabled
                    ? "Stop the current timer to change this setting."
                    : "Double tap to select. Swipe up or down to change duration."
            )
            .accessibilityAdjustableAction { direction in
                guard !disabled else { return }
                switch direction {
                case .increment:
                    changeMinutes(minutes + 1)
                case .decrement:
                    changeMinutes(minutes - 1)
                @unknown default:
                    break
                }
            }
        }
    }

    private var phaseButton: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(selected ? PomodoroughTheme.signal : PomodoroughTheme.steel)
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.routeLabel.uppercased())
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(selected ? PomodoroughTheme.ticket : .secondary)
                    Text(phase.title).font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 54)
            .foregroundStyle(selected ? PomodoroughTheme.porcelain : Color.primary)
            .background(selected ? PomodoroughTheme.platform : .clear, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var durationControls: some View {
        HStack(spacing: 0) {
            StepButton(title: "Reduce \(phase.title) duration", symbol: "minus") { changeMinutes(minutes - 1) }
            Text("\(minutes) min")
                .font(.callout.monospaced().bold())
                .frame(minWidth: 66)
                .accessibilityLabel("\(phase.title) duration")
                .accessibilityValue("\(minutes) minutes")
            StepButton(title: "Increase \(phase.title) duration", symbol: "plus") { changeMinutes(minutes + 1) }
        }
        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(PomodoroughTheme.steel, lineWidth: 1.5) }
        .disabled(disabled)
    }
}

#if DEBUG
#Preview {
    DurationRow(
        phase: .focus,
        minutes: 25,
        selected: true,
        disabled: false,
        select: {},
        changeMinutes: { _ in }
    )
    .padding()
}
#endif
