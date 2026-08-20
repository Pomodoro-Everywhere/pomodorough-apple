import SwiftUI

struct TimerControls: View {
    private enum GlassControlID: Hashable {
        case primary
        case finish
        case clear
        case cancel
    }

    private enum ControlState: Hashable {
        case idle
        case running
        case paused
        case clearable
    }

    let model: AppModel
    let layout: TimerLayout
    @Namespace private var glassNamespace

    var body: some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                GlassEffectContainer(spacing: 14) {
                    controls(glass: true)
                }
                .animation(.smooth(duration: 0.4), value: controlState)
            } else {
                controls(glass: false)
            }
        }
        .accessibilityRepresentation { accessibilityControls }
    }

    @ViewBuilder
    private var accessibilityControls: some View {
        let button = Button(primaryAccessibilityTitle, action: primaryAccessibilityAction)
            .accessibilityValue(activeTaskAccessibilityValue)
        if model.isTimerActive {
            if model.hasActiveCompletionAlert {
                button
                    .accessibilityAction(named: "Finish timer") { model.finish() }
                    .accessibilityAction(named: "Cancel timer") { model.cancel() }
                    .accessibilityAction(named: clearTimerTitle, model.stopSound)
            } else {
                button
                    .accessibilityAction(named: "Finish timer") { model.finish() }
                    .accessibilityAction(named: "Cancel timer") { model.cancel() }
            }
        } else if hasClearableTimer {
            button
                .accessibilityAction(named: clearTimerTitle, model.stopSound)
        } else {
            button
        }
    }

    private var primaryAccessibilityTitle: String {
        if model.canonicalTimer?.status == .running { return "Pause" }
        if model.canonicalTimer?.status == .paused { return "Resume" }
        return "Start \(model.selectedPhase.title.lowercased())"
    }

    private var primaryAccessibilityAction: () -> Void {
        if model.canonicalTimer?.status == .running { return { model.pause() } }
        if model.canonicalTimer?.status == .paused { return { model.resume() } }
        return model.start
    }

    private var activeTaskAccessibilityValue: String {
        guard let timer = model.canonicalTimer else { return "" }
        return "Focus task: \(model.task(forTimerID: timer.id)?.title ?? "No task")"
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
                        controlButton(clearTimerTitle, symbol: "speaker.slash", glassID: .clear, prominent: false, glass: glass, action: model.stopSound)
                    }
                } else if hasClearableTimer {
                    controlButton(clearTimerTitle, symbol: "speaker.slash", glassID: .clear, prominent: false, glass: glass, action: model.stopSound)
                }
            }
        } else {
            VStack(spacing: 14) {
                primaryButton(glass: glass)
                if model.isTimerActive {
                    #if os(macOS)
                    controlButton("Finish", symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                    controlButton("Cancel", symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
                    #else
                    HStack(spacing: 14) {
                        controlButton("Finish", symbol: "checkmark", glassID: .finish, prominent: false, glass: glass) { model.finish() }
                        controlButton("Cancel", symbol: "xmark", glassID: .cancel, prominent: false, glass: glass) { model.cancel() }
                    }
                    #endif
                }
                if model.hasActiveCompletionAlert || hasClearableTimer {
                    controlButton(clearTimerTitle, symbol: "speaker.slash", glassID: .clear, prominent: false, glass: glass, action: model.stopSound)
                }
            }
        }
    }

    private var clearTimerTitle: String {
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

    private var hasClearableTimer: Bool {
        guard let timer = model.canonicalTimer else { return false }
        guard timer.status != .running && timer.status != .paused else { return false }
#if os(iOS)
        return timer.status != .cancelled
#else
        return true
#endif
    }

    private var usesHorizontalControls: Bool {
#if os(iOS)
        layout == .landscape
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
        return hasClearableTimer ? .clearable : .idle
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
        }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: layout == .landscape ? 54 : 58)
            .buttonBorderShape(.capsule)
        if #available(iOS 26, macOS 26, *), glass {
            if prominent {
                button
                    .buttonStyle(.glassProminent)
                    .tint(PomodoroughTheme.signal)
                    .controlSize(.extraLarge)
                    .glassEffectID(glassID, in: glassNamespace)
                    .glassEffectTransition(glassID == .primary ? .matchedGeometry : .materialize)
            } else {
                button
                    .buttonStyle(.glass)
                    .tint(PomodoroughTheme.porcelain.opacity(0.16))
                    .controlSize(.extraLarge)
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
