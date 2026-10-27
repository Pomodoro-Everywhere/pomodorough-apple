import SwiftUI

/// AU02/AU03-shared tab-bar-measured bottom inset for scroll content under
/// the floating tab bar (Tasks, Pattern, Arrivals empty state). Clearance
/// derives from measured safe-area geometry, never a fixed guess; zero at
/// standard sizes where native insets already clear the bar. SE2 evidence
/// pins the ruler: the XXXL tab bar measures 83pt portrait, 64pt landscape.
enum TabBarScrollInset {
    /// Fallback when no tab-bar overlap is measured (previews, macOS,
    /// bar-less contexts). Only fixed number allowed here: a system-minimum
    /// touch target, per layout rules.
    static let minimumClearance: CGFloat = 44

    static func bottom(safeBottom: CGFloat, isAccessibilitySize: Bool) -> CGFloat {
        guard isAccessibilitySize else { return 0 }
        return max(safeBottom, minimumClearance)
    }
}
