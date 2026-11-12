import AuthenticationServices
import Foundation
import Security
import Testing
@testable import Pomodorough

/// IOS27-04 and IOS27-18: a failure is classified by error type or code, and
/// the person reads one authored sentence without error codes or type names.
@Suite("User-facing failure sentences")
struct UserFacingFailureTests {
    private static let missingEntitlement = KeychainError(
        operation: "save", status: errSecMissingEntitlement, message: "A required entitlement isn't present."
    )
    private static let secureStorageSentence =
        "Pomodorough could not use secure storage on this device. Unlock or restart the device, then try again."

    @Test func closingTheGooglePromptIsACancelledSignIn() {
        let iOSPrompt = NSError(domain: "com.google.GIDSignIn", code: -5)
        let macPrompt = NSError(
            domain: ASWebAuthenticationSessionErrorDomain,
            code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
        )
        #expect(UserFacingFailure.isCancelledSignIn(iOSPrompt))
        #expect(UserFacingFailure.isCancelledSignIn(macPrompt))
        #expect(UserFacingFailure.isCancelledSignIn(ASAuthorizationError(.canceled)))
        #expect(UserFacingFailure.isCancelledSignIn(GoogleConsentCallbackError.declined))
    }

    /// Batch B follow-up E: a cancelled request or task is not the person's
    /// choice, so it is a failure with the normal sign-in sentence.
    @Test func cancelledRequestOrTaskIsASignInFailure() {
        for failure: Error in [CancellationError(), URLError(.cancelled)] {
            #expect(!UserFacingFailure.isCancelledSignIn(failure), "\(failure)")
            #expect(UserFacingFailure.sentence(for: failure, during: .signIn) == "Sign-in did not finish. Try again.")
        }
    }

    @Test func otherSignInFailuresAreNotCancellations() {
        let googleKeychain = NSError(domain: "com.google.GIDSignIn", code: -2)
        let sameCodeOtherDomain = NSError(domain: NSCocoaErrorDomain, code: -5)
        let missingAnchor = NSError(
            domain: ASWebAuthenticationSessionErrorDomain,
            code: ASWebAuthenticationSessionError.Code.presentationContextNotProvided.rawValue
        )
        #expect(!UserFacingFailure.isCancelledSignIn(googleKeychain))
        #expect(!UserFacingFailure.isCancelledSignIn(sameCodeOtherDomain))
        #expect(!UserFacingFailure.isCancelledSignIn(missingAnchor))
        #expect(!UserFacingFailure.isCancelledSignIn(ASAuthorizationError(.failed)))
        #expect(!UserFacingFailure.isCancelledSignIn(URLError(.timedOut)))
        #expect(!UserFacingFailure.isCancelledSignIn(GoogleConsentCallbackError.rejected))
        #expect(!UserFacingFailure.isCancelledSignIn(AppError.missingIDToken))
        let cancelledText = NSError(domain: "Other", code: 1, userInfo: [NSLocalizedDescriptionKey: "The user canceled."])
        #expect(!UserFacingFailure.isCancelledSignIn(cancelledText), "message text never decides")
    }

    @Test func keychainFailureNamesSecureStorageWithoutTheStatusCode() {
        for operation in UserFacingFailure.Operation.allCases {
            let sentence = UserFacingFailure.sentence(for: Self.missingEntitlement, during: operation)
            #expect(sentence == Self.secureStorageSentence)
        }
        #expect(Self.missingEntitlement.localizedDescription.contains("OSStatus"), "the raw text carries the code")
    }

    @Test func connectionFailureAsksToCheckTheConnection() {
        let sentence = UserFacingFailure.sentence(for: URLError(.notConnectedToInternet), during: .signIn)
        #expect(sentence == "Pomodorough could not reach the server. Check your connection and try again.")
        let timedOut = UserFacingFailure.sentence(for: URLError(.timedOut), during: .createRoom)
        #expect(timedOut == sentence)
    }

    @Test func transportFailureThatIsNotAConnectionProblemIsUnclassified() {
        let sentence = UserFacingFailure.sentence(for: URLError(.cannotRemoveFile), during: .leaveRoom)
        #expect(sentence == "Leaving the room did not finish. Try again.")
    }

