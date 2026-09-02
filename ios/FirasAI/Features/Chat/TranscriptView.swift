import SwiftUI

/// The scrolling conversation.
///
/// Two rules decide everything here (`audit-ios-chat.md §Critical C5`): the reader owns the scroll
/// position — the view follows a growing answer **only** while they are already at the bottom — and
/// a row that has not changed is never re-evaluated, because every row is `Equatable` and only the
/// streaming one is handed `liveText`.
struct TranscriptView: View {

    private let env: AppEnvironment
    private let conversationID: String
    private let product: ProductKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsChip = false

    private static let bottomAnchor = "firas.transcript.bottom"
    /// The reader counts as "at the bottom" inside this many points (`design-brief.md §7.1`).
    private static let pinnedThreshold: CGFloat = 48
    /// The jump chip appears only once they are properly away from the end.
    private static let chipThreshold: CGFloat = 240

    init(env: AppEnvironment, conversationID: String, product: ProductKind) {
        self.env = env
        self.conversationID = conversationID
        self.product = product
    }

    var body: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        let motionOn = FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
        let conversation = env.chat.conversations[conversationID]
        let state = env.chat.states[conversationID]

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let conversation {
                        rows(conversation.messages, state: state, motionOn: motionOn)
                    } else {
                        SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
                            .padding(.top, 12)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(TranscriptView.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .readingColumn(env.prefs.contentWidth)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
            } action: { _, distance in
                apply(distance: distance, motionOn: motionOn)
            }
            .onChange(of: scrollSignature(conversation, state: state)) { _, _ in
                followIfPinned(proxy: proxy, motionOn: motionOn)
            }
            .overlay(alignment: .bottom) {
                jumpChip(palette: palette, lang: lang, motionOn: motionOn, proxy: proxy)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(
        _ messages: [ChatMessage],
        state: ConversationState?,
        motionOn: Bool
    ) -> some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        let scale = env.prefs.fontScale
        let latestAssistant = TranscriptView.latestAssistantID(messages)

        ForEach(messages) { message in
            VStack(alignment: .leading, spacing: 0) {
                if message.id != messages.first?.id {
                    Rectangle()
                        .fill(palette.border)
                        .frame(height: 1)
                        .padding(.bottom, 16)
                }

                if message.role == .user {
                    UserTurnView(
                        env: env,
                        message: message,
                        conversationID: conversationID,
                        product: product,
                        palette: palette,
                        lang: lang,
                        scale: scale,
                        motionOn: motionOn
                    )
                    .equatable()
                } else if message.role == .assistant {
                    AssistantTurnView(
                        env: env,
                        message: message,
                        conversationID: conversationID,
                        product: product,
                        palette: palette,
                        lang: lang,
                        scale: scale,
                        motionOn: motionOn,
                        isStreaming: isStreaming(message, state: state),
                        liveText: liveText(message, state: state),
                        liveReasoning: liveReasoning(message, state: state),
                        phaseLabel: phaseLabel(message, state: state, lang: lang),
                        isLatest: message.id == latestAssistant,
                        showsPlanPill: showsPlanPill(message, state: state),
                        expectsAsk: expectsAsk(state)
                    )
                    .equatable()
                }
            }
            .padding(.bottom, 16)
            .id(message.id)
        }
    }

    private static func latestAssistantID(_ messages: [ChatMessage]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            return message.id
        }
        return nil
    }

    // MARK: - Live turn

    private func isStreaming(_ message: ChatMessage, state: ConversationState?) -> Bool {
        guard let state else { return message.status == .streaming }
        if let live = state.streamingMessageID { return live == message.id }
        return message.status == .streaming
    }

    private func liveText(_ message: ChatMessage, state: ConversationState?) -> String {
        guard let state, isStreaming(message, state: state) else { return "" }
        return state.liveText
    }

    private func liveReasoning(_ message: ChatMessage, state: ConversationState?) -> String {
        guard let state, isStreaming(message, state: state) else { return "" }
        return state.liveReasoning
    }

    private func phaseLabel(
        _ message: ChatMessage,
        state: ConversationState?,
        lang: AppLanguage
    ) -> String? {
        guard let state, isStreaming(message, state: state) else { return nil }
        switch state.phase {
        case .searching: return Strings.Chat.searchingWeb(lang)
        case .thinking: return Strings.Chat.thinkingLive(lang)
        case .streaming, .completing, .idle, .failed(_): return nil
        }
    }

    private func showsPlanPill(_ message: ChatMessage, state: ConversationState?) -> Bool {
        guard product == .ai, let state else { return false }
        if case .awaitingApproval(let planMessageID) = state.plan.phase {
            return planMessageID == message.id
        }
        return false
    }

    private func expectsAsk(_ state: ConversationState?) -> Bool {
        guard let state else { return false }
        if case .awaitingAnswers = state.plan.phase { return true }
        return false
    }

    // MARK: - Scrolling

    /// What "something moved" means for the follow decision: a new row, or the live tail growing.
    private func scrollSignature(_ conversation: ChatConversation?, state: ConversationState?) -> Int {
        let messages = conversation?.messages.count ?? 0
        let live = state?.liveText.utf8.count ?? 0
        let last = conversation?.messages.last?.content.utf8.count ?? 0
        return messages &* 1_000_003 &+ live &+ last
    }

    /// Called on every scroll frame, so it writes nothing unless a boundary was actually crossed:
    /// storing the raw offset would re-evaluate this body at scroll frequency.
    private func apply(distance: CGFloat, motionOn: Bool) {
        let clamped = max(0, distance)
        let pinned = clamped <= TranscriptView.pinnedThreshold
        if let state = env.chat.states[conversationID], state.isAtBottom != pinned {
            state.isAtBottom = pinned
        }
        let visible = clamped > TranscriptView.chipThreshold
        if showsChip != visible {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                showsChip = visible
            }
        }
    }

    private func followIfPinned(proxy: ScrollViewProxy, motionOn: Bool) {
        guard env.chat.states[conversationID]?.isAtBottom ?? true else { return }
        scroll(proxy: proxy, motionOn: motionOn)
    }

    private func scroll(proxy: ScrollViewProxy, motionOn: Bool) {
        if motionOn {
            withAnimation(FirasMotion.standard) {
                proxy.scrollTo(TranscriptView.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(TranscriptView.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Jump chip

    @ViewBuilder
    private func jumpChip(
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool,
        proxy: ScrollViewProxy
    ) -> some View {
        if showsChip {
            Button {
                if let state = env.chat.states[conversationID] { state.isAtBottom = true }
                scroll(proxy: proxy, motionOn: motionOn)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.opacity)
            .accessibilityLabel(Text(Strings.Chat.scrollToBottom(lang)))
        }
    }
}
