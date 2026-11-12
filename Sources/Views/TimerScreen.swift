import SwiftUI

struct TimerScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var syncStatusBottom: CGFloat = 0
    /// Measured height of the docked primary control; zero until measured.
    @State private var primaryControlDockHeight: CGFloat = 0

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
    /// GeometryReader coordinate space. Uses the region frame verbatim:
    /// the system split arrangement constrains content to the regions
    /// this frame defines, so the probe and the layout share one boundary.
    /// Physical positions stay fixed across layout directions because the
    /// fold does not move. The compiler gate keeps the older CI SDK
    /// buildable; runtime availability preserves the ordinary adaptive
    /// layout on iOS 18 through 27.0.
    static func measuredDivisions(in proxy: GeometryProxy) -> [CGRect] {
        #if os(iOS) && compiler(>=6.4)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
                .filter(\.isActive)
                .map(\.frame)
        }
        #endif
        return []
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

    /// Size that decides portrait versus landscape. The phone landscape
    /// card hides the navigation and tab bars. Bars live in the safe area,
    /// so hiding them grows the content height. A decision made from the
    /// content height then flips back to portrait, which shows the bars
    /// again, without end, in any container whose width falls between the
    /// two heights (IOS18-01: iOS 18 animates a newly selected tab's stale
    /// frame through such sizes after a rotation). The container with its
    /// safe area added back does not move with bar visibility. Regular x
    /// regular never hides chrome and keeps the content size.
    static func layoutDecisionSize(
        contentSize: CGSize,
        safeAreaInsets: EdgeInsets,
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?
    ) -> CGSize {
        if usesStackedLandscape(horizontal: horizontal, vertical: vertical) { return contentSize }
        return CGSize(
            width: contentSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: contentSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
    }

    private func layoutDecisionSize(in geometry: GeometryProxy) -> CGSize {
        #if os(iOS)
        Self.layoutDecisionSize(
            contentSize: geometry.size,
            safeAreaInsets: geometry.safeAreaInsets,
            horizontal: horizontalSizeClass,
            vertical: verticalSizeClass
        )
        #else
        geometry.size
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = TimerLayout(
                size: layoutDecisionSize(in: geometry),
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )
            let hinge = Self.measuredHinge(in: geometry)
            timerStack(layout: layout, hinge: hinge, geometry: geometry)
                .animation(reduceMotion ? nil : .default, value: layout)
            #if DEBUG && os(iOS)
                .overlay(alignment: .topLeading) {
                    layoutTestProbe(size: geometry.size)
                    hingeTestProbe(hinge, origin: geometry.frame(in: .global).origin)
                }
            #endif
        }
        .background(TimerBackdrop())
        .navigationTitle("Timer")
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
                portraitScroll(hinge: hinge, geometry: geometry)
            }
#endif
        }
    }

    #if !os(macOS)
    /// Portrait card in its scroll view. While the primary control is
    /// docked (R54-AU05) it sits in a safe-area inset, so the card scrolls
    /// beside it. A bottom dock also lowers the height the card must fill.
    /// VoiceOver reads the docked control before the card, in the same
    /// order as the card reads it when undocked: primary control first.
    private func portraitScroll(hinge: TimerHingeLayout, geometry: GeometryProxy) -> some View {
        let dock = TimerPrimaryControlDock.placement(
            usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize,
            hinge: hinge,
            isVerticallyCompact: verticalSizeClass == .compact
        )
        return ScrollView {
            portraitContent(
                compactDial: usesCompactDial(for: geometry.size),
                availableHeight: geometry.size.height - (dock == .bottom ? primaryControlDockHeight : 0),
                topGap: Self.portraitTopGap(syncStatusBottom: syncStatusBottom, globalMinY: geometry.frame(in: .global).minY),
                hinge: hinge,
                docksPrimaryControl: dock != nil
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if dock == .bottom {
                TimerPrimaryControlDock(model: model, placement: .bottom)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { primaryControlDockHeight = $0 }
                    .accessibilitySortPriority(1)
            }
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if dock == .trailing {
                TimerPrimaryControlDock(model: model, placement: .trailing)
                    .frame(width: geometry.size.width * TimerPrimaryControlDock.trailingWidthShare)
                    .accessibilitySortPriority(1)
            }
        }
        // One container, so the dock's sort priority orders it against the card.
        .accessibilityElement(children: .contain)
        .timerChromeHidden(false)
    }
    #endif

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

    @ViewBuilder
    private func hingeTestProbe(_ hinge: TimerHingeLayout, origin: CGPoint) -> some View {
        if ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_HINGE"] == "1" {
            Text(verbatim: "AP07")
                .font(.caption2)
                .accessibilityIdentifier("AP07-divisions")
                .accessibilityValue(Text(verbatim: hinge.divisions.map {
                    let frame = $0.offsetBy(dx: origin.x, dy: origin.y)
                    return [frame.minX, frame.minY, frame.width, frame.height]
                        .map { String(Double($0)) }.joined(separator: ",")
                }.joined(separator: "|")))
                .allowsHitTesting(false)
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

    private func portraitContent(
        compactDial: Bool,
        availableHeight: CGFloat,
        topGap: CGFloat,
        hinge: TimerHingeLayout,
        docksPrimaryControl: Bool
    ) -> some View {
        VStack(spacing: 20) {
            if let conflict = model.conflictMessage {
                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
            }
            TimerMachineCard(
                model: model,
                layout: .portrait,
                usesCompactDial: compactDial,
                minimumHeight: model.conflictMessage == nil ? Self.portraitMinimumHeight(availableHeight: availableHeight, topGap: topGap) : nil,
                hinge: hinge,
                docksPrimaryControl: docksPrimaryControl
            )
        }
        .padding(.horizontal, TimerPortraitSpacing.screenMargin)
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
    /// IOS27-19: the card hides the tab bar and toolbar until the person
    /// asks for them. A choice, not a measurement, so showing the bars
    /// cannot feed back into the layout decision (IOS18-01).
    @State private var showsChrome = false

    var body: some View {
        // Scroll recovery: landscape height on small phones can
        // be shorter than the card, so content scrolls instead
        // of extending past the visible area.
        ScrollView {
            VStack(spacing: 10) {
                if !showsChrome {
                    TimerShowChromeButton { showsChrome = true }
                }
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
        .timerChromeHidden(!showsChrome)
    }
}

/// The phone landscape Timer's way back to the tabs without rotating.
private struct TimerShowChromeButton: View {
    static let identifier = "timer.show-tabs"
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            Label(
                String(localized: "timer.show-tabs", defaultValue: "Show tabs"),
                systemImage: "menubar.dock.rectangle"
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .accessibilityHint(String(localized: "Shows the tab bar and the toolbar"))
        .accessibilityIdentifier(Self.identifier)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TimerScreen(model: AppModel.preview(.running))
    }
}
#endif
