import Foundation
import SwiftUI
import Testing
@testable import Pomodorough

// R43-AP02: production Book pose layout must avoid the fold.
// Uses measured division frames in container-local coordinates,
// never a hardcoded spansHinge bool.
@Suite("Timer hinge Book pose production layout")
struct TimerHingeLayoutTests {
    // Inner display one window with active vertical fold, measured
    // on iPhone Duo simulator at 127 degrees hinge angle.
    static var bookContainer: CGSize { CGSize(width: 951, height: 669) }
    static var bookDivisions: [CGRect] {
        [CGRect(x: 455.5, y: 0, width: 40, height: 669)]
    }

    static var flatContainer: CGSize { CGSize(width: 951, height: 669) }

    @Test func bookVerticalFoldForcesStackedControls() {
        #expect(!TimerHingeLayout.shouldUseSingleRow(
            horizontal: .regular,
            vertical: .regular,
            containerSize: Self.bookContainer,
            divisions: Self.bookDivisions
        ))
    }

    @Test func flatUnfoldedKeepsSingleRow() {
        #expect(TimerHingeLayout.shouldUseSingleRow(
            horizontal: .regular,
            vertical: .regular,
            containerSize: Self.flatContainer,
            divisions: []
        ))
    }

    @Test func bookPlacesDialAsideControls() {
        #expect(TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: Self.bookContainer,
            divisions: Self.bookDivisions
        ))
        #expect(!TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: Self.flatContainer,
            divisions: []
        ))
    }

    @Test func fullWidthControlRowSpansBookFold() {
        let controlRow = CGRect(x: 0, y: 600, width: 951, height: 60)
        #expect(TimerHingeLayout.controlRowSpansFold(
            controlFrame: controlRow,
            divisions: Self.bookDivisions
        ))
        #expect(!TimerHingeLayout.controlRowSpansFold(
            controlFrame: controlRow,
            divisions: []
        ))
    }

    @Test func edgeSliverDoesNotForceStacked() {
        // Split View left window: fold sliver touches shared edge,
        // window sits beside fold rather than spanning it.
        let leftWindow = CGSize(width: 469, height: 669)
        let edgeSliver = [CGRect(x: 455.5, y: 0, width: 13.5, height: 669)]
        #expect(TimerHingeLayout.shouldUseSingleRow(
            horizontal: .regular,
            vertical: .regular,
            containerSize: leftWindow,
            divisions: edgeSliver
        ))
    }
}
