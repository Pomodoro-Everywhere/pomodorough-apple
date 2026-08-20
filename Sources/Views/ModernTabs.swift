#if os(iOS)
import SwiftUI

@available(iOS 18, *)
struct ModernTabs: View {
    let model: AppModel
    @Binding var selection: MainTab

    var body: some View {
        TabView(selection: $selection) {
            Tab("Timer", systemImage: "timer", value: MainTab.timer) {
                NavigationStack { TimerScreen(model: model) }
            }
            Tab("Tasks", systemImage: "checklist", value: MainTab.tasks) {
                NavigationStack { TasksScreen(model: model) }
            }
            Tab("Pattern", systemImage: "slider.horizontal.3", value: MainTab.pattern) {
                NavigationStack { ServicePatternScreen(model: model) }
            }
            Tab("Arrivals", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", value: MainTab.history) {
                NavigationStack { HistoryScreen(model: model) }
            }
        }
        .animation(.default, value: selection)
    }
}

#if DEBUG
@available(iOS 18, *)
#Preview {
    ModernTabs(model: AppModel.preview(.populated), selection: .constant(.timer))
}
#endif
#endif
