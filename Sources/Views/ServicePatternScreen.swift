import SwiftUI

struct ServicePatternScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel

    var body: some View {
        content.navigationTitle("Pattern")
    }

    private var content: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ServicePatternCard(model: model)
#if os(macOS)
                    VStack(alignment: .leading, spacing: 8) {
                        MenuBarTimerPicker()
                        Text("Total includes today’s completed Pomodoros and the current focus session.")
                            .font(.caption)
                            .foregroundStyle(PomodoroughTheme.secondaryText)
                    }
                    .padding(18)
                    .background(.background, in: .rect(cornerRadius: 22))
#endif
                    AppVersionFooter()
                }
                .padding()
                .padding(.bottom, TabBarScrollInset.bottom(
                    safeBottom: proxy.safeAreaInsets.bottom,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ))
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .avoidsDisplayDivisions()
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
