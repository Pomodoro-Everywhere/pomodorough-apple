import SwiftUI

struct TimerScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var syncStatusBottom: CGFloat = 0

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
                TimerScreenMacOSContent(model: model, layout: layout)
                #else
                if layout == .landscape {
                    TimerScreenIOSLandscapeContent(
                        model: model,
                        layout: layout,
                        landscapeHeight: max(220, geometry.size.height - 100)
                    )
                } else {
                    ScrollView {
                        portraitContent(
                            compactDial: usesCompactDial(for: geometry.size),
                            availableHeight: geometry.size.height,
                            topGap: Self.portraitTopGap(syncStatusBottom: syncStatusBottom, globalMinY: geometry.frame(in: .global).minY)
                        )
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
        .onPreferenceChange(SyncToolbarBottomPreferenceKey.self) { syncStatusBottom = $0 }
    }

    /// Top gap keeps the portrait card clear of the sync-status toolbar row.
    /// Both inputs share global space: syncStatusBottom is the toolbar row's
    /// bottom edge via SyncToolbarBottomPreferenceKey, globalMinY is this
    /// GeometryReader's origin. GeometryReader re-evaluates on
    /// rotation/multitask/toolbar changes, so the gap tracks layout; zero
    /// means no toolbar row reported and the resting 16pt gap applies.
    static func portraitTopGap(syncStatusBottom: CGFloat, globalMinY: CGFloat) -> CGFloat {
        syncStatusBottom > 0 ? max(0, syncStatusBottom + 16 - globalMinY) : 16
    }

    /// Minimum portrait card height fills the visible content area below
    /// the toolbar gap, minus the 23pt bottom shadow allowance that
    /// portraitContent reserves. Floors at zero on short screens. The
    /// caller passes nil while a conflict banner is shown so the card
    /// sizes to content instead of stretching past the banner.
    static func portraitMinimumHeight(availableHeight: CGFloat, topGap: CGFloat) -> CGFloat {
        max(0, availableHeight - topGap - 23)
    }

    private func portraitContent(compactDial: Bool, availableHeight: CGFloat, topGap: CGFloat) -> some View {
        VStack(spacing: 20) {
            if let conflict = model.conflictMessage {
                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
            }
            TimerMachineCard(
                model: model,
                layout: .portrait,
                usesCompactDial: compactDial,
                minimumHeight: model.conflictMessage == nil ? Self.portraitMinimumHeight(availableHeight: availableHeight, topGap: topGap) : nil
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, topGap)
        // The offset card shadow extends seven points below its layout bounds.
        .padding(.bottom, 23)
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

private struct TimerScreenMacOSContent: View {
    let model: AppModel
    let layout: TimerLayout

    var body: some View {
        VStack(spacing: 16) {
            if let conflict = model.conflictMessage {
                ConflictBanner(message: conflict, dismiss: { model.dismissConflict() })
            }
            TimerMachineCard(model: model, layout: layout)
        }
        .padding(24)
    }
}

private struct TimerScreenIOSLandscapeContent: View {
    let model: AppModel
    let layout: TimerLayout
    var landscapeHeight: CGFloat

    var body: some View {
        // Scroll recovery: landscape height on small phones can
        // be shorter than the card, so content scrolls instead
        // of extending past the visible area.
        ScrollView {
            VStack(spacing: 10) {
                if let conflict = model.conflictMessage {
                    ConflictBanner(message: conflict, dismiss: { model.dismissConflict() })
                }
                TimerMachineCard(
                    model: model,
                    layout: layout,
                    landscapeHeight: landscapeHeight
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .timerChromeHidden(true)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TimerScreen(model: AppModel.preview(.running))
    }
}
#endif
