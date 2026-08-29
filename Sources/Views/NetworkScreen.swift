import SwiftUI

struct NetworkScreen: View {
    let model: AppModel
    @State private var showsJoinRoom = false
    private let roomName: Binding<String>?
    private let isCreatingRoom: Binding<Bool>?

    init(
        model: AppModel,
        roomName: Binding<String>? = nil,
        isCreatingRoom: Binding<Bool>? = nil
    ) {
        self.model = model
        self.roomName = roomName
        self.isCreatingRoom = isCreatingRoom
    }

    var body: some View {
        ScrollView {
            NetworkSectionView(
                model: model,
                roomName: roomName,
                isCreating: isCreatingRoom
            ) {
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
