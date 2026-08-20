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
                Text(model.task(forTimerID: timer.id)?.title ?? "No task")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(PomodoroughTheme.ticket)
                    .accessibilityLabel("Focus task")
                    .accessibilityValue(model.task(forTimerID: timer.id)?.title ?? "No task")
                    .accessibilityHidden(true)
            } else {
                Picker("Focus task", selection: $model.selectedTaskID) {
                    Text("No task").tag(UUID?.none)
                    ForEach(model.tasks) { task in
                        Text(task.title).tag(Optional(task.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(PomodoroughTheme.ticket)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
    }
}

#if DEBUG
#Preview {
    TimerTaskPicker(model: AppModel.preview(), layout: .portrait)
        .padding()
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background(PomodoroughTheme.platform)
}
#endif
