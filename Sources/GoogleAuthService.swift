import Foundation
import GoogleSignIn
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import AuthenticationServices
import CryptoKit
import Security
#endif

@MainActor
protocol GoogleIdentityProviding: Sendable {
    func identityToken(nonce: String) async throws -> String
    @discardableResult func handle(_ url: URL) -> Bool
    func signOut()
}

struct SystemGoogleIdentityProvider: GoogleIdentityProviding {
    func identityToken(nonce: String) async throws -> String {
        try await GoogleAuthService.identityToken(nonce: nonce)
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        GoogleAuthService.handle(url)
    }

    func signOut() {
        GoogleAuthService.signOut()
    }
}

enum GoogleAuthService {
    @MainActor
    static func identityToken(nonce: String) async throws -> String {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.hasPrefix("REPLACE_ME") else {
            throw AppError.configuration
        }
#if os(iOS)
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else {
            throw AppError.missingPresentationAnchor
        }
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: root,
            hint: nil,
            additionalScopes: nil,
            nonce: nonce
        )
        guard let token = result.user.idToken?.tokenString else { throw AppError.missingIDToken }
        return token
#elseif os(macOS)
        return try await MacGoogleOAuth.identityToken(clientID: clientID, nonce: nonce)
#endif
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
#if os(iOS)
        GIDSignIn.sharedInstance.handle(url)
#else
        false
#endif
    }

    static func signOut() {
#if os(iOS)
        GIDSignIn.sharedInstance.signOut()
#endif
    }
}

#if os(macOS)
protocol GoogleOAuthTokenExchangeTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionGoogleOAuthTokenExchangeTransport: GoogleOAuthTokenExchangeTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum MacGoogleOAuthContract {
    private struct TokenResponse: Decodable {
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
        }
    }

    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        nonce: String,
        state: String,
        verifier: String
    ) throws -> URL {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        guard let url = components?.url else { throw AppError.configuration }
        return url
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidResponse
        }
        let parameters = Dictionary(
            callback.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        if let message = parameters["error_description"] ?? parameters["error"] {
            throw AppError.server(message)
        }
        guard parameters["state"] == expectedState,
              let code = parameters["code"],
              !code.isEmpty else {
            throw AppError.invalidResponse
        }
        return code
    }

    static func tokenRequest(
        code: String,
        clientID: String,
        redirectURI: String,
        verifier: String
    ) throws -> URLRequest {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AppError.configuration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        return request
    }

    static func exchangeCode(
        _ code: String,
        clientID: String,
        redirectURI: String,
        verifier: String,
        transport: any GoogleOAuthTokenExchangeTransport
    ) async throws -> String {
        let request = try tokenRequest(
            code: code,
            clientID: clientID,
            redirectURI: redirectURI,
            verifier: verifier
        )
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            throw AppError.server("Google rejected the sign-in response.")
        }
        guard let token = try JSONDecoder().decode(TokenResponse.self, from: data).idToken,
              !token.isEmpty else {
            throw AppError.missingIDToken
        }
        return token
    }

    static func formData(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

@MainActor
private final class MacGoogleOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    static func identityToken(clientID: String, nonce: String) async throws -> String {
        guard let callbackScheme = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
            .flatMap({ $0 as? [[String: Any]] })?
            .compactMap({ $0["CFBundleURLSchemes"] as? [String] })
            .flatMap({ $0 })
            .first,
              !callbackScheme.isEmpty else {
            throw AppError.configuration
        }

        let verifier = try randomBase64URL(byteCount: 32)
        let state = try randomBase64URL(byteCount: 32)
        let redirectURI = "\(callbackScheme):/oauth2callback"
        let authorizationURL = try MacGoogleOAuthContract.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            nonce: nonce,
            state: state,
            verifier: verifier
        )

        let callbackURL = try await MacGoogleOAuth().authenticate(
            at: authorizationURL,
            callbackScheme: callbackScheme
        )
        let code = try MacGoogleOAuthContract.authorizationCode(
            from: callbackURL,
            expectedState: state
        )

        return try await MacGoogleOAuthContract.exchangeCode(
            code,
            clientID: clientID,
            redirectURI: redirectURI,
            verifier: verifier,
            transport: URLSessionGoogleOAuthTokenExchangeTransport()
        )
    }

    private func authenticate(at url: URL, callbackScheme: String) async throws -> URL {
        guard NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first != nil else {
            throw AppError.missingPresentationAnchor
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: Self.completionHandler(owner: self, continuation: continuation)
            )
            session.presentationContextProvider = self
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: AppError.missingPresentationAnchor)
                return
            }
        }
    }

    private nonisolated static func completionHandler(
        owner: MacGoogleOAuth,
        continuation: CheckedContinuation<URL, any Error>
    ) -> (URL?, (any Error)?) -> Void {
        { [weak owner] callbackURL, error in
            Task { @MainActor in
                owner?.session = nil
            }
            if let error {
                continuation.resume(throwing: error)
            } else if let callbackURL {
                continuation.resume(returning: callbackURL)
            } else {
                continuation.resume(throwing: AppError.invalidResponse)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppError.configuration
        }
        return Data(bytes).base64URLString
    }

}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
