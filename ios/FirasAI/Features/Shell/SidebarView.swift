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
            /* There is exactly ONE new-conversation control in this panel, and it is the glass
               circle beside the account name in `SidebarAccountPill` — «و نيو جات على اليمين
               منها». The floating accent pill that used to hover over the bottom of this list sat
               about 60 pt above that circle, so the drawer shipped with two New chat buttons in
               view at once. */
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

    /// The name, then the two chips. `spacing: 2` because a pair of round chrome buttons should
    /// read as one control the way `ChatScreen`'s compose-and-«…» pair does; the 44 pt hit boxes
    /// already carry 3 pt of air around each 38 pt chip, so the visible gap lands at 8. The
    /// `Spacer` keeps the wordmark off them regardless.
    private var header: some View {
        HStack(spacing: 2) {
            wordmark

            Spacer(minLength: 8)

            /* THE BELL, AND NOTHING ELSE. A close button inside the drawer was the thing the
               owner circled: it duplicated three gestures that already close it - the swipe, the
               tap on the scrim, and the same toolbar chip on the screen behind - and it was the
               only control up here wearing a second look. «شيلها اريدك يبقى بدالها بس زر
               التحديثات». What is left is the announcements bell, in its glass circle. */
            bellButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// **The chip is the button.** `sidebar.leading` is one control with two states — closed, where
    /// it lives in the conversation's toolbar, and open, where it lives here — and the owner circled
    /// it in both because they did not look like the same thing. In the toolbar the system draws the
    /// glyph inside a soft round chip; in here it was a `FirasIconButton`, whose non-prominent
    /// branch is literally `Circle().fill(Color.clear)` — a glyph lying on the ground. Same for the
    /// bell beside it. This is the toolbar chip, off the toolbar, and it is not a new invention:
    /// `AppShell.drawerButton` already draws exactly this — 38 pt circle, 15 pt semibold glyph,
    /// `.floating` glass — for the Studio screen, which has no toolbar to put the button in either.
    ///
    /// The one thing added on top of `drawerButton` is a fill, and it is not decoration. `.floating`
    /// is `Glass.clear` at a 0.018 tint, which needs something behind it to refract; this panel is
    /// opaque, so over it the glass alone reads as nothing at all — the lesson `SidebarAccountPill`
    /// two files over already learned the hard way («الدائرة تكون ليكويد كلاس مو حيل شفاف»). It gave
    /// its circles a body with a tinted fill under the glass and a ring over it, and these do the
    /// same in the neutral pair (`surfaceSunken`/`border`) rather than the accent one, because the
    /// toolbar chip they are matching is chrome, not an accent control.
    ///
    /// 38 pt of chip inside a 44 pt target, the `FirasPill` rule: what the eye reads and what the
    /// thumb has to hit are two different numbers.
    private func headerChip(
        symbol: String,
        label: String,
        showsBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 38, height: 38)
                .background { Circle().fill(chipFill) }
                .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
                .overlay {
                    Circle()
                        .strokeBorder(palette.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if showsBadge { unseenDot }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(Text(label))
    }

    /// The ground the panel is *not* standing on, so the disc is always one step off it. `body`
    /// grounds the drawer on `surface` and the iPad column on `sidebar`, and in every dark theme
    /// `sidebar` and `surfaceSunken` are the same hex — filling with `surfaceSunken` on both would
    /// have drawn an invisible chip on the iPad in five of the six themes.
    private var chipFill: Color {
        isRegular ? palette.surface : palette.surfaceSunken
    }

    /// Parked at the 45° of the chip rather than at the corner of the hit box, so it rides the ring
    /// like a badge instead of floating off the button.
    private var unseenDot: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 9, height: 9)
            .padding(.top, 3)
            .padding(.trailing, 3)
            .allowsHitTesting(false)
    }

    /// The wordmark alone, and larger — «وخر الشعار مناك و بقي بس Firas AI بالانكليزي و كبر
    /// الجملتين». The drawn mark went with it: it is already the app icon, it is already the first
    /// thing on the empty conversation, and a third copy of it 14 pt from the edge of a list of
    /// titles was the one piece of chrome in this panel that said nothing. Two words, one of them
    /// in the accent, at a size that reads as a title rather than as a badge — Claude's drawer puts
    /// its own name here at exactly this weight.
    ///
    /// `forceLTR` because a Latin name in an Arabic shell must never be re-ordered, and `verbatim`
    /// because a brand is not copy to be translated.
    private var wordmark: some View {
        HStack(spacing: 6) {
            Text(verbatim: "Firas")
                .foregroundStyle(palette.textPrimary)
            Text(verbatim: "AI")
                .foregroundStyle(palette.accent)
        }
        .font(.system(size: 25, weight: .semibold, design: .rounded))
        .tracking(-0.4)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .forceLTR()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Firas AI"))
        .accessibilityAddTraits(.isHeader)
    }

    /// The bell was the other half of the owner's circle: it sat beside the drawer toggle with no
    /// chip either, a shade dimmer (`textSecondary`), and 4 pt smaller. Three differences between
    /// two buttons standing next to each other. It is now the same chip at the same weight — the
    /// only thing it keeps of its own is the dot.
    private var bellButton: some View {
        headerChip(
            symbol: "bell",
            label: Strings.Shell.announcements(lang),
            showsBadge: env.announcements.hasUnseen
        ) {
            Haptics.select()
            env.router.sheet = .announcements
        }
        .accessibilityValue(Text(
            env.announcements.hasUnseen ? Strings.Shell.announcementsUnseen.text(lang) : ""
        ))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            SidebarProductSwitcher(env: env)
            SidebarSearch(env: env, query: $query)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
