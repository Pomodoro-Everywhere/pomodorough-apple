import SwiftUI

#if os(iOS)
import UIKit
#endif

struct TasksScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coreCapabilities) private var coreCapabilities
    @Environment(PendingTaskDeletion.self) private var pendingDeletion
    @State private var localNewTaskTitle = ""
    @State private var today = Date.now
    @State private var renameDraft: TaskRenameDraft?
    @FocusState private var taskFieldFocused: Bool
    private let suppliedNewTaskTitle: Binding<String>?

    init(model: AppModel, newTaskTitle: Binding<String>? = nil) {
        self.model = model
        suppliedNewTaskTitle = newTaskTitle
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    TaskBoardHero(
                        finishedPomodoros: dayTotals.finishedPomodoros,
                        timeSpentMs: dayTotals.timeSpentMs,
                        date: today
                    )
                    TaskComposer(
                        title: taskTitle,
                        focused: $taskFieldFocused,
                        canAdd: canAddTask,
                        add: addTask
                    )
                    taskBoard
                }
                .padding()
                .padding(.bottom, TabBarScrollInset.bottom(
                    safeBottom: proxy.safeAreaInsets.bottom,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ))
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .background(TimerBackdrop())
        .navigationTitle("Tasks")
        .inlineNavigationTitleIfSupported()
        .primaryRouteAccountToolbar(model: model)
        .taskDeletionUndoWindow()
        .taskRenameDialog(draft: $renameDraft, rename: commitRename)
        .modifier(TaskBoardDayRefresh(today: $today))
    }

    private var taskBoard: some View {
        VStack(spacing: 0) {
            TaskBoardHeader()
            if summaries.isEmpty {
                TaskBoardEmptyState()
            } else {
                ForEach(summaries) { summary in
                    Divider().overlay(PomodoroughTheme.steel.opacity(0.45))
                    taskRow(for: summary)
                        .contextMenu {
                            taskRowMenu(for: summary)
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: summaries.map(\.id))
    }

    @ViewBuilder
    private func taskRow(for summary: TaskDailySummary) -> some View {
        let row = TaskSummaryRow(
            summary: summary,
            isFocusTask: model.selectedTaskID == summary.id,
            rename: coreCapabilities.supportsTaskRename ? { beginRename(summary) } : nil,
            delete: { requestDelete(summary) }
        )
#if os(iOS)
        SwipeToDeleteRow(delete: { requestDelete(summary) }) { row }
#else
        row
#endif
    }

    @ViewBuilder
    private func taskRowMenu(for summary: TaskDailySummary) -> some View {
        Button("Set as focus task", systemImage: "checkmark.circle") {
            model.selectedTaskID = summary.id
        }
        .disabled(model.selectedTaskID == summary.id)
        if coreCapabilities.supportsTaskRename {
            Button("Rename task…", systemImage: "pencil") {
                beginRename(summary)
            }
        }
        Button("Delete task", systemImage: "trash", role: .destructive) {
            requestDelete(summary)
        }
    }

    /// Pending deletion leaves the board immediately; the mutation runs when
    /// the undo window ends.
    private var summaries: [TaskDailySummary] {
        let hidden = pendingDeletion.entry?.id
        return model.taskSummaries(for: today).filter { $0.id != hidden }
    }

    private var dayTotals: (finishedPomodoros: Int, timeSpentMs: Int64) {
        model.dayFocusTotals(for: today)
    }

    private func requestDelete(_ summary: TaskDailySummary) {
        model.requestTaskDeletion(id: summary.id, title: summary.task.title)
    }

    private func beginRename(_ summary: TaskDailySummary) {
        renameDraft = TaskRenameDraft(id: summary.id, title: summary.task.title)
    }

    /// A pending deletion is committed first so a rename cannot land on a
    /// task that is about to disappear or collide with its identity.
    private func commitRename(id: UUID, title: String) {
        pendingDeletion.flush()
        Task {
            await model.renameTask(id: id, title: title)
        }
    }

    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    private var taskTitle: Binding<String> {
        suppliedNewTaskTitle ?? $localNewTaskTitle
    }

    private var canAddTask: Bool {
        FocusTask.acceptsDraft(taskTitle.wrappedValue)
    }

    private func addTask() {
        // Re-adding a pending-deleted title must not be undone by its flush.
        pendingDeletion.flush()
        Task {
            if await model.addTask(taskTitle.wrappedValue) {
                taskTitle.wrappedValue = ""
                taskFieldFocused = false
                // Submit always dismisses the keyboard: the render-pass
                // resign above stays transition-gated for the tap race,
                // but an explicit submit carries its own intent.
                resignComposerKeyboard()
            }
        }
    }

#if os(iOS)
    private func resignComposerKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
#else
    private func resignComposerKeyboard() {}
#endif
}

#if DEBUG
#Preview {
    NavigationStack {
        TasksScreen(model: AppModel.preview(.populated))
    }
    .environment(PendingTaskDeletion())
}
#endif
