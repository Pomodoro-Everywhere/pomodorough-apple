import SwiftUI

struct StepButton: View {
    @Environment(\.isEnabled) private var isEnabled
    /// IOS27-18: clearance around the symbol. The symbol grows with
    /// Dynamic Type; a fixed 44 pt box let it touch the minutes text and
    /// the stepper border at accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var symbolClearance: CGFloat = 4
    let title: String
    let symbol: String
    let action: () -> Void

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        // R50-U02: fill-derived symbol on the pale stepper fill.
        // Vivid signal is 2.53:1 on the light fill; darkened signal
        // keeps Button semantics and the 44x44 target below.
        Button(action: action) {
            // The label owns the target, so the whole box presses. macOS
            // otherwise draws a bezel hugging the glyph, which made the
            // minus button shorter than the plus button.
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .padding(symbolClearance)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(PomodoroughTheme.stepperSymbol)
        // A disabled step must not look pressable; WCAG exempts
        // disabled controls from the contrast minimum.
        .opacity(isEnabled ? 1 : 0.35)
    }
}

#if DEBUG
#Preview {
    StepButton(title: "Increase focus duration", symbol: "plus", action: {})
        .padding()
}
#endif
