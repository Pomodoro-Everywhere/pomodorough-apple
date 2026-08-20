import SwiftUI

struct TickMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.48
        for index in 0..<60 {
            let angle = Double(index) * .pi * 2 / 60 - .pi / 2
            let inner = outer - (index.isMultiple(of: 5) ? 12 : 6)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}
