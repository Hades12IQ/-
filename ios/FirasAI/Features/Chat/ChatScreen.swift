import SwiftUI

/// The conversation screen. Firas AI, Firas Agent and Firas Brain all render through it — the
/// product only changes the toolbar, the placeholder and which extras a turn may show.
///
/// The screen owns no navigation container of its own: the shell puts each product screen in a
/// `NavigationStack` (iPhone) or the detail column of a `NavigationSplitView` (iPad), so the toolbar
/// below attaches to that one. Navigation sheets are never presented here either — screens set
/// `router.sheet` and the shell presents it (`plan/Features-Shell.md`). The one exception is the
/// export pair — the format picker and the share sheet for the file it produced. Neither is a
/// destination, the second carries a temp file that dies with this screen, and routing them would
/// mean teaching the router about `URL`s it can never restore.
///
/// **The top-right corner has two states**, and which one is showing is decided by whether anything
/// has been said yet:
///
/// * an empty conversation shows ONE control — the temporary-chat switch. Nothing has been written
///   anywhere yet, so the moment before the first message is the only honest moment to offer a mode
///   that promises nothing ever will be.
/// * a conversation with a turn in it shows TWO — New chat, and `ChatTopBarMenu`, which carries
///   share, pin, rename, export and delete. The pair reads as one pill, the way Claude's app draws
///   the compose glyph and its «…».
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
    /// The whole conversation as one document: first the picker that asks which kind of document,
    /// then the share sheet for the file that came out. Nothing offered either before, so
    /// `ExportController.export(_:conversation:)` and the nine writers behind it were unreachable.
    @State private var exportSheet: ChatExportRoute?
    @State private var isExportingTranscript = false
    /// Raised the instant the switch is flipped on and consumed by the next `prepare()`, which is
    /// the one place a conversation is minted. The mode is deliberately not remembered anywhere
    /// else: coming back tomorrow to an app that is silently discarding your work would be the
    /// worst possible way to learn this feature exists.
    @State private var armTemporary = false
    @State private var isConfirmingTemporaryExit = false

    init(env: AppEnvironment, conversationID: String?, product: ProductKind) {
        self.env = env
        self.conversationID = conversationID
        self.product = product
    }

    var body: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang

        return content
            .background { FirasBackground(palette: palette, showHalo: isEmptyConversation) }
            .environment(\.firasMathPersistenceAllowed, !isTemporary)
            .toolbar { toolbarContent }
            .navigationBarTitleDisplayMode(.inline)
            /* Keyed on the new-chat counter as well as the id: pressing New chat while already on a
               blank conversation leaves the id at nil, and a task keyed on nil alone never re-runs. */
            .task(id: "\(conversationID ?? "")#\(env.router.newChatNonce)") { await prepare() }
            .task(id: messageCount) { updateHistoryNote() }
            .sheet(item: $exportSheet) { route in
                exportSheetBody(route)
            }
            .confirmationDialog(
                Strings.Chat.temporaryAsk(lang),
                isPresented: $isConfirmingTemporaryExit,
                titleVisibility: .visible
            ) {
                Button(Strings.Chat.temporaryEnd(lang), role: .destructive) {
                    env.router.newConversation(in: product)
                }
                Button(Strings.Common.cancel(lang), role: .cancel) {}
            }
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
                    openDrawer()
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
            trailingControls
        }
    }

    /// One control before the first message, two after it.
    @ViewBuilder
    private var trailingControls: some View {
        if isEmptyConversation {
            if offersTemporary {
                temporaryToggle
            } else {
                newChatButton
            }
        } else if let id = activeID {
            HStack(spacing: 2) {
                newChatButton
                ChatTopBarMenu(
                    env: env,
                    conversationID: id,
                    product: product,
                    isExporting: isExportingTranscript,
                    onExport: { exportSheet = .picker },
                    onEndTemporary: { newChatTapped() }
                )
            }
        } else {
            newChatButton
        }
    }

    private var newChatButton: some View {
        Button {
            newChatTapped()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel(Text(Strings.Chat.newChat(env.prefs.lang)))
    }

    /// The switch, and the only way into the mode. Flipping it on does not convert the conversation
    /// on screen: that one may have been on the server for an hour, and a switch claiming to
    /// un-save it would be the one lie this feature cannot afford. It opens a new one instead.
    @ViewBuilder
    private var temporaryToggle: some View {
        let lang = env.prefs.lang
        let on = isTemporary
        let button = Button {
            temporaryToggleTapped()
        } label: {
            Image(systemName: on ? "shield.fill" : "shield")
        }
        .accessibilityLabel(Text(on ? Strings.Chat.temporaryEnd.text(lang) : Strings.Chat.temporaryStart.text(lang)))
        .accessibilityValue(Text(on ? Strings.Chat.temporaryTitle.text(lang) : ""))

        // Two branches rather than `.tint(on ? accent : nil)`: an optional colour in a ternary is
        // the kind of expression that picks the wrong `tint` overload on a bad day.
        if on {
            button.tint(env.prefs.palette.accent)
        } else {
            button
        }
    }

    /// The picker and the finished file share one `.sheet`, so choosing a format has to leave the
    /// picker before the share sheet can arrive. `ExportFormatPicker` dismisses itself the moment it
    /// hands the format over, and the writing that follows is asynchronous — by the time there is a
    /// file to show, the sheet is free.
    @ViewBuilder
    private func exportSheetBody(_ route: ChatExportRoute) -> some View {
        switch route {
        case .picker:
            ExportFormatPicker(
                lang: env.prefs.lang,
                palette: env.prefs.palette,
                isWorking: isExportingTranscript
            ) { format in
                exportTranscript(format)
            }
        case .file(let finished):
            // `export:` and not `url:`. A picture of a long thread is several PNGs, and `url` is
            // page one; sharing that alone leaves the rest behind without saying so.
            FirasActivitySheet(export: finished)
        }
    }

    private func exportTranscript(_ format: ExportController.Format) {
        guard !isExportingTranscript, let conversation else { return }
        isExportingTranscript = true
        let controller = ExportController(env: env)
        let picked = Date()
        Task {
            await controller.export(format, conversation: conversation)
            isExportingTranscript = false
            if let finished = controller.result {
                await ChatExportRoute.settle(since: picked)
                exportSheet = .file(finished)
            }
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

    /// The drawer does not overlay this screen any more — it pushes it aside, and the panel and the
    /// conversation travel on one spring that `CompactDrawer` owns (`DrawerMotion`). So this button
    /// only raises the flag: wrapping it in a `withAnimation` of its own would put a second,
    /// competing transaction on the same frame. The keyboard is put away by the drawer, on the same
    /// frame it starts to move, so the conversation is not pushed out from under a raised keyboard.
    private func openDrawer() {
        Haptics.select()
        env.router.drawerOpen = true
    }

    // MARK: - The temporary conversation

    /// Offered on Firas AI only. Code keeps projects and Brain keeps notebooks, so a switch
    /// promising the opposite is one that cannot mean what it says there.
    private var offersTemporary: Bool {
        product == .ai
    }

    private var isTemporary: Bool {
        conversation?.ephemeral ?? false
    }

    private func temporaryToggleTapped() {
        Haptics.select()
        if isTemporary, temporaryHasSomethingToLose {
            isConfirmingTemporaryExit = true
            return
        }
        // Both directions leave through the same door: `prepare()` discards whatever temporary
        // conversation is alive and mints the next page, temporary or not.
        armTemporary = !isTemporary
        env.router.newConversation(in: product)
    }

    private func newChatTapped() {
        Haptics.select()
        if isTemporary, temporaryHasSomethingToLose {
            isConfirmingTemporaryExit = true
            return
        }
        env.router.newConversation(in: product)
    }

    private var temporaryHasSomethingToLose: Bool {
        guard let activeID else { return false }
        return hasSomethingToLose(activeID)
    }

    /// The composer counts. A question typed and not yet sent is still a question, and it is the
    /// one this mode exists for.
    private func hasSomethingToLose(_ id: String) -> Bool {
        if !(env.chat.conversation(id)?.messages.isEmpty ?? true) { return true }
        let draft = env.drafts.draft(for: DraftStore.key(conversationID: id))
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every exit from a temporary conversation comes through here — the switch, New chat, the menu
    /// item, and opening any other conversation from the drawer. The record is found in the store
    /// rather than remembered in a handle, so the two can never drift apart.
    private func dropTemporary() async {
        guard offersTemporary else { return }
        let ids: [String] = env.chat.conversations.filter { $0.value.ephemeral }.map { $0.key }
        guard !ids.isEmpty else { return }
        var lost = false
        for id in ids {
            if hasSomethingToLose(id) { lost = true }
            await env.chat.discardTemporary(id)
        }
        if lost {
            env.toasts.show(Strings.Chat.temporaryEnded(env.prefs.lang))
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

            if let strip = errorStrip, !strip.isEmpty {
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
        return !(errorStrip ?? "").isEmpty
    }

    /* THROUGH `resolve`, NEVER THROUGH THE RAW SUBSCRIPT — the same note this file already carries
       at `conversation`, and the same cause. `states` is keyed by the LOCAL id
       (`ChatStore.state(for:)` resolves before it files), so a screen opened by SERVER id — a
       notification tap, a shared link — read nothing here: the failure strip never appeared, and
       with it went the only Retry on the screen. `resolve` returns the id unchanged when it is
       already a key, so nothing changes for a conversation opened from the drawer. */
    private var liveState: ConversationState? {
        guard let activeID else { return nil }
        return env.chat.states[env.chat.resolve(activeID)]
    }

    private var errorStrip: String? {
        liveState?.errorStrip
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

    /* THROUGH `conversation(_:)`, NEVER THROUGH THE DICTIONARY. A conversation that started here
       and was then saved is filed under its local `ios_…` key with the server id beside it, so a
       screen opened by server id — a notification tap, a shared link — looks the record up under a
       key the dictionary does not have. It found nothing, and everything reading through it went
       quiet with it: the export wrote no file, the strip's Retry retried nothing, the temporary
       banner stayed down. `ChatStore.conversation(_:)` resolves either id onto the one record,
       which is why `ChatTopBarMenu` (which does exactly that) could offer an export this screen
       then silently declined to perform. */
    private var conversation: ChatConversation? {
        guard let activeID else { return nil }
        return env.chat.conversation(activeID)
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
        let arming = armTemporary
        armTemporary = false

        if let conversationID {
            await dropTemporary()
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
            await dropTemporary()
            let minted = env.chat.newConversation(
                product: product,
                flags: (agent: product == .agent, codeProj: false, brainNb: product == .brain)
            )
            if arming {
                // Read once, here, and never again: a conversation that began as temporary stays
                // temporary for as long as it exists.
                env.chat.mutate(minted) { conversation in
                    conversation.ephemeral = true
                }
                env.toasts.show(Strings.Chat.temporaryStarted(env.prefs.lang))
            }
            localID = minted
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

    /// Retry the turn that FAILED — never the one before it.
    ///
    /// `SendPipeline.failTurn` removes the failed turn's empty placeholder, so "the last assistant
    /// row" is the PREVIOUS turn's answer whenever a turn fails before a single character arrives.
    /// Regenerating that row re-answered the previous question and overwrote its answer, and on a
    /// first-turn failure it did nothing at all. So the lookup starts at the last QUESTION: an
    /// answer row after it is the failed turn's own row and may be regenerated; no row after it
    /// means the placeholder was dropped, and the question itself is asked again (its row is
    /// removed first, so the transcript does not show it twice).
    private func retryLastTurn() {
        guard let activeID, let messages = conversation?.messages else { return }
        if let state = liveState { state.errorStrip = nil }
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return }

        let after = messages[messages.index(after: userIndex)...]
        if let answer = after.first(where: { $0.role == .assistant }) {
            ChatTurnActions.regenerate(
                messageID: answer.id,
                conversationID: activeID,
                tier: nil,
                env: env
            )
            return
        }

        let question = messages[userIndex]
        let text = question.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        env.chat.mutate(activeID) { conversation in
            conversation.messages.removeAll { $0.id == question.id && $0.role == .user }
        }
        let chat = env.chat
        let kind = product
        Task {
            await chat.send(text: text, attachments: [], in: activeID, product: kind)
        }
    }
}

// MARK: - The export's one sheet

/// The two halves of an export — «which kind of file» and «here it is» — as one route.
///
/// One `Identifiable` case list rather than two separate `.sheet` modifiers: SwiftUI presents at
/// most one sheet per view, and stacking them is how a sheet ends up silently never presenting
/// (`AssistantFileSheet` and `LongFileViewer.SheetRoute` carry the same note for the same reason).
/// Shared by the top-bar menu's export and the action row's, because both walk the same two steps.
enum ChatExportRoute: Identifiable {
    /// Pick the format: `ExportFormatPicker`, nine rows in three groups.
    case picker
    /// The written file, on its way to the share sheet.
    case file(ExportController.Export)

    var id: String {
        switch self {
        case .picker: return "picker"
        case .file(let export): return "file-" + export.id.uuidString
        }
    }

    /// How long a sheet takes to leave the screen.
    ///
    /// The two halves share one slot, and the picker dismisses itself the instant it hands the
    /// format over. A `.sheet(item:)` set from nil to a value while the previous presentation is
    /// still animating out is dropped — no sheet, no error, nothing — and a small `.txt` of a
    /// short thread is written in a few milliseconds, well inside that window. So the finished
    /// file waits out whatever is left of the animation before it asks for the slot.
    static let dismissal: TimeInterval = 0.42

    /// Sleeps for the remainder of `dismissal` since `start`, and for nothing at all when the
    /// export already took longer than that — which every document of any size does.
    static func settle(since start: Date) async {
        let remaining = dismissal - Date().timeIntervalSince(start)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
}
