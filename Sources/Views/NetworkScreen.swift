import SwiftUI

struct NetworkScreen: View {
    let model: AppModel
    @State private var showsJoinRoom = false

    var body: some View {
        ScrollView {
            NetworkSectionView(model: model) {
                showsJoinRoom = true
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(TimerBackdrop())
        .navigationTitle("Network")
        .inlineNavigationTitleIfSupported()
        .sheet(isPresented: $showsJoinRoom) {
            JoinIrohRoomView(model: model)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        NetworkScreen(model: AppModel.preview(.signedIn))
    }
}
#endif
