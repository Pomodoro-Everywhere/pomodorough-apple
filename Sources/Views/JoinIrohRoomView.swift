import SwiftUI

struct JoinIrohRoomView: View {
    @Environment(\.dismiss) private var dismiss
    // Test seam: DEBUG UI tests prefill the invite without focusing the
    // field. Unresolved hypothesis: focusing a field may hang the main
    // thread in a layout loop on narrow (SE-width) simulators; requires
    // physical-SE verification and an Apple Feedback filing before
    // asserting as fact, so the failed-join regression is exercised
    // without summoning the keyboard.
    @State private var inviteText: String = {
#if DEBUG
        ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_INVITE"] ?? ""
#else
        ""
#endif
    }()
    @State private var isJoining = false
    @State private var joinError: String?

    let model: AppModel

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Join room")
            .inlineNavigationTitleIfSupported()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { cancelButton }
            }
#if os(iOS)
            .interactiveDismissDisabled(isJoining)
#endif
        }
#if os(iOS)
        // IOS27-02: the sheet always draws the navy railway backdrop, so the
        // bar uses the dark scheme in both appearances. In light mode the
        // system title was black on navy (about 1.3:1).
        .environment(\.colorScheme, .dark)
#endif
        .modifier(ErrorMessageAlert(model: model, host: .joinRoomSheet))
#if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
#endif
    }

    private var cancelButton: some View {
        Button { dismiss() } label: {
#if os(iOS)
            // IOS27-02: the accent tint is 3.7:1 on the navy bar glass.
            Text("Cancel")
                .foregroundStyle(PomodoroughTheme.porcelain.opacity(isJoining ? 0.4 : 1))
#else
            Text("Cancel")
#endif
        }
        .disabled(isJoining)
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
                    Text("Invite contains room secret and peer addresses. Treat it as sensitive. Endpoint secret key never leaves this device.")
                        .font(.footnote)
                        .foregroundStyle(PomodoroughTheme.steel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            // IOS18-06: the invite field grows to ten lines, which pushed
            // "Validate and join" under the keyboard. A bottom inset rides
            // the keyboard's safe area, so the action stays visible.
            .safeAreaInset(edge: .bottom, spacing: 0) { joinActions }
        }
    }

    private var joinActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            joinButton
            joinErrorView
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        // Matches the bottom of RailwayBackdrop, so scrolled text never
        // shows through the action.
        .background(PomodoroughTheme.platform)
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
        TextField("pomodorough1.…", text: $inviteText, prompt: invitePrompt, axis: .vertical)
            .lineLimit(4...10)
            .font(.callout.monospaced())
            .textFieldStyle(.plain)
            .padding(14)
            .foregroundStyle(PomodoroughTheme.track)
            .background(PomodoroughTheme.porcelain, in: .rect(cornerRadius: 14))
            .accessibilityLabel("Room invite")
            .accessibilityHint("Paste complete invite beginning with pomodorough1 dot")
#if os(iOS)
            // IOS27-10: an invite is an exact token; capitals or spelling
            // fixes would corrupt it.
            .textInputAutocapitalization(.never)
#endif
            .autocorrectionDisabled()
            .onChange(of: inviteText) { joinError = nil }
    }

    /// IOS27-08: the field stays porcelain in both appearances, so the
    /// placeholder uses the light-surface grey (about 8.5:1) instead of the
    /// system placeholder (about 1.7:1).
    private var invitePrompt: Text {
        Text("pomodorough1.…").foregroundStyle(PomodoroughTheme.secondaryTextOnLightSurface)
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
