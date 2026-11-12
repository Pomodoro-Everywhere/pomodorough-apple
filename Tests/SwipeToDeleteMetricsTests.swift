import Foundation
import Testing
@testable import Pomodorough

/// Threshold math for the trailing swipe-to-delete gesture.
@Suite("Swipe to delete metrics")
struct SwipeToDeleteMetricsTests {
    private let rowWidth: CGFloat = 400

    @Test func revealWidthIsProportionalWithTouchTargetFloor() {
        #expect(SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth) == rowWidth * SwipeToDeleteMetrics.revealFraction)
        #expect(SwipeToDeleteMetrics.revealWidth(rowWidth: 100) == SwipeToDeleteMetrics.minimumReveal)
        #expect(SwipeToDeleteMetrics.revealWidth(rowWidth: 0) == SwipeToDeleteMetrics.minimumReveal)
    }

    @Test func horizontalDragsEngageVerticalDragsDoNot() {
        #expect(SwipeToDeleteMetrics.isHorizontal(CGSize(width: -30, height: 4)))
        #expect(SwipeToDeleteMetrics.isHorizontal(CGSize(width: 30, height: -4)))
        #expect(!SwipeToDeleteMetrics.isHorizontal(CGSize(width: 4, height: 30)))
        #expect(!SwipeToDeleteMetrics.isHorizontal(CGSize(width: 10, height: 10)), "a diagonal tie keeps scrolling")
    }

    @Test func exposureClampsBetweenClosedAndRowWidth() {
        #expect(SwipeToDeleteMetrics.exposure(travel: 60, rowWidth: rowWidth, isOpen: false) == 60)
        #expect(SwipeToDeleteMetrics.exposure(travel: -60, rowWidth: rowWidth, isOpen: false) == 0)
        #expect(SwipeToDeleteMetrics.exposure(travel: 10_000, rowWidth: rowWidth, isOpen: false) == rowWidth)
        let reveal = SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth)
        #expect(SwipeToDeleteMetrics.exposure(travel: 0, rowWidth: rowWidth, isOpen: true) == reveal)
        #expect(SwipeToDeleteMetrics.exposure(travel: -reveal, rowWidth: rowWidth, isOpen: true) == 0)
    }

    @Test func outcomeThresholds() {
        let reveal = SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth)
        let commit = rowWidth * SwipeToDeleteMetrics.commitFraction
        #expect(SwipeToDeleteMetrics.outcome(exposure: commit, projectedExposure: commit, rowWidth: rowWidth) == .delete)
        #expect(SwipeToDeleteMetrics.outcome(exposure: commit - 1, projectedExposure: commit - 1, rowWidth: rowWidth) == .open)
        #expect(SwipeToDeleteMetrics.outcome(exposure: reveal / 2, projectedExposure: reveal / 2, rowWidth: rowWidth) == .open)
        #expect(SwipeToDeleteMetrics.outcome(exposure: reveal / 2 - 1, projectedExposure: reveal / 2 - 1, rowWidth: rowWidth) == .closed)
        #expect(SwipeToDeleteMetrics.outcome(exposure: 0, projectedExposure: 0, rowWidth: rowWidth) == .closed)
    }

    @Test func flickDecidesOpenButNeverDelete() {
        let reveal = SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth)
        #expect(SwipeToDeleteMetrics.outcome(exposure: 10, projectedExposure: reveal, rowWidth: rowWidth) == .open)
        #expect(SwipeToDeleteMetrics.outcome(exposure: 10, projectedExposure: rowWidth, rowWidth: rowWidth) == .open)
        #expect(SwipeToDeleteMetrics.outcome(exposure: reveal, projectedExposure: 0, rowWidth: rowWidth) == .closed, "a flick back from open closes")
    }

    @Test func releaseProjectsLikeScrollViewDeceleration() {
        #expect(SwipeToDeleteMetrics.projectedTravel(travel: 40, velocity: 0) == 40)
        // A 1,000 pt/s release coasts 499 points at the normal rate.
        #expect(abs(SwipeToDeleteMetrics.projectedTravel(travel: 40, velocity: 1000) - 539) < 0.01)
        #expect(SwipeToDeleteMetrics.projectedTravel(travel: 40, velocity: -1000) < 0, "a flick back projects past closed")
    }

    @Test func shortDragOpensOnlyWhenFlicked() {
        let reveal = SwipeToDeleteMetrics.revealWidth(rowWidth: rowWidth)
        func outcome(velocity: CGFloat) -> SwipeToDeleteMetrics.Outcome {
            let projected = SwipeToDeleteMetrics.projectedTravel(travel: 10, velocity: velocity)
            return SwipeToDeleteMetrics.outcome(
                exposure: SwipeToDeleteMetrics.exposure(travel: 10, rowWidth: rowWidth, isOpen: false),
                projectedExposure: SwipeToDeleteMetrics.exposure(travel: projected, rowWidth: rowWidth, isOpen: false),
                rowWidth: rowWidth
            )
        }
        #expect(reveal / 2 > 30, "fixture keeps the slow release below the open threshold")
        #expect(outcome(velocity: 20) == .closed)
        #expect(outcome(velocity: 300) == .open)
        #expect(outcome(velocity: 5000) == .open, "a flick never deletes")
    }

    @Test func unmeasuredRowNeverDeletes() {
        #expect(SwipeToDeleteMetrics.outcome(exposure: 500, projectedExposure: 500, rowWidth: 0) == .closed)
    }
}
