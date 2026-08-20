import SwiftUI

struct HistoryRow: View {
    let item: HistoryItem

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
                HStack {
                    Text(item.status.capitalized)
                    if let date = item.date { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(item.minutes) MIN")
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .padding(8)
                .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 7))
        }
        .accessibilityRepresentation {
            Text("\(item.phase.title), \(item.status), \(item.minutes) minutes")
                .accessibilityValue(
                    item.date?.formatted(date: .abbreviated, time: .shortened) ?? "Time not recorded"
                )
        }
    }
}

#if DEBUG
#Preview {
    HistoryRow(item: PreviewFixtures.history[0])
        .padding()
}
#endif
