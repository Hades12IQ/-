import SwiftUI

/// One conversation, in the two shapes the app shows it in.
///
/// `.compact` is the drawer's dense line — a title, a live dot, a selection wash. `.card` is the
/// all-chats page's rounded card, the owner's request after Claude's own list: the title centred
/// inside a rounded rectangle with the time it was last touched underneath. Both shapes carry the
/// same four verbs, because a conversation you can rename in the drawer and not on the page is a
/// conversation the app disagrees with itself about.
extension SidebarHistoryList {

    enum RowStyle: Hashable, Sendable {
        /// The drawer's dense line.
        case compact
        /// The all-chats page's rounded card.
        case card
    }

    @MainActor
    struct Row: View {

        private let env: AppEnvironment
        private let summary: ChatSummary
        private let style: RowStyle

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        @State private var isRenaming = false
        @State private var draftTitle: String = ""
        @FocusState private var renameFocused: Bool

        init(env: AppEnvironment, summary: ChatSummary, style: RowStyle) {
            self.env = env
            self.summary = summary
            self.style = style
        }

        private var palette: FirasPalette { env.prefs.palette }
        private var lang: AppLanguage { env.prefs.lang }
        private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
        private var isLive: Bool { env.jobs.isLive(conversationID: summary.id) }
        private var isSelected: Bool { env.router.selectedConversationID == summary.id }

        private var title: String {
            let trimmed = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Strings.Shell.untitledChat.text(lang) : trimmed
        }

        /// The line under a card title: what it is doing, or when it was last touched.
        private var caption: String {
            if isLive { return Strings.Shell.stillWorking.text(lang) }
            let stamp = summary.updatedAt.isEmpty ? summary.createdAt : summary.updatedAt
            return SidebarHistoryList.relativeTime(from: stamp, lang: lang)
        }

        var body: some View {
            Group {
                if isRenaming {
                    renameField
                } else {
                    openButton
                }
            }
            .contextMenu { menu }
        }

        // MARK: - Open

        private var openButton: some View {
            Button {
                Haptics.select()
                env.router.select(conversationID: summary.id, product: env.router.product)
            } label: {
                switch style {
                case .compact: compactBody
                case .card: cardBody
                }
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(caption))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }

