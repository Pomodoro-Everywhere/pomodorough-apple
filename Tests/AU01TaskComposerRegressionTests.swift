#if os(iOS)
import Combine
import Foundation
import Testing
import SwiftUI
import UIKit
@testable import Pomodorough

// Pins R53-AU01 (Tasks composer field): intrinsic 44pt floor at standard
// size, UIFontMetrics-scaled floor at accessibility sizes, transition-gated
// resign with commit-before-resign, async become on focus.
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

    @Test func resignCommitsFieldTextBeforeResigning() {
        var focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU01 stage")
            return
        }
        let model = stage.model
        au01KeepKey(stage.keyWindow)
        guard stage.field != nil else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        focusState.wrappedValue = true
        model.tick += 1
        au01Drain()
        au01KeepKey(stage.keyWindow)
        guard let focused = stage.field else {
            Issue.record("TaskTitleTextField lost after focus pass")
            return
        }
        #expect(stage.keyWindow.isKeyWindow)
        #expect(focused.isFirstResponder)
        // Ahead-of-binding field text (bypasses editingChanged, like a
        // programmatic set); the true->false pass must commit it, not drop it.
        focused.text = "R49 U03 standard"
        focusState.wrappedValue = false
        model.tick += 1
        au01Drain()
        guard let settled = stage.field else {
            Issue.record("TaskTitleTextField lost after unfocus pass")
            return
        }
        #expect(model.text == "R49 U03 standard")
        #expect(!settled.isFirstResponder)
    }

    @Test func becomeFirstResponderLandsAsyncOnFocus() {
        var focusState = FocusState<Bool>()
        guard let stage = AU01Stage(focus: focusState.projectedValue) else {
            Issue.record("No host window for AU01 stage")
            return
        }
        let model = stage.model
        au01KeepKey(stage.keyWindow)
        guard stage.field != nil else {
            Issue.record("TaskTitleTextField missing from hosted hierarchy")
            return
        }
        focusState.wrappedValue = true
        model.tick += 1
        // No pass has run yet, so the async become cannot have landed.
        #expect(stage.field?.isFirstResponder == false)
        au01Drain()
        au01KeepKey(stage.keyWindow)
        #expect(stage.keyWindow.isKeyWindow)
        #expect(stage.field?.isFirstResponder == true)
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
#endif
