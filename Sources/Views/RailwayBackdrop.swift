import SwiftUI

struct RailwayBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [PomodoroughTheme.platformDeep, PomodoroughTheme.platform], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let color = PomodoroughTheme.porcelain.opacity(0.08)
                for x in stride(from: 0.0, through: size.width, by: 48) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
                for y in stride(from: 0.0, through: size.height, by: 48) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    RailwayBackdrop()
}
#endif
