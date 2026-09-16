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
                GeometryReader { proxy in
                    emptyHistory(topPadding: Self.emptyTopPadding(forHeight: proxy.size.height))
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

    /// Empty-state top offset follows the visible height — 12% of the
    /// container, floored for short landscape and capped for tall iPad —
    /// instead of a fixed 80pt that crowds short screens and strands
    /// tall ones.
    static func emptyTopPadding(forHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 24 }
        return min(max(height * 0.12, 24), 120)
    }

    private func emptyHistory(topPadding: CGFloat) -> some View {
        ScrollView {
            ContentUnavailableView(
                "No arrivals yet",
                systemImage: "clock.badge.questionmark",
                description: Text("Your first run appears here.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, topPadding)
            .accessibilityRepresentation {
                Text("No arrivals yet")
                    .accessibilityValue("Your first run appears here.")
            }
        }
        .refreshable { await model.refreshForPull() }
        .accessibilityAction(named: Text("Refresh arrivals")) {
            Task { await model.refreshForPull() }
        }
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
