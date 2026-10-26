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

    static func isHorizontal(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.width > frame.height
    }

    /// Measured usable panels excluding active divisions, including
    /// their margins. Vertical folds split left/right; horizontal
    /// folds split top/bottom; otherwise the container is one panel.
    /// No fixed widths; every edge comes from measured geometry.
    static func usablePanels(containerSize: CGSize, divisions: [CGRect]) -> [CGRect] {
        guard containerSize.width > 0, containerSize.height > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: containerSize)
        let verticals = divisions.filter {
            isVertical($0) && $0.minX > 0 && $0.maxX < containerSize.width
                && $0.minY < containerSize.height && $0.maxY > 0
        }.sorted { $0.minX < $1.minX }
        if !verticals.isEmpty {
            var panels: [CGRect] = []
            var cursor: CGFloat = 0
            for division in verticals {
                if division.minX > cursor {
                    panels.append(CGRect(x: cursor, y: 0, width: division.minX - cursor, height: containerSize.height))
                }
                cursor = max(cursor, division.maxX)
            }
            if cursor < containerSize.width {
                panels.append(CGRect(x: cursor, y: 0, width: containerSize.width - cursor, height: containerSize.height))
            }
            return panels.filter { $0.width > 0 && $0.height > 0 }
        }
        let horizontals = divisions.filter {
            isHorizontal($0) && $0.minY > 0 && $0.maxY < containerSize.height
                && $0.minX < containerSize.width && $0.maxX > 0
        }.sorted { $0.minY < $1.minY }
        if !horizontals.isEmpty {
            var panels: [CGRect] = []
            var cursor: CGFloat = 0
            for division in horizontals {
                if division.minY > cursor {
                    panels.append(CGRect(x: 0, y: cursor, width: containerSize.width, height: division.minY - cursor))
                }
                cursor = max(cursor, division.maxY)
            }
            if cursor < containerSize.height {
                panels.append(CGRect(x: 0, y: cursor, width: containerSize.width, height: containerSize.height - cursor))
            }
            return panels.filter { $0.width > 0 && $0.height > 0 }
        }
        return [bounds]
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

    /// R52-U02 aside secondary spacing: the production VStack spacing inside
    /// the Book scroll recovery. Shared with the card so tests pin the value
    /// the repaired stacking is measured against.
    static let bookAsideLandscapeSpacing: CGFloat = 12
    static let bookAsidePortraitSpacing: CGFloat = 14

    /// R52-U02 repaired Start frame: keeps its measured size and sits at
    /// title.maxY plus the aside spacing, inside the same usable panel.
    static func stackedStartFrame(title: CGRect, start: CGRect, spacing: CGFloat) -> CGRect {
        CGRect(x: start.minX, y: title.maxY + spacing, width: start.width, height: start.height)
    }

    /// True when Start clears the title with exactly the aside spacing.
    static func startStackedBelowTitle(title: CGRect, start: CGRect, spacing: CGFloat) -> Bool {
        !title.intersects(start) && abs(start.minY - (title.maxY + spacing)) < 0.01
    }
}
