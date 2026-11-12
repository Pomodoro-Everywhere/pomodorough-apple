import SwiftUI

/// Pure geometry for the trailing swipe-to-delete gesture. Exposure is how
/// much of the trailing action area a drag has uncovered, in points.
enum SwipeToDeleteMetrics {
    /// Revealed action width as a proportion of the measured row width.
    static let revealFraction: CGFloat = 0.3
    /// Exposure past this proportion of the row width commits the delete.
    static let commitFraction: CGFloat = 0.65
    /// The revealed action never shrinks below the system touch target.
    static let minimumReveal: CGFloat = 44

    enum Outcome: Equatable {
        case closed
        case open
        case delete
    }

    static func revealWidth(rowWidth: CGFloat) -> CGFloat {
        max(minimumReveal, rowWidth * revealFraction)
    }

    /// A drag engages the row only when it starts predominantly sideways,
    /// so vertical scrolling keeps the gesture.
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    /// Exposure during a drag. `travel` is positive toward the trailing
    /// edge; an open row starts from its revealed position.
    static func exposure(travel: CGFloat, rowWidth: CGFloat, isOpen: Bool) -> CGFloat {
        let base = isOpen ? revealWidth(rowWidth: rowWidth) : 0
        return min(max(base + travel, 0), max(rowWidth, 0))
    }

    /// UIScrollView's normal deceleration rate per millisecond. A flick
    /// projects as far as a scroll view would coast at this rate.
    static let decelerationRate: CGFloat = 0.998

    /// Travel at which a release would come to rest. `velocity` is in points
    /// per second and signed like `travel`.
    static func projectedTravel(travel: CGFloat, velocity: CGFloat) -> CGFloat {
        travel + velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }

    /// Settled state after the finger lifts. Delete needs real exposure past
    /// the commit threshold; a flick only decides between open and closed.
    static func outcome(exposure: CGFloat, projectedExposure: CGFloat, rowWidth: CGFloat) -> Outcome {
        guard rowWidth > 0 else { return .closed }
        if exposure >= rowWidth * commitFraction { return .delete }
        if projectedExposure >= revealWidth(rowWidth: rowWidth) / 2 { return .open }
        return .closed
    }
}

#if os(iOS)
/// Wraps a board row with a trailing swipe that reveals a destructive
/// Delete action. A full swipe past the commit threshold deletes directly.
struct SwipeToDeleteRow<Content: View>: View {
    let delete: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowWidth: CGFloat = 0
    @State private var exposure: CGFloat = 0
    @State private var isOpen = false

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteAction
            content()
                .contentShape(.rect)
                .offset(x: -exposure)
                .onTapGesture {
                    guard isOpen else { return }
                    settle(.closed)
                }
                .gesture(HorizontalSwipeGesture(onSwipe: follow))
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
    }

    private var deleteAction: some View {
        Button(role: .destructive, action: delete) {
            PomodoroughTheme.danger
                .overlay(alignment: .trailing) {
                    Label("Delete", systemImage: "trash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth))
                }
        }
        .buttonStyle(.plain)
        .frame(width: exposure)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(!isOpen)
    }

    private func follow(_ event: HorizontalSwipeEvent) {
        switch event {
        case .changed(let travel):
            exposure = SwipeToDeleteMetrics.exposure(travel: travel, rowWidth: rowWidth, isOpen: isOpen)
        case .ended(let travel, let projectedTravel):
            settle(SwipeToDeleteMetrics.outcome(
                exposure: SwipeToDeleteMetrics.exposure(travel: travel, rowWidth: rowWidth, isOpen: isOpen),
                projectedExposure: SwipeToDeleteMetrics.exposure(
                    travel: projectedTravel,
                    rowWidth: rowWidth,
                    isOpen: isOpen
                ),
                rowWidth: rowWidth
            ))
        case .cancelled:
            // An interrupted swipe never deletes; the row returns to where it started.
            settle(isOpen ? .open : .closed)
        }
    }

    private func settle(_ outcome: SwipeToDeleteMetrics.Outcome) {
        switch outcome {
        case .delete:
            // The row leaves the board through the undo flow; reset so a
            // recycled row starts closed.
            isOpen = false
            exposure = 0
            delete()
        case .open:
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                isOpen = true
                exposure = SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth)
            }
        case .closed:
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                isOpen = false
                exposure = 0
            }
        }
    }
}
#endif
