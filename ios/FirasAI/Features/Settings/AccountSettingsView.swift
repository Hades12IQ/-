import SwiftUI

/// Identity → plan → change email → change password → redeem (admin) → danger zone
/// (`web-auth-account-settings.md §6.1`, `§3.9`, `§10`).
///
/// Two audit fixes live here. Every counter reads "unlimited" for every member today, so four
/// identical tiles collapse to one sentence (`F24`). And the server answers these routes with
/// Arabic sentences: they are never rendered — `SessionStore` maps status and code through
/// `ErrorPresenter` and hands back `errorText` in the reader's language (`F15`).
@MainActor
struct AccountSettingsView: View {

    let env: AppEnvironment

    @State var newEmail = ""
    @State var emailPassword = ""
    @State var currentPassword = ""
    @State var newPassword = ""
    @State var deletePassword = ""
    @State var redeemCode = ""
    @State var isDeleteArmed = false
    @State var notice: Notice?

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            hero

            if env.session.isMember {
                memberSections
            } else if env.session.isGuest {
                guestPanel
            } else {
                signedOutPanel
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 14) {
            Text(initial)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 54, height: 54)
                .background { Circle().fill(palette.accent) }

            VStack(alignment: .leading, spacing: 3) {
                Text(Strings.Settings.Account.eyebrow(lang))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                Text(displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                if let email = env.session.user?.email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .forceLTR()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .surfaceCard(palette)
        .bidiIsland(for: displayName, fallback: lang)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Member

    @ViewBuilder
    private var memberSections: some View {
        planPanel

        if let notice {
            SettingsNoticeBanner(text: notice.text, kind: notice.kind, palette: palette)
        }
        if let error = env.session.errorText, !error.isEmpty {
            SettingsNoticeBanner(text: error, kind: .error, palette: palette)
        }

        changeEmailPanel
        changePasswordPanel

        if env.session.isAdmin {
            redeemPanel
        }

        dangerPanel
        signOutButton
    }

    private var planPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.planHeader(lang),
            palette: palette,
            lang: lang
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Strings.Settings.Account.planChip(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background { Capsule(style: .continuous).fill(palette.accentSoft) }

                Text(Strings.Settings.Account.planBody(lang))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if usageItems.isEmpty {
                    Text(Strings.Settings.Account.unmetered(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    usageList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .bidiIsland(for: Strings.Settings.Account.planBody(lang), fallback: lang)
        }
    }

    private var usageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.Settings.Account.usageHeader(lang))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textMuted)
            ForEach(usageItems) { item in
                HStack(spacing: 8) {
                    Text(item.name(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: 8)
                    Text(
                        Strings.Settings.Account.usageLine.fmt(
                            lang,
                            ArabicText.count(item.used, lang),
                            ArabicText.count(item.limit, lang)
                        )
                    )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Change email

    private var changeEmailPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.changeEmailHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsField(
                title: Strings.Settings.Account.newEmail(lang),
                kind: .email,
                text: $newEmail,
                palette: palette
            )
            SettingsField(
                title: Strings.Settings.Account.currentPassword(lang),
                kind: .password,
                text: $emailPassword,
                palette: palette
            )
            SettingsSubmitButton(
                title: env.session.isAccountOp
                    ? Strings.Settings.working(lang)
                    : Strings.Settings.Account.saveEmail(lang),
                symbol: "envelope",
                palette: palette,
                isWorking: env.session.isAccountOp,
                action: { submitEmail() }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            SettingsNote(text: Strings.Settings.Account.googleHint(lang), palette: palette)
        }
    }

    // MARK: - Change password

    private var changePasswordPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.changePasswordHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsField(
                title: Strings.Settings.Account.currentPassword(lang),
                kind: .password,
                text: $currentPassword,
                palette: palette
            )
            SettingsField(
                title: Strings.Settings.Account.newPassword(lang),
                placeholder: Strings.Settings.Account.passwordHint(lang),
                kind: .password,
                text: $newPassword,
                palette: palette
            )
            SettingsSubmitButton(
                title: env.session.isAccountOp
                    ? Strings.Settings.working(lang)
                    : Strings.Settings.Account.savePassword(lang),
                symbol: "key",
                palette: palette,
                isWorking: env.session.isAccountOp,
                action: { submitPassword() }
            )
            .padding(14)
        }
    }

    // MARK: - Redeem (admin only)

    private var redeemPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.redeemHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsNote(text: Strings.Settings.Account.redeemNote(lang), palette: palette)
            SettingsField(
                title: Strings.Settings.Account.redeemField(lang),
                text: $redeemCode,
                palette: palette
            )
            SettingsSubmitButton(
                title: Strings.Settings.Account.redeemButton(lang),
                symbol: "ticket",
                palette: palette,
                prominent: false,
                isWorking: env.session.isAccountOp,
                action: { submitRedeem() }
            )
            .padding(14)
        }
    }

