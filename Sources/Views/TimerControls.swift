import SwiftUI

struct TimerControls: View {
    private enum GlassControlID: Hashable {
        case primary
        case finish
        case stopSound
        case cancel
        case skip
    }

    private enum ControlState: Hashable {
        case idle
        case running
        case paused
    }

    let model: AppModel
    let layout: TimerLayout
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var glassNamespace

    var body: some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                GlassEffectContainer(spacing: 14) {
                    controls(glass: true)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: controlState)
            } else {
                controls(glass: false)
            }
        }
    }

    private var primaryAccessibilityTitle: String {
        if model.canonicalTimer?.status == .running { return String(localized: "Pause") }
        if model.canonicalTimer?.status == .paused { return String(localized: "Resume") }
        return String(localized: "Start \(model.selectedPhase.title.lowercased())")
    }

    /// One button row where it fits (mac, iPad, regular-width phones);
    /// phones otherwise stack the primary control full-width on its own
    /// first row with the rest on the second, so Finish/Cancel never
    /// share the primary row or get squeezed into a "..." truncation.
    private var singleRow: Bool {
#if os(macOS)
        return true
#else
        return horizontalSizeClass == .regular
#endif
    }

    @ViewBuilder
    private func controls(glass: Bool) -> some View {
        if singleRow {
            // One row when the buttons fit side by side, stacked rows
            // when they don't (large text, narrow multitasking width).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    primaryButton(glass: glass)
                    secondaryInlineButtons(glass: glass)
                }
                VStack(spacing: 14) {
                    primaryButton(glass: glass)
                    secondaryStackedButtons(glass: glass)
                }
            }
        } else {
            VStack(spacing: 14) {
                primaryButton(glass: glass)
                secondaryStackedButtons(glass: glass)
            }
        }
    }

    @ViewBuilder
    private func secondaryInlineButtons(glass: Bool) -> some View {
        if model.isTimerActive {
            controlButton(String(localized: "Finish"), symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
            controlButton(String(localized: "Cancel"), symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
            if model.hasActiveCompletionAlert {
                controlButton(stopSoundTitle, symbol: "speaker.slash", glassID: .stopSound, prominent: false, glass: glass, action: model.stopSound)
            }
        } else if model.hasActiveCompletionAlert {
            controlButton(stopSoundTitle, symbol: "speaker.slash", glassID: .stopSound, prominent: false, glass: glass, action: model.stopSound)
        } else {
            controlButton(skipTitle, symbol: "forward.fill", glassID: .skip, prominent: false, glass: glass) {
                model.selectPhase(skipDestination)
            }
        }
    }

    @ViewBuilder
    private func secondaryStackedButtons(glass: Bool) -> some View {
        if model.isTimerActive {
            HStack(spacing: 14) {
                controlButton(String(localized: "Finish"), symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                controlButton(String(localized: "Cancel"), symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
            }
        }
        if model.isTimerActive {
            if model.hasActiveCompletionAlert {
                controlButton(stopSoundTitle, symbol: "speaker.slash", glassID: .stopSound, prominent: false, glass: glass, action: model.stopSound)
            }
        } else if model.hasActiveCompletionAlert {
            controlButton(stopSoundTitle, symbol: "speaker.slash", glassID: .stopSound, prominent: false, glass: glass, action: model.stopSound)
        } else {
            // Idle second row: keeps the button block two lines tall
            // in every state so the card never jumps, and offers a
            // way past the selected phase without starting it.
            // Finished timers land here too: the next Start replaces
            // them, so no Dismiss control is needed.
            controlButton(skipTitle, symbol: "forward.fill", glassID: .skip, prominent: false, glass: glass) {
                model.selectPhase(skipDestination)
            }
        }
    }

    /// Idle Skip follows the same break the current focus would earn
    /// from the core cycle (long break every fourth completed focus,
    /// so the 4th/8th/12th focus skips to the long break). Breaks
    /// return to focus. Nothing starts.
    private var skipDestination: TimerPhase {
        model.selectedPhase.isBreak ? .focus : model.skipDestinationFromFocus()
    }

    private var skipTitle: String {
        String(localized: "Skip to \(skipDestination.title)")
    }

    private var stopSoundTitle: String {
        TimerAlarmScheduler.stopSoundTitle
    }

    /// Prominent-button tint follows the selected phase so Start/Pause/
    /// Resume leaves red behind on breaks, matching the dial ring.
    private var phaseAccent: Color {
        PomodoroughTheme.accent(for: model.selectedPhase)
    }

    /// At accessibility sizes the icon is dropped and the title may take
    /// two lines: icon + headline text no longer fits side by side, and a
    /// clipped "…" label (Finish/Cancel) is worse than a taller button.
    @ViewBuilder
    private func controlLabel(title: String, symbol: String) -> some View {
        // Hidden from accessibility: the button carries the label. The
        // iOS 26 glass style otherwise exposes this inner text as a
        // second small element under the same title.
        let label: some View = Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
            } else {
                Label(title, systemImage: symbol)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
            }
        }
        label.accessibilityHidden(true)
    }

    @ViewBuilder
    private func primaryButton(glass: Bool) -> some View {
        if model.canonicalTimer?.status == .running {
            controlButton(String(localized: "Pause"), symbol: "pause.fill", glassID: .primary, prominent: true, glass: glass) { model.pause() }
        } else if model.canonicalTimer?.status == .paused {
            controlButton(String(localized: "Resume"), symbol: "play.fill", glassID: .primary, prominent: true, glass: glass) { model.resume() }
        } else {
            controlButton(
                String(localized: "Start \(model.selectedPhase.title.lowercased())"),
                symbol: "play.fill",
                glassID: .primary,
                prominent: true,
                glass: glass,
                action: model.start
            )
        }
    }

    private var controlState: ControlState {
        if model.canonicalTimer?.status == .running {
            return .running
        }
        if model.canonicalTimer?.status == .paused {
            return .paused
        }
        return .idle
    }

    @ViewBuilder
    private func controlButton(
        _ title: String,
        symbol: String,
        glassID: GlassControlID,
        prominent: Bool,
        glass: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            controlLabel(title: title, symbol: symbol)
                // AP117: this inner floor is what the glass style sizes from
                // (.regular padding contributes ~14pt: 28 + 14 measured 42 on
                // SE2, below the 44pt floor), so compact carries 32 to land
                // ~46 with raster margin. The post-style floor below still
                // guards the fallback path and the reported control frame.
                .frame(maxWidth: .infinity, minHeight: compact ? 32 : 44)
        }
            .font(.headline)
        let accessibilityTitle = glassID == .primary ? primaryAccessibilityTitle : glassID == .finish ? String(localized: "Finish timer") : glassID == .cancel ? String(localized: "Cancel timer") : title
        return sizedButton(
            styledButton(button, prominent: prominent, glass: glass, glassID: glassID),
            accessibilityTitle: accessibilityTitle
        )
    }

    @ViewBuilder
    private func styledButton<Content: View>(
        _ button: Content,
        prominent: Bool,
        glass: Bool,
        glassID: GlassControlID
    ) -> some View {
        if #available(iOS 26, macOS 26, *), glass {
            if prominent {
                // Same .glass family as the secondaries so control-size
                // padding matches exactly; .glassProminent takes the
                // phase tint instead of a hand-rolled glass effect.
                button
                    .buttonStyle(.glassProminent)
                    .tint(phaseAccent)
                    .foregroundStyle(prominentText)
                    .controlSize(compact ? .regular : .large)
                    .glassEffectID(glassID, in: glassNamespace)
                    // Materialize, not matched geometry: morphing the
                    // primary button across Pause/Resume identities can
                    // stall mid-flight on the glass engine, freezing the
                    // hittable frame below the 44pt touch target.
                    .glassEffectTransition(.materialize)
            } else {
                button
                    .buttonStyle(.glass)
                    .tint(PomodoroughTheme.porcelain.opacity(0.16))
                    .foregroundStyle(buttonText)
                    .controlSize(compact ? .regular : .large)
                    .glassEffectID(glassID, in: glassNamespace)
                    .glassEffectTransition(.materialize)
            }
        } else {
            button
                .buttonStyle(.borderedProminent)
                .tint(prominent ? phaseAccent : PomodoroughTheme.sky)
                .foregroundStyle(prominent ? prominentText : buttonText)
                .controlSize(compact ? .regular : .large)
        }
    }

    /// Secondary-button labels follow the system scheme explicitly: white
    /// on dark, black on light. (The prominent label is always black — see
    /// prominentText — because white fails contrast on the phase tints.)
    private var buttonText: Color {
        colorScheme == .dark ? .white : .black
    }

    /// Prominent-button label (AP116): dark-mode-aware via the theme's
    /// audited pair, black in both appearances so focus and both break
    /// tints clear WCAG AA 4.5:1. Previous white-on-dark reached only
    /// ~2.9:1 on signal red and ~1.5:1 on mint/ticket.
    private var prominentText: Color {
        let label = PomodoroughTheme.prominentLabelSRGB(
            for: colorScheme == .dark ? .dark : .light
        )
        return Color(red: label.red, green: label.green, blue: label.blue)
    }

    /// Floor after the style: the iOS 26 glass style imposes its own
    /// content sizing on the label it exposes, so the inner floor above is
    /// what survives the morph on glass; this outer floor keeps the
    /// fallback control and every reported frame at the 44pt touch target.
    private var rowMinHeight: CGFloat {
        compact ? 44 : layout == .landscape ? 54 : 58
    }

    private func sizedButton<Styled: View>(_ styled: Styled, accessibilityTitle: String) -> some View {
        styled
            .frame(maxWidth: .infinity, minHeight: rowMinHeight)
            .buttonBorderShape(.capsule)
            // Combine so the glass style's inner label is not exposed as
            // a second small element under the same title.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle)
    }
}

#if DEBUG
#Preview {
    TimerControls(model: AppModel.preview(.running), layout: .portrait)
        .padding()
        .foregroundStyle(PomodoroughTheme.porcelain)
        .background(PomodoroughTheme.platform)
}
#endif
