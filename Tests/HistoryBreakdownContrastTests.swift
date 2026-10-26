import SwiftUI
import Testing
@testable import Pomodorough

// Pins the R52-U01 decision: the Arrivals breakdown toolbar link uses the
// opaque fill-derived signalText foreground, not hierarchical `.secondary`.
// Under the root signal tint, `.secondary` renders signal at secondary
// opacity (#ffafa7), which is the 1.76:1 baseline failure on white.
@Suite("History breakdown contrast")
struct HistoryBreakdownContrastTests {
    private func ratio(
        label: (red: Double, green: Double, blue: Double),
        fill: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let labelLuminance = PomodoroughTheme.relativeLuminance(red: label.red, green: label.green, blue: label.blue)
        let fillLuminance = PomodoroughTheme.relativeLuminance(red: fill.red, green: fill.green, blue: fill.blue)
        return PomodoroughTheme.contrastRatio(
            lighter: max(labelLuminance, fillLuminance),
            darker: min(labelLuminance, fillLuminance)
        )
    }

    @Test func reportedGlyphOnWhiteIsBaselineFailure() {
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let glyph = (red: 255.0 / 255, green: 175.0 / 255, blue: 167.0 / 255)
        #expect(ratio(label: glyph, fill: white) < 4.5)
        #expect(abs(ratio(label: glyph, fill: white) - 1.75850) < 0.01)
    }

    @Test func repairDerivesFromFill() {
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let black = (red: 0.0, green: 0.0, blue: 0.0)
        #expect(PomodoroughTheme.signalTextSRGB(onFill: white) == PomodoroughTheme.signalTextLightRGB)
        #expect(PomodoroughTheme.signalTextSRGB(onFill: black) == PomodoroughTheme.signalSRGB)
    }

    @Test func repairClearsAAInBothAppearances() {
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let black = (red: 0.0, green: 0.0, blue: 0.0)
        #expect(ratio(label: PomodoroughTheme.signalTextSRGB(onFill: white), fill: white) >= 4.5)
        #expect(abs(ratio(label: PomodoroughTheme.signalTextSRGB(onFill: white), fill: white) - 7.05289) < 0.01)
        #expect(ratio(label: PomodoroughTheme.signalTextSRGB(onFill: black), fill: black) >= 4.5)
        #expect(abs(ratio(label: PomodoroughTheme.signalTextSRGB(onFill: black), fill: black) - 7.03805) < 0.01)
    }

    // R52-U01 view pin: the label carries the opaque signalText Color, not
    // hierarchical `.secondary`. Reverting the view fix leaves no Color in
    // the style chain, so the require fails; a wrong opaque color fails the
    // resolved sRGB and contrast pins below.
    @Test @MainActor func breakdownLabelResolvesToSignalTextFill() throws {
        let screen = HistoryScreen(model: AppModel.preview(.populated))
        let foreground = try #require(Self.foregroundColor(in: screen.completedFocusBreakdownLabel))
        var lightEnvironment = EnvironmentValues()
        lightEnvironment.colorScheme = .light
        var darkEnvironment = EnvironmentValues()
        darkEnvironment.colorScheme = .dark
        let light = foreground.resolve(in: lightEnvironment)
        let dark = foreground.resolve(in: darkEnvironment)
        #expect(abs(Double(light.red) - PomodoroughTheme.signalTextLightRGB.red) < 0.01)
        #expect(abs(Double(light.green) - PomodoroughTheme.signalTextLightRGB.green) < 0.01)
        #expect(abs(Double(light.blue) - PomodoroughTheme.signalTextLightRGB.blue) < 0.01)
        #expect(abs(Double(dark.red) - PomodoroughTheme.signalSRGB.red) < 0.01)
        #expect(abs(Double(dark.green) - PomodoroughTheme.signalSRGB.green) < 0.01)
        #expect(abs(Double(dark.blue) - PomodoroughTheme.signalSRGB.blue) < 0.01)
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let black = (red: 0.0, green: 0.0, blue: 0.0)
        let lightSRGB = (red: Double(light.red), green: Double(light.green), blue: Double(light.blue))
        let darkSRGB = (red: Double(dark.red), green: Double(dark.green), blue: Double(dark.blue))
        #expect(ratio(label: lightSRGB, fill: white) >= 4.5)
        #expect(ratio(label: darkSRGB, fill: black) >= 4.5)
    }

    private static func foregroundColor(in view: Any) -> Color? {
        var stack: [Any] = [view]
        while let current = stack.popLast() {
            if let color = current as? Color { return color }
            for child in Mirror(reflecting: current).children {
                stack.append(child.value)
            }
        }
        return nil
    }
}
