import SwiftUI

/// The conversation screen. Firas AI, Firas Agent and Firas Brain all render through it — the
/// product only changes the toolbar, the placeholder and which extras a turn may show.
///
/// The screen owns no navigation container of its own: the shell puts each product screen in a
/// `NavigationStack` (iPhone) or the detail column of a `NavigationSplitView` (iPad), so the toolbar
/// below attaches to that one. Sheets are never presented here either — screens set `router.sheet`
/// and the shell presents it (`plan/Features-Shell.md`).
struct ChatScreen: View {

    private let env: AppEnvironment
    private let conversationID: String?
    private let product: ProductKind

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var localID: String?
    /// The value of `Router.newChatNonce` this screen has already honoured. See `prepare()`.
    @State private var seenNewChatNonce: Int = -1
    @State private var historyTrimmed = false

    init(env: AppEnvironment, conversationID: String?, product: ProductKind) {
        self.env = env
        self.conversationID = conversationID
        self.product = product
    }

    var body: some View {
        let palette = env.prefs.palette

        return content
            .background { FirasBackground(palette: palette, showHalo: isEmptyConversation) }
            .toolbar { toolbarContent }
            .navigationBarTitleDisplayMode(.inline)
            /* Keyed on the new-chat counter as well as the id: pressing New chat while already on a
               blank conversation leaves the id at nil, and a task keyed on nil alone never re-runs. */
            .task(id: "\(conversationID ?? "")#\(env.router.newChatNonce)") { await prepare() }
            .task(id: messageCount) { updateHistoryNote() }
    }

    // MARK: - Layout

    private var content: some View {
        composerLayout(
            VStack(spacing: 0) {
                banners
                transcript
                    /* The keyboard had no way out on this screen: dragging the transcript only
                       works once there is something to drag, so on a new conversation it stayed up
                       and covered the answer. Tapping the conversation now dismisses it, the way
                       every other iOS app behaves. */
                    .dismissesKeyboardOnTap()
            }
        )
    }

