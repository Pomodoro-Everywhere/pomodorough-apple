import CoreGraphics
import SwiftUI

/// R43-AP02 production hinge layout from measured division regions.
/// Division frames are container-local with margins included, from
/// GeometryProxy.reservedRegions(kind: .division). Verticality comes
/// from proportions and spanning from CGRect math. No fixed widths.
struct TimerHingeLayout: Equatable {
    var containerSize: CGSize
    var divisions: [CGRect]

    static func isVertical(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.height > frame.width
    }

    static func verticalDivisionThroughContainer(
        containerSize: CGSize,
        divisions: [CGRect]
    ) -> Bool {
        guard containerSize.width > 0 && containerSize.height > 0 else { return false }
        for division in divisions where isVertical(division) {
            guard division.minX > 0 && division.maxX < containerSize.width else { continue }
            if division.minY < containerSize.height && division.maxY > 0 {
                return true
            }
        }
        return false
    }

    static func controlRowSpansFold(controlFrame: CGRect, divisions: [CGRect]) -> Bool {
        divisions.contains { $0.intersects(controlFrame) }
    }

    static func shouldUseSingleRow(
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?,
        containerSize: CGSize,
        divisions: [CGRect]
    ) -> Bool {
        if verticalDivisionThroughContainer(containerSize: containerSize, divisions: divisions) {
            return false
        }
        guard horizontal == .regular else { return false }
        switch vertical {
        case .regular, .compact:
            return true
        case nil:
            return true
        @unknown default:
            return true
        }
    }

    static func shouldPlaceDialAsideControls(
        containerSize: CGSize,
        divisions: [CGRect]
    ) -> Bool {
        verticalDivisionThroughContainer(containerSize: containerSize, divisions: divisions)
    }
}
