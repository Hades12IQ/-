import SwiftUI

/// Which field the keyboard is on. Declared next to the screen that owns the focus order; the name
/// is feature-prefixed so it cannot collide with another feature's focus enum.
enum AuthFieldFocus: Hashable {
    case name, email, password
}

/// The sign-in / sign-up card (`web-auth-account-settings.md §3`, `audit-ios-networking-auth.md
/// §B2 F8–F10`).
///
/// The shell of the old Codex screen is kept — focus order, an LTR email field inside an Arabic
/// layout, a width that behaves on iPad — and the content is rebuilt on the frozen stores. Fields
/// are glass (`.sheet` level, so iOS 26 gets `Glass.regular` and iOS 18 a material) sitting on the
/// theme ground: no grey slab inside a glass card.
///
/// Every error line comes from `SessionStore.errorText`, which is already mapped by
/// `ErrorPresenter` — a server sentence is never rendered — and is announced to VoiceOver the
/// moment it changes (F10). Google failures keep the mapped session sentence rather than a generic
/// one (F9); a cancelled account picker is silent.
///
/// The form itself lives in `AuthView+Fields.swift`.
struct AuthView: View {

    let env: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State var mode: AuthMode
    @State var name: String = ""
    @State var email: String = ""
    @State var password: String = ""
    @State private var localError: String?
    @State private var recovery: ForgotPasswordSheet.Mode?
    /// The store has no "cancel this pending signup" transition — the pending record lives on the
    /// server for 15 minutes — so `‹ الرجوع لتسجيل الدخول` hides the card locally instead.
    @State private var hidesPendingSignup: Bool = false
    @FocusState var focus: AuthFieldFocus?

    init(env: AppEnvironment, mode: AuthMode) {
        self.env = env
        _mode = State(initialValue: mode)
    }

    var prefs: PreferencesStore { env.prefs }
    var palette: FirasPalette { prefs.palette }
    var lang: AppLanguage { prefs.lang }
    var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }

    private var columnWidth: CGFloat { horizontalSizeClass == .regular ? 460 : 520 }

    var isBusy: Bool {
        env.session.isLoggingIn || env.session.isSigningUp || env.session.isGoogle
    }

    private var pendingVerification: (pid: String, email: String)? {
        guard !hidesPendingSignup else { return nil }
        if case .awaitingVerification(let pid, let address) = env.session.phase {
            return (pid, address)
        }
        return nil
    }

    var bannerText: String? {
        if let localError, !localError.isEmpty { return localError }
        if let text = env.session.errorText, !text.isEmpty { return text }
        // A verify-status poll came back `expired` or `gone`: the emailed link is dead and the
        // account was never created, so the honest instruction is "sign up again".
        if env.session.verificationExpired { return Strings.Auth.verifyBad(lang) }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            FirasBackground(palette: palette, showHalo: false)

            ScrollView {
                VStack(spacing: 24) {
                    header
                    cardContent
                }
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 74)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            topBar
        }
        .background(palette.background)
        .preferredColorScheme(prefs.theme.isLight ? .light : .dark)
        .tint(palette.accent)
        .sheet(item: $recovery) { requested in
            ForgotPasswordSheet(env: env, mode: requested)
        }
        .onAppear { consumePendingRoute() }
        .onChange(of: env.router.pendingRoute) { _, _ in consumePendingRoute() }
        .onChange(of: bannerText) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            AccessibilityNotification.Announcement(newValue).post()
        }
        .onChange(of: env.session.isMember) { _, isMember in
            if isMember { close() }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            FirasIconButton(
                symbol: "xmark",
                label: Strings.Common.close(lang),
                palette: palette,
                action: { close() }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var header: some View {
        VStack(spacing: 12) {
            FirasBrandMark(size: 48, showsWordmark: true, palette: palette)

            Text(verbatim: title)
                .font(FirasType.scaled(24, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(verbatim: subtitle)
                .font(FirasType.scaled(15, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .bidiIsland(for: title, fallback: lang)
    }

    var title: String {
        if pendingVerification != nil { return Strings.Auth.verifyTitle(lang) }
        return mode == .signup ? Strings.Auth.signupTitle(lang) : Strings.Auth.loginTitle(lang)
    }

    private var subtitle: String {
        if let pending = pendingVerification {
            return Strings.Auth.verifySubtitle(lang) + " " + pending.email
        }
        return mode == .signup ? Strings.Auth.signupSubtitle(lang) : Strings.Auth.loginSubtitle(lang)
    }

    // MARK: - The two states of the card

    @ViewBuilder
    private var cardContent: some View {
        if let pending = pendingVerification {
            VerificationCard(env: env, email: pending.email, onBack: { backToLogin() })
                .transition(motionOn ? FirasMotion.revealTransition : .opacity)
        } else {
            credentials
                .transition(motionOn ? FirasMotion.revealTransition : .opacity)
        }
    }

    // MARK: - Behaviour

    func switchMode() {
        Haptics.select()
        localError = nil
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            mode = mode == .signup ? .login : .signup
        }
        focus = mode == .signup ? .name : .email
    }

    private func backToLogin() {
        localError = nil
        password = ""
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            hidesPendingSignup = true
            mode = .login
        }
        focus = .email
    }

    func openForgot() {
        Haptics.select()
        recovery = .forgot(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func submit() {
        guard !isBusy else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        localError = nil

        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            localError = Strings.Auth.incomplete(lang)
            return
        }
        if mode == .signup {
            guard !trimmedName.isEmpty else {
                localError = Strings.Auth.incomplete(lang)
                focus = .name
                return
            }
            // The server answers 400 below eight characters; ask before spending a round trip.
            guard password.count >= 8 else {
                localError = Strings.Auth.passwordShort(lang)
                focus = .password
                return
            }
        }

        focus = nil
        let submittedMode = mode
        Task {
            let succeeded: Bool
            if submittedMode == .login {
                succeeded = await env.session.login(email: trimmedEmail, password: password)
            } else {
                succeeded = await env.session.signup(
                    name: trimmedName,
                    email: trimmedEmail,
                    password: password
                )
            }
            guard succeeded else {
                Haptics.error()
                return
            }
            password = ""
            if case .awaitingVerification(_, let address) = env.session.phase {
                hidesPendingSignup = false
                env.toasts.show(Strings.Auth.signupSent.fmt(lang, address))
            }
        }
    }

    func signInWithGoogle() {
        guard !isBusy else { return }
        localError = nil
        Haptics.select()
        Task {
            // A cancelled account picker returns false with no error text: stay silent, as the web
            // does. Everything else is already mapped onto `session.errorText` (F9).
            _ = await env.session.signInWithGoogle(provider: GoogleOAuthProvider.shared)
        }
    }

    /// The `?verify=` and `?reset=&uid=` deep links land in `Router.pendingRoute`; whichever screen
    /// is on top consumes them once. When Auth is up, that is Auth.
    private func consumePendingRoute() {
        guard let route = env.router.pendingRoute else { return }
        switch route {
        case .reset(let uid, let token):
            env.router.pendingRoute = nil
            recovery = .reset(uid: uid, token: token)
        case .verify(let token):
            env.router.pendingRoute = nil
            Task { _ = await env.session.verifySignup(token: token) }
        default:
            break
        }
    }

    private func close() {
        env.router.cover = nil
        dismiss()
    }
}
