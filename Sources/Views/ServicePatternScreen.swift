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
#if os(macOS)
                VStack(alignment: .leading, spacing: 8) {
                    MenuBarTimerPicker()
                    Text("Total includes today’s completed Pomodoros and the current focus session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.background, in: .rect(cornerRadius: 22))
#endif
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
