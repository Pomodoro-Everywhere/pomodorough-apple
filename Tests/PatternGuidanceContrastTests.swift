import SwiftUI
import Testing
@testable import Pomodorough

// Pins the R50-U01 decision: the Pattern active-timer guidance uses a
// fill-derived foreground on the opaque system-background card, not the
// fixed vivid signal. Vivid on white is the 2.98:1 baseline failure.
@Suite("Pattern guidance contrast")
struct PatternGuidanceContrastTests {
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

    @Test func guidanceFillIsSystemBackground() {
        #expect(PomodoroughTheme.patternGuidanceFillSRGB(for: .light) == (red: 1.0, green: 1.0, blue: 1.0))
        #expect(PomodoroughTheme.patternGuidanceFillSRGB(for: .dark) == (red: 0.0, green: 0.0, blue: 0.0))
    }

    @Test func guidanceDerivesFromFill() {
        #expect(PomodoroughTheme.patternGuidanceSRGB(for: .light) == PomodoroughTheme.signalTextLightRGB)
        #expect(PomodoroughTheme.patternGuidanceSRGB(for: .dark) == PomodoroughTheme.signalSRGB)
    }

    @Test func guidanceClearsAAInBothAppearances() {
        for appearance in [PomodoroughTheme.Appearance.light, .dark] {
            let label = PomodoroughTheme.patternGuidanceSRGB(for: appearance)
            let fill = PomodoroughTheme.patternGuidanceFillSRGB(for: appearance)
            #expect(ratio(label: label, fill: fill) >= 4.5)
        }
    }

    @Test func vividOnWhiteIsBaselineFailure() {
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        #expect(ratio(label: PomodoroughTheme.signalSRGB, fill: white) < 4.5)
        #expect(abs(ratio(label: PomodoroughTheme.signalSRGB, fill: white) - 2.98378) < 0.01)
        #expect(ratio(label: PomodoroughTheme.patternGuidanceSRGB(for: .light), fill: white) >= 4.5)
        #expect(abs(ratio(label: PomodoroughTheme.patternGuidanceSRGB(for: .light), fill: white) - 7.05289) < 0.01)
    }
}
