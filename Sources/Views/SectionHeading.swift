import SwiftUI

struct SectionHeading: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let kicker: String
    let title: String
    let subtitle: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { headingContent }
            } else {
                HStack(spacing: 12) { headingContent }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var headingContent: some View {
            Text(kicker)
                .font(.caption2.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(PomodoroughTheme.platform, in: .capsule)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
    }
}

#if DEBUG
#Preview {
    SectionHeading(kicker: "ROUTE", title: "Service pattern", subtitle: "Choose a mode and duration")
        .padding()
}
#endif