    @ViewBuilder
    private func composerLayout(_ inner: some View) -> some View {
        if let id = activeID {
            if #available(iOS 26.0, *) {
                inner.safeAreaBar(edge: .bottom) { composer(id: id) }
            } else {
                inner.safeAreaInset(edge: .bottom) { composer(id: id) }
            }
        } else {
            inner
        }
    }

    private func composer(id: String) -> some View {
        ComposerView(
            env: env,
            conversationID: id,
            product: product,
            placeholder: placeholder
        )
    }

    @ViewBuilder
    private var transcript: some View {
        if let id = activeID {
            if isEmptyConversation {
                ScrollView {
                    WelcomeView(
                        product: product,
                        firstName: env.session.user?.firstName,
                        palette: env.prefs.palette,
                        lang: env.prefs.lang,
                        motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
                    )
                    .padding(.top, 60)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(env: env, conversationID: id, product: product)
            }
        } else {
            SkeletonView(
                kind: .transcript,
                palette: env.prefs.palette,
                motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
            )
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if horizontalSizeClass == .compact {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.select()
                    env.router.drawerOpen = true
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .accessibilityLabel(Text(Strings.Chat.openDrawer(env.prefs.lang)))
            }
        }

        ToolbarItem(placement: .principal) {
            principalItem
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Haptics.select()
                env.router.newConversation(in: product)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel(Text(Strings.Chat.newChat(env.prefs.lang)))
        }
    }

    @ViewBuilder
    private var principalItem: some View {
        if product == .ai {
            TierPill(
                tier: env.prefs.tier,
                palette: env.prefs.palette,
                lang: env.prefs.lang,
                motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
            ) {
                Haptics.select()
                env.router.sheet = .tierPicker
            }
        } else {
            Text(product.title(env.prefs.lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(env.prefs.palette.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang

        VStack(spacing: 6) {
            if !env.network.isOnline {
                banner(
                    text: Strings.Chat.offlineBanner(lang),
                    symbol: "wifi.slash",
                    tint: palette.textSecondary,
                    palette: palette,
                    actionTitle: nil,
                    action: nil
                )
            }

            if env.session.sessionExpiredNotice {
                banner(
                    text: Strings.Errors.sessionExpired(lang),
                    symbol: "person.crop.circle.badge.exclamationmark",
                    tint: palette.error,
                    palette: palette,
                    actionTitle: Strings.Chat.sessionExpiredSignIn(lang)
                ) {
                    env.session.sessionExpiredNotice = false
                    env.router.cover = .auth(.login)
                }
            }

            if let strip = env.chat.states[activeID ?? ""]?.errorStrip, !strip.isEmpty {
                banner(
                    text: strip,
                    symbol: "exclamationmark.triangle",
                    tint: palette.error,
                    palette: palette,
                    actionTitle: Strings.Common.retry(lang)
                ) {
                    retryLastTurn()
                }
            }

            if historyTrimmed {
                banner(
                    text: Strings.Chat.historyTrimmed(lang),
                    symbol: "scissors",
                    tint: palette.textMuted,
                    palette: palette,
                    actionTitle: nil,
                    action: nil
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, bannerTopPadding)
        .readingColumn(env.prefs.contentWidth)
    }

    private var bannerTopPadding: CGFloat {
        hasAnyBanner ? 8 : 0
    }

    private var hasAnyBanner: Bool {
        if !env.network.isOnline { return true }
        if env.session.sessionExpiredNotice { return true }
        if historyTrimmed { return true }
        let strip = env.chat.states[activeID ?? ""]?.errorStrip
        return !(strip ?? "").isEmpty
    }

    private func banner(
        text: String,
        symbol: String,
        tint: Color,
        palette: FirasPalette,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - State

    private var activeID: String? {
        conversationID ?? localID
    }

    private var conversation: ChatConversation? {
        guard let activeID else { return nil }
        return env.chat.conversations[activeID]
    }

    private var messageCount: Int {
        conversation?.messages.count ?? 0
    }

    private var isEmptyConversation: Bool {
        guard let conversation else { return conversationID == nil }
        return conversation.messages.isEmpty
    }

    private var placeholder: String {
        let lang = env.prefs.lang
        switch product {
        case .agent:
            return Strings.Chat.composerPlaceholderAgent(lang)
        case .brain:
            return env.brain.activeDocIDs.isEmpty
                ? Strings.Chat.composerPlaceholderBrainEmpty(lang)
                : Strings.Chat.composerPlaceholderBrain(lang)
        case .ai, .code, .studio:
            return Strings.Chat.composerPlaceholder(lang)
        }
    }

    private func prepare() async {
        if let conversationID {
            localID = nil
            seenNewChatNonce = env.router.newChatNonce
            await env.chat.open(conversationID)
            return
        }
        /* A fresh page is owed whenever the counter has moved, even though the id has not: that is
           the "New chat pressed while already on a blank page" case. Without the counter this
           branch saw `localID != nil` and did nothing, so the button looked broken. */
        let nonce = env.router.newChatNonce
        if localID == nil || seenNewChatNonce != nonce {
            localID = env.chat.newConversation(
                product: product,
                flags: (agent: product == .agent, codeProj: false, brainNb: product == .brain)
            )
            seenNewChatNonce = nonce
        }
    }

    /// The window note is worked out once per new turn, never per frame: it walks the whole
    /// conversation.
    private func updateHistoryNote() {
        guard let messages = conversation?.messages, !messages.isEmpty else {
            historyTrimmed = false
            return
        }
        let trimmed = HistoryWindow.window(messages).trimmed
        if historyTrimmed != trimmed { historyTrimmed = trimmed }
    }

    private func retryLastTurn() {
        guard let activeID else { return }
        if let state = env.chat.states[activeID] { state.errorStrip = nil }
        guard let last = conversation?.messages.last(where: { $0.role == .assistant }) else { return }
        ChatTurnActions.regenerate(
            messageID: last.id,
            conversationID: activeID,
            tier: nil,
            env: env
        )
    }
}
