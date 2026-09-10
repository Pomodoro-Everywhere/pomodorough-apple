import SwiftUI

struct TimerScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let layout = TimerLayout(
                size: geometry.size,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )

            ZStack {
                if layout == .landscape {
                    // Scroll recovery: landscape height on small phones can
                    // be shorter than the card, so content scrolls instead
                    // of extending past the visible area.
                    ScrollView {
                        VStack(spacing: 10) {
                            if let conflict = model.conflictMessage {
                                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                            }
                            TimerMachineCard(model: model, layout: layout)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .timerChromeHidden(true)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            if let conflict = model.conflictMessage {
                                ConflictBanner(message: conflict, dismiss: model.dismissConflict)
                            }
                            TimerMachineCard(model: model, layout: layout)
                        }
                        .padding()
                        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 96 : 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .timerChromeHidden(false)
                }
            }
            .animation(reduceMotion ? nil : .default, value: layout)
        }
        .background(TimerBackdrop())
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Timer" : "Pomodorough")
        .inlineNavigationTitleIfSupported()
        .refreshable { await model.refreshForPull() }
        .primaryRouteAccountToolbar(model: model)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TimerScreen(model: AppModel.preview(.running))
    }
}
#endif
