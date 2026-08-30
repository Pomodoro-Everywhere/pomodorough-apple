import Foundation

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let name: String
    let avatarUrl: String
}

struct MeResponse: Codable, Sendable {
    let user: User
    let csrfToken: String
}

struct NativeChallenge: Codable, Sendable {
    let challenge: String
    let nonce: String
    let expiresAt: Date
}

struct TokenPair: Codable, Equatable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String
    let refreshTokenExpiresAt: Date
}

struct NativeExchangeRequest: Encodable, Sendable {
    let idToken: String
    let challenge: String
    let deviceId: String
    let platform: String
}

struct RefreshRequest: Encodable, Sendable { let refreshToken: String }
