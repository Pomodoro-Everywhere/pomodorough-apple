#if os(iOS)
import Combine
import Foundation
import Testing
import SwiftUI
import UIKit
@testable import Pomodorough

// Pins R53-AU01 (Tasks composer field): intrinsic 44pt floor at standard
// size, UIFontMetrics-scaled floor at accessibility sizes, and the
// steady-false pass never resigning a tap-won session. Focus delivery
// needs a real focus environment (a detached FocusState's wrappedValue
// setter is a no-op), so commit/focus legs live in the AU01 UI tests;
// nothing here drives the focus binding.
// Simulator legs: UIKit runtime required. Native AX-frame render legs stay
// with acceptance (scratch/accept-R53-AU01.md). No production edits.
// Harness notes (quality-R53-AU01 rejection rework):
// - External writes drive through an ObservableObject the hosted
//   representable observes. NEVER swap host.rootView mid-test: the setter
//   rebuilds the tree (new field + new coordinator), orphaning captures.
// - Focus drives through a test-owned FocusState whose binding the harness
//   installs in the real TaskTitleField. A view-owned @FocusState never
//   delivers in a unit-test host (onChange and onReceive both fire, but
//   production's updateUIView keeps reading false): the focus store needs
//   a fully appeared focus environment the test host never provides. Each
//   focus set pairs with a model tick so the change is observed on the
//   next update pass; nothing here calls production off its real paths.
// - The host is contained in the runner's appeared key window. A manual
//   scene-less window can never become key, so becomeFirstResponder
//   silently no-ops there (fallback path kept for structure only).
// - Suite is .serialized: parallel key windows would steal key from each
//   other. Field is re-resolved per assertion phase.
@Suite("AU01 task composer regression", .serialized)
@MainActor
struct AU01TaskComposerRegressionTests {
    @Test func standardIntrinsicFloorIs44() {
        let field = TaskTitleTextField()
        field.minHeight = 44
        field.font = TaskTitleTextField.scaledBodyFont()
        #expect(field.intrinsicContentSize.height == 44)
    }

    @Test func accessibilityIntrinsicFloorTracksScaledLine() {
        let ax5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: TaskTitleTextField.baseFont, compatibleWith: ax5)
        let field = TaskTitleTextField()
        field.minHeight = 0
        field.font = font
        let size = field.intrinsicContentSize
        #expect(size.height == max(44, ceil(font.lineHeight + TaskTitleTextField.verticalPadding)))
        #expect(size.height > 44)
        #expect(size.width == UIView.noIntrinsicMetric)
    }

    @Test func steadyFalsePassNeverResignsTapWonSession() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU01 stage")
            return
        }
        let model = stage.model
        au01KeepKey(stage.keyWindow)
        guard let field = stage.field else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        // Stand-in for the delayed didBegin: tap-won first responder with
        // the SwiftUI focus value still false (round-5 race condition).
        field.delegate = nil
        field.becomeFirstResponder()
        #expect(field.isFirstResponder)
        // External parent write flows through observed state; no rootView
        // swap, so the same field and coordinator see the pass.
        model.text = "R49 U03 standard"
        au01Drain()
        au01KeepKey(stage.keyWindow)
        guard let live = stage.field else {
            Issue.record("TaskTitleTextField lost after external-write pass")
            return
        }
        #expect(stage.keyWindow.isKeyWindow)
        #expect(live.isFirstResponder)
        #expect(live.text == "R49 U03 standard")
    }
}

