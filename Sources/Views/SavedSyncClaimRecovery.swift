import SwiftUI

struct SavedSyncClaimRecovery: View {
    let model: AppModel
    @State private var confirmsRecovery = false

    var body: some View {
        Button("Recover saved sync request") { confirmsRecovery = true }
            .disabled(model.isWorking)
            .accessibilityIdentifier("account.saved-sync-recovery")
            .confirmationDialog("Create a new sync request?", isPresented: $confirmsRecovery) {
                Button("Keep changes and recover") {
                    if model.recoverOversizedSavedSyncClaim(confirmed: true) {
                        Task { await model.sync(force: true) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The saved request exceeds the server limit. Recovery keeps every queued change and its identity, then creates smaller requests. Changes that may have reached the server remain marked as sent.")
            }
    }
}
