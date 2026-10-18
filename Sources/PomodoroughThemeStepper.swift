import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// R50-U02: duration stepper symbol foreground chosen from its actual
// fill. Kept apart from PomodoroughTheme.swift so the R50-U01 wave
// stays untouched. Non-text threshold is 3:1, not 4.5:1.
extension PomodoroughTheme {
    static let stepperLightFillSRGB = (
        red: 236.0 / 255, green: 236.0 / 255, blue: 237.0 / 255
    )
    static let stepperDarkFillSRGB = (
        red: 30.0 / 255, green: 30.0 / 255, blue: 32.0 / 255
    )

    static func stepperFillSRGB(
        for appearance: Appearance
    ) -> (red: Double, green: Double, blue: Double) {
        switch appearance {
        case .light: stepperLightFillSRGB
        case .dark: stepperDarkFillSRGB
        }
    }

    static func stepperSymbolSRGB(
        onFill fill: (red: Double, green: Double, blue: Double)
    ) -> (red: Double, green: Double, blue: Double) {
        let fillLuminance = relativeLuminance(
            red: fill.red, green: fill.green, blue: fill.blue
        )
        for foreground in [signalSRGB, signalTextLightRGB] {
            let foregroundLuminance = relativeLuminance(
                red: foreground.red, green: foreground.green, blue: foreground.blue
            )
            if contrastRatio(
                lighter: max(fillLuminance, foregroundLuminance),
                darker: min(fillLuminance, foregroundLuminance)
            ) >= 3.0 {
                return foreground
            }
        }
        return secondaryLabelSRGB(forFill: fill)
    }

    static func stepperSymbolSRGB(
        for appearance: Appearance
    ) -> (red: Double, green: Double, blue: Double) {
        stepperSymbolSRGB(onFill: stepperFillSRGB(for: appearance))
    }

    static var stepperSymbol: Color {
#if os(iOS)
        Color(UIColor { traits in
            let appearance: Appearance =
                traits.userInterfaceStyle == .dark ? .dark : .light
            let symbol = stepperSymbolSRGB(for: appearance)
            return UIColor(
                red: symbol.red, green: symbol.green, blue: symbol.blue, alpha: 1
            )
        })
#elseif os(macOS)
        Color(NSColor(name: nil) { appearance in
            let bucket: Appearance =
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark : .light
            let symbol = stepperSymbolSRGB(for: bucket)
            return NSColor(
                srgbRed: symbol.red, green: symbol.green, blue: symbol.blue, alpha: 1
            )
        })
#endif
    }
}
