import SwiftUI

#if os(iOS)
import UIKit
#endif

struct TaskComposer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var title: String
    var focused: FocusState<Bool>.Binding
    let canAdd: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD TASK")
                .font(.caption2.monospaced().bold())
                .tracking(1.2)
                .foregroundStyle(PomodoroughTheme.signalText)
                .accessibilityHidden(true)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) { composerControls }
                } else {
                    HStack(spacing: 10) { composerControls }
                }
            }
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PomodoroughTheme.steel, lineWidth: 2)
        }
    }

    @ViewBuilder
    private var composerControls: some View {
        TaskTitleField(
            text: $title,
            focused: focused,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 0 : 44,
            onSubmit: add
        )
        .accessibilityLabel("New task")
        // R49-U03 label: LabelStyle.automatic resolves standard-path title to
        // white on Xcode 26.6 / iPhone 17 even under .plain + foregroundStyle.
        // Explicit Text + decorative Image remove Label from color path.
        // R54-AU03: Add first collects the keys the keyboard still holds.
        Button(action: { TaskTitleField.submitAfterPendingInput(add) }) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .accessibilityHidden(true)
                    .foregroundStyle(addButtonLabel)
                Text("Add task")
                    .foregroundStyle(addButtonLabel)
            }
            .padding()
            .background(addButtonFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
    }

    /// Disabled Add keeps an opaque muted fill and a secondary label so it
    /// still reads in dark appearance. Half opacity sank the black label
    /// into the dark board.
    private var addButtonFill: Color {
        canAdd ? PomodoroughTheme.signal : PomodoroughTheme.steel.opacity(0.28)
    }

    private var addButtonLabel: AnyShapeStyle {
        canAdd ? AnyShapeStyle(PomodoroughTheme.taskComposerLabel) : AnyShapeStyle(.secondary)
    }
}

#if os(iOS)
// R53-AU01: wrapper .frame (min or exact) and .padding only size the wrapper;
// the UITextField keeps its 22pt intrinsic height centered, so its AX frame
// never grows. Size the field itself via intrinsicContentSize instead.
// Fourth rework: FIXED unscaled vertical padding (~11pt, the old SwiftUI
// field's line-to-frame delta). The old scaled padding (44 - base line ≈ 22)
// double-counted growth at AX sizes (81pt overshoot). Standard floors at
// exactly 44; AX5 tracks scaled line + 11 ≈ 65, matching the pre-fix XXXL
// measurement. Width is flexible: the placeholder-driven intrinsic width
// (~388pt at XXXL) overflowed the screen; the old SwiftUI field filled its
// proposal (174pt row / full-width stack).
final class TaskTitleTextField: UITextField {
    var minHeight: CGFloat = 0
    static let baseFont = UIFont.systemFont(ofSize: 17)
    static let verticalPadding: CGFloat = 11
    static func scaledBodyFont() -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        let lineHeight = font?.lineHeight ?? base.height
        let floor = max(44, ceil(lineHeight + Self.verticalPadding))
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: max(base.height, floor, minHeight)
        )
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.preferredContentSizeCategory
            != previous?.preferredContentSizeCategory
        {
            font = Self.scaledBodyFont()
            invalidateIntrinsicContentSize()
        }
    }

#if DEBUG
    // R54-AU03 UI-test stand-in for a keyboard that still holds keys at an
    // Add tap: XCUITest cannot make the out-of-process keyboard lag on
    // demand. With POMODOROUGH_UI_TEST_HELD_INPUT set, the field holds that
    // text and delivers it only inside its first resign, as a composition
    // that is then committed, the way the keyboard hands over held keys
    // when the input session ends. Without the variable it holds nothing.
    private var heldInput = ProcessInfo.processInfo.environment["POMODOROUGH_UI_TEST_HELD_INPUT"] ?? ""

    override func resignFirstResponder() -> Bool {
        if isFirstResponder, !heldInput.isEmpty {
            let held = heldInput
            heldInput = ""
            setMarkedText(held, selectedRange: NSRange(location: (held as NSString).length, length: 0))
            sendActions(for: .editingChanged)
            unmarkText()
            sendActions(for: .editingChanged)
        }
        return super.resignFirstResponder()
    }
#endif
}

