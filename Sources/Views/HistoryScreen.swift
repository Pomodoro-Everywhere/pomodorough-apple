import SwiftUI

struct HistoryScreen: View {
    let model: AppModel
    private let showCompletedFocusBreakdown: (() -> Void)?

    init(
        model: AppModel,
        showCompletedFocusBreakdown: (() -> Void)? = nil
    ) {
        self.model = model
        self.showCompletedFocusBreakdown = showCompletedFocusBreakdown
    }

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
                    completedFocusBreakdownControl
                }
            }
        }
        .primaryRouteAccountToolbar(model: model)
    }

    private var completedFocusBreakdownControl: some View {
        Group {
            if let showCompletedFocusBreakdown {
                Button(action: showCompletedFocusBreakdown) {
                    completedFocusBreakdownLabel
                }
            } else {
                NavigationLink {
                    CompletedFocusBreakdownScreen(model: model)
                } label: {
                    completedFocusBreakdownLabel
                }
            }
        }
        .accessibilityLabel("\(model.history.count) history entries")
        .accessibilityHint("Shows completed focus time by task")
    }

    private var completedFocusBreakdownLabel: some View {
        Text("\(model.history.count) total")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .contentTransition(.numericText())
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HistoryScreen(model: AppModel.preview(.populated))
    }
}
#endif
