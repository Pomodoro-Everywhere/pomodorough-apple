import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// IOS27-08: secondary text with a pinned, opaque colour. The system
// `.secondary` label is translucent grey (60, 60, 67 at 60%), which lands
// at about 3.4:1 on white cards and lower on the sky and mint backdrop.
// These values clear 4.5:1 on every fill the secondary text sits on.
extension PomodoroughTheme {
    /// Light appearance: about 9.1:1 on white, 8.2:1 on grouped grey
    /// (242, 242, 247), and above 5:1 on the mint backdrop and its
    /// signal band.
    static let secondaryTextLightSRGB = (red: 72.0 / 255, green: 72.0 / 255, blue: 76.0 / 255)
    /// Dark appearance: about 8.9:1 on black, 5.9:1 on the grouped cell
    /// fill (44, 44, 46), and above 5:1 on the night backdrop.
    static let secondaryTextDarkSRGB = (red: 168.0 / 255, green: 168.0 / 255, blue: 174.0 / 255)

    static func secondaryTextSRGB(
        for appearance: Appearance
    ) -> (red: Double, green: Double, blue: Double) {
        switch appearance {
        case .light: secondaryTextLightSRGB
        case .dark: secondaryTextDarkSRGB
        }
    }

    /// Light-appearance secondary text for surfaces that stay light in
    /// both appearances, such as the porcelain invite field.
    static let secondaryTextOnLightSurface = Color(
        red: secondaryTextLightSRGB.red,
        green: secondaryTextLightSRGB.green,
        blue: secondaryTextLightSRGB.blue
    )

    /// Secondary text that follows the appearance.
    static var secondaryText: Color {
#if os(iOS)
        Color(UIColor { traits in
            let appearance: Appearance = traits.userInterfaceStyle == .dark ? .dark : .light
            let text = secondaryTextSRGB(for: appearance)
            return UIColor(red: text.red, green: text.green, blue: text.blue, alpha: 1)
        })
#elseif os(macOS)
        Color(NSColor(name: nil) { appearance in
            let resolved: Appearance =
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            let text = secondaryTextSRGB(for: resolved)
            return NSColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: 1)
        })
#endif
    }
}