// Pins R54-AU02 (Add can save a truncated title while the software keyboard
// lags): Add stores the title the field shows and clears the binding, and
// keys the out-of-process keyboard still held at the tap can reach the field
// before updateUIView pushes that clear. The legs force this order without
// keyboard timing: the field reports through its real editingChanged
// target-action while the external write is still pending, and no run-loop
// turn runs between the write and the reports, so no update pass intervenes.
// The tests stay in this suite so .serialized keeps the key window theirs.
extension AU01TaskComposerRegressionTests {
    @Test func lateReportsAfterClearCannotRestoreTitle() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue),
            let field = stage.field
        else {
            Issue.record("No hosted TaskTitleTextField for AU02 stage")
            return
        }
        let model = stage.model
        au02Insert("AU02 late p", into: field)
        au01Drain()
        let stored = model.text
        // Add's clear, then the keys still in flight at the tap, delivered
        // as two reports.
        model.text = ""
        au02Insert("ro", into: field)
        au02Insert("be", into: field)
        #expect(model.text == "")
        au01Drain()
        #expect(stored == "AU02 late p")
        #expect(model.text == "")
        #expect(stage.field?.text == "")
        // The next real keystroke starts a fresh draft.
        au02Insert("n", into: field)
        #expect(model.text == "n")
        au01Drain()
        #expect(stage.field?.text == "n")
    }

    @Test func deferredPushWaitsOutMarkedTextThenApplies() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU02 stage")
            return
        }
        let model = stage.model
        au01KeepKey(stage.keyWindow)
        guard let field = stage.field else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        // Marked text needs a live field editor; no focus binding involved.
        field.delegate = nil
        field.becomeFirstResponder()
        #expect(field.isFirstResponder)
        au02Insert("AU02 ime", into: field)
        au01Drain()
        model.text = ""
        au02Compose("か", in: field)
        #expect(model.text == "")
        // This pass skips its push: a composition is active.
        au01Drain()
        au02Compose("かな", in: field)
        #expect(field.markedTextRange != nil)
        #expect(field.text == "AU02 imeかな")
        field.unmarkText()
        field.sendActions(for: .editingChanged)
        // No pass is coming, so the report itself applies the clear.
        #expect(field.text == "")
        #expect(model.text == "")
        au02NewWriteWaitsForItsPass(stage, field)
        field.resignFirstResponder()
    }

    // After a report applies the deferred clear, the field and the binding
    // agree again, so the next keys are typing and reach the model.
    @Test func typingAfterDeferredApplyReachesModel() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU02 stage")
            return
        }
        au01KeepKey(stage.keyWindow)
        guard let field = stage.field else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        field.delegate = nil
        field.becomeFirstResponder()
        au02Insert("AU02 apply", into: field)
        au01Drain()
        stage.model.text = ""
        au02Compose("か", in: field)
        au01Drain()
        field.unmarkText()
        field.sendActions(for: .editingChanged)
        #expect(field.text == "")
        au02Insert("z", into: field)
        #expect(stage.model.text == "z")
        au02Insert("y", into: field)
        #expect(stage.model.text == "zy")
        au01Drain()
        #expect(stage.model.text == "zy")
        #expect(stage.field?.text == "zy")
        field.resignFirstResponder()
    }

    // A pass that pushes an external write leaves no push deferred, so a
    // later external write still waits for its own pass.
    @Test func secondExternalWriteWaitsForItsOwnPass() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue),
            let field = stage.field
        else {
            Issue.record("No hosted TaskTitleTextField for AU02 stage")
            return
        }
        au02Insert("AU02 typed", into: field)
        au01Drain()
        stage.model.text = "AU02 first"
        au01Drain()
        #expect(stage.field?.text == "AU02 first")
        au02NewWriteWaitsForItsPass(stage, field)
    }

    // Runs with no pass in between: a new external write must wait for its
    // own pass, like Add's clear, whatever push came before it.
    private func au02NewWriteWaitsForItsPass(_ stage: AU01Stage, _ field: UITextField) {
        stage.model.text = "AU02 next"
        au02Insert("x", into: field)
        au02Insert("y", into: field)
        #expect(stage.model.text == "AU02 next")
        au01Drain()
        #expect(stage.model.text == "AU02 next")
        #expect(stage.field?.text == "AU02 next")
    }
}

