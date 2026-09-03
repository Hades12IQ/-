import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Public OAuth identifiers. These must stay byte-for-byte aligned with `GOOGLE_IOS_CLIENT_ID` /
/// `GOOGLE_IOS_REDIRECT` on the server and with `CFBundleURLSchemes` in `Info.plist`. Note the
/// **single** slash after the colon in the redirect — Google and the server compare it literally.
struct GoogleOAuthNativeConfiguration: Equatable, Sendable {
    let clientID: String
    let redirectURI: String
    let callbackScheme: String

    static let firas = GoogleOAuthNativeConfiguration(
        clientID: "237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e.apps.googleusercontent.com",
        redirectURI: "com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e:/oauth2redirect",
        callbackScheme: "com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e"
    )
}

/// The result of a successful in-app authorization: the one-time code plus the PKCE verifier and
/// the raw nonce.
///
/// The app deliberately does **not** exchange this at Google's token endpoint. The server does the
/// exchange (there is no client secret for an installed app), verifies the OIDC ID token against
/// Google's JWKS and compares the nonce with `===`, so the raw ID token never enters the binary.
/// Send all three fields as received; the nonce is raw, never SHA-256'd (that is Apple's
/// convention, not Google's).
struct GoogleAuthorization: Sendable, Equatable {
    /// The one-time authorization code. Goes on the wire as `code`.
    let code: String
    /// The PKCE verifier. Goes on the wire as `code_verifier`.
    let codeVerifier: String
    /// The raw nonce, echoed by Google inside the ID token and compared by the server with `===`.
    /// Goes on the wire as `nonce`.
    let nonce: String
}

/// Failures of the in-app authorization step. Codes only — user-facing copy is chosen by
/// `ErrorPresenter` / `Strings`, never taken from here.
enum GoogleOAuthError: Error, Equatable, Sendable {
    case alreadyInProgress
    case invalidConfiguration
    case unableToStart
    case invalidCallback
    case stateMismatch
    case provider(String)
}

/// Google sign-in, authorization-code + PKCE, in `ASWebAuthenticationSession`.
@MainActor
final class GoogleOAuthProvider: NSObject {
    static let shared = GoogleOAuthProvider()

    private let configuration: GoogleOAuthNativeConfiguration
    private var activeSession: ASWebAuthenticationSession?
    private var requestedAnchor: ASPresentationAnchor?

    init(configuration: GoogleOAuthNativeConfiguration = .firas) {
        self.configuration = configuration
        super.init()
    }

    /// Opens the consent screen and returns the material the server needs.
    ///
    /// - Parameter anchor: the window to present over. `nil` picks the app's key window, which is
    ///   what every caller in this app wants.
    /// - Throws: `CancellationError` when the user dismisses the sheet or Google answers
    ///   `error=access_denied`; `GoogleOAuthError` otherwise.
    func authorize(anchor: ASPresentationAnchor? = nil) async throws -> GoogleAuthorization {
        guard activeSession == nil else { throw GoogleOAuthError.alreadyInProgress }
        requestedAnchor = anchor

        let codeVerifier = try Self.secureRandomToken(byteCount: 32)
        let state = try Self.secureRandomToken(byteCount: 32)
        let nonce = try Self.secureRandomToken(byteCount: 32)
        let authorizationURL = try makeAuthorizationURL(
            codeChallenge: Self.codeChallenge(for: codeVerifier),
            state: state,
            nonce: nonce
        )

        let callbackURL = try await openAuthorizationSession(url: authorizationURL)
        try Task.checkCancellation()

        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let values = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        // State authenticates every callback, including provider-declared errors: a forged
        // custom-scheme URL must never be able to dismiss or steer the real flow.
        guard values["state"] == state else { throw GoogleOAuthError.stateMismatch }

        if let providerError = values["error"], !providerError.isEmpty {
            if providerError == "access_denied" { throw CancellationError() }
            throw GoogleOAuthError.provider(String(providerError.prefix(80)))
        }
        guard let code = values["code"], !code.isEmpty else {
            throw GoogleOAuthError.invalidCallback
        }

        return GoogleAuthorization(code: code, codeVerifier: codeVerifier, nonce: nonce)
    }

    /// Dismisses an in-flight sheet (sign-out, screen teardown). Safe to call when idle.
    func cancel() {
        activeSession?.cancel()
        activeSession = nil
        requestedAnchor = nil
    }

    // MARK: - Authorization URL

    private func makeAuthorizationURL(
        codeChallenge: String,
        state: String,
        nonce: String
    ) throws -> URL {
        guard URL(string: configuration.redirectURI)?.scheme == configuration.callbackScheme,
              var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        else {
            throw GoogleOAuthError.invalidConfiguration
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account")
        ]

        guard let url = components.url else { throw GoogleOAuthError.invalidConfiguration }
        return url
    }

    // MARK: - Session

    private func openAuthorizationSession(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let scheme = configuration.callbackScheme
                let session = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(scheme)
                ) { callbackURL, error in
                    Task { @MainActor [weak self] in
                        self?.activeSession = nil
                        self?.requestedAnchor = nil

                        if let authenticationError = error as? ASWebAuthenticationSessionError,
                           authenticationError.code == .canceledLogin {
                            continuation.resume(throwing: CancellationError())
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else if let callbackURL,
                                  callbackURL.scheme?.lowercased() == scheme.lowercased() {
                            continuation.resume(returning: callbackURL)
                        } else {
                            continuation.resume(throwing: GoogleOAuthError.invalidCallback)
                        }
                    }
                }

                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session

                guard session.start() else {
                    activeSession = nil
                    requestedAnchor = nil
                    continuation.resume(throwing: GoogleOAuthError.unableToStart)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activeSession?.cancel()
            }
        }
    }

    // MARK: - Anchor

    fileprivate func presentationAnchorForSession() -> ASPresentationAnchor {
        if let requestedAnchor { return requestedAnchor }

        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        if let key = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) {
            return key
        }
        if let anyKey = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return anyKey
        }
        if let visible = scenes.flatMap({ $0.windows }).first(where: { !$0.isHidden }) {
            return visible
        }
        return ASPresentationAnchor(frame: .zero)
    }

    // MARK: - PKCE

    private nonisolated static func secureRandomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard status == errSecSuccess else { throw GoogleOAuthError.invalidConfiguration }
        return base64URL(Data(bytes))
    }

    private nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension GoogleOAuthProvider: ASWebAuthenticationPresentationContextProviding {
    /// The protocol requirement is nonisolated; satisfying it with a main-actor method is a
    /// warning today and an error in Swift 6. AuthenticationServices only ever calls this on the
    /// main thread, so asserting the isolation is correct and keeps the class `@MainActor`.
    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated { self.presentationAnchorForSession() }
    }
}
