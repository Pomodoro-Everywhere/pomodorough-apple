import Foundation
import SwiftUI

struct TimerTaskPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    let layout: TimerLayout

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { pickerContent }
            } else {
                HStack(spacing: 12) { pickerContent }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: layout == .landscape ? 40 : 48)
        .background(PomodoroughTheme.track.opacity(0.58), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var pickerContent: some View {
            Label("FOCUS TASK", systemImage: "checklist")
                .font(.caption.monospaced().bold())
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(PomodoroughTheme.sky)
                .labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            if model.isTimerActive, let timer = model.canonicalTimer {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active timer task")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PomodoroughTheme.steel)
                    Text(model.task(forTimerID: timer.id)?.title ?? "Unassigned")
                        .font(.callout.weight(.semibold))
                }
                    .font(.callout.weight(.semibold))
                    .lineLimit(wrappingLineLimit)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: wrapsTaskText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(PomodoroughTheme.ticket)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Active timer task")
                    .accessibilityValue(model.task(forTimerID: timer.id)?.title ?? "Unassigned")
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Next focus task")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PomodoroughTheme.steel)
                        .accessibilityHidden(true)
                    Picker("Next focus task", selection: $model.selectedTaskID) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(model.tasks) { task in
                            Text(task.title).tag(Optional(task.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(PomodoroughTheme.ticket)
                    .lineLimit(wrappingLineLimit)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: wrapsTaskText)
                    .accessibilityHint("Applies to the next focus timer and does not reassign the active timer.")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Picker("Focus task", selection: $model.selectedTaskID) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(model.tasks) { task in
                        Text(task.title).tag(Optional(task.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(PomodoroughTheme.ticket)
                .lineLimit(wrappingLineLimit)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: wrapsTaskText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
    }

    /// At accessibility sizes the menu label wraps instead of clipping.
    private var wrapsTaskText: Bool { dynamicTypeSize.isAccessibilitySize }

    private var wrappingLineLimit: Int { wrapsTaskText ? 3 : 1 }
}

#if DEBUG
#Preview {
    TimerTaskPicker(model: AppModel.preview(), layout: .portrait)
        .padding()
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background(PomodoroughTheme.platform)
}
#endif
