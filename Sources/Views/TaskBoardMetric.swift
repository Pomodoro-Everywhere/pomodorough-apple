import SwiftUI

struct TaskBoardMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.sky)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .black))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

#if DEBUG
#Preview {
    TaskBoardMetric(label: "FOCUS TIME", value: "1h 15m")
        .padding()
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background(PomodoroughTheme.platform)
}
#endif
