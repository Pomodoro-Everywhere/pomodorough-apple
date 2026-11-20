import CoreGraphics

/// WCH-01: sizes the dial from the space it gets, so the ring always encloses
/// the phase, the countdown and the status. The ring is the largest circle
/// that fits; each line of text gets a box whose corners stay inside the
/// ring's inner edge, and the text shrinks to fit its box.
struct WatchDialLayout: Equatable {
    /// The progress arc is the wider of the two ring strokes.
    static let ringLineWidth: CGFloat = 5

    let diameter: CGFloat
    /// The diameter inside the ring stroke.
    let innerDiameter: CGFloat
    /// The countdown sits across the middle of the ring, where it is widest.
    let countdown: CGSize
    /// The phase above and the status below sit where the ring is narrower.
    let caption: CGSize

    init(available: CGSize) {
        diameter = max(0, min(available.width, available.height))
        innerDiameter = max(0, diameter - 2 * Self.ringLineWidth)
        countdown = CGSize(width: innerDiameter * 0.86, height: innerDiameter * 0.5)
        caption = CGSize(width: innerDiameter * 0.6, height: innerDiameter * 0.14)
    }

    /// The text column: caption, countdown, caption, stacked without gaps.
    var contentHeight: CGFloat { countdown.height + 2 * caption.height }
}
