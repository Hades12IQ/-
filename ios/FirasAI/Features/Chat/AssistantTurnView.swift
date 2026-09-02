import SwiftUI

/// One answer, rendered as a document rather than a bubble (`design-brief.md §7.6`).
///
/// Order: version pager · head · retry strip · thinking · body (markdown, ask panel or card) ·
/// Start pill · quick replies · action row. Only the row that is actually streaming reads
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

    @State private var revealed = false

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
        expectsAsk: Bool
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
            && lhs.lang == rhs.lang
            && lhs.scale == rhs.scale
            && lhs.motionOn == rhs.motionOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            versionPager
            header
            retryStrip
            thinking
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
            if !streaming { MarkdownRenderer.invalidate(messageID: message.id) }
            reveal()
        }
        .onAppear { if !isStreaming { revealed = true } }
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

    private var header: some View {
        HStack(spacing: 8) {
            FirasBrandMark(size: 18, showsWordmark: false, palette: palette)

            Text(product == .agent ? Strings.Chat.assistantNameAgent(lang) : Strings.Chat.assistantName(lang))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .firasTracking(for: Strings.Chat.assistantName(lang))

            if product != .agent, let badge = tierBadge {
                tierBadgeView(badge)
            }

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var tierBadge: ModelTier? {
        guard let raw = message.tier, let tier = ModelTier(rawValue: raw) else { return nil }
        return tier
    }

    private func tierBadgeView(_ tier: ModelTier) -> some View {
        HStack(spacing: 4) {
            if tier == .ultra || tier == .max {
                Circle()
                    .fill(tier == .max ? palette.maxTierDot : palette.accent)
                    .frame(width: 5, height: 5)
            }
            Text(tier.short(lang))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(badgeInk(tier))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous).fill(badgeFill(tier))
        }
    }

    private func badgeInk(_ tier: ModelTier) -> Color {
        switch tier {
        case .max: return palette.maxTierText
        case .ultra: return palette.accent
        case .mini, .pro: return palette.textMuted
        }
    }

    private func badgeFill(_ tier: ModelTier) -> Color {
        switch tier {
        case .max: return palette.maxTierBg
        case .ultra: return palette.accentSoft
        case .mini, .pro: return Color.clear
        }
    }

    @ViewBuilder
    private var retryStrip: some View {
        if message.retryOf != nil {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text(Strings.Chat.retryWasRetried(lang))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
            }
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
            MarkdownView(
                markdown: displayText,
                messageID: message.id,
                streaming: isStreaming,
                lang: lang,
                palette: palette,
                prefs: env.prefs,
                onFence: { fence in fenceView(fence) }
            )
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
                .font(.system(size: 14))
                .foregroundStyle(palette.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if message.status == .stopped {
            Text(Strings.Chat.messageStopped(lang))
                .font(.system(size: 14))
                .foregroundStyle(palette.textMuted)
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
            ) { topic in
                insertQuickReply(topic)
            }
            .opacity(revealed ? 1 : 0)
        }
    }

    private var showsQuickReplies: Bool {
        guard !isStreaming, product == .ai, !showsPlanPill, askSpec == nil else { return false }
        guard message.status == .delivered else { return false }
        return !ChatTurnActions.isCardTurn(message)
    }

    private func insertQuickReply(_ topic: String) {
        let text = Strings.Chat.qreplyAsk.fmt(lang, topic)
        let existing = env.drafts.draft(for: conversationID)
        let merged = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : existing + "\n" + text
        env.drafts.set(merged, for: conversationID)
        Haptics.select()
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
            .offset(y: revealed ? 0 : 6)
        }
    }

    private func reveal() {
        guard !revealed else { return }
        withAnimation(FirasMotion.gated(FirasMotion.reveal, motionOn: motionOn)) { revealed = true }
    }
}
