import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PomodoroughTheme {
    static let platform = Color(red: 20 / 255, green: 44 / 255, blue: 92 / 255)
    static let platformDeep = Color(red: 12 / 255, green: 27 / 255, blue: 57 / 255)
    // sRGB components double as the AP116 contrast-audit source, so the
    // shipped Colors below cannot drift from the pinned values.
    static let signalSRGB = (red: 255.0 / 255, green: 96.0 / 255, blue: 79.0 / 255)
    static let mintSRGB = (red: 168.0 / 255, green: 217.0 / 255, blue: 203.0 / 255)
    static let ticketSRGB = (red: 245.0 / 255, green: 208.0 / 255, blue: 91.0 / 255)
    static let signal = Color(red: signalSRGB.red, green: signalSRGB.green, blue: signalSRGB.blue)
    static let ticket = Color(red: ticketSRGB.red, green: ticketSRGB.green, blue: ticketSRGB.blue)
    static let sky = Color(red: 220 / 255, green: 234 / 255, blue: 241 / 255)
    static let porcelain = Color(red: 247 / 255, green: 248 / 255, blue: 242 / 255)
    static let track = Color(red: 17 / 255, green: 25 / 255, blue: 35 / 255)
    static let steel = Color(red: 143 / 255, green: 168 / 255, blue: 184 / 255)
    static let mint = Color(red: mintSRGB.red, green: mintSRGB.green, blue: mintSRGB.blue)
    static let danger = Color(red: 195 / 255, green: 61 / 255, blue: 56 / 255)
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
