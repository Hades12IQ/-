import SwiftUI

/// The sidebar: the drawer's content on iPhone, the leading column on iPad
/// (`design-brief.md §7.2`, `web-chat-ux.md §2, §11, §14`).
///
/// Top to bottom: brand and bell, the product switcher, the prominent new-conversation row, search,
/// the history filtered to the product on screen, the locally computed usage line, the guest slot,
/// and the account pill. The plan and the quota are deliberately absent from the pill — they belong
/// to Settings.
@MainActor
struct SidebarView: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var query: String = ""

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            SidebarHistoryList(env: env, query: query)
            footer
        }
        /* Opaque on both widths now. It used to be clear on compact because the drawer behind it
           carried glass; that glass is gone (the drawer is a solid panel, like Claude's), so the
           list needs its own ground or it draws on nothing. */
        .background(isRegular ? palette.sidebar : palette.surface)
        .task(id: env.session.identityID) { await refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            FirasBrandMark(size: 24, showsWordmark: true, palette: palette)
                .accessibilityLabel(Text(verbatim: "Firas AI"))

            Spacer(minLength: 8)

            bellButton

            if !isRegular {
                FirasIconButton(
                    symbol: "sidebar.leading",
                    label: Strings.Shell.closeSidebar(lang),
                    palette: palette
                ) {
                    Haptics.select()
                    withAnimation(FirasMotion.sheet) { env.router.drawerOpen = false }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var bellButton: some View {
        Button {
            Haptics.select()
            env.router.sheet = .announcements
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if env.announcements.hasUnseen {
                        Circle()
                            .fill(palette.accent)
                            .frame(width: 9, height: 9)
                            .padding(.top, 8)
                            .padding(.trailing, 7)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Shell.announcements(lang)))
        .accessibilityValue(Text(
            env.announcements.hasUnseen ? Strings.Shell.announcementsUnseen.text(lang) : ""
        ))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            SidebarProductSwitcher(env: env)
            newConversationRow
            SidebarSearch(env: env, query: $query)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var newConversationRow: some View {
        Button {
            Haptics.select()
            env.router.newConversation(in: env.router.product)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                Text(Strings.Chat.newChat(lang))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 42)
            .background { Capsule(style: .continuous).fill(palette.accent) }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(Text(Strings.Chat.newChat(lang)))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Divider().overlay(palette.border)
            usageRow
            if env.session.isGuest {
                guestSlot
            }
            SidebarAccountPill(env: env)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var usageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Strings.Shell.usageTitle(lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Text(Strings.Shell.usageWeek(lang))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
                Spacer(minLength: 0)
                Text(Strings.Settings.Account.planChip(lang))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
            }

            Text(usageSummary)
                .font(.system(size: 11))
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(Strings.Shell.usageNote(lang)))
    }

    private var guestSlot: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Shell.guestLocalNote(lang))
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.select()
                env.router.cover = .auth(.signup)
            } label: {
                VStack(spacing: 1) {
                    Text(Strings.Shell.signUpNow(lang))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(Strings.Shell.signUpNowAlt(lang))
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.textMuted)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background { Capsule(style: .continuous).fill(palette.accentSoft) }
                .overlay { Capsule(style: .continuous).strokeBorder(palette.accentRing, lineWidth: 1) }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Shell.signUpNow(lang)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    /// Seven days of conversation counts per product, computed here and sent nowhere
    /// (`usageNote`). Products with nothing this week are left out rather than shown as zero.
    private var usageSummary: String {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var counts: [ProductKind: Int] = [:]
        for row in env.chat.summaries {
            guard let stamp = Self.date(from: row.updatedAt) ?? Self.date(from: row.createdAt),
                  stamp >= cutoff
            else { continue }
            counts[row.product, default: 0] += 1
        }
        let parts = ProductKind.allCases.compactMap { product -> String? in
            guard let count = counts[product], count > 0 else { return nil }
            return Strings.Shell.usageLine.fmt(
                lang,
                product.title(lang),
                ArabicText.count(count, lang)
            )
        }
        guard !parts.isEmpty else { return Strings.Shell.usageNote(lang) }
        return parts.joined(separator: "  ·  ")
    }

    /// One pass per identity: the list belongs to whoever is signed in, and `loadConversations`
    /// throws away another owner's rows itself.
    private func refresh() async {
        guard env.session.isAuthenticated else { return }
        if !env.chat.isLoadingList {
            await env.chat.loadConversations()
        }
        if !env.announcements.hasLoaded {
            await env.announcements.load()
        }
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
