#if os(iOS)
import SwiftUI

struct LegacyTabs: View {
    let model: AppModel
    @Binding var selection: MainTab

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { TimerScreen(model: model) }
                .tabItem { Label("Timer", systemImage: "timer") }
                .tag(MainTab.timer)
            NavigationStack { TasksScreen(model: model) }
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(MainTab.tasks)
            NavigationStack { ServicePatternScreen(model: model) }
                .tabItem { Label("Pattern", systemImage: "slider.horizontal.3") }
                .tag(MainTab.pattern)
            NavigationStack { HistoryScreen(model: model) }
                .tabItem { Label("Arrivals", systemImage: "clock.arrow.circlepath") }
                .tag(MainTab.history)
        }
        .animation(.default, value: selection)
    }
}

#if DEBUG
#Preview {
    LegacyTabs(model: AppModel.preview(.populated), selection: .constant(.timer))
}
#endif
#endif
