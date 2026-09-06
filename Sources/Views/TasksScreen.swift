import SwiftUI

#if os(iOS)
import UIKit
#endif

struct TasksScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localNewTaskTitle = ""
    @State private var today = Date.now
    @State private var pendingDeleteTaskID: UUID?
    @FocusState private var taskFieldFocused: Bool
    private let suppliedNewTaskTitle: Binding<String>?

    init(model: AppModel, newTaskTitle: Binding<String>? = nil) {
        self.model = model
        suppliedNewTaskTitle = newTaskTitle
    }

    // size-exception: single declarative ScrollView composes hero, composer, board card, and day-refresh task/onReceive chain; splitting would duplicate summaries/delete wiring and hide toolbar/navigation/modifier ordering.
    var body: some View {
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
                VStack(spacing: 0) {
                    TaskBoardHeader()
                    if summaries.isEmpty {
                        TaskBoardEmptyState()
                    } else {
                        ForEach(summaries) { summary in
                            Divider().overlay(PomodoroughTheme.steel.opacity(0.45))
                            TaskSummaryRow(summary: summary) {
                                pendingDeleteTaskID = summary.id
                            }
                            .contextMenu {
                                Button("Delete task", systemImage: "trash", role: .destructive) {
                                    pendingDeleteTaskID = summary.id
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
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: summaries.map(\.id))
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
        .alert(
            deleteConfirmationTitle,
            isPresented: deleteConfirmationPresented
        ) {
            Button("Delete task", role: .destructive, action: confirmDelete)
            Button("Cancel", role: .cancel) { pendingDeleteTaskID = nil }
        } message: {
            Text("This removes the task from the board. Completed focus runs stay in history.")
        }
        .task(id: today) {
            let midnight = Self.nextMidnight(after: today)
            let delay = midnight.timeIntervalSinceNow
            guard delay > 0 else {
                today = Date.now
                return
            }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            today = Date.now
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = Date.now
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            today = Date.now
        }
#if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            today = Date.now
        }
#else
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            today = Date.now
        }
#endif
    }

    private var summaries: [TaskDailySummary] {
        model.taskSummaries(for: today)
    }

    private var dayTotals: (finishedPomodoros: Int, timeSpentMs: Int64) {
        model.dayFocusTotals(for: today)
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteTaskID != nil },
            set: { if !$0 { pendingDeleteTaskID = nil } }
        )
    }

    private var deleteConfirmationTitle: String {
        if let id = pendingDeleteTaskID,
           let title = summaries.first(where: { $0.id == id })?.task.title {
            return String(localized: "Delete “\(title)”?")
        }
        return String(localized: "Delete task?")
    }

    private func confirmDelete() {
        guard let id = pendingDeleteTaskID else { return }
        pendingDeleteTaskID = nil
        model.deleteTask(id: id)
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
