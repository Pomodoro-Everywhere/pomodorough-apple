import SwiftUI
import Testing
@testable import Pomodorough

// Pins the IOS27-08 decision: secondary text uses an opaque, appearance-
// pinned grey instead of the translucent system `.secondary`, which
// measured 2.27:1 to 4.0:1 on the app's cards and backdrops.
@Suite("Secondary text contrast")
struct SecondaryTextContrastTests {
    typealias RGB = (red: Double, green: Double, blue: Double)

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> RGB {
        (red: red / 255, green: green / 255, blue: blue / 255)
    }

    /// Light fills: white card, grouped grey, porcelain field, sky
    /// backdrop, and the mint backdrop under the 20% signal band.
    static let lightFills: [RGB] = [
        rgb(255, 255, 255), rgb(242, 242, 247), PomodoroughTheme.porcelainSRGB,
        PomodoroughTheme.skySRGB, rgb(198, 198, 185),
    ]

    /// Dark fills: black card, grouped cells, night surface, and the night
    /// surface under the 14% signal band.
    static let darkFills: [RGB] = [
        rgb(0, 0, 0), rgb(28, 28, 30), rgb(44, 44, 46), rgb(23, 36, 48), rgb(56, 44, 52),
    ]

    private func ratio(_ label: RGB, _ fill: RGB) -> Double {
        let labelLuminance = PomodoroughTheme.relativeLuminance(red: label.red, green: label.green, blue: label.blue)
        let fillLuminance = PomodoroughTheme.relativeLuminance(red: fill.red, green: fill.green, blue: fill.blue)
        return PomodoroughTheme.contrastRatio(
            lighter: max(labelLuminance, fillLuminance),
            darker: min(labelLuminance, fillLuminance)
        )
    }

    @Test func systemSecondaryOnWhiteIsBaselineFailure() {
        // `.secondary` (60, 60, 67) at 60% over white composites to
        // (138, 138, 143), the 3.44:1 grey the audit measured.
        let composite = Self.rgb(138, 138, 143)
        #expect(abs(ratio(composite, Self.rgb(255, 255, 255)) - 3.44) < 0.05)
    }

    @Test func secondaryTextClearsAAOnEveryLightFill() {
        let text = PomodoroughTheme.secondaryTextSRGB(for: .light)
        for fill in Self.lightFills {
            #expect(ratio(text, fill) >= 4.5, "light fill \(fill)")
        }
        #expect(abs(ratio(text, Self.rgb(255, 255, 255)) - 9.10) < 0.05)
    }

    @Test func secondaryTextClearsAAOnEveryDarkFill() {
        let text = PomodoroughTheme.secondaryTextSRGB(for: .dark)
        for fill in Self.darkFills {
            #expect(ratio(text, fill) >= 4.5, "dark fill \(fill)")
        }
        #expect(abs(ratio(text, Self.rgb(44, 44, 46)) - 5.89) < 0.05)
    }

    @Test @MainActor func dynamicColorResolvesToPinnedValues() {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        let resolvedLight = PomodoroughTheme.secondaryText.resolve(in: light)
        let resolvedDark = PomodoroughTheme.secondaryText.resolve(in: dark)
        #expect(abs(Double(resolvedLight.red) - PomodoroughTheme.secondaryTextLightSRGB.red) < 0.01)
        #expect(abs(Double(resolvedLight.blue) - PomodoroughTheme.secondaryTextLightSRGB.blue) < 0.01)
        #expect(abs(Double(resolvedDark.red) - PomodoroughTheme.secondaryTextDarkSRGB.red) < 0.01)
        #expect(abs(Double(resolvedDark.blue) - PomodoroughTheme.secondaryTextDarkSRGB.blue) < 0.01)
    }
}
