import GoogleSignInSwift
import SwiftUI

struct AccountView: View {
    private enum Sheet: String, Identifiable {
        case joinRoom
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    @State private var presentedSheet: Sheet?
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let user = model.user {
                    Section {
                        HStack(spacing: 14) {
                            AsyncImage(url: URL(string: user.avatarUrl)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill").resizable()
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(.circle)
                            VStack(alignment: .leading) {
                                Text(user.name).font(.headline)
                                Text(user.email).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityRepresentation {
                            Text(user.name)
                                .accessibilityValue(user.email)
                        }
                    }
                } else {
                    Section {
                        Label("Timer works without internet", systemImage: "iphone")
                            .accessibilityLabel("On-device mode")
                            .accessibilityValue("Timer works without internet")
                        GoogleSignInButton(action: model.signIn)
                            .frame(maxWidth: 280)
                            .disabled(model.isWorking)
                            .accessibilityHint("Signs in to sync your timer across devices")
                        if model.isWorking {
                            ProgressView("Opening Google")
                        }
                    } header: {
                        Text("On-device mode")
                            .accessibilityHidden(true)
                    } footer: {
                        Text("Sign in only if you want to sync this timer and its history across devices.")
                            .accessibilityHidden(true)
                    }
                }
                Section {
                    LabeledContent("Sync", value: model.syncLabel)
                        .accessibilityRepresentation {
                            Text("Line status")
                                .accessibilityValue(
                                    "Sync \(model.syncLabel), device \(model.deviceMark), " +
                                        "\(model.completedFocusCount) completed focus runs"
                                )
                        }
                    LabeledContent("Device", value: model.deviceMark)
                        .accessibilityHidden(true)
                    LabeledContent("Completed focus runs", value: "\(model.completedFocusCount)")
                        .accessibilityHidden(true)
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        Task {
                            if model.replicationMode == .iroh {
                                await model.syncIrohNow()
                            } else {
                                await model.sync(force: true)
                            }
                        }
                    }
                    .disabled(
                        model.replicationMode == .offline
                            || (model.replicationMode == .centralized && !model.isSignedIn)
                            || model.isSyncing
                            || model.isHistoryResolutionBlocking
                    )
                } header: {
                    Text("Line status")
                        .accessibilityHidden(true)
                }
                Section {
                    NetworkSectionView(
                        model: model,
                        join: { presentedSheet = .joinRoom }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Network")
                        .accessibilityHidden(true)
                }
                if model.isSignedIn {
                    Section {
                        Button("Sign out", role: .destructive) { confirmsSignOut = true }
                            .disabled(model.isWorking)
                    } footer: {
                        Text("Pending changes are stored on this device until they can sync.")
                    }
                }
            }
            .navigationTitle("Account")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Pomodorough?", isPresented: $confirmsSignOut) {
                Button("Sign out", role: .destructive, action: model.signOut)
                Button("Cancel", role: .cancel) { }
            } message: {
                if model.pendingChangeCount > 0 {
                    Text("This will discard \(model.pendingChangeCount) changes still waiting to sync.")
                } else {
                    Text("Local account and timer data will be removed from this device.")
                }
            }
            .onChange(of: model.historyResolutionState) {
                if model.isHistoryResolutionBlocking { dismiss() }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .joinRoom:
                    JoinIrohRoomView(model: model)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
#endif
    }
}

#if DEBUG
#Preview {
    AccountView(model: AppModel.preview(.signedIn))
}
#endif
