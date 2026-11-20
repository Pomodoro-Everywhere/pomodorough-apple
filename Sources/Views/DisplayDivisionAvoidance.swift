import SwiftUI

/// Keeps a screen's content off an active display division, such as the
/// fold of a half-open iPhone Duo (IOS27-22). Timer splits its card around
/// the fold. Tasks, Pattern and Arrivals have no second pane, so their
/// content moves into the reading-leading panel beside a vertical fold, or
/// the top panel above a horizontal one, and the backdrop fills the rest.
/// The panels come from the same measured geometry as the Timer
/// (`TimerHingeLayout.usablePanels`). Without an active division every
/// inset is zero and the layout is unchanged.
struct DisplayDivisionAvoidance: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var hinge = TimerHingeLayout(containerSize: .zero, divisions: [])

    func body(content: Content) -> some View {
        content
            // Padding, not safe-area padding: list row backgrounds extend
            // into the safe area and would still cross the fold.
            .padding(Self.contentInsets(for: hinge, layoutDirection: layoutDirection))
            // Measured outside the padding, so the insets never feed back
            // into the geometry they come from.
            .onGeometryChange(for: TimerHingeLayout.self) { proxy in
                TimerHingeLayout.measured(in: proxy)
            } action: { measured in
                hinge = measured
            }
    }

    /// Insets that confine content to one usable panel. Division frames
    /// are physical (they do not mirror in right-to-left layouts), so the
    /// physical left and right insets swap onto leading and trailing there.
    static func contentInsets(for hinge: TimerHingeLayout, layoutDirection: LayoutDirection) -> EdgeInsets {
        let panels = TimerHingeLayout.usablePanels(containerSize: hinge.containerSize, divisions: hinge.divisions)
        guard let first = panels.first, let last = panels.last, panels.count > 1 else { return EdgeInsets() }
        let isRightToLeft = layoutDirection == .rightToLeft
        let sideBySide = first.minY == last.minY
        let panel = sideBySide && isRightToLeft ? last : first
        let physicalLeft = panel.minX
        let physicalRight = hinge.containerSize.width - panel.maxX
        return EdgeInsets(
            top: panel.minY,
            leading: isRightToLeft ? physicalRight : physicalLeft,
            bottom: hinge.containerSize.height - panel.maxY,
            trailing: isRightToLeft ? physicalLeft : physicalRight
        )
    }
}

extension View {
    func avoidsDisplayDivisions() -> some View {
        modifier(DisplayDivisionAvoidance())
    }
}
