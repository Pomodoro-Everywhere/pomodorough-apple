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

    /// Full Dynamic Type range: the menu title wraps at accessibility
    /// sizes instead of shrinking to an unreadable scale. The native
    /// menu Picker reports single-line ideal but renders hyphenated
    /// two-line Unassigned at XXXL, so the title below carries its own
    /// two-line floor inside the control (R48-AP09).
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

    /// Two-line floor for the rendered menu title at accessibility
    /// sizes. Derived from the menu font for the current Dynamic Type,
    /// not a fixed height, so full scale is preserved. The floor lives
    /// inside the menu label: the old outside-stack reserve left room
    /// in the card while the native control still clipped its second
    /// line. macOS windows are wide enough that no floor is needed.
    static func pickerTitleMinHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        #if os(iOS)
        guard dynamicTypeSize.isAccessibilitySize else { return 0 }
        return menuFont(for: dynamicTypeSize).lineHeight * 2
        #else
        return 0
        #endif
    }

    /// Displayed menu title for a selection. Unassigned covers nil and
    /// stale identifiers so the control never renders a blank title.
    /// Long titles pass through verbatim; wrapping is handled by the
    /// multiline label, never by truncation in the model. Pure and
    /// nonisolated so background unit probes never trip MainActor.
    nonisolated static func menuTitle(selectedID: UUID?, tasks: [FocusTask]) -> String {
        guard let selectedID else { return "Unassigned" }
        return tasks.first(where: { $0.id == selectedID })?.title ?? "Unassigned"
    }

    #if os(iOS)
    /// Menu title font at the current Dynamic Type, from the system
    /// preferred body font so the floor tracks the rendered size.
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
            pickerMenu
    }

    private var selectedTitle: String {
        Self.menuTitle(selectedID: model.selectedTaskID, tasks: model.tasks)
    }

    private var pickerMenu: some View {
        Menu {
            menuOptions
        } label: {
            menuLabel
        }
        .tint(PomodoroughTheme.ticket)
        .accessibilityLabel("Focus task, \(selectedTitle)")
        .accessibilityHint("Applies to the current running focus timer and the next timer.")
    }

    @ViewBuilder
    private var menuOptions: some View {
        Button("Unassigned") { model.selectedTaskID = nil }
        ForEach(model.tasks) { task in
            Button(task.title) { model.selectedTaskID = task.id }
        }
    }

    private var menuLabel: some View {
        HStack(spacing: 6) {
            Text(selectedTitle)
                .lineLimit(Self.pickerLineLimit(for: dynamicTypeSize))
                .minimumScaleFactor(Self.pickerScaleFactor(for: dynamicTypeSize))
                .allowsTightening(true)
                .multilineTextAlignment(Self.pickerMultilineAlignment(for: dynamicTypeSize))
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.bold())
                .accessibilityHidden(true)
        }
        .foregroundStyle(PomodoroughTheme.ticket)
        .frame(maxWidth: .infinity, alignment: Self.pickerAlignment(for: dynamicTypeSize))
        .frame(minHeight: Self.pickerTitleMinHeight(for: dynamicTypeSize))
        .fixedSize(horizontal: false, vertical: true)
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
