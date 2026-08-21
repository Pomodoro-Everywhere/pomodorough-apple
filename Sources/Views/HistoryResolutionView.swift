import SwiftUI

struct HistoryResolutionView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                RailwayBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        RouteClockMark()
                        content
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Choose synchronized state")
            .inlineNavigationTitleIfSupported()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.historyResolutionState {
        case .none:
            EmptyView()
        case .preflighting:
            resolutionStatus(
                title: "Checking both histories",
                message: "No local changes will sync until this check finishes."
            )
        case .choosing:
            chooser
        case .confirming(let strategy):
            confirmation(for: strategy)
        case .submitting(let strategy):
            resolutionStatus(
                title: "Applying \(strategy.title)",
                message: "Your choice is saved on this device and can be retried safely."
            )
        case .retryable(let strategy):
            retryCard(strategy: strategy)
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                Text("SYNCHRONIZED STATE")
                    .font(.caption.monospaced().bold())
                    .tracking(1.4)
                    .foregroundStyle(PomodoroughTheme.ticket)
                Text("Choose synchronized state")
                    .font(.title.bold())
                    .foregroundStyle(PomodoroughTheme.porcelain)
                Text("This device has \(model.localHistoryResolutionCount) completed entries. Your account has \(model.remoteHistoryResolutionCount). Timers, tasks, or settings may also differ.")
                    .foregroundStyle(PomodoroughTheme.sky)
            }
            .accessibilityHidden(true)

            resolutionButton(
                title: "Keep Local",
                detail: "Replace account data with this device's timer, history, tasks, settings, and queued changes.",
                strategy: .replaceRemote
            )
            resolutionButton(
                title: "Keep Remote",
                detail: "Replace this device's timer, history, tasks, settings, and queued changes with account data.",
                strategy: .keepRemote
            )
            resolutionButton(
                title: "Keep Both",
                detail: "Merge queued local changes into account data. Conflicts or rejected changes are possible.",
                strategy: .merge
            )
        }
        .padding(20)
        .background(PomodoroughTheme.platform.opacity(0.94), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History conflict. This device has \(model.localHistoryResolutionCount) completed entries. Your account has \(model.remoteHistoryResolutionCount).")
    }

    private func resolutionButton(
        title: String,
        detail: String,
        strategy: BootstrapResolutionStrategy
    ) -> some View {
        Button {
            model.requestHistoryResolution(strategy)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PomodoroughTheme.track)
        .background(PomodoroughTheme.porcelain, in: .rect(cornerRadius: 14))
        .accessibilityHint(detail)
    }

    private func confirmation(for strategy: BootstrapResolutionStrategy) -> some View {
        VStack(spacing: 18) {
            Image(systemName: strategy == .merge ? "arrow.trianglehead.merge" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(PomodoroughTheme.signal)
                .accessibilityHidden(true)
            Text("Confirm \(strategy.title)")
                .font(.title.bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .accessibilityHidden(true)
            Text(confirmationMessage(for: strategy))
                .multilineTextAlignment(.center)
                .foregroundStyle(PomodoroughTheme.sky)
                .accessibilityHidden(true)
            Button(strategy.title, role: strategy == .merge ? nil : .destructive) {
                Task { await model.confirmHistoryResolution() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityHint("Confirms \(strategy.title) and starts history resolution")
            Button("Cancel", role: .cancel, action: model.cancelHistoryResolutionConfirmation)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Returns to history choices without changing data")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(PomodoroughTheme.platform.opacity(0.94), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm \(strategy.title). \(confirmationMessage(for: strategy))")
    }

    private func confirmationMessage(for strategy: BootstrapResolutionStrategy) -> String {
        switch strategy {
        case .replaceRemote:
            String(localized: "Account timer, history, tasks, settings, and queued changes will be replaced by this device's data.")
        case .keepRemote:
            String(localized: "This device's timer, history, tasks, settings, and queued changes will be replaced by account data.")
        case .merge:
            String(localized: "Queued local changes will be merged into account data. Conflicts or rejected changes are possible.")
        }
    }

    private func resolutionStatus(title: String, message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(PomodoroughTheme.ticket)
                .accessibilityLabel(title)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(PomodoroughTheme.sky)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(PomodoroughTheme.platform.opacity(0.94), in: .rect(cornerRadius: 22))
        .accessibilityRepresentation {
            Text("History resolution in progress")
                .accessibilityValue(title)
        }
    }

    private func retryCard(strategy: BootstrapResolutionStrategy?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(PomodoroughTheme.ticket)
                .accessibilityHidden(true)
            Text("History setup needs a retry")
                .font(.title2.bold())
                .foregroundStyle(PomodoroughTheme.porcelain)
                .accessibilityHidden(true)
            Text(retryMessage(for: strategy))
                .multilineTextAlignment(.center)
                .foregroundStyle(PomodoroughTheme.sky)
                .accessibilityHidden(true)
            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await model.retryHistoryResolution() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Retries saved history resolution")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(PomodoroughTheme.platform.opacity(0.94), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History resolution retry required. \(retryMessage(for: strategy))")
    }

    private func retryMessage(for strategy: BootstrapResolutionStrategy?) -> String {
        guard let strategy else {
            return String(localized: "Remote history could not be checked. Local data remains unchanged.")
        }
        return String(localized: "Your \(strategy.title) request is saved exactly and local data remains unchanged.")
    }
}

#if DEBUG
#Preview {
    HistoryResolutionView(model: AppModel.preview(.resolving))
}
#endif
