import SwiftUI

extension View {
    @ViewBuilder
    func timerChromeHidden(_ hidden: Bool) -> some View {
#if os(iOS)
        toolbar(hidden ? .hidden : .visible, for: .navigationBar)
            .toolbar(hidden ? .hidden : .visible, for: .tabBar)
#else
        self
#endif
    }

    @ViewBuilder
    func inlineNavigationTitleIfSupported() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    func digitalReadoutPanel(cornerRadius: CGFloat) -> some View {
        background(PomodoroughTheme.track, in: .rect(cornerRadius: cornerRadius))
    }
}
