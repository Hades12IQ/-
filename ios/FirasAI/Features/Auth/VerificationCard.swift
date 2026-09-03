import Combine
import SwiftUI

/// The "check your email" card (`server-auth-session-account.md §4.2–4.4`,
/// `web-auth-account-settings.md §3.5`).
///
/// While it is on screen and the scene is active it polls `POST /api/auth/verify-status` every 3 s
/// through `SessionStore.pollVerification()`; the store stops the phase itself on `verified`,
/// `expired` and `gone`, so the loop simply ends when `phase` leaves `.awaitingVerification`.
/// Going to the background cancels the loop (the task id carries the scene phase) and the card
/// says so instead of pretending to work. Resend is rate limited by the store's own 30 s cooldown,
/// counted down here in the UI language's digits.
///
/// The one-second heartbeat comes from a `Timer` publisher rather than a sleeping task, so the
/// loop is cancelled deterministically by SwiftUI when the card goes away.
struct VerificationCard: View {

    private let env: AppEnvironment
    private let email: String
    private let onBack: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var secondsRemaining: Int = 0
    @State private var note: String?

    init(env: AppEnvironment, email: String, onBack: @escaping () -> Void) {
        self.env = env
        self.email = email
        self.onBack = onBack
    }

    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }
    private var isActive: Bool { scenePhase == .active }

    private var isAwaiting: Bool {
        if case .awaitingVerification = env.session.phase { return true }
        return false
    }

    private var canResend: Bool {
        env.session.canResendVerification && !env.session.isResendingVerification
    }

    private var pollKey: String {
        "\(isAwaiting ? 1 : 0)-\(isActive ? 1 : 0)-\(email)"
    }

    var body: some View {
        VStack(spacing: 16) {
            waiting
            status
            if let note, !note.isEmpty { noteLine(note) }
            if let message = env.session.errorText, !message.isEmpty { errorLine(message) }
            resendButton
            backButton
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .firasGlass(
            .sheet,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .bidiIsland(for: Strings.Auth.verifyWaiting(lang), fallback: lang)
        .task(id: pollKey) {
            await watch()
        }
    }

    // MARK: - Pieces

    private var waiting: some View {
        VStack(spacing: 10) {
            Text(verbatim: email)
                .font(FirasType.mono)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .forceLTR()
                .accessibilityLabel(Text(verbatim: email))

            Text(verbatim: Strings.Auth.verifyWaiting(lang))
                .font(FirasType.scaled(14, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(lang == .arabic ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: some View {
        HStack(spacing: 9) {
            if isActive {
                LiveDot(palette: palette, motionOn: motionOn)
            } else {
                Image(systemName: "pause.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }

            Text(verbatim: isActive ? Strings.Auth.verifyWatching(lang) : Strings.Auth.verifyPaused(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func noteLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(FirasType.caption)
            .foregroundStyle(palette.success)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func errorLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.error)
                .accessibilityHidden(true)

            Text(verbatim: text)
                .font(FirasType.caption)
                .foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var resendButton: some View {
        Button {
            resend()
        } label: {
            HStack(spacing: 8) {
                if env.session.isResendingVerification {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(palette.accent)
                        .accessibilityHidden(true)
                }

                Text(verbatim: resendTitle)
                    .font(FirasType.label)
                    .foregroundStyle(canResend ? palette.accent : palette.textMuted)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background {
                Capsule(style: .continuous)
                    .strokeBorder(canResend ? palette.accentRing : palette.border, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canResend)
        .accessibilityLabel(Text(verbatim: resendTitle))
    }

    private var resendTitle: String {
        guard secondsRemaining > 0 else { return Strings.Auth.resend(lang) }
        return Strings.Auth.resendCountdown.fmt(lang, ArabicText.count(secondsRemaining, lang))
    }

    private var backButton: some View {
        Button {
            Haptics.select()
            onBack()
        } label: {
            Text(verbatim: Strings.Auth.backToLogin(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Strings.Auth.backToLogin(lang)))
    }

    // MARK: - Polling

    /// One immediate read, then one every third heartbeat (3 s, the web's cadence). Ends the moment
    /// the phase leaves `.awaitingVerification` or SwiftUI cancels the task.
    @MainActor
    private func watch() async {
        syncCountdown()
        guard isActive, isAwaiting else { return }

        _ = await env.session.pollVerification()
        guard isAwaiting else { return }

        var beats = 0
        let heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect().values
        for await _ in heartbeat {
            if Task.isCancelled { return }
            syncCountdown()
            guard isAwaiting else { return }

            beats += 1
            if beats % 3 == 0 {
                _ = await env.session.pollVerification()
            }
        }
    }

    private func syncCountdown() {
        guard let until = env.session.resendCooldownEndsAt else {
            if secondsRemaining != 0 { secondsRemaining = 0 }
            return
        }
        let remaining = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
        if remaining != secondsRemaining { secondsRemaining = remaining }
    }

    private func resend() {
        guard canResend else { return }
        Haptics.select()
        note = nil
        Task {
            let accepted = await env.session.resendVerification()
            syncCountdown()
            if accepted {
                note = Strings.Auth.codeResent(lang)
                env.toasts.show(Strings.Auth.resendOk(lang))
            } else if env.session.errorText == nil {
                env.toasts.show(Strings.Auth.resendWait(lang), isError: true)
            }
        }
    }
}
