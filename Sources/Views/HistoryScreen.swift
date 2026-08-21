import SwiftUI

struct HistoryScreen: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No arrivals yet",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Your first run appears here.")
                )
                .accessibilityRepresentation {
                    Text("No arrivals yet")
                        .accessibilityValue("Your first run appears here.")
                }
            } else {
                List(model.history) { item in
                    HistoryRow(item: item, taskContext: model.taskContext(for: item))
                }
                .listStyle(.plain)
                .refreshable { await model.sync(force: true) }
            }
        }
        .navigationTitle("Arrivals")
        .toolbar {
            if !model.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        CompletedFocusBreakdownScreen(model: model)
                    } label: {
                        Text("\(model.history.count) total")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .contentTransition(.numericText())
                    }
                    .accessibilityLabel("\(model.history.count) history entries")
                    .accessibilityHint("Shows completed focus time by task")
                }
            }
        }
        .primaryRouteAccountToolbar(model: model)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HistoryScreen(model: AppModel.preview(.populated))
    }
}
#endif
