import SwiftUI

struct ConflictBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync needs attention").font(.headline)
                Text(message).font(.subheadline)
            }
            .accessibilityHidden(true)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Sync needs attention. \(message). Dismiss")
        }
        .padding()
        .foregroundStyle(.white)
        .background(PomodoroughTheme.danger, in: .rect(cornerRadius: 16))
    }
}

#if DEBUG
#Preview {
    ConflictBanner(message: "A synchronized change was rejected.", dismiss: {})
        .padding()
}
#endif
