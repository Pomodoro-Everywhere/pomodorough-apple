import Foundation
import SwiftUI
import Testing
@testable import Pomodorough

// R43-AP02: production Book pose layout must avoid the fold.
// Uses measured division frames in container-local coordinates,
// never a hardcoded spansHinge bool.
@Suite("Timer hinge Book pose production layout")
struct TimerHingeLayoutTests {
    @Test func rawFoldEdgeIsTheProductionBoundary() {
        // The production adapter reports the measured region frame
        // verbatim, matching the regions the system split arrangement
        // uses. A control starting exactly at the raw edge avoids the
        // fold; one point inside still spans it.
        let edge = Self.bookDivisions[0].maxX
        #expect(!TimerHingeLayout.controlRowSpansFold(
            controlFrame: CGRect(x: edge, y: 600, width: 100, height: 60),
            divisions: Self.bookDivisions
        ))
        #expect(TimerHingeLayout.controlRowSpansFold(
            controlFrame: CGRect(x: edge - 1, y: 600, width: 100, height: 60),
            divisions: Self.bookDivisions
        ))
    }

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

    // R51-U01: accessibility portrait Book keeps picker, Start, Skip
    // inside measured usable panels, outside 40-point division.
    @Test func bookPanelsExcludeFortyPointDivision() {
        let panels = TimerHingeLayout.usablePanels(
            containerSize: Self.bookContainer, divisions: Self.bookDivisions)
        #expect(panels.count == 2)
        #expect(abs(panels[0].maxX - 455.5) < 0.01)
        #expect(abs(panels[1].minX - 495.5) < 0.01)
        #expect(abs(Self.bookDivisions[0].width - 40) < 0.01)
        for panel in panels {
            #expect(!panel.intersects(Self.bookDivisions[0]))
        }
    }

    @Test func closedAndFlatContainersStaySinglePanel() {
        let closed = TimerHingeLayout.usablePanels(
            containerSize: CGSize(width: 466, height: 678), divisions: [])
        #expect(closed.count == 1)
        let flat = TimerHingeLayout.usablePanels(
            containerSize: Self.bookContainer, divisions: [])
        #expect(flat.count == 1)
    }

    @Test func horizontalDivisionSplitsTopBottom() {
        let container = CGSize(width: 669, height: 951)
        let division = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let panels = TimerHingeLayout.usablePanels(
            containerSize: container, divisions: [division])
        #expect(panels.count == 2)
        #expect(abs(panels[0].maxY - 455.5) < 0.01)
        #expect(abs(panels[1].minY - 495.5) < 0.01)
        for panel in panels {
            #expect(!panel.intersects(division))
        }
    }

    @Test func crossingFramesReproduceDefectWhilePanelsAvoid() {
        let panels = TimerHingeLayout.usablePanels(
            containerSize: Self.bookContainer, divisions: Self.bookDivisions)
        let countdown = CGRect(x: 50, y: 256, width: 293, height: 114.3333)
        #expect(!TimerHingeLayout.controlRowSpansFold(
            controlFrame: countdown, divisions: Self.bookDivisions))
        #expect(panels.contains { $0.contains(countdown) })
        let start = CGRect(x: 440.6667, y: 357, width: 394.3333, height: 93.3333)
        let skip = CGRect(x: 440.6667, y: 464.3333, width: 394.3333, height: 76.6667)
        let picker = CGRect(x: 454.6667, y: 200, width: 300, height: 80)
        for frame in [start, skip, picker] {
            #expect(TimerHingeLayout.controlRowSpansFold(
                controlFrame: frame, divisions: Self.bookDivisions))
            #expect(!panels.contains { $0.contains(frame) })
        }
        let repaired = CGRect(x: 500, y: 357, width: 350, height: 93.3333)
        #expect(!TimerHingeLayout.controlRowSpansFold(
            controlFrame: repaired, divisions: Self.bookDivisions))
        #expect(panels.contains { $0.contains(repaired) })
    }

    // R51-U01 view wiring: TimerMachineCard holds hinge default
    // TimerHingeLayout(containerSize: .zero, divisions: []) before
    // GeometryReader/reservedRegions deliver measured geometry, and both iOS
    // cards branch on shouldPlaceDialAsideControls into bookAsideContent
    // (ArrangementView split) vs fallbackAsideContent (HStack). This pins
    // that the unmeasured default routes to the fallback and only the
    // measured Book pose routes aside, so a missing measurement can never
    // place picker/Start/Skip across the fold.
    @Test func unmeasuredHingeStaysFallbackUntilMeasuredBook() {
        #expect(!TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: .zero, divisions: []))
        #expect(!TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: .zero, divisions: Self.bookDivisions))
        #expect(!TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: Self.bookContainer, divisions: []))
        #expect(TimerHingeLayout.shouldPlaceDialAsideControls(
            containerSize: Self.bookContainer, divisions: Self.bookDivisions))
        #expect(TimerHingeLayout.usablePanels(
            containerSize: .zero, divisions: Self.bookDivisions).isEmpty)
    }

    @Test func focusOrderStaysDialThenPickerThenActions() {
        let panels = TimerHingeLayout.usablePanels(
            containerSize: Self.bookContainer, divisions: Self.bookDivisions)
        #expect(panels.count == 2)
        #expect(panels[0].minX < panels[1].minX)
        let dial = CGRect(x: 50, y: 256, width: 293, height: 114.3333)
        let picker = CGRect(x: 500, y: 200, width: 350, height: 80)
        let primary = CGRect(x: 500, y: 357, width: 350, height: 93.3333)
        let secondary = CGRect(x: 500, y: 464.3333, width: 350, height: 76.6667)
        #expect(panels[0].contains(dial))
        for frame in [picker, primary, secondary] {
            #expect(panels[1].contains(frame))
        }
        #expect(picker.minY < primary.minY)
        #expect(primary.minY < secondary.minY)
    }
}
