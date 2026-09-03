import Foundation

// Authentication, guest identity and account maintenance.
// Wire shapes: server-auth-session-account.md §4.1–4.17 and §5.1 (verified against server.mjs
// 1859-2332, 7542-7581). Every helper encodes exactly the fields the server reads.

// MARK: - Request bodies

private struct AuthLoginBody: Encodable, Sendable {
    let email: String
    let password: String
}

private struct AuthSignupBody: Encodable, Sendable {
    let name: String
    let email: String
    let password: String
}

private struct AuthPidBody: Encodable, Sendable {
    let pid: String
}

private struct AuthTokenBody: Encodable, Sendable {
    let token: String
}

private struct AuthEmailBody: Encodable, Sendable {
    let email: String
}

private struct AuthResetBody: Encodable, Sendable {
    let uid: String
    let token: String
    let password: String
}

private struct AuthGoogleNativeBody: Encodable, Sendable {
    let code: String
    let codeVerifier: String
    let nonce: String

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
        case nonce
    }
}

private struct AuthChangeEmailBody: Encodable, Sendable {
    let current: String
    let email: String
}

private struct AuthChangePasswordBody: Encodable, Sendable {
    let current: String
    let password: String
}

private struct AuthCurrentPasswordBody: Encodable, Sendable {
    let current: String
}

private struct AuthRedeemBody: Encodable, Sendable {
    let code: String
}

// MARK: - Response envelopes

private struct AuthUserEnvelope: Decodable, Sendable {
    let user: User
}

private struct AuthSignupEnvelope: Decodable, Sendable {
    let pid: String?
    let email: String?
    let user: User?
}

// MARK: - Endpoints

extension APIClient {

    /// `GET /api/auth/me` → `{ "user": … }`. 401 for guests and anonymous callers.
    func me() async throws -> User {
        let envelope = try await json(
            .get,
            "/api/auth/me",
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `POST /api/auth/login` → `{ "user": … }` + `firas_session`.
    func login(email: String, password: String) async throws -> User {
        let body = AuthLoginBody(email: email, password: password)
        let envelope = try await json(
            .post,
            "/api/auth/login",
            body: body,
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `POST /api/auth/signup` → `{ ok, pending, email, pid }` (no cookie; the account is created
    /// when the emailed link is opened). A body that carries a `user` instead means the server
    /// signed this device in directly.
    func signup(name: String, email: String, password: String) async throws -> PendingSignup {
        let body = AuthSignupBody(name: name, email: email, password: password)
        let envelope = try await json(
            .post,
            "/api/auth/signup",
            body: body,
            budget: .interactive,
            as: AuthSignupEnvelope.self
        )
        let resolvedEmail = envelope.email ?? envelope.user?.email ?? email
        return PendingSignup(
            pid: envelope.pid ?? "",
            email: resolvedEmail,
            user: envelope.user
        )
    }

    /// `POST /api/auth/verify-status` — the signing-up device polls this with its `pid`.
    /// Always 200 once the pid is present; `verified` sets the session cookie on this device.
    func verifyStatus(pid: String) async throws -> VerificationStatus {
        let body = AuthPidBody(pid: pid)
        let envelope = try await json(
            .post,
            "/api/auth/verify-status",
            body: body,
            budget: .interactive,
            as: VerificationStatusResponse.self
        )
        return envelope.resolved
    }

    /// `POST /api/auth/verify-signup` — the device that opened the emailed link.
    func verifySignup(token: String) async throws -> User {
        let body = AuthTokenBody(token: token)
        let envelope = try await json(
            .post,
            "/api/auth/verify-signup",
            body: body,
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `POST /api/auth/resend-code` — rotates the pending token and re-sends the link.
    /// The server keys pending signups by **email**, not by `pid`; it always answers
    /// `200 {"ok":true}` (anti-enumeration), so success here never proves an email was sent.
    func resendCode(email: String) async throws {
        let body = AuthEmailBody(email: email)
        _ = try await raw(
            .post,
            "/api/auth/resend-code",
            body: body,
            budget: .interactive
        )
    }

    /// `POST /api/auth/forgot` — always `200 {"ok":true}`.
    func forgotPassword(email: String) async throws {
        let body = AuthEmailBody(email: email)
        _ = try await raw(
            .post,
            "/api/auth/forgot",
            body: body,
            budget: .interactive
        )
    }

    /// `POST /api/auth/reset` — signs every other device out and re-issues the cookie here.
    func resetPassword(uid: String, token: String, password: String) async throws -> User {
        let body = AuthResetBody(uid: uid, token: token, password: password)
        let envelope = try await json(
            .post,
            "/api/auth/reset",
            body: body,
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `POST /api/auth/logout` — clears `firas_session`; never touches `firas_guest`.
    func logout() async throws {
        _ = try await raw(
            .post,
            "/api/auth/logout",
            budget: .interactive
        )
    }

    /// `POST /api/auth/google-native` — the app runs the PKCE authorization-code flow and hands
    /// the one-time code to the server, which exchanges it and verifies the OIDC token itself.
    /// The `nonce` travels raw (Google echoes it verbatim; the server compares with `===`).
    func googleNative(code: String, codeVerifier: String, nonce: String) async throws -> User {
        let body = AuthGoogleNativeBody(code: code, codeVerifier: codeVerifier, nonce: nonce)
        let envelope = try await json(
            .post,
            "/api/auth/google-native",
            body: body,
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `POST /api/guest` — mints or resumes `firas_guest`; a member cookie wins and is returned
    /// untouched.
    func guestStart() async throws -> User {
        let envelope = try await json(
            .post,
            "/api/guest",
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `DELETE /api/guest` — clears `firas_guest`. Fire-and-forget after a migration.
    func guestEnd() async throws {
        _ = try await raw(
            .delete,
            "/api/guest",
            budget: .interactive
        )
    }

    /// `POST /api/auth/change-email` → `{ ok, user }`. The address becomes unverified server-side.
    func changeEmail(currentPassword: String, newEmail: String) async throws -> User {
        let body = AuthChangeEmailBody(current: currentPassword, email: newEmail)
        let envelope = try await json(
            .post,
            "/api/auth/change-email",
            body: body,
            budget: .interactive,
            as: AuthUserEnvelope.self
        )
        return envelope.user
    }

    /// `POST /api/auth/change-password` → `{ ok: true }`; every other device is signed out.
    func changePassword(currentPassword: String, newPassword: String) async throws {
        let body = AuthChangePasswordBody(current: currentPassword, password: newPassword)
        _ = try await raw(
            .post,
            "/api/auth/change-password",
            body: body,
            budget: .interactive
        )
    }

    /// `POST /api/auth/delete-account` → `{ ok: true }`. Google-only accounts need no password.
    func deleteAccount(currentPassword: String) async throws {
        let body = AuthCurrentPasswordBody(current: currentPassword)
        _ = try await raw(
            .post,
            "/api/auth/delete-account",
            body: body,
            budget: .interactive
        )
    }

    /// `POST /api/redeem` → `{ ok, sub }`. The response carries the subscription only, so the
    /// refreshed user is read back from `/api/auth/me` (member-only route, cookie already set).
    func redeem(code: String) async throws -> User {
        let body = AuthRedeemBody(code: code)
        _ = try await raw(
            .post,
            "/api/redeem",
            body: body,
            budget: .interactive
        )
        return try await me()
    }
}
