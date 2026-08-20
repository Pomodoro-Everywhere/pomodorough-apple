import SwiftUI

struct RailwayNetworkLines: View {
    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1, dash: [4, 7])
            for fraction in [0.2, 0.5, 0.8] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addCurve(
                    to: CGPoint(x: size.width, y: size.height * (1 - fraction)),
                    control1: CGPoint(x: size.width * 0.35, y: size.height * fraction),
                    control2: CGPoint(x: size.width * 0.65, y: size.height * (1 - fraction))
                )
                context.stroke(path, with: .color(PomodoroughTheme.sky.opacity(0.08)), style: stroke)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    RailwayNetworkLines()
        .frame(width: 400, height: 240)
}
#endif
