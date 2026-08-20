import SwiftUI

enum TimerLayout: Equatable {
    case portrait
    case landscape

    init(size: CGSize, usesAccessibleLayout: Bool = false) {
#if os(iOS)
        self = size.width > size.height && !usesAccessibleLayout ? .landscape : .portrait
#else
        self = .landscape
#endif
    }
}
