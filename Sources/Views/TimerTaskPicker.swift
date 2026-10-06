import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct TimerTaskPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    let layout: TimerLayout

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    pickerContent
                    Spacer(minLength: Self.pickerReserveHeight(for: dynamicTypeSize))
                }
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

    /// Full Dynamic Type range: the picker wraps at accessibility sizes
    /// instead of shrinking to an unreadable scale. The menu button
    /// reports single-line ideal but renders hyphenated two-line Unassigned
    /// at XXXL on narrow phones, so the reserve below adds one line.
    static func pickerLineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
    }

    /// No sub-0.75 shrink: accessibility sizes stay at full scale,
    /// standard sizes tighten slightly before ViewThatFits stacks.
    static func pickerScaleFactor(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 1.0 : 0.75
    }

    /// Intrinsic-width containment: the stacked accessibility layout
    /// uses leading alignment so the single-line title starts at the
    /// container edge and truncates inside it. The single-row standard
    /// layout keeps trailing alignment.
    static func pickerAlignment(for dynamicTypeSize: DynamicTypeSize) -> Alignment {
        dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
    }

    /// Single-line titles share the stack alignment so truncation stays
    /// inside instead of pushing past the opposite edge.
    static func pickerMultilineAlignment(for dynamicTypeSize: DynamicTypeSize) -> TextAlignment {
        dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
    }

    /// One-line reserve for the hyphenated Unassigned second line at
    /// XXXL on narrow phones. Derived from the menu font for the current
    /// Dynamic Type, not a fixed height, so full scale is preserved.
    /// macOS windows are wide enough that no reserve is needed.
    static func pickerReserveHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        #if os(iOS)
        guard dynamicTypeSize.isAccessibilitySize else { return 0 }
        return menuFont(for: dynamicTypeSize).lineHeight
        #else
        return 0
        #endif
    }

    #if os(iOS)
    /// Menu title font at the current Dynamic Type, from the system
    /// preferred body font so the reserve tracks the rendered size.
    static func menuFont(for dynamicTypeSize: DynamicTypeSize) -> UIFont {
        let category = contentSizeCategory(for: dynamicTypeSize)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    }

    /// DynamicTypeSize to UIContentSizeCategory for font measurement.
    /// Table-driven to keep complexity low; unknown future sizes fall
    /// back to large rather than failing closed on rendering.
    static func contentSizeCategory(for dynamicTypeSize: DynamicTypeSize) -> UIContentSizeCategory {
        Self.sizeCategoryTable[dynamicTypeSize] ?? .large
    }

    private static let sizeCategoryTable: [DynamicTypeSize: UIContentSizeCategory] = [
        .xSmall: .extraSmall,
        .small: .small,
        .medium: .medium,
        .large: .large,
        .xLarge: .extraLarge,
        .xxLarge: .extraExtraLarge,
        .xxxLarge: .extraExtraExtraLarge,
        .accessibility1: .accessibilityMedium,
        .accessibility2: .accessibilityLarge,
        .accessibility3: .accessibilityExtraLarge,
        .accessibility4: .accessibilityExtraExtraLarge,
        .accessibility5: .accessibilityExtraExtraExtraLarge,
    ]
    #endif

    @ViewBuilder
    private var pickerContent: some View {
            Label("FOCUS TASK", systemImage: "checklist")
                .font(.caption.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.sky)
                .labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            pickerControl
    }

    private var pickerControl: some View {
        Picker("Focus task", selection: $model.selectedTaskID) {
            Text("Unassigned").tag(UUID?.none)
            ForEach(model.tasks) { task in
                Text(task.title).tag(Optional(task.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(PomodoroughTheme.ticket)
        .lineLimit(Self.pickerLineLimit(for: dynamicTypeSize))
        .minimumScaleFactor(Self.pickerScaleFactor(for: dynamicTypeSize))
        .allowsTightening(true)
        .multilineTextAlignment(Self.pickerMultilineAlignment(for: dynamicTypeSize))
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: Self.pickerAlignment(for: dynamicTypeSize))
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
