import SwiftUI

/// One answer, rendered as a document rather than a bubble (`design-brief.md §7.6`).
///
/// There is no header on an answer any more: no avatar mark, no `FIRAS` wordmark, no tier pill.
/// Repeated once per turn down the whole conversation, that strip was chrome the reader had already
/// read — the toolbar's tier pill says which model is answering, and an answer that is not in a
/// bubble is already unmistakably not the reader's own words. Removing it lets the first line of the
/// answer be the first thing on the page, which is how Claude reads and what the owner asked for.
///
/// Order: version pager · retry note · thinking · body (markdown, ask panel or card) · Start pill ·
/// quick replies · action row. Only the row that is actually streaming reads
/// `ConversationState.liveText`; every other row is `Equatable` on its own content and is skipped
/// entirely while an answer above or below it grows (`audit-ios-chat.md §Critical C5`).
struct AssistantTurnView: View, Equatable {

    let env: AppEnvironment
    let message: ChatMessage
    let conversationID: String
    let product: ProductKind
    let palette: FirasPalette
    let lang: AppLanguage
    let scale: FontScale
    let motionOn: Bool

    /// True only for the one row the current turn is writing into.
    let isStreaming: Bool
    /// The text as it arrives; empty for every settled row.
    let liveText: String
    let liveReasoning: String
    /// A localized "searching / thinking" line shown before the first token.
    let phaseLabel: String?
    /// The action row belongs to the latest answer; every turn keeps its long-press menu.
    let isLatest: Bool
    /// `PlanCycle.showsStartPill` resolved for **this** message (`web-plan-mode.md §7.7`).
    let showsPlanPill: Bool
    /// The cycle is waiting for answers, so a bare `json` block counts as an ask (defect D11).
    let expectsAsk: Bool
    /// The long-file worker's progress for THIS row, when the turn in flight is a `longfile` job.
    /// `nil` on every other turn, which is every turn but one.
    let longFileProgress: LongFileProgress?

    @State private var revealed = false

    // Deliberately `internal`, not `private`: the fence wiring lives in
    // `AssistantTurnView+Fences.swift`, and a `private` member is visible only to extensions in the
    // SAME file — the note `SongCard` carries for the same reason.

    /// The document a non-durable file card last built, kept so the card can show its real size.
    @State var preparedFile: ExportController.Export?
    /// One build at a time, and the card says so instead of looking inert.
    @State var isPreparingFile = false
    /// ONE sheet for preview, share and save. Three `.sheet(item:)` on a single view is a known way
    /// to get a sheet that silently never presents.
    @State var fileSheet: AssistantFileSheet?

    init(
        env: AppEnvironment,
        message: ChatMessage,
        conversationID: String,
        product: ProductKind,
        palette: FirasPalette,
        lang: AppLanguage,
        scale: FontScale,
        motionOn: Bool,
        isStreaming: Bool,
        liveText: String,
        liveReasoning: String,
        phaseLabel: String?,
        isLatest: Bool,
        showsPlanPill: Bool,
        expectsAsk: Bool,
        longFileProgress: LongFileProgress? = nil
    ) {
        self.env = env
        self.message = message
        self.conversationID = conversationID
        self.product = product
        self.palette = palette
        self.lang = lang
        self.scale = scale
        self.motionOn = motionOn
        self.isStreaming = isStreaming
        self.liveText = liveText
        self.liveReasoning = liveReasoning
        self.phaseLabel = phaseLabel
        self.isLatest = isLatest
        self.showsPlanPill = showsPlanPill
        self.expectsAsk = expectsAsk
        self.longFileProgress = longFileProgress
    }

