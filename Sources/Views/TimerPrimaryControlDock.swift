import SwiftUI

/// R54-AU05: at accessibility text sizes the portrait Timer card is taller
/// than the screen, and Start sat a full scroll below the countdown. The
/// screen then docks the primary control (Start, Pause or Resume) outside
/// the scrolling card, so it is visible with the countdown. The rest of the
/// card scrolls beside the dock.
struct TimerPrimaryControlDock: View {
    static let accessibilityIdentifier = "timer-primary-control-dock"

    /// The screen edge that holds the dock.
    enum Placement: Sendable {
        /// Above the tab bar. The countdown stays visible at the top.
        case bottom
        /// Beside the card. A short screen has no room for the dock under
        /// the countdown.
        case trailing
    }

    /// Share of the screen width a trailing dock takes.
    static let trailingWidthShare: CGFloat = 0.4

    let model: AppModel
    let placement: Placement

    /// Accessibility text sizes dock the primary control; other sizes keep
    /// it in the card. A Book fold also keeps it in the card's aside panel:
    /// a dock along a screen edge would span the fold.
    static func placement(
        usesAccessibleLayout: Bool,
        hinge: TimerHingeLayout,
        isVerticallyCompact: Bool
    ) -> Placement? {
        guard usesAccessibleLayout else { return nil }
        let foldPlacesControlsAside = TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: hinge.containerSize,
            divisions: hinge.divisions
        )
        guard !foldPlacesControlsAside else { return nil }
        return isVerticallyCompact ? .trailing : .bottom
    }

    var body: some View {
        TimerControls(model: model, layout: .portrait, group: .primaryOnly)
            .padding(TimerPortraitSpacing.controlInset)
            .foregroundStyle(PomodoroughTheme.porcelain)
            .background(PomodoroughTheme.platform, in: .rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .padding(placement == .bottom ? [.horizontal] : [.trailing], TimerPortraitSpacing.screenMargin)
            .padding(.bottom, placement == .bottom ? TimerPortraitSpacing.dockBottomGap : 0)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

#if DEBUG
#Preview {
    TimerPrimaryControlDock(model: AppModel.preview(.running), placement: .bottom)
        .background(TimerBackdrop())
        .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
