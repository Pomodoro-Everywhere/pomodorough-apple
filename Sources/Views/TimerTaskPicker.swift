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

    /// Full Dynamic Type range: the picker wraps to two lines at
    /// accessibility sizes instead of shrinking to an unreadable scale.
    static func pickerLineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
    }

    /// No sub-0.75 shrink: accessibility sizes wrap at full scale,
    /// standard sizes tighten slightly before ViewThatFits stacks.
    static func pickerScaleFactor(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 1.0 : 0.75
    }

    @ViewBuilder
    private var pickerContent: some View {
            Label("FOCUS TASK", systemImage: "checklist")
                .font(.caption.monospaced().bold())
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
            // The menu label is system-rendered: at accessibility sizes it
            // wraps to a second line at full scale inside the scrolling
            // parent instead of clipping; standard sizes stay one line.
            .lineLimit(Self.pickerLineLimit(for: dynamicTypeSize))
            .minimumScaleFactor(Self.pickerScaleFactor(for: dynamicTypeSize))
            .allowsTightening(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHint("Applies to the current running focus timer and the next timer.")
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
