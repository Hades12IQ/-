import SwiftUI

/// The first view in the window, and the only place that reads `SessionStore.phase`.
///
/// Booting plays the MentronX signature — that *is* the loading state, so nothing spins over it —
/// and hands over to a skeleton if identity takes longer than the animation. Signed out is the
/// consent door once, then the landing page. Awaiting verification is the auth screen with its own
/// card. A member or a guest gets the shell. Unreachable also gets the shell, over whatever the
/// device already had, with one honest banner on top (`web-chat-ux.md §1.1–1.6`,
/// `design-brief.md §7.17`, `audit-ios-networking-auth.md §B1 F1`).
@MainActor
struct RootView: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var introFinished = false

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        ZStack {
            FirasBackground(palette: palette, showHalo: true)
                .ignoresSafeArea()

            phaseContent

            // `ToastHostView` lives inside `AppShell`, so the doors that come before the shell —
            // the verification card's «أعدنا الإرسال», the consent and landing pages — would
            // otherwise toast into a screen with nothing drawing it. Exactly one host is mounted
            // at a time; `showsShell` is the same partition as `phaseContent`.
            if !showsShell {
                ToastHostView(env: env)
            }

            if !introFinished {
                MentronXEntryView(palette: palette) {
                    introFinished = true
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
        .tint(palette.accent)
        .animation(.easeOut(duration: 0.18), value: introFinished)
        .task { await boot() }
    }

    // MARK: - Phases

    /// True for exactly the phases that render `AppShell` — which brings its own toast host.
    private var showsShell: Bool {
        switch env.session.phase {
        case .member, .guest, .unreachable:
            return true
        case .booting, .signedOut, .awaitingVerification:
            return false
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch env.session.phase {
        case .booting:
            bootingView
        case .signedOut:
            signedOutFlow
        case .awaitingVerification:
            AuthView(env: env, mode: .signup)
        case .member, .guest:
            AppShell(env: env)
        case .unreachable:
            AppShell(env: env)
                .overlay(alignment: .top) {
                    unreachableBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
        }
    }

    /// After the signature has played, identity is still in flight: show the shape of the app,
    /// never a spinner and never the "you have no conversations" line.
    private var bootingView: some View {
        VStack(spacing: 0) {
            SkeletonView(
                kind: .transcript,
                palette: palette,
                motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
            )
            .padding(.horizontal, 20)
            .padding(.top, 90)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Strings.Shell.bootingLabel(lang)))
    }

    /// The consent door is shown once per device and writes `prefs.consentAccepted` itself, which
    /// is what moves this branch on — there is no second source of truth.
    @ViewBuilder
    private var signedOutFlow: some View {
        if env.prefs.consentAccepted {
            LandingView(env: env)
                .fullScreenCover(item: coverBinding) { cover in
                    preAuthCover(cover)
                }
        } else {
            ConsentView(prefs: env.prefs) {
                // `consentAccepted` has already flipped inside the view; nothing else to do.
            }
        }
    }

    // MARK: - Pre-auth presentation

    /// Signed out, the shell is not on screen, so the router's cover has no host. Only the auth
    /// door can be reached from here; anything else is dropped rather than half-presented.
    private var coverBinding: Binding<AppCover?> {
        Binding(
            get: {
                guard case .auth = env.router.cover else { return nil }
                return env.router.cover
            },
            set: { newValue in
                env.router.cover = newValue
            }
        )
    }

    @ViewBuilder
    private func preAuthCover(_ cover: AppCover) -> some View {
        if case .auth(let mode) = cover {
            AuthView(env: env, mode: mode)
        } else {
            Color.clear
        }
    }

    // MARK: - Unreachable

    private var unreachableBanner: some View {
        let message = Strings.Errors.offline(lang)
        return HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: message, fallback: lang)

            Button {
                Task { await env.session.restore() }
            } label: {
                Text(Strings.Common.retry(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(env.session.isRestoring)
            .opacity(env.session.isRestoring ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .firasGlass(
            .floating,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Boot

    /// `restore()` guards its own re-entry, so a second call from the app lifecycle is free.
    private func boot() async {
        env.network.start()
        if case .booting = env.session.phase {
            await env.session.restore()
        }
    }
}
