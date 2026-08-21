import SwiftUI

private struct PrimaryRouteAccountToolbar: ViewModifier {
    let model: AppModel
    @State private var showsAccount = false

    func body(content: Content) -> some View {
#if os(iOS)
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SyncToolbarStatus(model: model)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Account", systemImage: "person.crop.circle") {
                        showsAccount = true
                    }
                    .accessibilityValue("\(model.syncLabel); Iroh \(model.irohStatusLabel)")
                    .accessibilityHint("Opens Account. Network controls are inside Account.")
                    .accessibilityActions {
                        if model.isSignedIn && !model.isSyncing && !model.isHistoryResolutionBlocking {
                            Button("Sync now") {
                                Task { await model.sync(force: true) }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showsAccount) {
                AccountView(model: model)
            }
#else
        content
#endif
    }
}

extension View {
    func primaryRouteAccountToolbar(model: AppModel) -> some View {
        modifier(PrimaryRouteAccountToolbar(model: model))
    }
}
