import Foundation
import Observation

/// The single source of identity. Cookies are the only credential: this store never reads,
/// copies or stores them — it only makes the calls whose `Set-Cookie` the shared jar keeps
/// across launches. Nothing here presents UI: screens observe `phase`, `sessionExpiredNotice`
/// and `errorText`, and the shell decides what to show.
///
/// Sign-in, verification and account operations live in `SessionStore+Account.swift`; the
/// members they share are internal (never `private`) so both files compile independently.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case booting
        case member(User)
        case guest(User)
        case signedOut
        case awaitingVerification(pid: String, email: String)
        case unreachable(lastKnown: User?)
    }

    /// One busy flag per operation, so a stuck restore never disables Sign in.
    enum BusyFlag: Equatable, Sendable {
        case login, signup, google, forgot, account, resend, guestStart
    }

    private(set) var phase: Phase = .booting

    /// Set when a member cookie died under us (a 401 after boot). The shell shows Auth.
    var sessionExpiredNotice: Bool = false

    /// Always localized through `ErrorPresenter` — never the server sentence.
    var errorText: String?

    private(set) var isRestoring: Bool = false
    private(set) var isLoggingIn: Bool = false
    private(set) var isSigningUp: Bool = false
    private(set) var isGoogle: Bool = false
    private(set) var isForgot: Bool = false
    private(set) var isAccountOp: Bool = false
    private(set) var isStartingGuest: Bool = false
    private(set) var isResendingVerification: Bool = false

    /// Status of the last failed call, so the Auth screen can pick a field-accurate sentence
    /// (a 401 from `login` is bad credentials, not an expired session).
    private(set) var lastErrorStatus: Int?
    /// True once a verify-status poll came back `expired` or `gone`; cleared by a new signup.
    private(set) var verificationExpired: Bool = false
    /// Resend button cooldown (30 s, as on the web).
    private(set) var resendCooldownEndsAt: Date?

    /// Fired once when a guest identity becomes a member; `GuestMigration` listens.
    var onGuestBecameMember: ((_ previousGuestID: String) async -> Void)?
    /// Fired on a member 401 so `JobManager` can suspend that owner's watchers.
    var onUnauthorized: (() -> Void)?
    /// Persist/hand over owned work before logout invalidates its credentials.
    var onWillSignOut: (() async -> Void)?

    @ObservationIgnored let api: APIClient
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var lastKnownUser: User?
    @ObservationIgnored private var lastValidatedAt: Date?
    @ObservationIgnored private var isHandlingUnauthorized = false
    @ObservationIgnored private var unauthorizedTask: Task<Void, Never>?
    @ObservationIgnored private var connectivityTask: Task<Void, Never>?

    private static let revalidateAfter: TimeInterval = 600
    private static let resendCooldown: TimeInterval = 30

    init(api: APIClient, prefs: PreferencesStore, network: NetworkMonitor) {
        self.api = api
        self.prefs = prefs
        self.network = network
        observeUnauthorized()
        observeConnectivity()
    }

    // MARK: - Derived identity

    var user: User? {
        switch phase {
        case .member(let value), .guest(let value):
            return value
        case .unreachable(let lastKnown):
            return lastKnown
        case .booting, .signedOut, .awaitingVerification:
            return nil
        }
    }

    /// Owner key for caches, drafts, guest chats and job pointers.
    var identityID: String? { user?.id }

    var isMember: Bool {
        if case .member = phase { return true }
        return false
    }

    var isGuest: Bool {
        if case .guest = phase { return true }
        return false
    }

    var isAuthenticated: Bool { isMember || isGuest }

    var isAdmin: Bool { user?.admin ?? false }

    /// Entitlements as the server reports them; nil before the first successful identity call.
    var plan: PlanKind? { user?.sub.plan }

    var canResendVerification: Bool {
        guard !isResendingVerification else { return false }
        guard let until = resendCooldownEndsAt else { return true }
        return Date() >= until
    }

    // MARK: - Lifecycle

    /// Never blocks the first frame: the shell renders `.booting` while this runs.
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        clearError()

        do {
            let restored = try await api.me()
            applyMember(restored)
        } catch {
            if status(of: error) == 401 {
                await resumeGuestOrSignOut()
            } else if isConnectivityFailure(error) {
                phase = .unreachable(lastKnown: lastKnownUser)
                present(error)
            } else {
                await resumeGuestOrSignOut()
                if !isAuthenticated { present(error) }
            }
        }
    }

    /// Re-validate a member session when the last check is older than ten minutes; guests skip.
    func applicationDidBecomeActive() async {
        switch phase {
        case .booting, .unreachable:
            await restore()
        case .member:
            let due = lastValidatedAt.map { Date().timeIntervalSince($0) >= Self.revalidateAfter } ?? true
            guard due, !isRestoring else { return }
            await revalidateMember()
        case .guest, .signedOut, .awaitingVerification:
            return
        }
    }

    /// Idempotent, and only while `.member`: a guest 401 means "sign up", not "expired".
    func handleUnauthorized() async {
        guard case .member = phase, !isHandlingUnauthorized else { return }
        isHandlingUnauthorized = true
        defer { isHandlingUnauthorized = false }

        sessionExpiredNotice = true
        lastKnownUser = nil
        lastValidatedAt = nil
        phase = .signedOut
        onUnauthorized?()

        do {
            let identity = try await api.guestStart()
            adopt(identity)
        } catch {
            // Staying signed out is the correct fallback; Auth is already on screen.
        }

        // Set last: adopting an identity clears the error slot.
        if !isMember {
            errorText = Strings.Errors.sessionExpired(prefs.lang)
            lastErrorStatus = 401
        }
    }

    // MARK: - Guest

    @discardableResult
    func continueAsGuest() async -> Bool {
        guard begin(.guestStart) else { return false }
        defer { end(.guestStart) }

        do {
            let identity = try await api.guestStart()
            adopt(identity)
            return true
        } catch {
            present(error)
            return false
        }
    }

    // MARK: - Identity transitions (shared with SessionStore+Account.swift)

    /// `POST /api/guest` answers with a member when a member cookie is still present.
    func adopt(_ identity: User) {
        if identity.isGuest {
            applyGuest(identity)
        } else {
            applyMember(identity)
        }
    }

    func applyMember(_ member: User) {
        var previousGuestID: String? = nil
        if case .guest(let guestIdentity) = phase {
            previousGuestID = guestIdentity.id
        }

        lastKnownUser = member
        lastValidatedAt = Date()
        sessionExpiredNotice = false
        verificationExpired = false
        resendCooldownEndsAt = nil
        phase = .member(member)
        clearError()

        if let previousGuestID {
            prefs.guestActive = false
            Task { [weak self] in
                guard let self, let migrate = self.onGuestBecameMember else { return }
                await migrate(previousGuestID)
            }
        }
    }

    func markSignedOut(dropGuestFlag: Bool) {
        if dropGuestFlag { prefs.guestActive = false }
        lastKnownUser = nil
        lastValidatedAt = nil
        sessionExpiredNotice = false
        verificationExpired = false
        resendCooldownEndsAt = nil
        phase = .signedOut
    }

    func awaitVerification(pid: String, email: String) {
        verificationExpired = false
        resendCooldownEndsAt = nil
        phase = .awaitingVerification(pid: pid, email: email)
    }

    /// The pending signup is gone (expired or already consumed elsewhere).
    func markVerificationEnded() {
        phase = .signedOut
        verificationExpired = true
        resendCooldownEndsAt = nil
    }

    func startResendCooldown() {
        resendCooldownEndsAt = Date().addingTimeInterval(Self.resendCooldown)
    }

    /// The server re-issued this device cookie inside the response we just read.
    func markValidated() {
        lastValidatedAt = Date()
    }

    private func applyGuest(_ identity: User) {
        prefs.guestActive = true
        lastKnownUser = identity
        lastValidatedAt = Date()
        phase = .guest(identity)
        clearError()
    }

    private func resumeGuestOrSignOut() async {
        guard prefs.guestActive else {
            phase = .signedOut
            return
        }
        do {
            let identity = try await api.guestStart()
            adopt(identity)
        } catch {
            if isConnectivityFailure(error) {
                phase = .unreachable(lastKnown: lastKnownUser)
            } else {
                phase = .signedOut
            }
            present(error)
        }
    }

    private func revalidateMember() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            let refreshed = try await api.me()
            applyMember(refreshed)
        } catch {
            if status(of: error) == 401 {
                await handleUnauthorized()
            }
            // Anything else keeps the current member session: the shell stays usable offline.
        }
    }

    // MARK: - Operation gate

    /// Claims an operation slot and clears the error line. False when it is already running.
    func begin(_ operation: BusyFlag) -> Bool {
        guard !isRunning(operation) else { return false }
        setRunning(operation, true)
        clearError()
        return true
    }

    func end(_ operation: BusyFlag) {
        setRunning(operation, false)
    }

    private func isRunning(_ operation: BusyFlag) -> Bool {
        switch operation {
        case .login: return isLoggingIn
        case .signup: return isSigningUp
        case .google: return isGoogle
        case .forgot: return isForgot
        case .account: return isAccountOp
        case .resend: return isResendingVerification
        case .guestStart: return isStartingGuest
        }
    }

    private func setRunning(_ operation: BusyFlag, _ value: Bool) {
        switch operation {
        case .login: isLoggingIn = value
        case .signup: isSigningUp = value
        case .google: isGoogle = value
        case .forgot: isForgot = value
        case .account: isAccountOp = value
        case .resend: isResendingVerification = value
        case .guestStart: isStartingGuest = value
        }
    }

    // MARK: - Observation

    private func observeUnauthorized() {
        let stream = api.unauthorized
        unauthorizedTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.handleUnauthorized()
            }
        }
    }

    private func observeConnectivity() {
        let updates = network.updates
        connectivityTask = Task { [weak self] in
            for await online in updates {
                guard let self else { return }
                guard online else { continue }
                if case .unreachable = self.phase {
                    await self.restore()
                }
            }
        }
    }

    // MARK: - Errors

    func present(_ error: Error) {
        if error is CancellationError { return }
        if let apiError = error as? APIError {
            if case .cancelled = apiError { return }
            lastErrorStatus = apiError.status
        } else {
            lastErrorStatus = nil
        }

        switch ErrorPresenter.present(error, feature: nil, isGuest: isGuest, lang: prefs.lang) {
        case .toast(let text):
            errorText = text(prefs.lang)
        case .toastText(let text):
            errorText = text
        case .sessionExpired:
            errorText = Strings.Errors.sessionExpired(prefs.lang)
        case .silent:
            errorText = nil
        case .signUpPrompt, .blockedAgent, .creditsBlocked, .hideFeature:
            errorText = Strings.Errors.generic(prefs.lang)
        }
    }

    /// The two login sentences `ARCHITECTURE.md §2.15` asks for that `ErrorPresenter` cannot
    /// choose on its own: `present(_:)` never learns which route failed, so a 401 there reads as
    /// an expired session and a 500 as a busy server. On `/api/auth/login` both mean "those
    /// credentials did not work". Every other status keeps the shared mapping.
    func presentLoginFailure(_ error: Error) {
        guard let apiError = error as? APIError, let httpStatus = apiError.status else {
            present(error)
            return
        }
        switch httpStatus {
        case 401:
            lastErrorStatus = httpStatus
            errorText = Strings.Errors.credentials(prefs.lang)
        case 500:
            // The server's "valid input" trap: a Google-only account, or a hashing failure.
            lastErrorStatus = httpStatus
            errorText = Strings.Errors.credentialsOrGoogle(prefs.lang)
        default:
            present(error)
        }
    }

    func status(of error: Error) -> Int? {
        (error as? APIError)?.status
    }

    func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func clearError() {
        errorText = nil
        lastErrorStatus = nil
    }

    private func isConnectivityFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .offline, .transport, .deadline:
            return true
        case .http(let httpStatus, _, _):
            return httpStatus >= 500
        case .invalidURL, .decoding, .cancelled:
            return false
        }
    }
}
