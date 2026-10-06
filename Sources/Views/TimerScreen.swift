import SwiftUI

struct TimerScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var syncStatusBottom: CGFloat = 0

    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Regular x regular (iPad full-screen, unfolded Duo) stacks the
    /// landscape card; compact width (phones, split-view, half-folded Duo)
    /// or compact height (landscape phones) uses the measured side-column
    /// card with scroll recovery.
    static func usesStackedLandscape(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> Bool {
        horizontal == .regular && vertical == .regular
    }

    /// Active division frames from measured reserved regions, in the
    /// GeometryReader coordinate space with margins included. Filters
    /// inactive folds so flat keeps existing layout; physical positions
    /// stay fixed across layout directions because the fold does not move.
    ///
    /// Fold detection needs the iOS 27.1 SDK (GeometryProxy.reservedRegions),
    /// but release and CI pin Xcode 26.6, whose SDK lacks that symbol, so any
    /// reference fails compile even inside `#available`. Return the empty
    /// flat-layout set until the toolchain bump; TimerHingeLayout already
    /// treats [] as unfolded.
    static func measuredDivisions(in proxy: GeometryProxy) -> [CGRect] {
        []
    }

    /// Measured hinge from container size plus active divisions.
    /// GeometryReader re-evaluates on fold, rotation, and multitasking
    /// changes, so Book pose arrives without cached state.
    static func measuredHinge(in proxy: GeometryProxy) -> TimerHingeLayout {
        TimerHingeLayout(containerSize: proxy.size, divisions: measuredDivisions(in: proxy))
    }

    /// Floor for the phone-landscape card height: short landscape
    /// screens (SE/12 mini, ~375pt) keep a usable dial instead of
    /// collapsing to the raw geometry remainder.
    static let landscapeMinimumHeight: CGFloat = 220

    /// Width below which the side column takes a larger share: a fixed
    /// third of SE/12-mini landscape (~667-740pt) squeezes the picker
    /// and controls, so narrow cards give the column 42% and the dial
    /// keeps the rest.
    static let narrowLandscapeWidth: CGFloat = 700
    static let narrowColumnFraction: CGFloat = 0.42

    /// Bounded phone-landscape card height from available geometry.
    /// GeometryReader dials need a bounded height; inside the vertical
    /// ScrollView they collapse to zero without it.
    static func landscapeCardHeight(for size: CGSize) -> CGFloat {
        max(landscapeMinimumHeight, size.height - 100)
    }

    /// Proportional side-column share of the measured card width. Nil
    /// falls back to content sizing so the height-bound dial keeps the
    /// remainder on every phone size with no device constants.
    static func landscapeColumnWidth(for totalWidth: CGFloat) -> CGFloat? {
        guard totalWidth > 0 else { return nil }
        return totalWidth < narrowLandscapeWidth
            ? totalWidth * narrowColumnFraction
            : totalWidth / 3
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = TimerLayout(
                size: geometry.size,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )
            let hinge = Self.measuredHinge(in: geometry)
            timerStack(layout: layout, hinge: hinge, geometry: geometry)
                .animation(reduceMotion ? nil : .default, value: layout)
            #if DEBUG && os(iOS)
                .overlay(alignment: .topLeading) { layoutTestProbe(size: geometry.size) }
            #endif
        }
        .background(TimerBackdrop())
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Timer" : "Pomodorough")
        .inlineNavigationTitleIfSupported()
        .refreshable { await model.refreshForPull() }
        .primaryRouteAccountToolbar(model: model)
        .onPreferenceChange(SyncToolbarBottomPreferenceKey.self) { syncStatusBottom = $0 }
    }

    @ViewBuilder
    private func timerStack(layout: TimerLayout, hinge: TimerHingeLayout, geometry: GeometryProxy) -> some View {
        ZStack {
#if os(macOS)
            TimerScreenMacOSContent(model: model, layout: layout)
#else
            if layout == .landscape {
#if os(iOS)
                if Self.usesStackedLandscape(horizontal: horizontalSizeClass, vertical: verticalSizeClass) {
                    TimerScreenIPadLandscapeContent(model: model, hinge: hinge)
                } else {
                    TimerScreenIOSLandscapeContent(
                        model: model,
                        layout: layout,
                        landscapeHeight: Self.landscapeCardHeight(for: geometry.size),
                        landscapeWidth: geometry.size.width,
                        hinge: hinge
                    )
                }
#endif
            } else {
                ScrollView {
                    portraitContent(
                        compactDial: usesCompactDial(for: geometry.size),
                        availableHeight: geometry.size.height,
                        topGap: Self.portraitTopGap(syncStatusBottom: syncStatusBottom, globalMinY: geometry.frame(in: .global).minY),
                        hinge: hinge
                    )
                }
                .timerChromeHidden(false)
            }
#endif
        }
    }

    #if DEBUG && os(iOS)
    // XCTest cannot read the app's SwiftUI size classes. Report raw inputs,
    // never chrome visibility, so eligibility cannot mask a chrome regression.
    @ViewBuilder
    private func layoutTestProbe(size: CGSize) -> some View {
        if ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_LAYOUT"] == "1" {
            Text(verbatim: "AP01")
                .font(.caption2)
                .accessibilityIdentifier("AP01-layout")
                .accessibilityValue(Text(verbatim: [
                    String(Double(size.width)), String(Double(size.height)),
                    sizeClassName(horizontalSizeClass), sizeClassName(verticalSizeClass),
                    String(dynamicTypeSize.isAccessibilitySize)
                ].joined(separator: "|")))
                .allowsHitTesting(false)
        }
    }

    private func sizeClassName(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        case nil: "unspecified"
        @unknown default: "unknown"
        }
    }
    #endif

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

    private func portraitContent(compactDial: Bool, availableHeight: CGFloat, topGap: CGFloat, hinge: TimerHingeLayout) -> some View {
        VStack(spacing: 20) {
            if let conflict = model.conflictMessage {
                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
            }
            TimerMachineCard(
                model: model,
                layout: .portrait,
                usesCompactDial: compactDial,
                minimumHeight: model.conflictMessage == nil ? Self.portraitMinimumHeight(availableHeight: availableHeight, topGap: topGap) : nil,
                hinge: hinge
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, topGap)
        // The offset card shadow extends seven points below its layout bounds.
        .padding(.bottom, 23)
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

private struct TimerScreenIPadLandscapeContent: View {
    let model: AppModel
    var hinge = TimerHingeLayout(containerSize: .zero, divisions: [])

    var body: some View {
        VStack {
            if let conflict = model.conflictMessage {
                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
            }
            TimerMachineCard(model: model, layout: .landscape, hinge: hinge)
        }
        .padding()
        // Regular-size landscape keeps the native adaptive tabs and Account
        // toolbar reachable when unfolding; only the phone card hides chrome.
        .timerChromeHidden(false)
    }
}

private struct TimerScreenIOSLandscapeContent: View {
    let model: AppModel
    let layout: TimerLayout
    var landscapeHeight: CGFloat
    var landscapeWidth: CGFloat
    var hinge = TimerHingeLayout(containerSize: .zero, divisions: [])

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
                    landscapeHeight: landscapeHeight,
                    landscapeWidth: landscapeWidth,
                    hinge: hinge
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
