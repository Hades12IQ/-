import SwiftUI

/// The guest upsell (`web-auth-account-settings.md §5.4`, `openSignUpPrompt(feature)`).
///
/// Two pieces of copy: the image variant when the blocked feature is image generation, the generic
/// one for everything else. The primary action closes the sheet and opens Auth in **signup** mode;
/// the guest's local chats stay exactly where they are and `GuestMigration` moves them the moment
/// the account exists, so nothing the guest already wrote is at risk. `لاحقًا` just closes.
struct SignUpPromptSheet: View {

    private let env: AppEnvironment
    private let feature: FeatureKey

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, feature: FeatureKey) {
        self.env = env
        self.feature = feature
    }

    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }

    private var title: String { Strings.Auth.upsellTitle(feature).text(lang) }
    private var message: String { Strings.Auth.upsellBody(feature).text(lang) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                FirasBrandMark(size: 46, showsWordmark: false, palette: palette)
                    .padding(.top, 4)

                Text(verbatim: title)
                    .font(FirasType.scaled(20, scale: prefs.fontScale, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: message)
                    .font(FirasType.scaled(15, scale: prefs.fontScale))
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(lang == .arabic ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)

                primaryButton
                laterButton

                Text(verbatim: Strings.Auth.guestKeepsWork(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .firasSheetBackground(palette)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationSizing(.form)
        .preferredColorScheme(prefs.theme.isLight ? .light : .dark)
        .tint(palette.accent)
        .bidiIsland(for: title, fallback: lang)
    }

    // MARK: - Actions

    private var primaryButton: some View {
        Button {
            createAccount()
        } label: {
            Text(verbatim: Strings.Auth.guestUpgradeCta(lang))
                .font(FirasType.scaled(17, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background { Capsule(style: .continuous).fill(palette.accent) }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Strings.Auth.guestUpgradeCta(lang)))
    }

    private var laterButton: some View {
        Button {
            dismiss()
        } label: {
            Text(verbatim: Strings.Auth.guestLater(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Strings.Auth.guestLater(lang)))
    }

    private func createAccount() {
        Haptics.select()
        // Close this sheet first: `Router.open(.auth(mode:))` sets the cover, and a sheet still on
        // screen would sit on top of it.
        env.router.sheet = nil
        dismiss()
        env.router.open(.auth(mode: .signup))
    }
}
