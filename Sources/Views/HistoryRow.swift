import SwiftUI

struct HistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: HistoryItem
    let taskContext: String

    var body: some View {
        rowLayout
            .accessibilityRepresentation {
                Text("\(item.phase.title), \(taskContext), \(item.statusText), \(item.spokenDurationText)")
                    .accessibilityValue(
                        item.date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Time not recorded")
                    )
            }
    }

    /// IOS27-14: at accessibility sizes the phase mark and the minutes pill
    /// share one line above the text, so the text takes the full row width
    /// and neither mark is centred far down a long row.
    @ViewBuilder
    private var rowLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    phaseMark
                    durationPill
                }
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 14) {
                phaseMark
                details
                Spacer()
                durationPill
            }
        }
    }

    private var phaseMark: some View {
        Text(item.phase.abbreviation)
            .font(.caption.monospaced().bold())
            .foregroundStyle(PomodoroughTheme.porcelain)
            .frame(width: 44, height: 44)
            .background(PomodoroughTheme.platform, in: .circle)
            .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.phase.title).font(.headline)
            Text(taskContext)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(item.statusText)
                if let date = item.date { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var durationPill: some View {
        Text(item.durationText.localizedUppercase)
            .font(.caption.monospaced().bold())
            .foregroundStyle(PomodoroughTheme.porcelain)
            .padding(8)
            .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 7))
    }
}

#if DEBUG
#Preview {
    HistoryRow(item: PreviewFixtures.history[0], taskContext: "Preview task")
        .padding()
}
#endif
