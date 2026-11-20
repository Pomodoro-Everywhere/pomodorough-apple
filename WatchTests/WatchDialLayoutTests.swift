import CoreGraphics
import Testing
@testable import Pomodorough

/// WCH-01: the ring encloses the phase, the countdown and the status.
struct WatchDialLayoutTests {
    /// Representative dial spaces, not measurements: wide rows like the
    /// one above the controls at standard text sizes, squares like the
    /// dial at accessibility text sizes, and one tall space.
    static let availableSizes: [CGSize] = [
        CGSize(width: 162, height: 118),
        CGSize(width: 205, height: 150),
        CGSize(width: 146, height: 146),
        CGSize(width: 189, height: 189),
        CGSize(width: 120, height: 200),
    ]

    @Test(arguments: availableSizes)
    func ringIsTheLargestCircleThatFits(available: CGSize) {
        let layout = WatchDialLayout(available: available)
        #expect(layout.diameter == min(available.width, available.height))
        #expect(layout.innerDiameter == layout.diameter - 2 * WatchDialLayout.ringLineWidth)
    }

    @Test(arguments: availableSizes)
    func everyTextBoxStaysInsideTheRing(available: CGSize) {
        let layout = WatchDialLayout(available: available)
        let radius = layout.innerDiameter / 2
        let countdownCorner = hypot(layout.countdown.width / 2, layout.countdown.height / 2)
        let captionCorner = hypot(layout.caption.width / 2, layout.contentHeight / 2)
        #expect(countdownCorner <= radius, "countdown corner \(countdownCorner) > \(radius)")
        #expect(captionCorner <= radius, "caption corner \(captionCorner) > \(radius)")
    }

    @Test(arguments: availableSizes)
    func countdownGetsMostOfTheRingWidth(available: CGSize) {
        let layout = WatchDialLayout(available: available)
        #expect(layout.countdown.width >= layout.innerDiameter * 0.8)
        #expect(layout.caption.height > 0)
    }

    @Test func emptySpaceGivesAnEmptyDial() {
        let layout = WatchDialLayout(available: .zero)
        #expect(layout.diameter == 0)
        #expect(layout.innerDiameter == 0)
        #expect(layout.contentHeight == 0)
    }
}
