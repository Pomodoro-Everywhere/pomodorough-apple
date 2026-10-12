import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PomodoroughTheme {
    // sRGB components double as the contrast-audit source, so the
    // shipped Colors below cannot drift from the pinned values.
    static let platformSRGB = (red: 20.0 / 255, green: 44.0 / 255, blue: 92.0 / 255)
    static let platformDeepSRGB = (red: 12.0 / 255, green: 27.0 / 255, blue: 57.0 / 255)
    static let porcelainSRGB = (red: 247.0 / 255, green: 248.0 / 255, blue: 242.0 / 255)
    static let steelSRGB = (red: 143.0 / 255, green: 168.0 / 255, blue: 184.0 / 255)
    static let dangerSRGB = (red: 195.0 / 255, green: 61.0 / 255, blue: 56.0 / 255)
    static let platform = Color(red: platformSRGB.red, green: platformSRGB.green, blue: platformSRGB.blue)
    static let platformDeep = Color(red: platformDeepSRGB.red, green: platformDeepSRGB.green, blue: platformDeepSRGB.blue)
    static let signalSRGB = (red: 255.0 / 255, green: 96.0 / 255, blue: 79.0 / 255)
    static let mintSRGB = (red: 168.0 / 255, green: 217.0 / 255, blue: 203.0 / 255)
    static let ticketSRGB = (red: 245.0 / 255, green: 208.0 / 255, blue: 91.0 / 255)
    static let signal = Color(red: signalSRGB.red, green: signalSRGB.green, blue: signalSRGB.blue)
    static let ticket = Color(red: ticketSRGB.red, green: ticketSRGB.green, blue: ticketSRGB.blue)
    static let skySRGB = (red: 220.0 / 255, green: 234.0 / 255, blue: 241.0 / 255)
    static let sky = Color(red: skySRGB.red, green: skySRGB.green, blue: skySRGB.blue)
    static let porcelain = Color(red: porcelainSRGB.red, green: porcelainSRGB.green, blue: porcelainSRGB.blue)
    static let track = Color(red: 17 / 255, green: 25 / 255, blue: 35 / 255)
    static let steel = Color(red: steelSRGB.red, green: steelSRGB.green, blue: steelSRGB.blue)
    static let mint = Color(red: mintSRGB.red, green: mintSRGB.green, blue: mintSRGB.blue)
    static let danger = Color(red: dangerSRGB.red, green: dangerSRGB.green, blue: dangerSRGB.blue)
    static let night = Color(red: 13 / 255, green: 23 / 255, blue: 34 / 255)
    static let nightSurface = Color(red: 23 / 255, green: 36 / 255, blue: 48 / 255)

    /// Ring and primary-button accent per phase: focus keeps signal red,
    /// short break goes mint, long break goes ticket gold. Nothing stays
    /// red across phases.
    static func accent(for phase: TimerPhase) -> Color {
        switch phase {
        case .focus: signal
        case .shortBreak: mint
        case .longBreak: ticket
        }
    }

    /// Appearance bucket for scheme-dependent foreground choices. Foundation
    /// only, so unit tests can pin contrast without importing SwiftUI.
    enum Appearance {
        case light
        case dark
    }

    /// sRGB components of the per-phase prominent tint, sourced from the
    /// same tuples as the shipped Colors so the AP116 contrast pins audit
    /// the values on screen.
    static func accentSRGB(for phase: TimerPhase) -> (red: Double, green: Double, blue: Double) {
        switch phase {
        case .focus: signalSRGB
        case .shortBreak: mintSRGB
        case .longBreak: ticketSRGB
        }
    }

    /// Prominent-button label sRGB (AP116): black in both appearances. White
    /// reaches only ~2.9:1 on signal red and ~1.5-1.6:1 on mint/ticket in
    /// dark mode; black clears WCAG AA 4.5:1 on all three tints in both
    /// schemes (signal 7.0, mint 13.5, ticket 14.1).
    static func prominentLabelSRGB(for appearance: Appearance) -> (red: Double, green: Double, blue: Double) {
        switch appearance {
        case .light, .dark: (red: 0, green: 0, blue: 0)
        }
    }

    /// Effective secondary fills (R48-AP08). The pre-iOS-26 fallback fill
    /// is opaque sky, identical in both appearances. The iOS-26 glass
    /// secondary tints porcelain at 16% over the card backdrop: night
    /// surface in dark, porcelain in light. Composites below are the exact
    /// `backdrop * 0.84 + porcelain * 0.16` mixes so the audit pins the
    /// values the label choice is made against.
    static let glassSecondaryDarkFillSRGB = (
        red: (23.0 * 0.84 + 247.0 * 0.16) / 255,
        green: (36.0 * 0.84 + 248.0 * 0.16) / 255,
        blue: (48.0 * 0.84 + 242.0 * 0.16) / 255
    )
    static let glassSecondaryLightFillSRGB = (
        red: 247.0 / 255, green: 248.0 / 255, blue: 242.0 / 255
    )

    /// Label with the higher WCAG contrast against the given fill.
    /// Black wins on sky (~17.1 vs ~1.23) and on the light glass
    /// composite (~19.7 vs ~1.07); white wins on the dark glass
    /// composite (~9.7 vs ~2.2). Margins clear AA 4.5:1 in both
    /// appearances and leave headroom for Increase Contrast shifts.
    static func secondaryLabelSRGB(
        forFill fill: (red: Double, green: Double, blue: Double)
    ) -> (red: Double, green: Double, blue: Double) {
        let fillLuminance = relativeLuminance(red: fill.red, green: fill.green, blue: fill.blue)
        let whiteLuminance = 1.0
        let blackLuminance = 0.0
        let whiteRatio = contrastRatio(
            lighter: max(whiteLuminance, fillLuminance),
            darker: min(whiteLuminance, fillLuminance)
        )
        let blackRatio = contrastRatio(
            lighter: max(blackLuminance, fillLuminance),
            darker: min(blackLuminance, fillLuminance)
        )
        if blackRatio >= whiteRatio {
            return (red: 0, green: 0, blue: 0)
        }
        return (red: 1, green: 1, blue: 1)
    }

    /// Fallback secondary label, chosen from the actual sky fill, not the
    /// scheme alone: black in both appearances. White on sky is the
    /// 1.23:1 baseline failure in iOS 18 dark mode.
    static func secondaryFallbackLabelSRGB(
        for appearance: Appearance
    ) -> (red: Double, green: Double, blue: Double) {
        switch appearance {
        case .light, .dark: secondaryLabelSRGB(forFill: skySRGB)
        }
    }

    /// Glass secondary label, chosen from the actual composite fill per
    /// appearance: white in dark, black in light.
    static func glassSecondaryLabelSRGB(
        for appearance: Appearance
    ) -> (red: Double, green: Double, blue: Double) {
        switch appearance {
        case .light: secondaryLabelSRGB(forFill: glassSecondaryLightFillSRGB)
        case .dark: secondaryLabelSRGB(forFill: glassSecondaryDarkFillSRGB)
        }
    }

    /// sRGB components of the darkened signal red used for small text on light
    /// surfaces. Kept separate so the vivid accent stays for decoration only.
    static let signalTextLightRGB = (red: 172.0 / 255, green: 32.0 / 255, blue: 28.0 / 255)

    /// Small-text foreground: darkened signal on light appearances, vivid
    /// signal on dark appearances.
    static var signalText: Color {
#if os(iOS)
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(signal)
                : UIColor(
                    red: signalTextLightRGB.red,
                    green: signalTextLightRGB.green,
                    blue: signalTextLightRGB.blue,
                    alpha: 1
                )
        })
#elseif os(macOS)
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(signal)
                : NSColor(
                    srgbRed: signalTextLightRGB.red,
                    green: signalTextLightRGB.green,
                    blue: signalTextLightRGB.blue,
                    alpha: 1
                )
        })
#endif
    }

    /// WCAG relative luminance for an sRGB color with components in 0...1.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two relative luminances.
    static func contrastRatio(lighter: Double, darker: Double) -> Double {
        (lighter + 0.05) / (darker + 0.05)
    }
}
