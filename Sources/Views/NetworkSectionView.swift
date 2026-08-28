import SwiftUI

struct NetworkSectionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var localRoomName = ""
    @State private var localIsCreating = false

    let model: AppModel
    let join: () -> Void
    private let suppliedRoomName: Binding<String>?
    private let suppliedIsCreating: Binding<Bool>?

    init(
        model: AppModel,
        roomName: Binding<String>? = nil,
        isCreating: Binding<Bool>? = nil,
        join: @escaping () -> Void
    ) {
        self.model = model
        self.join = join
        suppliedRoomName = roomName
        suppliedIsCreating = isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modeBoard
            Divider().overlay(PomodoroughTheme.steel.opacity(0.45))
            roomControls
            privacyNote
        }
        .padding(20)
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(PomodoroughTheme.platformDeep.gradient)
                .overlay {
                    RailwayNetworkLines()
                        .clipShape(.rect(cornerRadius: 24))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(PomodoroughTheme.ticket.opacity(0.5), lineWidth: 1.5)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network replication")
        .confirmationDialog(
            "Leave this Iroh room?",
            isPresented: Binding(
                get: { model.isIrohRoomLeaveConfirmationPresented },
                set: { if !$0 { model.cancelIrohRoomLeave() } }
            )
        ) {
            Button("Leave room", role: .destructive) {
                Task { await model.confirmIrohRoomLeave() }
            }
            Button("Cancel", role: .cancel) { model.cancelIrohRoomLeave() }
        } message: {
            Text("Leaving restores the workspace you used before joining. The room's retained operation log stays saved on this device so you can return later.")
        }
    }

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { headerContent }
            } else {
                HStack(spacing: 14) { headerContent }
            }
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        ZStack {
            Circle().fill(PomodoroughTheme.ticket)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2.bold())
                .foregroundStyle(PomodoroughTheme.platformDeep)
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
            Text("NETWORK SWITCHBOARD")
                .font(.caption.monospaced().bold())
                .tracking(1.2)
                .foregroundStyle(PomodoroughTheme.ticket)
            Text("Choose one replication line")
                .font(.title3.bold())
            Text("Timer stays usable and saved on this device in every mode.")
                .font(.subheadline)
                .foregroundStyle(PomodoroughTheme.sky)
        }
    }

    private var modeBoard: some View {
        VStack(spacing: 8) {
            modeButton(
                .offline,
                symbol: "iphone",
                detail: "No remote endpoint. Local work continues."
            )
            modeButton(
                .iroh,
                symbol: "point.3.filled.connected.trianglepath.dotted",
                detail: model.hasIrohRoom
                    ? "Equal-peer room. No Pomodorough server required."
                    : "Create or join a room before selecting this line."
            )
            modeButton(
                .centralized,
                symbol: "cloud",
                detail: model.isSignedIn
                    ? "Existing HTTPS account synchronization."
                    : "Sign in with Google to use cloud synchronization."
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Replication mode")
    }

    private func modeButton(
        _ mode: ReplicationMode,
        symbol: String,
        detail: String
    ) -> some View {
        let selected = model.replicationMode == mode
        return Button {
            Task { await model.setReplicationMode(mode) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.headline)
                    .frame(width: 24)
                    .foregroundStyle(selected ? PomodoroughTheme.platformDeep : PomodoroughTheme.ticket)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(selected ? PomodoroughTheme.platform : PomodoroughTheme.sky)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PomodoroughTheme.platform)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? PomodoroughTheme.platformDeep : PomodoroughTheme.porcelain)
            .background(
                selected ? PomodoroughTheme.ticket : PomodoroughTheme.platform.opacity(0.72),
                in: .rect(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .disabled(mode == .iroh && !model.hasIrohRoom)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(detail)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selected)
    }

    private var roomName: Binding<String> {
        suppliedRoomName ?? $localRoomName
    }

    private var isCreating: Binding<Bool> {
        suppliedIsCreating ?? $localIsCreating
    }

    @ViewBuilder
    private var roomControls: some View {
        if let room = model.preferredRoom {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.roomName ?? "Unnamed room")
                            .font(.headline)
                        Text("ROOM \(String(room.roomID.prefix(8)).uppercased())")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(PomodoroughTheme.steel)
                    }
                    Spacer()
                    Text(model.replicationMode == .iroh ? model.irohStatusLabel : "Saved")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(room.conflict == nil ? PomodoroughTheme.mint : PomodoroughTheme.signal)
                }
                HStack(spacing: 18) {
                    Label("\(room.peerCount) peers", systemImage: "person.2")
                    Label("\(room.operationCount) records", systemImage: "tray.full")
                }
                .font(.caption)
                .foregroundStyle(PomodoroughTheme.sky)
                if room.conflict != nil {
                    Label("Immutable-ID conflict. Iroh sync is stopped; rotate to a new room to repair.", systemImage: "exclamationmark.octagon.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PomodoroughTheme.signal)
                    TextField("Replacement room name (optional)", text: roomName)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(PomodoroughTheme.track)
                    Button {
                        isCreating.wrappedValue = true
                        Task {
                            _ = await model.createIrohRoom(name: roomName.wrappedValue)
                            isCreating.wrappedValue = false
                        }
                    } label: {
                        Label(isCreating.wrappedValue ? "Rotating room" : "Create replacement room", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating.wrappedValue || roomName.wrappedValue.unicodeScalars.count > 64)
                } else if model.replicationMode == .iroh {
                    Button("Create invite", systemImage: "ticket") {
                        Task { await model.refreshIrohInvite() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PomodoroughTheme.ticket)
                    .foregroundStyle(PomodoroughTheme.platformDeep)
                }
                if let invite = model.roomInvite {
                    invitePanel(invite)
                }
                HStack {
                    Button("Join another room", systemImage: "arrow.triangle.branch") { join() }
                        .buttonStyle(.bordered)
                    if model.replicationMode == .iroh {
                        Button("Leave room", role: .destructive) {
                            model.requestIrohRoomLeave()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isLeavingIrohRoom)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("OPEN A PEER ROUTE")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(PomodoroughTheme.ticket)
                TextField("Room name (optional)", text: roomName)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(PomodoroughTheme.track)
                    .accessibilityHint("One through 64 characters. Room name is display-only.")
                Button {
                    isCreating.wrappedValue = true
                    Task {
                        _ = await model.createIrohRoom(name: roomName.wrappedValue)
                        isCreating.wrappedValue = false
                    }
                } label: {
                    Label(isCreating.wrappedValue ? "Creating room" : "Create Iroh room", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PomodoroughTheme.ticket)
                .foregroundStyle(PomodoroughTheme.platformDeep)
                .disabled(isCreating.wrappedValue || roomName.wrappedValue.unicodeScalars.count > 64)
                Button("Join with invite", systemImage: "rectangle.and.text.magnifyingglass") { join() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func invitePanel(_ invite: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROOM INVITE")
                .font(.caption2.monospaced().bold())
                .foregroundStyle(PomodoroughTheme.ticket)
            Text(invite)
                .font(.caption.monospaced())
                .lineLimit(3)
                .textSelection(.enabled)
                .foregroundStyle(PomodoroughTheme.sky)
            ShareLink(item: invite) {
                Label("Share invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Invite grants full read and write access to this room")
        }
        .padding(12)
        .background(PomodoroughTheme.track.opacity(0.58), in: .rect(cornerRadius: 12))
    }

    private var privacyNote: some View {
        Label {
            Text("Peers may see each other's IP addresses. Relays keep content encrypted but can observe endpoint IDs, addresses, timing, and traffic volume. Anyone with an invite has full room access; v1 has no member revocation.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .foregroundStyle(PomodoroughTheme.ticket)
        }
        .foregroundStyle(PomodoroughTheme.sky)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview {
    NetworkSectionView(model: AppModel.preview(.local), join: {})
        .padding()
}
#endif
