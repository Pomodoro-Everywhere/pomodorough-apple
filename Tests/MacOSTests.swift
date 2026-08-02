#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import Pomodorough

@Suite("macOS")
@MainActor
struct MacOSTests {
    @Test func googleOAuthAuthorizationURLUsesPKCEStateNonceAndExactRedirect() throws {
        let verifier = "known-verifier"
        let url = try MacGoogleOAuthContract.authorizationURL(
            clientID: "client-id",
            redirectURI: "com.example:/oauth2callback",
            nonce: "nonce-value",
            state: "state-value",
            verifier: verifier
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: try #require(components.queryItems).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        let expectedChallenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        #expect(query == [
            "client_id": "client-id",
            "redirect_uri": "com.example:/oauth2callback",
            "response_type": "code",
            "scope": "openid email profile",
            "nonce": "nonce-value",
            "state": "state-value",
            "code_challenge": expectedChallenge,
            "code_challenge_method": "S256",
            "include_granted_scopes": "true",
        ])
    }

    @Test func googleOAuthCallbackValidatesStateCodeAndProviderErrors() throws {
        let valid = try #require(URL(string: "com.example:/oauth2callback?state=expected&code=code-value"))
        #expect(try MacGoogleOAuthContract.authorizationCode(
            from: valid,
            expectedState: "expected"
        ) == "code-value")

        let mismatch = try #require(URL(string: "com.example:/oauth2callback?state=wrong&code=code-value"))
        #expect(throws: AppError.self) {
            try MacGoogleOAuthContract.authorizationCode(from: mismatch, expectedState: "expected")
        }
        let missingCode = try #require(URL(string: "com.example:/oauth2callback?state=expected"))
        #expect(throws: AppError.self) {
            try MacGoogleOAuthContract.authorizationCode(from: missingCode, expectedState: "expected")
        }
        let providerError = try #require(URL(string: "com.example:/oauth2callback?error=access_denied&error_description=User%20cancelled"))
        do {
            _ = try MacGoogleOAuthContract.authorizationCode(from: providerError, expectedState: "expected")
            Issue.record("Expected provider error")
        } catch let error as AppError {
            #expect(error.localizedDescription == "User cancelled")
        }
    }

    @Test func googleOAuthTokenRequestUsesSortedEscapedFormContract() throws {
        let request = try MacGoogleOAuthContract.tokenRequest(
            code: "code +/value",
            clientID: "client:id",
            redirectURI: "com.example:/oauth2 callback",
            verifier: "verify~value"
        )

        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) ==
            "client_id=client%3Aid&code=code%20%2B%2Fvalue&code_verifier=verify~value&grant_type=authorization_code&redirect_uri=com.example%3A%2Foauth2%20callback")
    }

    @Test func googleOAuthExchangeUsesInjectedTransportAndReturnsIDToken() async throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let transport = RecordingGoogleOAuthTransport(
            data: Data(#"{"id_token":"identity-token"}"#.utf8),
            response: response
        )

        let token = try await MacGoogleOAuthContract.exchangeCode(
            "authorization-code",
            clientID: "client-id",
            redirectURI: "com.example:/oauth2callback",
            verifier: "verifier",
            transport: transport
        )

        #expect(token == "identity-token")
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [400, 500])
    func googleOAuthExchangeRejectsHTTPFailure(statusCode: Int) async throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        let transport = RecordingGoogleOAuthTransport(data: Data(), response: response)

        await #expect(throws: AppError.self) {
            try await MacGoogleOAuthContract.exchangeCode(
                "code",
                clientID: "client",
                redirectURI: "com.example:/oauth2callback",
                verifier: "verifier",
                transport: transport
            )
        }
    }

    @Test(arguments: [#"{}"#, #"{"id_token":""}"#])
    func googleOAuthExchangeRejectsMissingIDToken(body: String) async throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let transport = RecordingGoogleOAuthTransport(data: Data(body.utf8), response: response)

        await #expect(throws: AppError.self) {
            try await MacGoogleOAuthContract.exchangeCode(
                "code",
                clientID: "client",
                redirectURI: "com.example:/oauth2callback",
                verifier: "verifier",
                transport: transport
            )
        }
    }

    @Test func alarmSchedulerOperationsAreSafeWithoutAlarmKit() async throws {
        let scheduler = TimerAlarmScheduler()
        let timerID = "timer-83a06d73-1d2d-441e-afc2-e36da0518613"

        try await scheduler.requestAuthorization()
        try await scheduler.schedule(timerID: timerID, phase: .focus, duration: 60)
        try await scheduler.pause(timerID: timerID)
        try await scheduler.resume(timerID: timerID, phase: .focus, duration: 30)
        try await scheduler.cancel(timerID: timerID)
    }
}
#endif