struct TaskTitleField: UIViewRepresentable {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var minHeight: CGFloat
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focused: focused,
            onSubmit: onSubmit,
            initialText: text
        )
    }

    func makeUIView(context: Context) -> TaskTitleTextField {
        let field = TaskTitleTextField()
        field.delegate = context.coordinator
        field.placeholder = "Task name"
        field.returnKeyType = .done
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.accessibilityLabel = "New task"
        field.minHeight = minHeight
        field.font = TaskTitleTextField.scaledBodyFont()
        field.adjustsFontForContentSizeCategory = true
        field.text = text
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: TaskTitleTextField, context: Context) {
        // R53-AU01: single source of truth per direction. Field->model flows
        // ONLY through editingChanged (which advances syncedText alongside
        // the binding, atomically on the main thread). Model->field applies
        // ONLY on divergence from syncedText — i.e. an external set
        // (clear/submit/parent write) that bypassed the field. Keystroke
        // echoes always satisfy text == syncedText at pass time, so they
        // never push back and typing cannot be clobbered. The prior guard
        // re-stamped its token on every pass (render side), letting a stale
        // model value overwrite in-flight keystrokes. Never fight markedText.
        if field.markedTextRange == nil,
            text != context.coordinator.syncedText
        {
            field.text = text
            context.coordinator.syncedText = text
        }
        // R54-AU02: true only when markedText blocked the push above.
        context.coordinator.pushDeferred = text != context.coordinator.syncedText
        if field.minHeight != minHeight {
            field.minHeight = minHeight
            field.invalidateIntrinsicContentSize()
        }
        // R53-AU01: focus transitions only. Resigning on bare
        // focused==false raced tap-driven first responders: the delegate's
        // didBegin (focused=true) lands after the render pass triggered by
        // the first keystroke, so that pass saw stale false + isFirstResponder
        // and resigned focus after 1 char (XXXL: tap never stuck at all).
        // Resign only on a true->false SwiftUI transition, committing field
        // text to the binding first so nothing is lost. Become is async so
        // it lands outside the view-update cycle.
        let wantFocus = focused.wrappedValue
        let hadFocus = context.coordinator.lastFocused
        context.coordinator.lastFocused = wantFocus
        if wantFocus, !field.isFirstResponder {
            DispatchQueue.main.async { [weak field] in
                field?.becomeFirstResponder()
            }
        } else if !wantFocus, hadFocus, field.isFirstResponder {
            let current = field.text ?? ""
            context.coordinator.syncedText = current
            context.coordinator.text.wrappedValue = current
            field.resignFirstResponder()
        }
    }

    // R54-AU03: an Add tap reaches the app directly, while the keys typed
    // just before it travel through the out-of-process keyboard. A lagging
    // keyboard can still hold some of them when the tap lands, and Add then
    // stored the shorter title the field showed. Resigning the first
    // responder ends the input session synchronously: the keyboard delivers
    // the keys it holds, and commits any marked text, before the call
    // returns. No external write is pending yet, so editingChanged accepts
    // those keys and the binding holds the whole title when submit reads
    // it. Submit runs even when nothing was first responder. Return needs
    // no flush: it travels through the same keyboard queue as the keys.
    static func submitAfterPendingInput(_ submit: () -> Void) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        submit()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var focused: FocusState<Bool>.Binding
        var onSubmit: () -> Void
        // R53-AU01: external-change token — text believed to be in the field.
        // Advanced ONLY by field reports (editingChanged) and external pushes
        // above, never by keystroke echo.
        var syncedText: String
        // R53-AU01: last SwiftUI focus value seen in updateUIView. Resign is
        // gated on a true->false transition so passes racing a tap-driven
        // first responder (still false) never resign a just-won session.
        var lastFocused = false
        // R54-AU02: the last update pass left an external write unpushed
        // because markedText was active, and no later pass is scheduled.
        var pushDeferred = false

        init(
            text: Binding<String>,
            focused: FocusState<Bool>.Binding,
            onSubmit: @escaping () -> Void,
            initialText: String
        ) {
            self.text = text
            self.focused = focused
            self.onSubmit = onSubmit
            self.syncedText = initialText
        }

        @objc func editingChanged(_ sender: UITextField) {
            // R54-AU02: an external write that updateUIView has not pushed
            // yet (Add's clear, a parent draft) wins over field reports.
            // The out-of-process keyboard can deliver keys typed before an
            // Add tap, one report or several, after Add stored the title
            // the field showed and cleared the binding. Accepting them
            // would put the full title back in the composer and undo the
            // clear, so drop them until the pending pass pushes the write.
            // Only when a pass already skipped that push for markedText is
            // no pass coming; then this report applies it, never over an
            // active composition.
            if text.wrappedValue != syncedText {
                if pushDeferred, sender.markedTextRange == nil {
                    sender.text = text.wrappedValue
                    syncedText = text.wrappedValue
                    pushDeferred = false
                }
                return
            }
            let current = sender.text ?? ""
            syncedText = current
            text.wrappedValue = current
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            focused.wrappedValue = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            focused.wrappedValue = false
        }
    }
}
#else
// macOS fallback: pre-AU01 plain TextField contract (placeholder, Done key,
// submit, FocusState bridge) with the same min-height intent. macOS never
// took the UIKit path; the wrapper minHeight is a no-op at 0.
struct TaskTitleField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var minHeight: CGFloat
    var onSubmit: () -> Void

    var body: some View {
        TextField("Task name", text: $text)
            .focused(focused)
            .submitLabel(.done)
            .onSubmit(onSubmit)
            .frame(minHeight: minHeight)
    }

    // R54-AU03 is an iOS keyboard-process race; macOS Add submits directly.
    static func submitAfterPendingInput(_ submit: () -> Void) {
        submit()
    }
}
#endif

#if DEBUG
private struct TaskComposerPreview: View {
    @State private var title = "Write release notes"
    @FocusState private var focused: Bool

    var body: some View {
        TaskComposer(
            title: $title,
            focused: $focused,
            canAdd: FocusTask.acceptsDraft(title),
            add: { title = "" }
        )
        .padding()
    }
}

#Preview {
    TaskComposerPreview()
}
#endif
