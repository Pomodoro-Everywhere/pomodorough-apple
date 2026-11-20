import SwiftUI

/// WCH-02: at the largest text sizes "Pomodorough" is wider than the 40 mm
/// screen, and a freely wrapping Text then breaks it in the middle of the
/// word. Each candidate here breaks only between words; the last one also
/// shrinks until its longest word fits on one line.
struct WatchPhoneUnavailableMessage: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            message("Open Pomodorough\non iPhone", lineCount: 2)
            message("Open\nPomodorough\non iPhone", lineCount: 3)
                .minimumScaleFactor(0.3)
        }
    }

    private func message(_ lines: String, lineCount: Int) -> some View {
        Text(lines)
            .font(.headline)
            .lineLimit(lineCount)
            .multilineTextAlignment(.center)
            .accessibilityLabel("Open Pomodorough on iPhone")
    }
}
