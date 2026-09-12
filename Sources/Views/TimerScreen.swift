import SwiftUI

struct TimerScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let layout = TimerLayout(
                size: geometry.size,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )

            ZStack {
                #if os(macOS)
                VStack(spacing: 16) {
                    if let conflict = model.conflictMessage {
                        ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                    }
                    TimerMachineCard(model: model, layout: layout)
                }
                .padding(24)
                #else
                if layout == .landscape {
                    // Scroll recovery: landscape height on small phones can
                    // be shorter than the card, so content scrolls instead
                    // of extending past the visible area.
                    ScrollView {
                        VStack(spacing: 10) {
                            if let conflict = model.conflictMessage {
                                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                            }
                            TimerMachineCard(
                                model: model,
                                layout: layout,
                                landscapeHeight: max(220, geometry.size.height - 100)
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .timerChromeHidden(true)
                } else {
                    ScrollView {
                        portraitContent(compactDial: usesCompactDial(for: geometry.size))
                    }
                    .timerChromeHidden(false)
                }
                #endif
            }
            .animation(reduceMotion ? nil : .default, value: layout)
        }
        .background(TimerBackdrop())
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Timer" : "Pomodorough")
        .inlineNavigationTitleIfSupported()
        .refreshable { await model.refreshForPull() }
        .primaryRouteAccountToolbar(model: model)
    }

    private func portraitContent(compactDial: Bool) -> some View {
        VStack(spacing: 20) {
            if let conflict = model.conflictMessage {
                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
            }
            TimerMachineCard(model: model, layout: .portrait, usesCompactDial: compactDial)
        }
        .padding()
        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 96 : 16)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    /// The full circular dial stays on every phone tall enough to fit it
    /// with room to spare (base 17 / Pro / Pro Max in portrait, idle and
    /// running). Only short phones (SE class) fall back to the compact
    /// readout; there the scroll view is the overflow escape hatch. Size is
    /// the visible content area (below the navigation bar, above the tab
    /// bar), not the device height.
    private func usesCompactDial(for size: CGSize) -> Bool {
        if dynamicTypeSize.isAccessibilitySize { return false }
        return size.height < 600
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TimerScreen(model: AppModel.preview(.running))
    }
}
#endif
