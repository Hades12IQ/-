import SwiftUI

/// The credentials form of `AuthView`: Google, the "or" rule, the three fields, the error banner
/// and the action rows. Split out so neither file carries a view body the type checker has to
/// solve in one go.
extension AuthView {

    // MARK: - The whole form

    var credentials: some View {
        VStack(spacing: 16) {
            googleButton
            dividerRow
            fields
            if let bannerText { errorBanner(bannerText) }
            submitButton
            if mode == .login { forgotButton }
            if mode == .signup { termsNote }
            switchRow
        }
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: mode)
        .bidiIsland(for: title, fallback: lang)
    }

    // MARK: - Google

    private var googleButton: some View {
        Button {
            signInWithGoogle()
        } label: {
            HStack(spacing: 10) {
                if env.session.isGoogle {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(palette.textPrimary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityHidden(true)
                }

                Text(verbatim: Strings.Auth.google(lang))
                    .font(FirasType.scaled(16, scale: prefs.fontScale, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .firasGlass(.sheet, palette: palette, in: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .disabled(isBusy)
        .opacity(isBusy ? 0.7 : 1)
        .accessibilityLabel(Text(verbatim: Strings.Auth.google(lang)))
    }

    private var dividerRow: some View {
        HStack(spacing: 12) {
            rule
            Text(verbatim: Strings.Auth.or(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
            rule
        }
        .accessibilityHidden(true)
    }

    private var rule: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(spacing: 11) {
            if mode == .signup {
                field(label: Strings.Auth.name(lang)) {
                    TextField(text: $name, prompt: Text(verbatim: Strings.Auth.name(lang))) {
                        Text(verbatim: Strings.Auth.name(lang))
                    }
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .email }
                }
            }

            field(label: Strings.Auth.email(lang)) {
                TextField(text: $email, prompt: Text(verbatim: Strings.Auth.email(lang))) {
                    Text(verbatim: Strings.Auth.email(lang))
                }
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
                .forceLTR()
            }

            field(label: Strings.Auth.password(lang)) {
                SecureField(text: $password, prompt: Text(verbatim: Strings.Auth.password(lang))) {
                    Text(verbatim: Strings.Auth.password(lang))
                }
                .textContentType(mode == .login ? .password : .newPassword)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { submit() }
                .forceLTR()
            }
        }
        .disabled(isBusy)
    }

    /// One glass field. The label is never drawn — the prompt carries it visually — but it is what
    /// VoiceOver reads, so the field is never an unnamed text box.
    private func field<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .labelsHidden()
            .font(FirasType.scaled(16, scale: prefs.fontScale))
            .foregroundStyle(palette.textPrimary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 15)
            .frame(height: 50)
            .firasGlass(.sheet, palette: palette, in: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            .accessibilityLabel(Text(verbatim: label))
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

    private var submitTitle: String {
        mode == .signup ? Strings.Auth.signupButton(lang) : Strings.Auth.loginButton(lang)
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 9) {
                if env.session.isLoggingIn || env.session.isSigningUp {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(palette.onAccent)
                        .accessibilityHidden(true)
                }

                Text(verbatim: submitTitle)
                    .font(FirasType.scaled(17, scale: prefs.fontScale, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background { Capsule(style: .continuous).fill(palette.accent) }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.75 : 1)
        .accessibilityLabel(Text(verbatim: submitTitle))
    }

    private var forgotButton: some View {
        Button {
            openForgot()
        } label: {
            Text(verbatim: Strings.Auth.forgot(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(Text(verbatim: Strings.Auth.forgot(lang)))
    }

    private var termsNote: some View {
        Text(verbatim: Strings.Auth.termsNote(lang))
            .font(FirasType.caption)
            .foregroundStyle(palette.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private var switchRow: some View {
        HStack(spacing: 6) {
            Text(verbatim: mode == .signup ? Strings.Auth.toLogin(lang) : Strings.Auth.toSignup(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)

            Button {
                switchMode()
            } label: {
                Text(verbatim: mode == .signup ? Strings.Auth.toLoginButton(lang) : Strings.Auth.toSignupButton(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity)
    }
}
