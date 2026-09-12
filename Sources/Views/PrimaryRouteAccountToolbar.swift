import SwiftUI

struct SyncToolbarBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PrimaryRouteAccountToolbar: ViewModifier {
    let model: AppModel
    @State private var showsAccount = false

    func body(content: Content) -> some View {
#if os(iOS)
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SyncToolbarStatus(model: model)
                        .background {
                            GeometryReader { geometry in
                                // Glass toolbar backgrounds extend four points beyond the button.
                                Color.clear.preference(
                                    key: SyncToolbarBottomPreferenceKey.self,
                                    value: geometry.frame(in: .global).maxY + toolbarBackgroundInset
                                )
                            }
                        }
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

    private var toolbarBackgroundInset: CGFloat {
        if #available(iOS 26, *) { return 4 }
        return 0
    }
}

extension View {
    func primaryRouteAccountToolbar(model: AppModel) -> some View {
        modifier(PrimaryRouteAccountToolbar(model: model))
    }
}
