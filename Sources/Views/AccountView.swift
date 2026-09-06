import GoogleSignInSwift
import SwiftUI
import UserNotifications

#if os(iOS)
import AlarmKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AccountView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsSignOut = false
    @State private var confirmsAccountDeletion = false
    @State private var accountDeletionConfirmation = ""
    @State private var timerAlertStatusLabel = String(localized: "Checking…")
    @State private var timerAlertCanEnable = false
    @State private var timerAlertNeedsSettings = false
    @State private var isEnablingTimerAlerts = false

    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
#if os(iOS)
                networkSection
#endif
                completionGuaranteeSection
                identitySection
                if model.hasPendingAccountDeletionRecovery {
                    accountDeletionRecoverySection
                }
                lineStatusSection
                if model.isSignedIn {
                    signOutSection
                    accountManagementSection
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
            .alert("Permanently delete account?", isPresented: $confirmsAccountDeletion) {
                TextField("Type DELETE", text: $accountDeletionConfirmation)
                Button("Delete account", role: .destructive) {
                    let confirmation = accountDeletionConfirmation
                    Task { await model.deleteAccount(confirmation: confirmation) }
                }
                .disabled(accountDeletionConfirmation != "DELETE")
                Button("Cancel", role: .cancel) { accountDeletionConfirmation = "" }
            } message: {
                Text("This permanently deletes your account and cloud data, revokes every session, and removes account data stored by this app on this device. This cannot be undone.")
            }
            .onChange(of: model.historyResolutionState) {
                if model.isHistoryResolutionBlocking { dismiss() }
            }

        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
#endif
    }

    @ViewBuilder
    private var identitySection: some View {
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
                    Text(user.name).accessibilityValue(user.email)
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
                if model.isWorking { ProgressView("Opening Google") }
            } header: {
                Text("On-device mode").accessibilityHidden(true)
            } footer: {
                Text("Sign in only if you want to sync this timer and its history across devices.")
                    .accessibilityHidden(true)
            }
        }
    }

    private var lineStatusSection: some View {
        Section {
            LabeledContent("Sync", value: model.syncLabel)
                .accessibilityRepresentation {
                    Text("Line status")
                        .accessibilityValue(lineStatusAccessibilityValue)
                }
            LabeledContent("Device", value: model.deviceMark)
                .accessibilityHidden(true)
            LabeledContent("Completed focus runs", value: "\(model.completedFocusCount)")
                .accessibilityHidden(true)
            LabeledContent("Iroh", value: model.irohStatusLabel)
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    if model.replicationMode == .iroh {
                        await model.syncIrohNow()
                    } else {
                        await model.sync(force: true)
                    }
                }
            }
            .disabled(syncNowDisabled)
        } header: {
            Text("Line status").accessibilityHidden(true)
        }
    }

    private var lineStatusAccessibilityValue: String {
        "Sync \(model.syncLabel), device \(model.deviceMark), \(model.completedFocusCount) completed focus runs"
    }

    private var syncNowDisabled: Bool {
        model.replicationMode == .offline
            || (model.replicationMode == .centralized && !model.isSignedIn)
            || model.isSyncing
            || model.isHistoryResolutionBlocking
    }

    private var signOutSection: some View {
        Section {
            Button("Sign out", role: .destructive) { confirmsSignOut = true }
                .disabled(model.isWorking)
        } footer: {
            Text("Pending changes are stored on this device until they can sync.")
        }
    }

    private var accountDeletionRecoverySection: some View {
        Section {
            Button("Retry account deletion") {
                Task { await model.retryAccountDeletionRecovery() }
            }
            .disabled(model.isWorking)
        } header: {
            Text("Account deletion recovery")
        } footer: {
            Text("Account data remains quarantined until deletion and local cleanup can be confirmed.")
        }
    }

    private var completionGuaranteeSection: some View {
        Section {
            Text("Pomodorough requests an operating-system notification or alarm for timer completion. Delivery requires your authorization and remains subject to the operating system's delivery policy.")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Timer alerts", value: timerAlertStatusLabel)
                .accessibilityIdentifier("account.timer-alerts-status")
            if timerAlertCanEnable {
                Button {
                    isEnablingTimerAlerts = true
                    Task {
                        await model.allowTimerAlerts()
                        await refreshTimerAlertStatus()
                        isEnablingTimerAlerts = false
                    }
                } label: {
                    if isEnablingTimerAlerts {
                        ProgressView("Enabling timer alerts")
                    } else {
                        Label("Enable timer alerts", systemImage: "bell.badge.fill")
                    }
                }
                .disabled(isEnablingTimerAlerts)
                .accessibilityIdentifier("account.timer-alerts-enable")
            }
            if timerAlertNeedsSettings {
                Button {
                    openTimerAlertSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .accessibilityIdentifier("account.timer-alerts-settings")
                .accessibilityHint("Opens system settings to re-enable timer alerts after denial.")
            }
        } header: {
            Text("Timer alert limits")
                .accessibilityIdentifier("account.timer-alert-limits")
        }
        .task { await refreshTimerAlertStatus() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refreshTimerAlertStatus() }
            }
        }
    }

    private func refreshTimerAlertStatus() async {
        let notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        var alarmState: AlarmAuthorizationProbe = .unavailable
#if os(iOS)
        if #available(iOS 26.0, *) {
            alarmState = AlarmAuthorizationProbe.current()
        }
#endif
        applyTimerAlertPresentation(timerAlertPresentation(notification: notificationStatus, alarm: alarmState))
    }

    private func applyTimerAlertPresentation(_ presentation: TimerAlertPresentation) {
        switch presentation.state {
        case .on:
            timerAlertStatusLabel = String(localized: "On")
        case .off:
            timerAlertStatusLabel = String(localized: "Off")
        case .notEnabled:
            timerAlertStatusLabel = String(localized: "Not enabled")
        case .limited:
            timerAlertStatusLabel = String(localized: "Limited")
        }
        timerAlertCanEnable = presentation.canEnable
        timerAlertNeedsSettings = presentation.needsSettings
    }

    private func openTimerAlertSettings() {
#if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { _ = await UIApplication.shared.open(url) }
#elseif os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
#endif
    }

    private var networkSection: some View {
        Section {
            NavigationLink {
                NetworkScreen(model: model)
            } label: {
                LabeledContent("Network", value: networkSummary)
            }
            .accessibilityLabel("Network")
            .accessibilityValue(networkSummary)
            .accessibilityHint("Opens cloud synchronization and Iroh room controls.")
        }
    }

    private var networkSummary: String {
        String(localized: "\(model.syncLabel); Iroh \(model.irohStatusLabel)")
    }

    private var accountManagementSection: some View {
        Section {
            Link("Privacy policy", destination: URL(string: "https://pomodorough.egigoka.me/privacy")!)
            Button("Delete account", role: .destructive) {
                accountDeletionConfirmation = ""
                confirmsAccountDeletion = true
            }
            .disabled(model.isWorking)
        } header: {
            Text("Privacy and account")
        } footer: {
            Text("Account deletion permanently removes your cloud timer, task, history, and session data. Type DELETE to confirm.")
        }
    }
}

#if DEBUG
#Preview {
    AccountView(model: AppModel.preview(.signedIn))
}
#endif
