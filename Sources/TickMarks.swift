import SwiftUI

struct TickMarks: Shape {
    /// One tick per minute of the displayed timer.
    var count: Int = 60

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.48
        let total = max(1, count)
        for index in 0..<total {
            let angle = Double(index) * .pi * 2 / Double(total) - .pi / 2
            let inner = outer - (index.isMultiple(of: 5) ? 12 : 6)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}