    nonisolated static func == (lhs: AssistantTurnView, rhs: AssistantTurnView) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.content.utf8.count == rhs.message.content.utf8.count
            && lhs.message.reasoning?.utf8.count == rhs.message.reasoning?.utf8.count
            && lhs.message.status == rhs.message.status
            && lhs.message.altAt == rhs.message.altAt
            && lhs.message.alts?.count == rhs.message.alts?.count
            && lhs.message.askAnswered == rhs.message.askAnswered
            && lhs.isStreaming == rhs.isStreaming
            && lhs.liveText.utf8.count == rhs.liveText.utf8.count
            && lhs.liveReasoning.utf8.count == rhs.liveReasoning.utf8.count
            && lhs.phaseLabel == rhs.phaseLabel
            && lhs.isLatest == rhs.isLatest
            && lhs.showsPlanPill == rhs.showsPlanPill
            && lhs.expectsAsk == rhs.expectsAsk
            && lhs.longFileProgress == rhs.longFileProgress
            && lhs.lang == rhs.lang
            // THE PAINT IS PART OF THE ROW. Without this a theme change redraws nothing
            // that is already on screen, and the answer keeps yesterday's ink.
            && lhs.palette.id == rhs.palette.id
            && lhs.scale == rhs.scale
            && lhs.motionOn == rhs.motionOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            versionPager
            retryNote
            thinking
            longFile
            content
            planPill
            quickReplies
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            MessageContextMenu(
                env: env,
                message: message,
                conversationID: conversationID,
                product: product
            )
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                MarkdownRenderer.invalidate(messageID: message.id)
                MathBlockView.invalidate(messageID: message.id)
            }
            reveal()
        }
        .onAppear { if !isStreaming { revealed = true } }
        .sheet(item: $fileSheet) { route in
            switch route.intent {
            // `export:` and not `url:` on all three. A picture export comes out as one PNG per
            // page, and `url` is page one alone — the rest were written and then never left the
            // app, which is the silent half of a crop.
            case .preview:
                FirasDocumentPreview(export: route.export)
            case .share:
                FirasActivitySheet(export: route.export)
            case .save:
                FirasFileSaver(export: route.export) { _ in fileSheet = nil }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Head

    @ViewBuilder
    private var versionPager: some View {
        if let alts = message.alts, alts.count > 1 {
            VersionPager(
                index: min(max(message.altAt ?? alts.count - 1, 0), alts.count - 1),
                total: alts.count,
                palette: palette,
                lang: lang
            ) { index in
                env.chat.selectVersion(messageID: message.id, index: index, in: conversationID)
            }
        }
    }

    /// «أُعيد هذا الجواب…» — a note, not a panel. It used to sit in a filled sunken box with its own
    /// corner radius, which drew more attention than the answer it was annotating.
    @ViewBuilder
    private var retryNote: some View {
        if message.retryOf != nil {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text(Strings.Chat.retryWasRetried(lang))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.textMuted)
        }
    }

    // MARK: - Reasoning

    @ViewBuilder
    private var thinking: some View {
        let reasoning = isStreaming && !liveReasoning.isEmpty
            ? liveReasoning
            : (message.reasoning ?? "")
        if showsThinking, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ThinkingDisclosure(
                reasoning: reasoning,
                isLive: isStreaming,
                palette: palette,
                lang: lang,
                scale: scale,
                motionOn: motionOn
            )
        }
    }

    private var showsThinking: Bool {
        guard let raw = message.tier, let tier = ModelTier(rawValue: raw) else { return true }
        return tier.showThinking
    }

    // MARK: - The long file being written

    /// A `longfile` turn writes for minutes and streams almost nothing, so without this the reader
    /// watched a blank answer and had no way to stop it. `longfile` is also the one chat-queue kind
    /// the server genuinely cancels, which is why Stop is offered here and nowhere else.
    @ViewBuilder
    private var longFile: some View {
        if isStreaming, let progress = longFileProgress, !progress.complete {
            LongFileCard(
                progress: progress,
                palette: palette,
                lang: lang,
                motionOn: motionOn,
                onStop: { stopLongFile() },
                onOpen: { openLongFile() }
            )
        }
    }

    private func stopLongFile() {
        let chat = env.chat
        let id = conversationID
        Task { await chat.stop(in: id) }
    }

    private func openLongFile() {
        guard let jobID = env.chat.states[conversationID]?.jobPointerID, !jobID.isEmpty else {
            return
        }
        env.router.sheet = .longFile(jobID: jobID)
    }

    // MARK: - Body

    var displayText: String {
        if isStreaming, !liveText.isEmpty { return liveText }
        return message.visibleContent
    }

    @ViewBuilder
    private var content: some View {
        if let spec = askSpec {
            AskPanelView(
                spec: spec,
                answered: message.askAnswered == true,
                isStreaming: isBusy,
                palette: palette,
                lang: lang,
                scale: scale,
                motionOn: motionOn,
                onSubmit: { answers, extra in submitAsk(answers: answers, extra: extra) },
                onBlocked: { env.toasts.show(Strings.Chat.busyWait(lang)) }
            )
        } else if isStreaming, AskSpec.hasOpenAskFence(displayText) {
            FirasActivityLabel(
                text: Strings.Chat.askPreparing(lang),
                palette: palette,
                motionOn: motionOn
            )
        } else if displayText.isEmpty {
            emptyBody
        } else {
            // «كانما جاي يكتب بس بنفس الوقت سريع مو بطيء» — the reveal is paced here, not by the
            // network. ONLY the markdown branch is wrapped: the ask panel, the `firas-ask` activity
            // label and `emptyBody` all read `displayText` directly, because a form that appears
            // one character at a time is not a form.
            StreamingText(
                text: displayText,
                isStreaming: isStreaming,
                motionOn: motionOn,
                identity: message.id
            ) { shown in
                MarkdownView(
                    markdown: shown,
                    messageID: message.id,
                    streaming: isStreaming,
                    lang: lang,
                    palette: palette,
                    prefs: env.prefs,
                    onFence: { fence in fenceView(fence) }
                )
            }
        }
    }

    @ViewBuilder
    private var emptyBody: some View {
        if isStreaming {
            FirasActivityLabel(
                text: phaseLabel ?? Strings.Chat.streaming(lang),
                palette: palette,
                motionOn: motionOn
            )
        } else if case .failed(let reason) = message.status {
            Text(reason.isEmpty ? Strings.Chat.errorTitle(lang) : reason)
                .font(FirasType.scaled(15, scale: scale))
                .foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if message.status == .stopped {
            Text(Strings.Chat.messageStopped(lang))
                .font(FirasType.scaled(15, scale: scale))
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            EmptyView()
        }
    }

    private var isBusy: Bool {
        env.chat.states[conversationID]?.isBusy ?? false
    }

    private var askSpec: AskSpec? {
        let text = displayText
        guard text.contains("firas-ask") || (expectsAsk && text.contains("questions")) else {
            return nil
        }
        return AskSpec.parse(text)
    }

    private func submitAsk(answers: [String: [String]], extra: String) {
        let id = message.id
        let conversation = conversationID
        Task {
            await env.chat.submitAsk(
                answers: answers,
                extra: extra,
                askMessageID: id,
                in: conversation
            )
        }
    }

    // MARK: - Plan, replies, actions

    @ViewBuilder
    private var planPill: some View {
        if showsPlanPill, !isStreaming, askSpec == nil {
            PlanStartPill(
                palette: palette,
                lang: lang,
                motionOn: motionOn,
                isEnabled: !isBusy
            ) {
                ChatTurnActions.approvePlan(conversationID: conversationID, env: env)
            }
        }
    }

    @ViewBuilder
    private var quickReplies: some View {
        if showsQuickReplies {
            QuickReplies(
                from: displayText,
                lang: lang,
                palette: palette
            ) { sentence in
                sendQuickReply(sentence)
            }
            .opacity(revealed ? 1 : 0)
        }
    }

    private var showsQuickReplies: Bool {
        guard !isStreaming, product == .ai, !showsPlanPill, askSpec == nil else { return false }
        guard message.status == .delivered else { return false }
        return !ChatTurnActions.isCardTurn(message)
    }

    /* THE CHIP IS THE MESSAGE, not a suggestion to go and type one. It used to drop the
       sentence in the composer, leaving the reader to press send on words they had not
       written — «مباشرتا تنرسل كاني انا ارسلتها».

       It also arrived formatted TWICE. `QuickReplies` already wraps the topic in the ask
       sentence before handing it over; this method wrapped the result again, so the question
       sat nested inside a copy of itself. The sentence now travels verbatim. */
    private func sendQuickReply(_ sentence: String) {
        guard !isBusy else {
            env.toasts.show(Strings.Chat.busyWait(lang))
            return
        }
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.send()
        // A chip that sends must not also leave its sentence behind in the box.
        env.drafts.clear(conversationID)
        let conversation = conversationID
        let kind = product
        Task {
            await env.chat.send(text: text, attachments: [], in: conversation, product: kind)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isLatest, !isStreaming, message.status.isTerminal, !displayText.isEmpty {
            MessageActionsRow(
                env: env,
                message: message,
                conversationID: conversationID,
                product: product
            )
            .opacity(revealed ? 1 : 0)
        }
    }

    /// The answer settles in, it does not slide in. The old reveal moved the action row 6 pt up
    /// while the last line of text was still finding its own height, so two things moved at once
    /// on the frame an answer finished — a small lurch at exactly the moment the reader looks.
    private func reveal() {
        guard !revealed else { return }
        withAnimation(FirasMotion.gated(FirasMotion.reveal, motionOn: motionOn)) { revealed = true }
    }
}

// MARK: - The file card's one sheet

/// What a non-durable file card asked for, and the document that was built for it.
///
/// One `Identifiable` route rather than three booleans: SwiftUI presents at most one sheet per
/// view, and stacking `.sheet(item:)` modifiers is how a sheet ends up never appearing at all.
struct AssistantFileSheet: Identifiable {

    enum Intent: String {
        case preview
        case share
        case save
    }

    let intent: Intent
    let export: ExportController.Export

    var id: String { export.id.uuidString + ":" + intent.rawValue }
}