    // MARK: - Danger zone

    private var dangerPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.dangerHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsNote(text: Strings.Settings.Account.dangerBody(lang), palette: palette)

            if isDeleteArmed {
                SettingsNote(text: Strings.Settings.Account.deleteConfirmBody(lang), palette: palette)
                SettingsField(
                    title: Strings.Settings.Account.currentPassword(lang),
                    kind: .password,
                    text: $deletePassword,
                    palette: palette
                )
                HStack(spacing: 10) {
                    SettingsSubmitButton(
                        title: Strings.Common.cancel(lang),
                        palette: palette,
                        prominent: false,
                        action: { disarmDelete() }
                    )
                    SettingsSubmitButton(
                        title: Strings.Settings.Account.deleteFinal(lang),
                        symbol: "trash",
                        palette: palette,
                        destructive: true,
                        isWorking: env.session.isAccountOp,
                        action: { submitDelete() }
                    )
                }
                .padding(14)
            } else {
                SettingsSubmitButton(
                    title: Strings.Settings.Account.deleteButton(lang),
                    symbol: "exclamationmark.triangle",
                    palette: palette,
                    prominent: false,
                    destructive: true,
                    action: { armDelete() }
                )
                .padding(14)
            }
        }
    }

    private var signOutButton: some View {
        SettingsSubmitButton(
            title: Strings.Settings.Account.signOut(lang),
            symbol: "rectangle.portrait.and.arrow.right",
            palette: palette,
            prominent: false,
            isWorking: env.session.isAccountOp,
            action: { signOut() }
        )
    }

    // MARK: - Guest and signed out

    private var guestPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.guestHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsNote(text: Strings.Settings.Account.guestBody(lang), palette: palette)
            SettingsSubmitButton(
                title: Strings.Settings.Account.guestCTA(lang),
                symbol: "person.crop.circle.badge.plus",
                palette: palette,
                action: { startSignUp() }
            )
            .padding(14)
        }
    }

    private var signedOutPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Account.signedOutTitle(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsNote(text: Strings.Settings.Account.signedOutBody(lang), palette: palette)
            SettingsSubmitButton(
                title: Strings.Settings.Account.signIn(lang),
                symbol: "person.crop.circle",
                palette: palette,
                action: { startSignIn() }
            )
            .padding(14)
        }
    }

    // MARK: - Plumbing

    var palette: FirasPalette { env.prefs.palette }
    var lang: AppLanguage { env.prefs.lang }

    private var displayName: String {
        guard let user = env.session.user else {
            return Strings.Settings.Account.signedOutTitle(lang)
        }
        if user.isGuest { return Strings.Settings.Account.guestName(lang) }
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let local = user.email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "Firas" : local
    }

    private var initial: String {
        guard let user = env.session.user, !user.isGuest else { return "F" }
        let value = user.initial
        return value.isEmpty ? "F" : value
    }

    /// Every plan limit is `-1` today, so this is normally empty and the plan card shows one line
    /// instead of four counters (`audit F24`).
    private var usageItems: [UsageItem] {
        guard let sub = env.session.user?.sub else { return [] }
        let rows = [
            UsageItem(id: "ai", used: sub.used.ai, limit: sub.limits.ai),
            UsageItem(id: "code", used: sub.used.code, limit: sub.limits.code),
            UsageItem(id: "agent", used: sub.used.agent, limit: sub.limits.agent),
            UsageItem(id: "brain", used: sub.used.brain, limit: sub.limits.brain)
        ]
        return rows.filter { $0.limit >= 0 }
    }

    private struct UsageItem: Identifiable {
        let id: String
        let used: Int
        let limit: Int

        var name: LText { Strings.Errors.productName(id) }
    }

    struct Notice {
        let text: String
        let kind: SettingsNoticeBanner.Kind
    }
}
