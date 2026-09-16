import SwiftUI

struct RouteClockMark: View {
    @ScaledMetric(relativeTo: .body) private var regularDiameter: CGFloat = 88
    @ScaledMetric(relativeTo: .body) private var compactDiameter: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var regularFontSize: CGFloat = 42
    @ScaledMetric(relativeTo: .body) private var compactFontSize: CGFloat = 20

    /// Base diameters before Dynamic Type scaling; kept static so layout
    /// pins can verify the compact/regular pair without rendering.
    static let regularBaseDiameter: CGFloat = 88
    static let compactBaseDiameter: CGFloat = 44

    /// Outer ring width stays ~4.5% of the diameter at any scale, matching
    /// the shipped 4pt at 88 and 2pt at 44.
    static func outerLineWidth(forDiameter diameter: CGFloat) -> CGFloat {
        diameter * 0.045
    }

    /// Inner ring width stays ~9% of the diameter, matching the shipped
    /// 8pt at 88 and 4pt at 44.
    static func innerLineWidth(forDiameter diameter: CGFloat) -> CGFloat {
        diameter * 0.09
    }

    /// Inner ring inset stays ~9% of the diameter, matching the shipped
    /// 8pt at 88 and 4pt at 44.
    static func ringPadding(forDiameter diameter: CGFloat) -> CGFloat {
        diameter * 0.09
    }

    var compact = false

    private var diameter: CGFloat {
        compact ? compactDiameter : regularDiameter
    }

    var body: some View {
        let diameter = diameter
        ZStack {
            Circle().fill(PomodoroughTheme.ticket)
            Circle().stroke(PomodoroughTheme.porcelain, lineWidth: Self.outerLineWidth(forDiameter: diameter))
            Circle().stroke(PomodoroughTheme.platform, lineWidth: Self.innerLineWidth(forDiameter: diameter))
                .padding(Self.ringPadding(forDiameter: diameter))
            Text("P")
                .font(.system(size: compact ? compactFontSize : regularFontSize, weight: .black, design: .rounded))
                .foregroundStyle(PomodoroughTheme.platform)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    RouteClockMark()
        .padding()
}
#endif
