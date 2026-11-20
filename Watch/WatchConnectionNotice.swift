import SwiftUI

/// WCH-03: says in words, not only in color, that the iPhone is out of reach,
/// so the timer below is the last synced one and may no longer match the
/// phone. It replaces a 5 pt grey dot that was the only cue.
struct WatchConnectionNotice: View {
    var body: some View {
        Label("Not connected", systemImage: "iphone.slash")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("iPhone unreachable, showing last synced timer")
    }
}
