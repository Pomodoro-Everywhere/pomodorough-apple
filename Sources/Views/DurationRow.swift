import SwiftUI

struct DurationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var indicatorWidth: CGFloat = 5
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 54
    @ScaledMetric(relativeTo: .body) private var minutesMinWidth: CGFloat = 66

    let phase: TimerPhase
    let minutes: Int
    let selected: Bool
    let disabled: Bool
    let select: () -> Void
    let changeMinutes: (Int) -> Void

    /// Accessibility sizes stack unconditionally; large standard sizes
    /// stack only when the side-by-side row no longer fits, via the
    /// ViewThatFits fallback in durationControls.
    static func shouldStackDurations(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        Group {
            if Self.shouldStackDurations(for: dynamicTypeSize) {
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
    }

    private var phaseButton: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(selected ? PomodoroughTheme.signal : PomodoroughTheme.steel)
                    .frame(width: indicatorWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.routeLabel.localizedUppercase)
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(selected ? PomodoroughTheme.ticket : .secondary)
                    Text(phase.title).font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: rowMinHeight)
            .foregroundStyle(selected ? PomodoroughTheme.porcelain : Color.primary)
            .background(selected ? PomodoroughTheme.platform : .clear, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(phase.title)
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(
            disabled
                ? String(localized: "Stop the current timer to change this setting.")
                : String(localized: "Double tap to select this phase.")
        )
    }

    private var durationControls: some View {
        // One row where it fits; wraps the minutes label above the
        // stepper when large standard text overflows the row instead
        // of clipping or squeezing the phase button.
        ViewThatFits(in: .horizontal) {
            stepperRow
            VStack(spacing: 4) {
                minutesLabel
                HStack(spacing: 0) {
                    StepButton(title: "Reduce \(phase.title) duration", symbol: "minus") { changeMinutes(minutes - 1) }
                    StepButton(title: "Increase \(phase.title) duration", symbol: "plus") { changeMinutes(minutes + 1) }
                }
            }
        }
        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(PomodoroughTheme.steel, lineWidth: 1.5) }
        .disabled(disabled)
    }

    private var stepperRow: some View {
        HStack(spacing: 0) {
            StepButton(title: "Reduce \(phase.title) duration", symbol: "minus") { changeMinutes(minutes - 1) }
            minutesLabel
            StepButton(title: "Increase \(phase.title) duration", symbol: "plus") { changeMinutes(minutes + 1) }
        }
    }

    private var minutesLabel: some View {
        Text(TaskTimeText.shortMinutes(minutes))
            .font(.callout.monospaced().bold())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(minWidth: minutesMinWidth)
            .accessibilityLabel("\(phase.title) duration")
            .accessibilityValue("\(minutes) minutes")
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