        private var compactBody: some View {
            HStack(spacing: 8) {
                if isLive {
                    LiveDot(palette: palette, motionOn: motionOn)
                } else if summary.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 8)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bidiIsland(for: title, fallback: lang)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? palette.accentSoft : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        /* Centred text needs no bidi island: a centred line has no leading edge to get wrong, and
           `Text` already resolves Arabic and Latin runs correctly inside one paragraph. */
        private var cardBody: some View {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 5) {
                    if isLive {
                        LiveDot(palette: palette, motionOn: motionOn)
                    } else if summary.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.textMuted)
                            .accessibilityHidden(true)
                    }
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 12.5))
                            .foregroundStyle(isLive ? palette.accent : palette.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background { cardShape.fill(isSelected ? palette.accentSoft : palette.surface) }
            .overlay {
                cardShape
                    .strokeBorder(isSelected ? palette.accentRing : palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(cardShape)
            .shadow(color: Color.black.opacity(palette.isLightFamily ? 0.04 : 0.12), radius: 3, y: 1)
            .contentShape(cardShape)
        }

        private var cardShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        }

        // MARK: - Rename

        @ViewBuilder
        private var renameField: some View {
            let field = TextField(text: $draftTitle) {
                Text(Strings.Shell.renamePrompt(lang))
                    .foregroundStyle(palette.textMuted)
            }
            .textFieldStyle(.plain)
            .font(.system(size: style == .card ? 16 : 14.5, weight: style == .card ? .semibold : .regular))
            .foregroundStyle(palette.textPrimary)
            .multilineTextAlignment(style == .card ? .center : .leading)
            .focused($renameFocused)
            .submitLabel(.done)
            .onSubmit { commitRename() }
            .onChange(of: renameFocused) { _, focused in
                if !focused { commitRename() }
            }
            .accessibilityLabel(Text(Strings.Shell.renamePrompt(lang)))

            if style == .card {
                field
                    .padding(.horizontal, 16)
                    .padding(.vertical, 21)
                    .frame(maxWidth: .infinity)
                    .background { cardShape.fill(palette.surfaceSunken) }
                    .overlay { cardShape.strokeBorder(palette.accentRing, lineWidth: 1) }
            } else {
                field
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.surfaceSunken)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.accentRing, lineWidth: 1)
                    }
            }
        }

        private func beginRename() {
            draftTitle = summary.title
            isRenaming = true
            // The field does not exist until this update lands; focusing it in the same turn is a
            // no-op, so the request waits one main-actor turn.
            Task { renameFocused = true }
        }

        private func commitRename() {
            guard isRenaming else { return }
            let wanted = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            isRenaming = false
            renameFocused = false
            draftTitle = ""
            guard !wanted.isEmpty, wanted != summary.title else { return }
            Task { await env.chat.rename(summary.id, title: wanted) }
        }

        // MARK: - Menu

        @ViewBuilder
        private var menu: some View {
            Button {
                beginRename()
            } label: {
                Label {
                    Text(Strings.Common.rename(lang))
                } icon: {
                    Image(systemName: "pencil")
                }
            }

            Button {
                Task { await env.chat.pin(summary.id, !summary.pinned) }
            } label: {
                Label {
                    Text(summary.pinned ? Strings.Shell.unpin.text(lang) : Strings.Shell.pin.text(lang))
                } icon: {
                    Image(systemName: summary.pinned ? "pin.slash" : "pin")
                }
            }

            Button {
                env.router.sheet = .share(conversationID: summary.id, messageCID: nil)
            } label: {
                Label {
                    Text(Strings.Common.share(lang))
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }

            Divider()

            Button(role: .destructive) {
                if isRenaming {
                    isRenaming = false
                    draftTitle = ""
                }
                Haptics.select()
                Task { await env.chat.delete(summary.id) }
            } label: {
                Label {
                    Text(Strings.Common.delete(lang))
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    // MARK: - Placeholders

    /// The five states a history list can be in with nothing to draw: loading, load error, a search
    /// that found nothing, a pinned filter with nothing pinned, and a genuinely empty product.
    @MainActor
    struct Placeholder: View {

        private let env: AppEnvironment
        private let query: String
        private let pinnedOnly: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(env: AppEnvironment, query: String, pinnedOnly: Bool) {
            self.env = env
            self.query = query
            self.pinnedOnly = pinnedOnly
        }

        private var palette: FirasPalette { env.prefs.palette }
        private var lang: AppLanguage { env.prefs.lang }
        private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
        private var trimmedQuery: String {
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @ViewBuilder
        var body: some View {
            if env.chat.isLoadingList {
                SkeletonView(kind: .sidebar, palette: palette, motionOn: motionOn)
                    .padding(.horizontal, 12)
            } else if let error = env.chat.listError {
                EmptyStateView(
                    title: Strings.Chat.chatsLoadError.text(lang),
                    subtitle: error,
                    buttonTitle: Strings.Common.retry(lang),
                    palette: palette
                ) {
                    Task { await env.chat.loadConversations() }
                }
            } else if !trimmedQuery.isEmpty {
                EmptyStateView(
                    title: Strings.Shell.searchEmptyTitle.text(lang),
                    subtitle: Strings.Shell.searchEmptySubtitle.text(lang),
                    buttonTitle: nil,
                    palette: palette,
                    action: nil
                )
            } else if pinnedOnly {
                EmptyStateView(
                    title: Strings.Shell.pinnedEmptyTitle.text(lang),
                    subtitle: Strings.Shell.pinnedEmptySubtitle.text(lang),
                    buttonTitle: nil,
                    palette: palette,
                    action: nil
                )
            } else {
                EmptyStateView(
                    title: Strings.Shell.emptyHistory(for: env.router.product).text(lang),
                    subtitle: nil,
                    buttonTitle: Strings.Chat.newChat(lang),
                    palette: palette
                ) {
                    env.router.newConversation(in: env.router.product)
                }
            }
        }
    }

    // MARK: - Relative time

    /// «قبل ٣ ساعات» — the card's caption. Anything a week old or more becomes a plain date, which
    /// is more useful than counting days nobody counts.
    static func relativeTime(from raw: String?, lang: AppLanguage) -> String {
        guard let stamp = timestamp(from: raw) else { return "" }
        let seconds = Date().timeIntervalSince(stamp)
        if seconds < 60 { return Strings.Shell.justNow.text(lang) }

        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return ArabicPlurals.count(
                minutes, lang,
                zero: Strings.Shell.minutesAgoZero,
                one: Strings.Shell.minutesAgoOne,
                two: Strings.Shell.minutesAgoTwo,
                few: Strings.Shell.minutesAgoFew,
                many: Strings.Shell.minutesAgoMany,
                other: Strings.Shell.minutesAgoOther
            )
        }

        let hours = minutes / 60
        if hours < 24 {
            return ArabicPlurals.count(
                hours, lang,
                zero: Strings.Shell.hoursAgoZero,
                one: Strings.Shell.hoursAgoOne,
                two: Strings.Shell.hoursAgoTwo,
                few: Strings.Shell.hoursAgoFew,
                many: Strings.Shell.hoursAgoMany,
                other: Strings.Shell.hoursAgoOther
            )
        }

        let days = hours / 24
        if days == 1 { return Strings.Shell.relativeYesterday.text(lang) }
        if days < 7 {
            return ArabicPlurals.count(
                days, lang,
                zero: Strings.Shell.daysAgoZero,
                one: Strings.Shell.daysAgoOne,
                two: Strings.Shell.daysAgoTwo,
                few: Strings.Shell.daysAgoFew,
                many: Strings.Shell.daysAgoMany,
                other: Strings.Shell.daysAgoOther
            )
        }
        return absoluteDate(stamp, lang: lang)
    }

    /// A medium date in the reader's own numerals. Built per call rather than cached, because a
    /// shared `DateFormatter` would be mutable state living outside any actor.
    static func absoluteDate(_ date: Date, lang: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang == .arabic ? "ar-IQ-u-nu-arab" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
