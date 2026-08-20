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
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
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
