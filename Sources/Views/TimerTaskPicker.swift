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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { pickerContent }
                    VStack(alignment: .leading, spacing: 8) { pickerContent }
                }
            }
        }
        .padding(.horizontal, 14)
        .fixedSize(horizontal: false, vertical: true)
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
            Picker("Focus task", selection: $model.selectedTaskID) {
                Text("Unassigned").tag(UUID?.none)
                ForEach(model.tasks) { task in
                    Text(task.title).tag(Optional(task.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(PomodoroughTheme.ticket)
            // The menu label is rendered by the system and ignores
            // lineLimit, so cap its growth like the caption: otherwise
            // the value wraps into a clipped second line.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .lineLimit(1)
            .minimumScaleFactor(wrapsTaskText ? 0.5 : 0.75)
            .allowsTightening(true)
            .fixedSize(horizontal: false, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHint("Applies to the current running focus timer and the next timer.")
    }

    /// At accessibility sizes the menu value stays on one line and shrinks
    /// instead of wrapping into a clipped second line.
    private var wrapsTaskText: Bool { dynamicTypeSize.isAccessibilitySize }
}

#if DEBUG
#Preview {
    TimerTaskPicker(model: AppModel.preview(), layout: .portrait)
        .padding()
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background(PomodoroughTheme.platform)
}
#endif
