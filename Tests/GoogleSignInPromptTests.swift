#if os(iOS)
import GoogleSignInSwift
import SwiftUI
import Testing
import UIKit
@testable import Pomodorough

// IOS27-04: while Google's prompt is open, the button draws its own
// disabled state, and the progress row keeps spinner and text on one line.
@Suite("Google sign-in prompt")
@MainActor
struct GoogleSignInPromptTests {
    @Test func buttonLooksDisabledOnlyWhileOpening() {
        let opening = GoogleSignInPrompt(isOpening: true, signIn: {})
        let idle = GoogleSignInPrompt(isOpening: false, signIn: {})
        #expect(opening.signInButton.viewModel.state == .disabled)
        #expect(idle.signInButton.viewModel.state == .normal)
    }

    @Test func openingProgressIsOneLine() {
        let host = UIHostingController(rootView: OpeningGoogleProgress())
        let size = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        // A titled ProgressView stacks the spinner above the text: about two
        // lines tall. One line plus the spinner's own height stays below 1.5.
        #expect(size.height < lineHeight * 1.5, "progress row size \(size), line \(lineHeight)")
        #expect(size.width > size.height * 2, "progress row is horizontal: \(size)")
    }
}
#endif
