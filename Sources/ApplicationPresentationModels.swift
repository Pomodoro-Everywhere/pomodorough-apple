import Foundation

enum AppError: Equatable, LocalizedError {
    case configuration
    case missingPresentationAnchor
    case missingIDToken
    case unauthorized
    case conflict(String)
    case server(String)
    case historyReplacementUnavailable
    case invalidResponse
    case invalidLocalClock

    var errorDescription: String? {
        switch self {
        case .configuration: String(localized: "Google Sign-In is not configured for this build.")
        case .missingPresentationAnchor: String(localized: "No window is available for Google Sign-In.")
        case .missingIDToken: String(localized: "Google did not return an identity token.")
        case .unauthorized: String(localized: "Session expired. Sign in again.")
        // The server's own text stays in the associated value for the log;
        // the person reads an authored sentence.
        case .conflict:
            String(
                localized: "app-error.conflict",
                defaultValue: "This change conflicts with a newer change on the server. Try again."
            )
        case .server:
            String(localized: "app-error.server", defaultValue: "The server could not finish the request. Try again later.")
        case .historyReplacementUnavailable:
            String(localized: "Keeping local history requires a server update. Your saved choice and local data remain on this device.")
        case .invalidResponse: String(localized: "Server returned an invalid response.")
        case .invalidLocalClock:
            String(localized: "Change blocked because saved sequence or trusted-time state is invalid. Queued changes were not modified.")
        }
    }
}

/// The surface that shows `AppModel.errorMessage` as an alert. Every sheet
/// is a host: the root alert cannot present over a sheet without closing it.
enum ErrorAlertHost: Equatable, Sendable, CaseIterable {
    case root
    case accountSheet
    case joinRoomSheet
    case historyResolutionSheet
}
