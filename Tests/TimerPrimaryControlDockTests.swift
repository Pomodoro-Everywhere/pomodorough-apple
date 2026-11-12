import CoreGraphics
import Testing
@testable import Pomodorough

/// R54-AU05: the primary Timer control is docked outside the scrolling card
/// at accessibility text sizes, except where a Book fold places it aside.
@Suite("Timer primary control dock")
struct TimerPrimaryControlDockTests {
    private static let phone = TimerHingeLayout(containerSize: CGSize(width: 375, height: 554), divisions: [])
    /// Inner display with an active vertical fold, as measured on iPhone Duo.
    private static let book = TimerHingeLayout(
        containerSize: CGSize(width: 951, height: 669),
        divisions: [CGRect(x: 455.5, y: 0, width: 40, height: 669)]
    )

    private static func placement(
        accessible: Bool, hinge: TimerHingeLayout, compact: Bool = false
    ) -> TimerPrimaryControlDock.Placement? {
        TimerPrimaryControlDock.placement(
            usesAccessibleLayout: accessible, hinge: hinge, isVerticallyCompact: compact
        )
    }

    @Test func standardTextSizesKeepThePrimaryControlInTheCard() {
        #expect(Self.placement(accessible: false, hinge: Self.phone) == nil)
        #expect(Self.placement(accessible: false, hinge: Self.phone, compact: true) == nil)
        #expect(Self.placement(accessible: false, hinge: Self.book) == nil)
    }

    @Test func accessibilityTextSizesDockThePrimaryControlAboveTheTabBar() {
        #expect(Self.placement(accessible: true, hinge: Self.phone) == .bottom)
        let unmeasured = TimerHingeLayout(containerSize: .zero, divisions: [])
        #expect(Self.placement(accessible: true, hinge: unmeasured) == .bottom)
    }

    @Test func shortScreensDockThePrimaryControlBesideTheCard() {
        let landscapePhone = TimerHingeLayout(containerSize: CGSize(width: 667, height: 291), divisions: [])
        #expect(Self.placement(accessible: true, hinge: landscapePhone, compact: true) == .trailing)
    }

    @Test func bookFoldKeepsThePrimaryControlInTheAsidePanel() {
        #expect(Self.placement(accessible: true, hinge: Self.book) == nil)
        #expect(Self.placement(accessible: true, hinge: Self.book, compact: true) == nil)
    }
}
