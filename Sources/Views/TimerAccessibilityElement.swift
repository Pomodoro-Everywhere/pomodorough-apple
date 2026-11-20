import SwiftUI

/// Turns the visible phase title and countdown of a dial face into the one
/// VoiceOver element for the timer. The element keeps the frame of the
/// readout it is applied to, so touch exploration on the digits reads the
/// timer (IOS27-09). A substitute accessibility representation took its
/// intrinsic text size instead and sat in a corner of the dial.
struct TimerAccessibilityElement: ViewModifier {
    let phase: TimerPhase
    let status: String
    let timeText: String

    /// UITest probe flag. Production never sets POMODOROUGH_UI_TEST_DIAL.
    /// Probe runs keep the readout's children so XCTest can measure the
    /// rendered countdown digits and phase label.
    static var showsDigitProbe: Bool {
        ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_DIAL"] == "1"
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if Self.showsDigitProbe {
            content
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(phase.title) timer"))
                .accessibilityValue(Text("\(timeText) remaining, \(status)"))
        }
    }
}

extension View {
    func timerAccessibilityElement(phase: TimerPhase, status: String, timeText: String) -> some View {
        modifier(TimerAccessibilityElement(phase: phase, status: status, timeText: timeText))
    }
}

#if DEBUG
#Preview {
    Text("17:00")
        .timerAccessibilityElement(phase: .focus, status: "Running", timeText: "17:00")
        .padding()
}
#endif
