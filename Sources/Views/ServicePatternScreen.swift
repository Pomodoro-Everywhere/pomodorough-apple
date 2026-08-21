import SwiftUI

struct ServicePatternScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            ServicePatternCard(model: model)
                .padding()
                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 80 : 0)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(TimerBackdrop())
        .navigationTitle("Pattern")
        .inlineNavigationTitleIfSupported()
        .primaryRouteAccountToolbar(model: model)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ServicePatternScreen(model: AppModel.preview(.populated))
    }
}
#endif
