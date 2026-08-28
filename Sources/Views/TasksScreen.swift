import SwiftUI

struct TasksScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    @State private var localNewTaskTitle = ""
    @FocusState private var taskFieldFocused: Bool
    private let suppliedNewTaskTitle: Binding<String>?

    init(model: AppModel, newTaskTitle: Binding<String>? = nil) {
        self.model = model
        suppliedNewTaskTitle = newTaskTitle
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                TaskBoardHero(
                    finishedPomodoros: summaries.reduce(0) { $0 + $1.finishedPomodoros },
                    timeSpentMs: summaries.reduce(0) { $0 + $1.timeSpentMs }
                )
                TaskComposer(
                    title: taskTitle,
                    focused: $taskFieldFocused,
                    canAdd: canAddTask,
                    add: addTask
                )
                VStack(spacing: 0) {
                    TaskBoardHeader()
                    if summaries.isEmpty {
                        TaskBoardEmptyState()
                    } else {
                        ForEach(summaries) { summary in
                            Divider().overlay(PomodoroughTheme.steel.opacity(0.45))
                            TaskSummaryRow(summary: summary) {
                                model.deleteTask(id: summary.id)
                            }
                            .contextMenu {
                                Button("Delete task", systemImage: "trash", role: .destructive) {
                                    model.deleteTask(id: summary.id)
                                }
                            }
                        }
                    }
                }
                .background(.background, in: .rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(PomodoroughTheme.steel, lineWidth: 2)
                }
                .clipShape(.rect(cornerRadius: 20))
                .animation(.smooth(duration: 0.3), value: summaries.map(\.id))
            }
            .padding()
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 80 : 0)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(TimerBackdrop())
        .navigationTitle("Tasks")
        .inlineNavigationTitleIfSupported()
        .primaryRouteAccountToolbar(model: model)
    }

    private var summaries: [TaskDailySummary] {
        model.taskSummaries()
    }

    private var taskTitle: Binding<String> {
        suppliedNewTaskTitle ?? $localNewTaskTitle
    }

    private var canAddTask: Bool {
        FocusTask(title: taskTitle.wrappedValue) != nil
    }

    private func addTask() {
        Task {
            if await model.addTask(taskTitle.wrappedValue) {
                taskTitle.wrappedValue = ""
                taskFieldFocused = false
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TasksScreen(model: AppModel.preview(.populated))
    }
}
#endif
