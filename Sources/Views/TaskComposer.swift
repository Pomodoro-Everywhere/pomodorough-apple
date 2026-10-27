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
        Button(action: add) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .accessibilityHidden(true)
                    .foregroundStyle(PomodoroughTheme.taskComposerLabel)
                Text("Add task")
                    .foregroundStyle(PomodoroughTheme.taskComposerLabel)
            }
            .padding()
            .background(PomodoroughTheme.signal, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(canAdd ? 1 : 0.5)
        .disabled(!canAdd)
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
        field.placeholder = "Write release notes"
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
        TextField("Write release notes", text: $text)
            .focused(focused)
            .submitLabel(.done)
            .onSubmit(onSubmit)
            .frame(minHeight: minHeight)
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
            canAdd: FocusTask(title: title) != nil,
            add: { title = "" }
        )
        .padding()
    }
}

#Preview {
    TaskComposerPreview()
}
#endif
