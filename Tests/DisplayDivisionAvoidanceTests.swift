import Foundation
import SwiftUI
import Testing
@testable import Pomodorough

// IOS27-22: on a half-open Duo only Timer avoided the fold; Tasks, Pattern
// and Arrivals laid their content across it. Those screens now pad their
// content into one usable panel, from the same measured divisions.
@Suite("Display division avoidance")
struct DisplayDivisionAvoidanceTests {
    private static let bookContainer = CGSize(width: 951, height: 669)
    private static let bookFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    /// Panels of different widths, so a right-to-left layout that kept the
    /// left panel cannot land on the right panel's insets by symmetry.
    private static let offCentreBookFold = CGRect(x: 300, y: 0, width: 40, height: 669)
    private static let tabletopContainer = CGSize(width: 669, height: 951)
    private static let tabletopFold = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    private func insets(_ size: CGSize, _ divisions: [CGRect], _ direction: LayoutDirection) -> EdgeInsets {
        DisplayDivisionAvoidance.contentInsets(
            for: TimerHingeLayout(containerSize: size, divisions: divisions), layoutDirection: direction
        )
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func flatOrUnmeasuredScreensKeepTheirLayout(direction: LayoutDirection) {
        #expect(insets(Self.bookContainer, [], direction) == EdgeInsets())
        #expect(insets(.zero, [Self.bookFold], direction) == EdgeInsets())
    }

    @Test func bookPoseMovesContentToTheLeftPanelLeftToRight() {
        let result = insets(Self.bookContainer, [Self.bookFold], .leftToRight)
        #expect(result == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 951 - 455.5))
    }

    /// Division frames are physical, so the reading-leading panel in a
    /// right-to-left layout is the right one, and its physical left inset
    /// is the trailing inset.
    @Test func bookPoseMovesContentToTheRightPanelRightToLeft() {
        let result = insets(Self.bookContainer, [Self.bookFold], .rightToLeft)
        #expect(result == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 495.5))
    }

    @Test func offCentreBookPoseMovesContentToTheLeftPanelLeftToRight() {
        let result = insets(Self.bookContainer, [Self.offCentreBookFold], .leftToRight)
        #expect(result == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 951 - 300))
    }

    /// The right panel spans 340-951, so its physical left inset of 340
    /// is the trailing inset; the left panel would leave 651 instead.
    @Test func offCentreBookPoseMovesContentToTheRightPanelRightToLeft() {
        let result = insets(Self.bookContainer, [Self.offCentreBookFold], .rightToLeft)
        #expect(result == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 340))
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func horizontalFoldKeepsContentInTheTopPanel(direction: LayoutDirection) {
        let result = insets(Self.tabletopContainer, [Self.tabletopFold], direction)
        #expect(result == EdgeInsets(top: 0, leading: 0, bottom: 951 - 455.5, trailing: 0))
    }

    @Test func confinedContentNeverCrossesTheFold() {
        let size = Self.bookContainer
        let result = insets(size, [Self.bookFold], .leftToRight)
        let content = CGRect(
            x: result.leading, y: result.top,
            width: size.width - result.leading - result.trailing,
            height: size.height - result.top - result.bottom
        )
        #expect(!content.intersects(Self.bookFold))
        #expect(content.width > 0)
    }
}
