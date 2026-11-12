import SwiftUI

/// Bottom banner shown while a task deletion waits out its undo window. The
/// window has no time limit, so the banner carries its own Delete now
/// action, which ends the window and writes the deletion at once.
struct TaskDeletionUndoBanner: View {
    let title: String
    let undo: () -> Void
    let deleteNow: () -> Void

    static let undoIdentifier = "task-deletion.undo"
    static let deleteNowIdentifier = "task-deletion.delete-now"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                message
                undoButton
                deleteNowButton
            }
            VStack(alignment: .leading, spacing: 8) {
                message
                stackedActions
            }
        }
        .font(.subheadline.weight(.bold))
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(PomodoroughTheme.steel.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .onAppear(perform: announce)
    }

    private var message: some View {
        Text("Deleted “\(title)”")
            .font(.subheadline.weight(.medium))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Side by side while both labels fit on one line; one above the other
    /// at the largest text sizes, where a row would break the words.
    private var stackedActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                undoButton
                deleteNowButton
            }
            VStack(alignment: .leading, spacing: 8) {
                undoButton
                deleteNowButton
            }
        }
    }

    private var undoButton: some View {
        Button(action: undo) {
            // White on the signal fill is 2.98:1; the composer label colour
            // clears AA on the same fill.
            Text("Undo")
                .foregroundStyle(PomodoroughTheme.taskComposerLabel)
                .modifier(MinimumTouchTarget())
        }
        .buttonStyle(.borderedProminent)
        // The label colour above is measured on the vivid fill, so the fill
        // keeps it instead of the app tint.
        .tint(PomodoroughTheme.signal)
        .accessibilityIdentifier(Self.undoIdentifier)
    }

    private var deleteNowButton: some View {
        Button(action: deleteNow) {
            Text(String(localized: "task-deletion.delete-now", defaultValue: "Delete now"))
                .modifier(MinimumTouchTarget())
        }
        .buttonStyle(.bordered)
        // The signal tint is 2.98:1 as text on a light fill.
        .tint(PomodoroughTheme.signalText)
        .accessibilityHint(String(localized: "Finishes deleting the task"))
        .accessibilityIdentifier(Self.deleteNowIdentifier)
    }

    /// Spoken when the banner appears, so screen-reader users learn that the
    /// deletion can still be undone without finding the banner first.
    static func announcement(title: String) -> String {
        String(localized: "Deleted “\(title)”. Undo is available.")
    }

    private func announce() {
        var spoken = AttributedString(Self.announcement(title: title))
        spoken.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(spoken).post()
    }
}

/// The system minimum touch target belongs to the label, so the whole
/// bordered button is at least that large. The label wraps instead of
/// truncating when even the stacked layout is narrower than one line;
/// `ViewThatFits` still measures its one-line ideal width first.
private struct MinimumTouchTarget: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
#else
        content
#endif
    }
}

#if DEBUG
#Preview {
    TaskDeletionUndoBanner(title: "Write release notes", undo: {}, deleteNow: {})
        .padding()
}
#endif
