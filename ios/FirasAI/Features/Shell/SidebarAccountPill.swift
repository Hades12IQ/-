import SwiftUI

/// The account row at the foot of the sidebar (`web-chat-ux.md §14`,
/// `web-auth-account-settings.md §4`).
///
/// Avatar, name, settings, sign out — and deliberately **no plan and no quota**: those live in
/// Settings and in the usage row, exactly as on the web. A guest reads `ضيف`, and signing out is
/// the guest-exit confirmation instead, because it erases the chats on this device.
@MainActor
struct SidebarAccountPill: View {

    private let env: AppEnvironment

    @State private var confirmsGuestExit = false

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var isGuest: Bool { env.session.isGuest }

    var body: some View {
        HStack(spacing: 10) {
            avatar

            Text(displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: displayName, fallback: lang)

            FirasIconButton(
                symbol: "gearshape",
                label: Strings.Common.settings(lang),
                palette: palette
            ) {
                Haptics.select()
                env.router.sheet = .settings(.account)
            }

            FirasIconButton(
                symbol: "rectangle.portrait.and.arrow.right",
                label: isGuest ? Strings.Shell.guestExit(lang) : Strings.Shell.logout(lang),
                palette: palette
            ) {
                signOut()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Shell.accountPillHint(lang)))
        .confirmationDialog(
            Text(Strings.Shell.guestExitConfirm(lang)),
            isPresented: $confirmsGuestExit,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await env.session.logout() }
            } label: {
                Text(Strings.Shell.guestExit(lang))
            }
            Button(role: .cancel) {
                confirmsGuestExit = false
            } label: {
                Text(Strings.Common.cancel(lang))
            }
        }
    }

    // MARK: - Pieces

    private var avatar: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 30, height: 30)
            .overlay {
                Text(initial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .forceLTR()
            }
            .accessibilityHidden(true)
    }

    // MARK: - Identity

    /// `applyUserIdentity`: guest → `ضيف`; otherwise the name, then the email local part, then
    /// `Firas`.
    private var displayName: String {
        if isGuest { return Strings.Settings.Account.guestName.text(lang) }
        guard let user = env.session.user else {
            return Strings.Shell.accountFallbackName.text(lang)
        }
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let local = user.email.split(separator: "@").first.map(String.init) ?? ""
        if !local.isEmpty { return local }
        return Strings.Shell.accountFallbackName.text(lang)
    }

    private var initial: String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = source.first else { return "F" }
        return String(first).uppercased()
    }

    private func signOut() {
        Haptics.select()
        if isGuest {
            confirmsGuestExit = true
        } else {
            Task { await env.session.logout() }
        }
    }
}
