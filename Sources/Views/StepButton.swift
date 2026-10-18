import SwiftUI

struct StepButton: View {
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
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .foregroundStyle(PomodoroughTheme.stepperSymbol)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

#if DEBUG
#Preview {
    StepButton(title: "Increase focus duration", symbol: "plus", action: {})
        .padding()
}
#endif
