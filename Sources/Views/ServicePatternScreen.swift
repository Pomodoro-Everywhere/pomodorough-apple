import SwiftUI

struct ServicePatternScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    var showsNavigationTitle = true

    @ViewBuilder
    var body: some View {
        if showsNavigationTitle {
            content.navigationTitle("Pattern")
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                ServicePatternCard(model: model)
                AppVersionFooter()
            }
                .padding()
                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 80 : 0)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(TimerBackdrop())
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
