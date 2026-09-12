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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    @ViewBuilder
    private func controls(glass: Bool) -> some View {
        if usesHorizontalControls {
            HStack(spacing: 14) {
                primaryButton(glass: glass)
                if model.isTimerActive {
                    controlButton("Finish", symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                    controlButton("Cancel", symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
                    if model.hasActiveCompletionAlert {
                        controlButton(stopSoundTitle, symbol: "speaker.slash", glassID: .stopSound, prominent: false, glass: glass, action: model.stopSound)
                    }
                } else if model.hasActiveCompletionAlert {
                    controlButton(stopSoundTitle, symbol: "speaker.slash", glassID: .stopSound, prominent: false, glass: glass, action: model.stopSound)
                }
            }
        } else {
            VStack(spacing: 14) {
                primaryButton(glass: glass)
                if model.isTimerActive {
                    HStack(spacing: 14) {
                        controlButton("Finish", symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                        controlButton("Cancel", symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
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

    @ViewBuilder
    private func primaryButton(glass: Bool) -> some View {
        if model.canonicalTimer?.status == .running {
            controlButton("Pause", symbol: "pause.fill", glassID: .primary, prominent: true, glass: glass) { model.pause() }
        } else if model.canonicalTimer?.status == .paused {
            controlButton("Resume", symbol: "play.fill", glassID: .primary, prominent: true, glass: glass) { model.resume() }
        } else {
            controlButton(
                "Start \(model.selectedPhase.title.lowercased())",
                symbol: "play.fill",
                glassID: .primary,
                prominent: true,
                glass: glass,
                action: model.start
            )
        }
    }

    private var usesHorizontalControls: Bool {
#if os(iOS)
        // Side-by-side landscape card has a narrow button column; a
        // three-up row would clip, so iOS always stacks vertically.
        false
#else
        layout != .landscape
#endif
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
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: layout == .landscape ? 54 : 58)
            .buttonBorderShape(.capsule)
            .accessibilityLabel(glassID == .primary ? primaryAccessibilityTitle : glassID == .finish ? String(localized: "Finish timer") : glassID == .cancel ? String(localized: "Cancel timer") : title)
        if #available(iOS 26, macOS 26, *), glass {
            if prominent {
                button
                    .buttonStyle(.glassProminent)
                    .tint(PomodoroughTheme.signal)
                    .controlSize(.large)
                    .glassEffectID(glassID, in: glassNamespace)
                    .glassEffectTransition(glassID == .primary ? .matchedGeometry : .materialize)
            } else {
                button
                    .buttonStyle(.glass)
                    .tint(PomodoroughTheme.porcelain.opacity(0.16))
                    .controlSize(.large)
                    .glassEffectID(glassID, in: glassNamespace)
                    .glassEffectTransition(glassID == .primary ? .matchedGeometry : .materialize)
            }
        } else {
            button
                .buttonStyle(.borderedProminent)
                .tint(prominent ? PomodoroughTheme.ticket : PomodoroughTheme.sky)
                .foregroundStyle(PomodoroughTheme.track)
                .controlSize(.large)
        }
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
