import AuthenticationServices
import Foundation
import GoogleSignIn

/// The one sentence a person reads when sign-in or a room operation fails.
/// It says what happened and what to do next. Failures are classified by
/// error type or code, never by message text, and the sentence carries no
/// exception message, status code or type name. The raw error stays on the
/// caller's log and diagnostic path.
enum UserFacingFailure {
    enum Operation: Sendable, CaseIterable {
        case signIn
        case signOut
        case deleteAccount
        case createRoom
        case joinRoom
        case leaveRoom
        case changeReplicationMode
        case createInvite
        case addTask
        case renameTask
        case changeTimer
        case changeWorkspace
        case recoverSavedSyncRequest
        case recoverSavedWorkspace
        case resolveHistory
    }

    /// True only when the person closed the sign-in prompt or declined
    /// consent. Nothing went wrong, so nothing is shown or captured.
    /// Decided by error type and code only, never by whether the current
    /// task is cancelled: a real failure that arrives during cancellation
    /// is still a failure. A cancelled request (`URLError.cancelled`) or
    /// task (`CancellationError`) is not the person's choice, so it gets the
    /// normal failure sentence; a sign-in that a newer one replaced is
    /// already dropped as stale before this check.
    static func isCancelledSignIn(_ error: Error) -> Bool {
        switch error {
        case let google as GIDSignInError: google.code == .canceled
        case let web as ASWebAuthenticationSessionError: web.code == .canceledLogin
        case let authorization as ASAuthorizationError: authorization.code == .canceled
        case GoogleConsentCallbackError.declined: true
        default: false
        }
    }

    static func sentence(for error: Error, during operation: Operation) -> String {
        switch error {
        case is AppError, is IrohProtocolError:
            // Sentences this app or its server authored for the person.
            error.localizedDescription
        case is KeychainError:
            String(
                localized: "user-facing-failure.secure-storage",
                defaultValue: "Pomodorough could not use secure storage on this device. Unlock or restart the device, then try again."
            )
        case let transport as URLError where connectionFailures.contains(transport.code):
            String(
                localized: "user-facing-failure.connection",
                defaultValue: "Pomodorough could not reach the server. Check your connection and try again."
            )
        default:
            unclassifiedSentence(during: operation)
        }
    }

    /// Transport failures the person can fix by checking the connection.
    private static let connectionFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .secureConnectionFailed,
    ]

    private static func unclassifiedSentence(during operation: Operation) -> String {
        switch operation {
        case .addTask, .renameTask, .changeTimer, .changeWorkspace,
             .recoverSavedSyncRequest, .recoverSavedWorkspace, .resolveHistory:
            workspaceSentence(during: operation)
        case .signIn:
            String(localized: "user-facing-failure.sign-in", defaultValue: "Sign-in did not finish. Try again.")
        case .signOut:
            String(localized: "user-facing-failure.sign-out", defaultValue: "Sign-out did not finish. Try again.")
        case .deleteAccount:
            String(
                localized: "user-facing-failure.delete-account",
                defaultValue: "Account deletion did not finish. Try again."
            )
        case .createRoom:
            String(localized: "user-facing-failure.create-room", defaultValue: "The room was not created. Try again.")
        case .joinRoom:
            String(
                localized: "user-facing-failure.join-room",
                defaultValue: "Joining the room did not finish. Check the invite and try again."
            )
        case .leaveRoom:
            String(localized: "user-facing-failure.leave-room", defaultValue: "Leaving the room did not finish. Try again.")
        case .changeReplicationMode:
            String(
                localized: "user-facing-failure.change-replication-mode",
                defaultValue: "The replication line was not changed. Try again."
            )
        case .createInvite:
            String(localized: "user-facing-failure.create-invite", defaultValue: "The invite was not created. Try again.")
        }
    }

    private static func workspaceSentence(during operation: Operation) -> String {
        switch operation {
        case .addTask:
            String(localized: "user-facing-failure.add-task", defaultValue: "The task was not added. Try again.")
        case .renameTask:
            String(localized: "user-facing-failure.rename-task", defaultValue: "The task was not renamed. Try again.")
        case .changeTimer:
            String(localized: "user-facing-failure.change-timer", defaultValue: "The timer change was not saved. Try again.")
        case .recoverSavedSyncRequest:
            String(
                localized: "user-facing-failure.recover-saved-sync-request",
                defaultValue: "The saved sync request was not recovered. Try again."
            )
        case .recoverSavedWorkspace:
            String(
                localized: "user-facing-failure.recover-saved-workspace",
                defaultValue: "The saved workspace was not recovered. Restart Pomodorough, then try again."
            )
        case .resolveHistory:
            String(
                localized: "user-facing-failure.resolve-history",
                defaultValue: "Your history choice was not applied. Try again."
            )
        default:
            String(localized: "user-facing-failure.change-workspace", defaultValue: "The change was not saved. Try again.")
        }
    }
}
