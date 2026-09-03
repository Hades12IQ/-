import SwiftUI

/// Password recovery, both halves (`server-auth-session-account.md §4.13–4.14`,
/// `web-auth-account-settings.md §3.6–3.7`).
///
/// `.forgot` asks for the address and then says the same "check your inbox" sentence whatever the
/// server answered — the endpoint is deliberately anti-enumerating, so the UI must not leak whether
/// the address exists. `.reset` is the `?reset=&uid=` deep link: a new password, checked for the
/// server's 8-character minimum before the request leaves the device, and on success the account is
/// signed in on this device while every other one is signed out.
struct ForgotPasswordSheet: View {

    /// Which half of recovery this sheet is. `Identifiable` so `.sheet(item:)` can carry it.
    enum Mode: Identifiable, Equatable, Sendable {
        case forgot(email: String)
        case reset(uid: String, token: String)

        var id: String {
            switch self {
            case .forgot(let email):
                return "forgot:" + email
            case .reset(let uid, let token):
                return "reset:" + uid + ":" + String(token.prefix(8))
            }
        }
    }

    private let env: AppEnvironment
    private let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var email: String
    @State private var password: String = ""
    @State private var localError: String?
    @State private var sent: Bool = false
    /// `session.errorText` is shared with the card that presented this sheet, so a login failure
    /// would otherwise be waiting inside a password-recovery sheet the moment it opens. Only an
    /// error raised by *this* sheet's own request is shown.
    @State private var attempted: Bool = false

    init(env: AppEnvironment, mode: Mode) {
        self.env = env
        self.mode = mode
        if case .forgot(let address) = mode {
            _email = State(initialValue: address)
        } else {
            _email = State(initialValue: "")
        }
    }

    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }
    private var isBusy: Bool { env.session.isForgot }

    private var isReset: Bool {
        if case .reset = mode { return true }
        return false
    }

    private var title: String {
        isReset ? Strings.Auth.resetTitle(lang) : Strings.Auth.forgotTitle(lang)
    }

    private var subtitle: String {
        isReset ? Strings.Auth.resetSubtitle(lang) : Strings.Auth.forgotSubtitle(lang)
    }

    private var bannerText: String? {
        if let localError, !localError.isEmpty { return localError }
        if attempted, let text = env.session.errorText, !text.isEmpty { return text }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if isReset { resetForm } else { forgotForm }
                if let bannerText { errorBanner(bannerText) }
                actionButton
                closeButton
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .firasSheetBackground(palette)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationSizing(.form)
        .preferredColorScheme(prefs.theme.isLight ? .light : .dark)
        .tint(palette.accent)
        .bidiIsland(for: title, fallback: lang)
        .onChange(of: bannerText) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            AccessibilityNotification.Announcement(newValue).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 9) {
            Text(verbatim: title)
                .font(FirasType.scaled(20, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(verbatim: subtitle)
                .font(FirasType.scaled(14, scale: prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Forms

    @ViewBuilder
    private var forgotForm: some View {
        if sent {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.success)
                    .accessibilityHidden(true)

                Text(verbatim: Strings.Auth.forgotSent(lang))
                    .font(FirasType.scaled(15, scale: prefs.fontScale))
                    .foregroundStyle(palette.textPrimary)
                    .lineSpacing(lang == .arabic ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.surfaceSunken)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            TextField(text: $email, prompt: Text(verbatim: Strings.Auth.email(lang))) {
                Text(verbatim: Strings.Auth.email(lang))
            }
            .labelsHidden()
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit { perform() }
            .forceLTR()
            .font(FirasType.scaled(16, scale: prefs.fontScale))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 15)
            .frame(height: 50)
            .firasGlass(.sheet, palette: palette, in: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            .disabled(isBusy)
            .accessibilityLabel(Text(verbatim: Strings.Auth.email(lang)))
        }
    }

    private var resetForm: some View {
        VStack(spacing: 10) {
            SecureField(text: $password, prompt: Text(verbatim: Strings.Auth.newPassword(lang))) {
                Text(verbatim: Strings.Auth.newPassword(lang))
            }
            .labelsHidden()
            .textContentType(.newPassword)
            .submitLabel(.go)
            .onSubmit { perform() }
            .forceLTR()
            .font(FirasType.scaled(16, scale: prefs.fontScale))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 15)
            .frame(height: 50)
            .firasGlass(.sheet, palette: palette, in: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            .disabled(isBusy)
            .accessibilityLabel(Text(verbatim: Strings.Auth.newPassword(lang)))

            Text(verbatim: Strings.Auth.resetSignedOutOthers(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.error)
                .accessibilityHidden(true)

            Text(verbatim: message)
                .font(FirasType.scaled(14, scale: prefs.fontScale))
                .foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.error.opacity(0.10))
        }
        .bidiIsland(for: message, fallback: lang)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButton: some View {
        if sent, !isReset {
            EmptyView()
        } else {
            Button {
                perform()
            } label: {
                HStack(spacing: 9) {
                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(palette.onAccent)
                            .accessibilityHidden(true)
                    }

                    Text(verbatim: isReset ? Strings.Auth.resetButton(lang) : Strings.Auth.forgotSend(lang))
                        .font(FirasType.scaled(16, scale: prefs.fontScale, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .background { Capsule(style: .continuous).fill(palette.accent) }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.75 : 1)
            .animation(FirasMotion.gated(FirasMotion.composer, motionOn: motionOn), value: isBusy)
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Text(verbatim: sent ? Strings.Common.done(lang) : Strings.Common.cancel(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func perform() {
        guard !isBusy else { return }
        localError = nil
        attempted = true

        switch mode {
        case .forgot:
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                localError = Strings.Auth.forgotNeedEmail(lang)
                return
            }
            Task {
                let accepted = await env.session.forgotPassword(email: address)
                // The endpoint answers 200 whether or not the address exists, so one success
                // sentence covers both and never leaks which addresses are registered. A failure
                // is a rate limit or a dead connection: swapping the form for «تحقّق من بريدك»
                // there would promise a mail nobody sent and leave no way to try again, so the
                // banner explains it and the send button stays where it was.
                guard accepted else {
                    Haptics.error()
                    return
                }
                withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                    sent = true
                }
            }

        case .reset(let uid, let token):
            guard password.count >= 8 else {
                localError = Strings.Auth.passwordShort(lang)
                return
            }
            Task {
                let changed = await env.session.resetPassword(uid: uid, token: token, password: password)
                if changed {
                    password = ""
                    env.toasts.show(Strings.Auth.resetDone(lang))
                    dismiss()
                } else {
                    Haptics.error()
                    if env.session.errorText == nil {
                        localError = Strings.Auth.resetInvalid(lang)
                    }
                }
            }
        }
    }
}
