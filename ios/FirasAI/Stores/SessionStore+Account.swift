import Foundation

/// Sign-in, verification, password recovery and account operations. Every method claims its own
/// busy flag through `begin(_:)`, maps failures through `ErrorPresenter` (never the server
/// sentence) and returns a plain Bool the Auth screen can act on.
extension SessionStore {
    // MARK: - Sign in / sign up

    func login(email: String, password: String) async -> Bool {
        guard begin(.login) else { return false }
        defer { end(.login) }

        do {
            let signedIn = try await api.login(email: normalizedEmail(email), password: password)
            applyMember(signedIn)
            return true
        } catch {
            presentLoginFailure(error)
            return false
        }
    }

    func signup(name: String, email: String, password: String) async -> Bool {
        guard begin(.signup) else { return false }
        defer { end(.signup) }

        do {
            let pending = try await api.signup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: normalizedEmail(email),
                password: password
            )
            if let signedIn = pending.user {
                applyMember(signedIn)
            } else if !pending.pid.isEmpty {
                awaitVerification(pid: pending.pid, email: pending.email)
            } else {
                // Neither a session nor a pending id: there is nothing to poll for, and parking
                // the screen on a verification card with an empty `pid` would poll forever.
                present(APIError.decoding("signup answered with neither a session nor a pending id"))
                return false
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// One poll. The caller loops every 3 s while the card is visible and stops as soon as
    /// `phase` leaves `.awaitingVerification` (verified, expired or gone).
    @discardableResult
    func pollVerification() async -> Bool {
        guard case .awaitingVerification(let pid, _) = phase else { return false }

        do {
            let outcome = try await api.verifyStatus(pid: pid)
            switch outcome {
            case .verified:
                // That same response carried the session cookie; read the account back.
                if let signedIn = try? await api.me() {
                    applyMember(signedIn)
                    return true
                }
                return false
            case .expired, .gone:
                // A pending record is deleted the moment it is consumed, so `gone` also describes
                // "already verified on this device, and `me()` failed on the winning poll". Read
                // the account back before declaring the link dead: a member cookie proves it was
                // verified, and a 401 here is a no-op while `phase` is `.awaitingVerification`.
                if let signedIn = try? await api.me() {
                    applyMember(signedIn)
                    return true
                }
                markVerificationEnded()
                return false
            case .pending:
                return false
            }
        } catch {
            // Transport hiccups are swallowed: the caller keeps polling.
            return false
        }
    }

    /// `POST /api/auth/resend-code` is keyed by **email**, not by the pending id — `DB.pending`
    /// has no pid→email route — so the address carried in `.awaitingVerification` is what goes on
    /// the wire. The server always answers `200 {"ok":true}` (anti-enumeration), so a `true` here
    /// means "accepted", never "a mail was sent".
    func resendVerification() async -> Bool {
        guard case .awaitingVerification(_, let email) = phase, canResendVerification else { return false }
        let address = normalizedEmail(email)
        guard !address.isEmpty else { return false }
        guard begin(.resend) else { return false }
        defer { end(.resend) }

        do {
            try await api.resendCode(email: address)
            startResendCooldown()
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// The emailed link opened on this device (the `verify` deep link).
    func verifySignup(token: String) async -> Bool {
        guard begin(.signup) else { return false }
        defer { end(.signup) }

        do {
            let signedIn = try await api.verifySignup(token: token)
            applyMember(signedIn)
            return true
        } catch {
            present(error)
            return false
        }
    }

    // MARK: - Password recovery

    /// The server answers 200 whether or not the address exists; only rate limiting fails.
    func forgotPassword(email: String) async -> Bool {
        guard begin(.forgot) else { return false }
        defer { end(.forgot) }

        do {
            try await api.forgotPassword(email: normalizedEmail(email))
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// The `reset` deep link. The server signs this device in and revokes every other one.
    func resetPassword(uid: String, token: String, password: String) async -> Bool {
        guard begin(.forgot) else { return false }
        defer { end(.forgot) }

        do {
            let signedIn = try await api.resetPassword(uid: uid, token: token, password: password)
            applyMember(signedIn)
            return true
        } catch {
            present(error)
            return false
        }
    }

    // MARK: - Google

    func signInWithGoogle(provider: GoogleOAuthProvider) async -> Bool {
        guard begin(.google) else { return false }
        defer { end(.google) }

        do {
            // The app runs the PKCE authorization-code flow and hands the one-time code to the
            // server, which does the Google token exchange itself: `/api/auth/google-native`
            // accepts `{code, code_verifier, nonce}` and nothing else. No ID token or access
            // token ever enters this binary.
            let authorization = try await provider.authorize(anchor: nil)
            let signedIn = try await api.googleNative(
                code: authorization.code,
                codeVerifier: authorization.codeVerifier,
                nonce: authorization.nonce
            )
            applyMember(signedIn)
            return true
        } catch is CancellationError {
            // Closing the account picker is an expected outcome, not an error.
            return false
        } catch {
            present(error)
            return false
        }
    }

    // MARK: - Account

    func logout() async {
        guard begin(.account) else { return }
        defer { end(.account) }

        if isGuest {
            try? await api.guestEnd()
        } else {
            try? await api.logout()
        }
        markSignedOut(dropGuestFlag: true)
    }

    func refreshAccount() async {
        guard begin(.account) else { return }
        defer { end(.account) }

        do {
            if isGuest {
                let identity = try await api.guestStart()
                adopt(identity)
            } else if isMember {
                let refreshed = try await api.me()
                applyMember(refreshed)
            }
        } catch {
            if status(of: error) == 401 {
                await handleUnauthorized()
            } else {
                present(error)
            }
        }
    }

    func changeEmail(currentPassword: String, newEmail: String) async -> Bool {
        guard isMember, begin(.account) else { return false }
        defer { end(.account) }

        do {
            let updated = try await api.changeEmail(
                currentPassword: currentPassword,
                newEmail: normalizedEmail(newEmail)
            )
            applyMember(updated)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func changePassword(currentPassword: String, newPassword: String) async -> Bool {
        guard isMember, begin(.account) else { return false }
        defer { end(.account) }

        do {
            // The server bumps its session version and re-issues this device cookie in the
            // same response, so the shared jar keeps us signed in while other devices drop.
            try await api.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            markValidated()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func deleteAccount(currentPassword: String) async -> Bool {
        guard isMember, begin(.account) else { return false }
        defer { end(.account) }

        do {
            try await api.deleteAccount(currentPassword: currentPassword)
            markSignedOut(dropGuestFlag: true)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func redeem(code: String) async -> Bool {
        guard isMember, begin(.account) else { return false }
        defer { end(.account) }

        do {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = try await api.redeem(code: trimmed)
            applyMember(updated)
            return true
        } catch {
            present(error)
            return false
        }
    }
}
