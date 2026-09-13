import SwiftUI

struct HistoryRow: View {
    let item: HistoryItem
    let taskContext: String

    var body: some View {
        HStack(spacing: 14) {
            Text(item.phase.abbreviation)
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .frame(width: 44, height: 44)
                .background(PomodoroughTheme.platform, in: .circle)
                .accessibilityHidden(true)
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
            Spacer()
            Text(TaskTimeText.shortMinutes(item.minutes).localizedUppercase)
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .padding(8)
                .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 7))
        }
        .accessibilityRepresentation {
            Text("\(item.phase.title), \(taskContext), \(item.statusText), \(item.minutes) minutes")
                .accessibilityValue(
                    item.date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Time not recorded")
                )
        }
    }
}

#if DEBUG
#Preview {
    HistoryRow(item: PreviewFixtures.history[0], taskContext: "Preview task")
        .padding()
}
#endif
