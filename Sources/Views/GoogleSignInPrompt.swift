import GoogleSignInSwift
import SwiftUI

/// Signed-out Account rows: the Google button and, while Google's prompt
/// is open, a one-line progress row.
struct GoogleSignInPrompt: View {
    let isOpening: Bool
    let signIn: () -> Void

    var body: some View {
        signInButton
            .frame(maxWidth: 280)
            .accessibilityHint("Signs in to sync your timer across devices")
        if isOpening {
            OpeningGoogleProgress()
        }
    }

    /// IOS27-04: the button's own disabled state, not only SwiftUI's
    /// `.disabled`, so it also looks unavailable while the prompt is open.
    /// An outer `.disabled` blocks taps but leaves the button drawn as
    /// enabled.
    var signInButton: GoogleSignInButton {
        GoogleSignInButton(state: isOpening ? .disabled : .normal, action: signIn)
    }
}

/// IOS27-04: a titled ProgressView stacks its spinner above the text in
/// a list row. The label keeps the spinner and the text on one line.
struct OpeningGoogleProgress: View {
    var body: some View {
        Label {
            Text("Opening Google")
        } icon: {
            ProgressView()
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview {
    List {
        GoogleSignInPrompt(isOpening: true, signIn: {})
    }
}
#endif
