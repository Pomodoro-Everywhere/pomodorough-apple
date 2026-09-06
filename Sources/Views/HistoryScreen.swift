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
                ScrollView {
                    ContentUnavailableView(
                        "No arrivals yet",
                        systemImage: "clock.badge.questionmark",
                        description: Text("Your first run appears here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                .refreshable { await model.refreshForPull() }
                .accessibilityRepresentation {
                    Text("No arrivals yet")
                        .accessibilityValue("Your first run appears here.")
                }
                .accessibilityIdentifier("history.empty-scroll")
            } else {
                List {
                    Section {
                        ForEach(model.history) { item in
                            HistoryRow(item: item, taskContext: model.taskContext(for: item))
                        }
                    } header: {
                        Text("\(model.history.count) arrivals")
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.refreshForPull() }
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
        .accessibilityLabel("View focus breakdown")
        .accessibilityValue("\(completedRunCount) completed of \(model.history.count) runs")
        .accessibilityHint("Shows completed focus time by task")
    }

    private var completedRunCount: Int {
        model.history.count { $0.phase == .focus && $0.status == "completed" }
    }

    private var completedFocusBreakdownLabel: some View {
        Text("Completed focus: \(completedRunCount)")
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
