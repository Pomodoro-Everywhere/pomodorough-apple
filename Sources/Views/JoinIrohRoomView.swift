import SwiftUI

struct JoinIrohRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inviteText = ""
    @State private var isJoining = false
    @State private var joinError: String?

    let model: AppModel

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Join room")
            .inlineNavigationTitleIfSupported()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isJoining)
                }
            }
#if os(iOS)
            .interactiveDismissDisabled(isJoining)
#endif
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
#endif
    }

    private var content: some View {
        ZStack {
            RailwayBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    Text("Joining saves your current workspace, downloads the room's fixed genesis and operations, then switches views. Leaving restores your previous workspace unchanged.")
                        .foregroundStyle(PomodoroughTheme.sky)
                        .fixedSize(horizontal: false, vertical: true)
                    inviteField
                    joinButton
                    joinErrorView
                    Text("Invite contains room secret and peer addresses. Treat it as sensitive. Endpoint secret key never leaves this device.")
                        .font(.footnote)
                        .foregroundStyle(PomodoroughTheme.steel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 14) {
            RouteClockMark(compact: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("PEER TRANSFER")
                    .font(.caption.monospaced().bold())
                    .tracking(1.2)
                    .foregroundStyle(PomodoroughTheme.ticket)
                Text("Join an Iroh room")
                    .font(.title.bold())
                    .foregroundStyle(PomodoroughTheme.porcelain)
            }
        }
    }

    private var inviteField: some View {
        TextField("pomodorough1.…", text: $inviteText, axis: .vertical)
            .lineLimit(4...10)
            .font(.callout.monospaced())
            .textFieldStyle(.plain)
            .padding(14)
            .foregroundStyle(PomodoroughTheme.track)
            .background(PomodoroughTheme.porcelain, in: .rect(cornerRadius: 14))
            .accessibilityLabel("Room invite")
            .accessibilityHint("Paste complete invite beginning with pomodorough1 dot")
            .onChange(of: inviteText) { joinError = nil }
    }

    private var joinButton: some View {
        Button {
            isJoining = true
            joinError = nil
            Task {
                if await model.joinIrohRoom(inviteText: inviteText) {
                    dismiss()
                } else if let message = model.errorMessage {
                    // Keep the failure inside the sheet: the global RootView
                    // error alert would displace this sheet and drop the
                    // typed invite (fail-closed join contract).
                    model.errorMessage = nil
                    joinError = message
                }
                isJoining = false
            }
        } label: {
            HStack {
                if isJoining { ProgressView().tint(PomodoroughTheme.platformDeep) }
                Label("Validate and join", systemImage: "arrow.right.circle.fill")
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .font(.headline)
        .foregroundStyle(PomodoroughTheme.platformDeep)
        .background(PomodoroughTheme.ticket, in: .rect(cornerRadius: 14))
        .disabled(isJoining || inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder
    private var joinErrorView: some View {
        if let joinError {
            Text(joinError)
                .font(.footnote)
                .foregroundStyle(PomodoroughTheme.signal)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("Join room error")
        }
    }
}

#if DEBUG
#Preview {
    JoinIrohRoomView(model: AppModel.preview(.local))
}
#endif
