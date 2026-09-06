import SwiftUI

struct ServicePatternCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(kicker: "ROUTE", title: "Service pattern", subtitle: "Choose a mode and duration")
            if model.isTimerActive {
                Label("Duration changes apply to next timer", systemImage: "forward.end.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PomodoroughTheme.signal)
                    .accessibilityHint("Duration changes do not alter the running or paused timer. Auto-start controls the break after the current focus.")
            }
            ForEach(TimerPhase.allCases) { phase in
                DurationRow(
                    phase: phase,
                    minutes: model.durationMinutes(for: phase),
                    selected: model.selectedPhase == phase,
                    disabled: false,
                    select: { model.selectPhase(phase) },
                    changeMinutes: { model.setDurationMinutes($0, for: phase) }
                )
            }
            Divider().overlay(PomodoroughTheme.steel)
            Toggle("Auto-start breaks", isOn: $model.autoStartBreaks)
                .font(.headline)
                .accessibilityHint(model.isTimerActive
                    ? "Controls the break after the current focus. Short after focus. Long every fourth completed focus."
                    : "Short after focus. Long every fourth completed focus.")
            Text(model.isTimerActive
                ? "Starts the break after the current focus automatically. Short after focus. Long every fourth completed focus."
                : "Short after focus. Long every fourth completed focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).stroke(PomodoroughTheme.steel, lineWidth: 2)
        }
    }
}

#if DEBUG
#Preview {
    ServicePatternCard(model: AppModel.preview())
        .padding()
}
#endif
