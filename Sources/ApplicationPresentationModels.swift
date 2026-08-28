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
        case .conflict(let message): message
        case .server(let message): message
        case .historyReplacementUnavailable:
            String(localized: "Keeping local history requires a server update. Your saved choice and local data remain on this device.")
        case .invalidResponse: String(localized: "Server returned an invalid response.")
        case .invalidLocalClock:
            String(localized: "Change blocked because saved sequence or trusted-time state is invalid. Queued changes were not modified.")
        }
    }
}
