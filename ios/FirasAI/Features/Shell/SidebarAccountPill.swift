import SwiftUI

/// The account row at the foot of the sidebar (`web-chat-ux.md §14`,
/// `web-auth-account-settings.md §4`).
///
/// Three things live here and nothing else: who you are, the way into Settings, and a new
/// conversation. The circle is the door — «الدائرة هي توديني اعدادات و بيها تسجيل خروج» — so the
/// gear icon is gone (the circle was already the obvious target and two controls for one
/// destination is one too many), and **sign out is gone from the sidebar entirely**: it lives in
/// the account page the circle opens, which is where Claude keeps it.
///
/// The plan and the quota are deliberately absent too — they belong to Settings, exactly as on the
/// web.
///
/// The circle wears glass that is actually there: `.floating` alone is `Glass.clear`, which over an
/// opaque sidebar reads as nothing at all («الدائرة تكون ليكويد كلاس مو حيل شفاف»). A tinted fill
/// under the glass and a ring over it give it a body without turning it into a flat button.
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
        if isGuest {
            row
                .contextMenu { guestExitItem }
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
        } else {
            row
        }
    }

    // MARK: - Row

    /// Circle and name are one target: a 30 pt disc is a small thing to ask a thumb for, and the
    /// name points at the same place. New chat sits immediately after it.
    private var row: some View {
        HStack(spacing: 8) {
            Button {
                openAccount()
            } label: {
                HStack(spacing: 10) {
                    avatar
                    Text(displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .bidiIsland(for: displayName, fallback: lang)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(displayName))
            .accessibilityHint(Text(Strings.Common.settings(lang)))

            newChatButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Shell.accountPillHint(lang)))
    }

    // MARK: - Pieces

    private var avatar: some View {
        Text(initial)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.accent)
            .forceLTR()
            .frame(width: 40, height: 40)
            .background { Circle().fill(palette.accentSoft) }
            .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
            .overlay {
                Circle()
                    .strokeBorder(palette.accentRing, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    private var newChatButton: some View {
        Button {
            Haptics.select()
            env.router.newConversation(in: env.router.product)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 40, height: 40)
                .background { Circle().fill(palette.accentSoft) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
        .overlay {
            Circle()
                .strokeBorder(palette.accentRing, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .hoverEffect(.lift)
        .accessibilityLabel(Text(Strings.Chat.newChat(lang)))
    }

    /// A guest has no account page to sign out of — the circle takes them to the sign-up panel
    /// instead — so leaving guest mode, which erases the chats on this device, stays reachable as a
    /// long press rather than as a fourth control nobody presses.
    private var guestExitItem: some View {
        Button(role: .destructive) {
            confirmsGuestExit = true
        } label: {
            Label(Strings.Shell.guestExit(lang), systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    // MARK: - Actions

    private func openAccount() {
        Haptics.select()
        env.router.sheet = .settings(.account)
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
}