    @Test func unclassifiedFailureGetsTheSentenceOfItsOperation() {
        let raw = NSError(
            domain: "uniffi.IrohError", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "RawCanary(code: 7) at endpoint.rs:42"]
        )
        let expected: [UserFacingFailure.Operation: String] = [
            .signIn: "Sign-in did not finish. Try again.",
            .signOut: "Sign-out did not finish. Try again.",
            .deleteAccount: "Account deletion did not finish. Try again.",
            .createRoom: "The room was not created. Try again.",
            .joinRoom: "Joining the room did not finish. Check the invite and try again.",
            .leaveRoom: "Leaving the room did not finish. Try again.",
            .changeReplicationMode: "The replication line was not changed. Try again.",
            .createInvite: "The invite was not created. Try again.",
            .addTask: "The task was not added. Try again.",
            .renameTask: "The task was not renamed. Try again.",
            .changeTimer: "The timer change was not saved. Try again.",
            .changeWorkspace: "The change was not saved. Try again.",
            .recoverSavedSyncRequest: "The saved sync request was not recovered. Try again.",
            .recoverSavedWorkspace: "The saved workspace was not recovered. Restart Pomodorough, then try again.",
            .resolveHistory: "Your history choice was not applied. Try again.",
        ]
        #expect(expected.count == UserFacingFailure.Operation.allCases.count)
        for (operation, sentence) in expected {
            #expect(UserFacingFailure.sentence(for: raw, during: operation) == sentence)
        }
    }

    @Test func authoredAppAndRoomSentencesPassThrough() {
        let app = UserFacingFailure.sentence(for: AppError.missingIDToken, during: .signIn)
        #expect(app == AppError.missingIDToken.localizedDescription)
        let room = IrohProtocolError.limit("RawCanary operation count 9001")
        #expect(UserFacingFailure.sentence(for: room, during: .joinRoom) == room.localizedDescription)
    }

    /// The server's text and an Iroh error's reason never reach the person.
    @Test func serverTextAndRoomReasonsStayOutOfTheSentence() {
        let canary = "RawCanary server text 503"
        for error: Error in [AppError.server(canary), AppError.conflict(canary)] {
            let sentence = UserFacingFailure.sentence(for: error, during: .changeWorkspace)
            #expect(!sentence.contains("RawCanary"), "\(error)")
        }
        let reasons: [IrohProtocolError] = [
            .invalidInvite(canary), .invalidMessage(canary), .limit(canary), .unavailable(canary),
            .invalidFrame, .authenticationFailed, .wrongRoom, .immutableConflict, .notFound, .roomAlreadyActive,
        ]
        let sentences = Set(reasons.map { UserFacingFailure.sentence(for: $0, during: .joinRoom) })
        // A malformed frame and a malformed message are the same fault to the person.
        #expect(sentences.count == reasons.count - 1)
        #expect(!sentences.contains { $0.contains("RawCanary") })
        #expect(reasons.allSatisfy { $0.diagnosticDetail.contains("RawCanary") == ($0.reason != nil) })
    }

    @Test func errorAlertShowsOnlyOnItsHost() {
        #expect(ErrorMessageAlert.isShown(on: .root, message: "Failed", activeHost: .root))
        #expect(!ErrorMessageAlert.isShown(on: .root, message: "Failed", activeHost: .accountSheet))
        #expect(ErrorMessageAlert.isShown(on: .accountSheet, message: "Failed", activeHost: .accountSheet))
        #expect(!ErrorMessageAlert.isShown(on: .accountSheet, message: "Failed", activeHost: .root))
        #expect(!ErrorMessageAlert.isShown(on: .root, message: nil, activeHost: .root))
    }

    /// B4: every sheet hosts the alert, so the root never presents over one.
    @Test func everySheetHostsTheAlertWhileItIsInFront() {
        let sheets = ErrorAlertHost.allCases.filter { $0 != .root }
        #expect(Set(sheets.map(String.init(describing:))) == [
            "accountSheet", "joinRoomSheet", "historyResolutionSheet",
        ])
        for sheet in sheets {
            #expect(ErrorMessageAlert.isShown(on: sheet, message: "Failed", activeHost: sheet))
            #expect(!ErrorMessageAlert.isShown(on: .root, message: "Failed", activeHost: sheet))
            #expect(ErrorMessageAlert.activeHost(afterClosing: sheet, activeHost: sheet) == .root)
            // L4: a sheet that closes after another one opened leaves it the alert.
            for other in sheets where other != sheet {
                #expect(ErrorMessageAlert.activeHost(afterClosing: sheet, activeHost: other) == other)
            }
        }
    }

    /// L4: closing a host hands the alert back only while that host holds it.
    @Test func closingHostReturnsTheAlertOnlyWhileItHoldsIt() {
        #expect(ErrorMessageAlert.activeHost(afterClosing: .accountSheet, activeHost: .accountSheet) == .root)
        // The root view going away never takes the alert from an open sheet.
        #expect(ErrorMessageAlert.activeHost(afterClosing: .root, activeHost: .accountSheet) == .accountSheet)
        #expect(ErrorMessageAlert.activeHost(afterClosing: .root, activeHost: .root) == .root)
    }
}
