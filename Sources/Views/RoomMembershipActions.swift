import SwiftUI

/// Join and Leave for the current room. The pair shares a row only when
/// both labels fit on one line each; at 375 pt "Join another room" wrapped
/// beside "Leave room" (IOS18-06), so the buttons stack instead.
/// Accessibility sizes always stack.
struct RoomMembershipActions: View {
    let canLeave: Bool
    let isLeaving: Bool
    let join: @MainActor () -> Void
    let leave: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack { buttons }
            }
            VStack(alignment: .leading, spacing: 12) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Join another room", systemImage: "arrow.triangle.branch", action: join)
            .buttonStyle(.bordered)
        if canLeave {
            Button("Leave room", role: .destructive, action: leave)
                .buttonStyle(.bordered)
                .disabled(isLeaving)
        }
    }
}

#if DEBUG
#Preview {
    RoomMembershipActions(canLeave: true, isLeaving: false, join: {}, leave: {})
        .padding()
}
#endif
