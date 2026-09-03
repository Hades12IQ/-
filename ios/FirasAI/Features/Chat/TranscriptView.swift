import SwiftUI

/// The scrolling conversation.
///
/// Three rules decide everything here. The reader owns the scroll position — the view follows a
/// growing answer **only** while they are already at the bottom (`audit-ios-chat.md §Critical C5`).
/// A row that has not changed is never re-evaluated, because every row is `Equatable` and only the
/// streaming one is handed `liveText`. And the page has a rhythm: a question and its answer are one
/// exchange and sit close together, exchanges are separated by a generous gap with a single hairline
/// through it — the web's `.turn + .turn` rule, which is also the only line of chrome left in the
/// transcript.
struct TranscriptView: View {

    private let env: AppEnvironment
    private let conversationID: String
    private let product: ProductKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showsChip = false
    /// How many rows the transcript held last time it followed the tail. A change means a new turn
    /// arrived, which is the only moment the follow is allowed to animate.
    @State private var lastRowCount = 0

    private static let bottomAnchor = "firas.transcript.bottom"
    /// The reader counts as "at the bottom" inside this many points (`design-brief.md §7.1`).
    private static let pinnedThreshold: CGFloat = 48
    /// The jump chip appears only once they are properly away from the end — far enough that
    /// scrolling back by hand is a chore, which is the only case where it earns its place.
    private static let chipThreshold: CGFloat = 220

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
                .padding(.top, 14)
                /* Room for the last answer’s action row to sit ABOVE the composer once the page is
                   scrolled to its end. At 28 the copy and share buttons of the final turn ended up
                   flush against the composer’s top edge and read as part of it. */
                .padding(.bottom, 44)
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
                follow(
                    proxy: proxy,
                    rowCount: conversation?.messages.count ?? 0,
                    lastRole: conversation?.messages.last?.role,
                    motionOn: motionOn
                )
            }
            .onAppear {
                lastRowCount = conversation?.messages.count ?? 0
                proxy.scrollTo(TranscriptView.bottomAnchor, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                jumpChip(palette: palette, lang: lang, motionOn: motionOn, proxy: proxy)
            }
        }
    }

    // MARK: - Rhythm

    /// `turn` separates one exchange from the next; `pair` separates a question from its own answer.
    /// iPad gets the wider gap the brief asks for, because the column there is wider too.
    private var rhythm: (turn: CGFloat, pair: CGFloat) {
        sizeClass == .regular ? (turn: 40, pair: 22) : (turn: 32, pair: 18)
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
        let gaps = rhythm
        let firstID = messages.first?.id

        ForEach(messages) { message in
            if message.role == .user {
                VStack(alignment: .leading, spacing: 0) {
                    exchangeRule(isFirst: message.id == firstID, gap: gaps.turn, palette: palette)
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
                }
                .id(message.id)
            } else if message.role == .assistant {
                VStack(alignment: .leading, spacing: 0) {
                    answerGap(isFirst: message.id == firstID, gap: gaps.pair)
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
                        expectsAsk: expectsAsk(state),
                        longFileProgress: longFileProgress(message, state: state)
                    )
                    .equatable()
                }
                .id(message.id)
            }
        }
    }

    /// The hairline that opens a new exchange. Never above the first row of the conversation.
    @ViewBuilder
    private func exchangeRule(isFirst: Bool, gap: CGFloat, palette: FirasPalette) -> some View {
        if !isFirst {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
                .padding(.vertical, gap / 2)
                .accessibilityHidden(true)
        }
    }

    /// The smaller step between a question and the answer that belongs to it.
    @ViewBuilder
    private func answerGap(isFirst: Bool, gap: CGFloat) -> some View {
        if !isFirst {
            Color.clear.frame(height: gap)
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

    /// Only the row that is actually being written gets the document's progress; every other row
    /// stays `Equatable`-identical and is never re-evaluated while it advances.
    private func longFileProgress(
        _ message: ChatMessage,
        state: ConversationState?
    ) -> LongFileProgress? {
        guard let state, isStreaming(message, state: state) else { return nil }
        return state.longFileProgress
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
        case .streaming, .completing, .idle, .failed: return nil
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

    /// Follows the tail while the reader is pinned to it.
    ///
    /// A spring is started per call, so animating the ten-times-a-second follow of a streaming
    /// answer meant ten overlapping springs chasing a target that had already moved — the answer
    /// arrived in visible jerks. A new row is a real event and is worth animating; a token is not,
    /// and an unanimated follow of a few points per tick is what reads as smooth typing.
    private func follow(proxy: ScrollViewProxy, rowCount: Int, lastRole: ChatRole?, motionOn: Bool) {
        let isNewRow = rowCount != lastRowCount
        if isNewRow { lastRowCount = rowCount }
        /* SENDING IS AN EXPLICIT ACT, and it always wins. Reading further up the conversation
           correctly stops a STREAMING answer from yanking the page around — that is what
           `isAtBottom` protects. But a message the reader just typed is not the answer arriving;
           they asked for it, and leaving them stranded above their own question with the
           keyboard still up is the complaint: "اذا كنت صاعد فوق وارسلت رسالة اريده
           ينزلني تحت". So a new USER row scrolls unconditionally; everything else still
           respects where the reader is. This is Claude’s rule and it holds for every product. */
        let sentByReader = isNewRow && lastRole == .user
        guard sentByReader || (env.chat.states[conversationID]?.isAtBottom ?? true) else { return }
        if sentByReader { env.chat.states[conversationID]?.isAtBottom = true }
        scroll(proxy: proxy, animated: isNewRow && motionOn)
    }

    private func scroll(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
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
                /* THE KEYBOARD GOES FIRST. Pressing the chip with the keyboard up scrolled to a
                   bottom that was then hidden behind it — the reader landed on the end of the
                   conversation and still could not see the last line of the answer or the copy
                   and share row under it: "ينزلني اخر شي بحيث اخر كلمة تكون ضاهرة امامي،
                   والنسخ والمشاركة هم تكون ضاهرة". Dismissing first gives the scroll view its
                   full height back, so the bottom it scrolls to is the bottom the reader sees.
                   The second scroll, after the keyboard’s own animation, is what makes it land:
                   the first one is measured against a viewport that is still shrinking. */
                Keyboard.dismiss()
                if let state = env.chat.states[conversationID] { state.isAtBottom = true }
                scroll(proxy: proxy, animated: motionOn)
                Task {
                    await JobClock.rest(0.32)
                    scroll(proxy: proxy, animated: motionOn)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 36, height: 36)
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