// Pins R54-AU03 (keys the keyboard still held at an Add tap were lost): Add
// resigns the first responder before it submits, and the keyboard delivers
// the keys it holds while that resign runs. The first leg models the
// delivery by inserting the held keys when the field ends editing, which
// happens only inside that resign, so submit sees them only if the resign
// came first. The Add button's own resign is pinned in the real app by
// PomodoroughAU01ComposerFocusUITests, and the real keyboard-process
// delivery by the starved real-app probe (apple/scratch/fix-R54-AU03.md).
extension AU01TaskComposerRegressionTests {
    @Test func addCollectsHeldKeysBeforeSubmit() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU03 stage")
            return
        }
        let model = stage.model
        au01KeepKey(stage.keyWindow)
        guard let field = stage.field else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        field.delegate = nil
        field.becomeFirstResponder()
        #expect(field.isFirstResponder)
        au02Insert("AU03 held p", into: field)
        au01Drain()
        let held = au03DeliverOnEndEditing("robe", to: field)
        var submitted: [String] = []
        TaskTitleField.submitAfterPendingInput {
            submitted.append(model.text)
            #expect(!field.isFirstResponder)
        }
        field.removeAction(held, for: .editingDidEnd)
        #expect(submitted == ["AU03 held probe"])
        field.resignFirstResponder()
    }

    @Test func addSubmitsWithoutKeyboardSession() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue),
            let field = stage.field
        else {
            Issue.record("No hosted TaskTitleTextField for AU03 stage")
            return
        }
        au02Insert("AU03 idle", into: field)
        au01Drain()
        #expect(!field.isFirstResponder)
        var submitted: [String] = []
        TaskTitleField.submitAfterPendingInput { submitted.append(stage.model.text) }
        #expect(submitted == ["AU03 idle"])
    }

    // An active composition is part of the title Add stores, and Add still
    // resigns before submit reads it. The unit host has no keyboard session,
    // so its resign leaves the marked range in place; the keyboard's commit
    // of that range is pinned by the real-app IME probe.
    @Test func addResignsBeforeSubmitWhileComposing() {
        let focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU03 stage")
            return
        }
        au01KeepKey(stage.keyWindow)
        guard let field = stage.field else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        field.delegate = nil
        field.becomeFirstResponder()
        au02Insert("AU03 ime ", into: field)
        au02Compose("かな", in: field)
        var submitted: [String] = []
        TaskTitleField.submitAfterPendingInput {
            submitted.append(stage.model.text)
            #expect(!field.isFirstResponder)
        }
        #expect(submitted == ["AU03 ime かな"])
        #expect(field.text == "AU03 ime かな")
        field.resignFirstResponder()
    }
}

private final class AU01Model: ObservableObject {
    @Published var text = ""
    @Published var tick = 0
}

private struct AU01FocusHarness: View {
    @ObservedObject var model: AU01Model
    var focus: FocusState<Bool>.Binding

    var body: some View {
        TaskTitleField(text: $model.text, focused: focus, minHeight: 44, onSubmit: {})
    }
}

// Manual view-controller containment in the runner's appeared key window,
// so the hosting controller gets balanced appearance. Detaches on release.
// Falls back to an owned scene-backed key window when the runner offers
// no parent (focus legs cannot pass there: the window never becomes key).
private final class AU01Stage {
    let model = AU01Model()
    let host: UIHostingController<AU01FocusHarness>
    let keyWindow: UIWindow
    private weak var parent: UIViewController?
    private let ownedWindow: UIWindow?

    @MainActor init?(focus: FocusState<Bool>.Binding) {
        host = UIHostingController(rootView: AU01FocusHarness(model: model, focus: focus))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        if let window = windows.first(where: { $0.isKeyWindow }),
            let root = window.rootViewController
        {
            keyWindow = window
            ownedWindow = nil
            parent = root
            root.addChild(host)
            host.view.frame = root.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
        } else if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            let window = UIWindow(windowScene: scene)
            window.frame = UIScreen.main.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            keyWindow = window
            ownedWindow = window
        } else {
            return nil
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        au01Drain(1.0)
        keyWindow.makeKeyAndVisible()
        au01Drain(0.1)
    }

    var field: TaskTitleTextField? {
        au01Field(in: host.view)
    }

    var usedContainment: Bool { parent != nil }

    deinit {
        if parent != nil {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        } else {
            ownedWindow?.isHidden = true
        }
    }
}

private func au01Field(in view: UIView) -> TaskTitleTextField? {
    if let field = view as? TaskTitleTextField { return field }
    for sub in view.subviews {
        if let found = au01Field(in: sub) { return found }
    }
    return nil
}

@MainActor private func au01KeepKey(_ window: UIWindow) {
    if !window.isKeyWindow {
        window.makeKeyAndVisible()
    }
    au01Drain(0.1)
}

private func au01Drain(_ seconds: TimeInterval = 0.5) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

// Stands in for a keyboard insertion at the end of the field: UIKit edits
// the field text, then sends editingChanged, the only field-to-model path.
@MainActor private func au02Insert(_ text: String, into field: UITextField) {
    field.text = (field.text ?? "") + text
    field.sendActions(for: .editingChanged)
}

// Stands in for an IME composition update (marked text at the caret).
@MainActor private func au02Compose(_ marked: String, in field: UITextField) {
    field.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0))
    field.sendActions(for: .editingChanged)
    #expect(field.markedTextRange != nil)
}

// Stands in for the keyboard delivering keys it still holds while the field
// resigns. Editing ends only inside that resign, so the keys land there as
// an end-of-field insertion. The caller removes the returned action.
@MainActor private func au03DeliverOnEndEditing(_ held: String, to field: UITextField) -> UIAction {
    let action = UIAction { _ in au02Insert(held, into: field) }
    field.addAction(action, for: .editingDidEnd)
    return action
}
#endif
