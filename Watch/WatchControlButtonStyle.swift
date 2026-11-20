import SwiftUI

/// WCH-04: the button style draws the 44 pt capsule or circle, so the
/// button's accessibility frame is the whole visible control. With the plain
/// style and the frame on the label (or outside the button), VoiceOver
/// framed only the text or the icon.
struct WatchControlButtonStyle<Fill: ShapeStyle, Outline: Shape>: ButtonStyle {
    let shape: Outline
    let fill: Fill

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .background(fill, in: shape)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
