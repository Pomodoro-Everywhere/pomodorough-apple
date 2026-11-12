import CoreGraphics

/// Spacing the portrait Timer card and the docked primary control share,
/// so the dock lines up with the card instead of repeating its numbers.
enum TimerPortraitSpacing {
    /// Gap between the screen edge and the card or the dock.
    static let screenMargin: CGFloat = 16
    /// Gap between the edge of the card's control panel, or of the dock,
    /// and the controls inside it.
    static let controlInset: CGFloat = 16
    /// Gap between the bottom dock and the tab bar below it.
    static let dockBottomGap: CGFloat = screenMargin / 2
}
