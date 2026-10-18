import SwiftUI
import Testing
@testable import Pomodorough

// Pins the R50-U02 decision: duration stepper symbols use a
// fill-derived foreground on the pale secondary fill, not the fixed
// vivid signal tint. Vivid on the light fill is the 2.53:1 baseline.
@Suite("Stepper symbol contrast")
struct StepperSymbolContrastTests {
    private func ratio(
        symbol: (red: Double, green: Double, blue: Double),
        fill: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let symbolLuminance = PomodoroughTheme.relativeLuminance(
            red: symbol.red, green: symbol.green, blue: symbol.blue
        )
        let fillLuminance = PomodoroughTheme.relativeLuminance(
            red: fill.red, green: fill.green, blue: fill.blue
        )
        return PomodoroughTheme.contrastRatio(
            lighter: max(symbolLuminance, fillLuminance),
            darker: min(symbolLuminance, fillLuminance)
        )
    }

    @Test func stepperFillMatchesMeasuredSurfaces() {
        #expect(PomodoroughTheme.stepperFillSRGB(for: .light)
            == PomodoroughTheme.stepperLightFillSRGB)
        #expect(PomodoroughTheme.stepperFillSRGB(for: .dark)
            == PomodoroughTheme.stepperDarkFillSRGB)
    }

    @Test func stepperDerivesFromFill() {
        #expect(PomodoroughTheme.stepperSymbolSRGB(for: .light)
            == PomodoroughTheme.signalTextLightRGB)
        #expect(PomodoroughTheme.stepperSymbolSRGB(for: .dark)
            == PomodoroughTheme.signalSRGB)
    }

    @Test func stepperClearsNonTextInBothAppearances() {
        for appearance in [PomodoroughTheme.Appearance.light, .dark] {
            let symbol = PomodoroughTheme.stepperSymbolSRGB(for: appearance)
            let fill = PomodoroughTheme.stepperFillSRGB(for: appearance)
            #expect(ratio(symbol: symbol, fill: fill) >= 3.0)
        }
    }

    @Test func vividOnLightFillIsBaselineFailure() {
        let fill = PomodoroughTheme.stepperFillSRGB(for: .light)
        #expect(ratio(symbol: PomodoroughTheme.signalSRGB, fill: fill) < 3.0)
        #expect(abs(ratio(symbol: PomodoroughTheme.signalSRGB, fill: fill)
            - 2.52735) < 0.01)
        #expect(ratio(
            symbol: PomodoroughTheme.stepperSymbolSRGB(for: .light),
            fill: fill
        ) >= 3.0)
        #expect(abs(ratio(
            symbol: PomodoroughTheme.stepperSymbolSRGB(for: .light),
            fill: fill
        ) - 5.97401) < 0.01)
    }

    @Test func stepperFallsBackToSecondaryLabelOnLowContrastFill() {
        let fill = PomodoroughTheme.signalSRGB
        #expect(ratio(symbol: PomodoroughTheme.signalSRGB, fill: fill) < 3.0)
        #expect(ratio(symbol: PomodoroughTheme.signalTextLightRGB, fill: fill) < 3.0)
        #expect(PomodoroughTheme.stepperSymbolSRGB(onFill: fill)
            == PomodoroughTheme.secondaryLabelSRGB(forFill: fill))
        #expect(PomodoroughTheme.stepperSymbolSRGB(onFill: fill) == (red: 0, green: 0, blue: 0))
    }

    @Test @MainActor func stepperKeepsButtonAction() {
        var fired = 0
        let button = StepButton(title: "Increase Focus duration", symbol: "plus") {
            fired += 1
        }
        #expect(button.title == "Increase Focus duration")
        #expect(button.symbol == "plus")
        button.action()
        #expect(fired == 1)
    }

    @Test @MainActor func stepperAccessibleLabelsDistinguishDirection() {
        let reduce = StepButton(title: "Reduce Focus duration", symbol: "minus") {}
        let increase = StepButton(title: "Increase Focus duration", symbol: "plus") {}
        #expect(reduce.title != increase.title)
        #expect(reduce.symbol != increase.symbol)
        #expect(reduce.title.contains("Reduce"))
        #expect(increase.title.contains("Increase"))
    }
}
