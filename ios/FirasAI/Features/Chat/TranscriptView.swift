import SwiftUI

/// The scrolling conversation.
///
/// Three rules decide everything here. The reader owns the scroll position — the view follows a
/// growing answer **only** while they are already at the bottom (`audit-ios-chat.md §Critical C5`),
/// and the one thing that overrides them is a question they just asked. A row that has not changed
/// is never re-evaluated, because every row is `Equatable` and only the streaming one is handed
/// `liveText`. And the page has a rhythm made **entirely of empty space**: a question and its answer
/// are one exchange and sit close together, and one exchange is separated from the next by a gap more
/// than twice as large. There is no rule between turns — «معليك بالفقاعة بس كترتيب بدال الخط الي
/// يصير بين كل رسالة». A line drawn every two rows is chrome repeated down the whole page, and both
/// ChatGPT and Claude get the same separation out of the gap alone.
struct TranscriptView: View {

    private let env: AppEnvironment
    private let conversationID: String
    private let product: ProductKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var position = ScrollPosition(edge: .top)
    @State private var showsChip = false
    @State private var followsTail = true
    @State private var isUserScrolling = false
    @State private var isJumping = false
    @State private var lastUserID: String?
    @State private var seededConversationID: String?
    @State private var metrics = ChatScrollMeasurement()
    @State private var textSelection = FirasTextSelection()

    private static let pinnedThreshold: CGFloat = 48
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
        let conversation = record
        let state = liveState

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let conversation {
                    rows(conversation.messages, state: state, motionOn: motionOn)
                    if let preparation = state?.mediaPreparation,
                       !preparation.hasCard(in: conversation.messages) {
                        FirasActivityLabel(text: preparation.label(lang), palette: palette, motionOn: motionOn)
                            .padding(.top, rhythm.pair)
                    }
                } else {
                    SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .readingColumn(env.prefs.contentWidth)
        }
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: ChatScrollMeasurement.self) { geometry in
            let distance = max(0, geometry.contentSize.height + geometry.contentInsets.bottom
                - geometry.contentOffset.y - geometry.containerSize.height)
            return ChatScrollMeasurement(
                contentHeight: geometry.contentSize.height.rounded(),
                viewportHeight: geometry.containerSize.height.rounded(),
                pinned: distance <= Self.pinnedThreshold,
                away: distance > Self.chipThreshold
            )
        } action: { old, new in
            metrics = new
            if liveState?.isAtBottom != new.pinned { liveState?.isAtBottom = new.pinned }
            if isUserScrolling { followsTail = new.pinned }
            let chip = new.away && !isJumping
            if showsChip != chip { showsChip = chip }
            // Follow layout changes as well as incoming tokens: media covers, math and keyboard
            // dismissal all change the real content extent after a message has arrived.
            if !isUserScrolling, followsTail,
               old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight {
                scrollToEnd(animated: false)
            }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting {
                isUserScrolling = true
                followsTail = false
                isJumping = false
            } else if phase == .idle {
                if isUserScrolling { followsTail = metrics.pinned }
                isUserScrolling = false
                if isJumping {
                    isJumping = false
                    // Clamp to the final measured edge after lazy rows finish materializing.
                    if followsTail { scrollToEnd(animated: false) }
                }
            }
        }
        .onChange(of: Self.latestUserID(conversation?.messages ?? [])) { _, newest in
            guard newest != lastUserID else { return }
            lastUserID = newest
            jump(motionOn: motionOn)
        }
        .onAppear { seed(messages: conversation?.messages ?? []) }
        .onChange(of: conversationID) { _, _ in seed(messages: record?.messages ?? []) }
        .environment(\.firasTextSelection, textSelection)
        .onChange(of: textSelection.request) { _, request in
            guard let request else { return }
            env.chat.state(for: conversationID).pendingQuote = String(request.text.prefix(8_000))
        }
        .overlay(alignment: .bottom) {
            jumpChip(palette: palette, lang: lang, motionOn: motionOn)
        }
    }

    // MARK: - Rhythm

    /// `turn` separates one exchange from the next; `pair` separates a question from its own answer.
    /// iPad gets the wider gap the brief asks for, because the column there is wider too.
    ///
    /// Both grew when the hairline went. A rule does the separating on its own and lets the space
    /// around it be small; without one, the ONLY thing telling the reader that a new question has
    /// started is that the gap above it is more than twice the gap inside an exchange. 32 against 18
    /// was not that ratio — it read as a page of evenly spaced paragraphs the moment the line came
    /// out. 44 against 20 is, and it is the proportion ChatGPT and Claude both settle on.
    private var rhythm: (turn: CGFloat, pair: CGFloat) {
        sizeClass == .regular ? (turn: 52, pair: 24) : (turn: 44, pair: 20)
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
                    gap(gaps.turn, isFirst: message.id == firstID)
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
                    gap(gaps.pair, isFirst: message.id == firstID)
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

    /// The step that opens a row — the big one before a new question, the small one before the
    /// answer that belongs to it. Never above the first row of the conversation, which has the
    /// stack's own top padding above it already.
    ///
    /// This is all that is left of `exchangeRule`. It used to draw a hairline in `palette.border`
    /// with half the gap on either side of it; the owner asked for the line to go and for the
    /// spacing to do its work, so there is nothing to paint here any more and nothing to hide from
    /// VoiceOver either — empty space was never announced.
    @ViewBuilder
    private func gap(_ height: CGFloat, isFirst: Bool) -> some View {
        if !isFirst {
            Color.clear.frame(height: height)
        }
    }

    private static func latestAssistantID(_ messages: [ChatMessage]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            return message.id
        }
        return nil
    }

    /// The newest question in the transcript. `follow` compares it against the one it saw last to
    /// decide whether the reader sent something — see the note there for why counting rows and
    /// reading the last one's role could not answer that.
    private static func latestUserID(_ messages: [ChatMessage]) -> String? {
        for message in messages.reversed() where message.role == .user {
            return message.id
        }
        return nil
    }

    // MARK: - Live turn

    /* A ROW'S OWN STATUS COUNTS FIRST, and the order used to be the other way round.
       `if let live = state.streamingMessageID { return live == message.id }` CONSUMES the
       question: the moment any row in the conversation is the live one — or a stale id is left
       behind — every other row is reported as not streaming, including a row whose own status
       says `.streaming` in so many words.
       A media row is exactly that. `MediaStore` places its card with `status: .streaming` while
       the render runs on the server, and the conversation's own stream is not involved at all.
       So the row was told it was idle, the branch that hides an unfinished card never ran, and
       the reader watched the block's raw JSON arrive — the engine's English style string and
       every line of the lyrics. That is «ظهور برومبت الاغاني و الفيديو و الصور», and it was never
       in the card or the fence: it was in this comparison. */
    private func isStreaming(_ message: ChatMessage, state: ConversationState?) -> Bool {
        if message.status == .streaming { return true }
        guard let state else { return false }
        return state.streamingMessageID == message.id
    }

    private func liveText(_ message: ChatMessage, state: ConversationState?) -> String {
        guard let state, state.streamingMessageID == message.id else { return "" }
        return state.liveText
    }

    private func liveReasoning(_ message: ChatMessage, state: ConversationState?) -> String {
        guard let state, state.streamingMessageID == message.id else { return "" }
        return state.liveReasoning
    }

    /// Only the row that is actually being written gets the document's progress; every other row
    /// stays `Equatable`-identical and is never re-evaluated while it advances.
    private func longFileProgress(
        _ message: ChatMessage,
        state: ConversationState?
    ) -> LongFileProgress? {
        guard let state, state.streamingMessageID == message.id else { return nil }
        return state.longFileProgress
    }

    private func phaseLabel(
        _ message: ChatMessage,
        state: ConversationState?,
        lang: AppLanguage
    ) -> String? {
        guard let state, state.streamingMessageID == message.id else { return nil }
        switch state.phase {
        case .searching: return Strings.Chat.searchingWeb(lang)
        /* NOT «فِراس يفكّر» HERE. That sentence belongs to the thinking panel, which owns the
           chevron that opens it — and printing it in the status line as well is why the owner's
           screenshot shows it twice, once with an arrow and once without. The status line says
           what it has always said, and the reader gets what they asked for: with thinking off,
           «يكتب فِراس» alone; with it on, the panel above and «يكتب فِراس» beneath it. */
        case .thinking: return Strings.Chat.streaming(lang)
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

    // MARK: - The record

    /* THROUGH `conversation(_:)`, NEVER THROUGH THE DICTIONARY — the note `ChatScreen` carries at
       its own `conversation`, for the same reason and with the same consequence. A conversation
       that began on the device and was then saved is filed under its local `ios_…` key with the
       server id beside it, so a screen opened by server id (a notification tap, a shared link)
       looks it up under a key `conversations` does not have. `ChatScreen` resolves the pair and
       therefore decides the transcript has messages; this view did not, found nil, and drew the
       loading skeleton over a conversation that was sitting right there in the store. */
    private var record: ChatConversation? {
        env.chat.conversation(conversationID)
    }

    /// `resolve` and not `state(for:)`: the latter MINTS a state and files it, and a store write
    /// from inside `body` is the one thing this must not do. Every id that reaches this view has
    /// been through `ChatStore.state(for:)` on open or on send already.
    private var liveState: ConversationState? {
        env.chat.states[env.chat.resolve(conversationID)]
    }

    // MARK: - Scrolling

    private func seed(messages: [ChatMessage]) {
        // Returning from a sheet or another surface must preserve the reader's position.
        guard seededConversationID != conversationID else { return }
        seededConversationID = conversationID
        lastUserID = Self.latestUserID(messages)
        followsTail = true
        isUserScrolling = false
        isJumping = false
        showsChip = false
        scrollToEnd(animated: false)
    }

    private func jump(motionOn: Bool) {
        Keyboard.dismiss()
        isUserScrolling = false
        followsTail = true
        isJumping = motionOn
        showsChip = false
        liveState?.isAtBottom = true
        scrollToEnd(animated: motionOn)
    }

    /// An edge position is clamped by ScrollView. A lazy sentinel's estimated frame can land
    /// beyond media while rows are being measured; neither a sentinel nor delayed jump tasks
    /// participate here. A non-overshooting curve keeps explicit long jumps smooth.
    private func scrollToEnd(animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.30)) { position.scrollTo(edge: .bottom) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        }
    }

    // MARK: - Jump chip

    @ViewBuilder
    private func jumpChip(
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool
    ) -> some View {
        if showsChip {
            Button {
                /* THE KEYBOARD GOES FIRST. Pressing the chip with the keyboard up scrolled to a
                   bottom that was then hidden behind it — the reader landed on the end of the
                   conversation and still could not see the last line of the answer or the copy
                   and share row under it: "ينزلني اخر شي بحيث اخر كلمة تكون ضاهرة امامي،
                   والنسخ والمشاركة هم تكون ضاهرة". Dismissing first gives the scroll view its
                   full height back, so the bottom it scrolls to is the bottom the reader sees;
                   `jump` scrolls a second time once that height has stopped changing. */
                Keyboard.dismiss()
                liveState?.isAtBottom = true
                jump(motionOn: motionOn)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 36, height: 36)
                    .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.opacity)
            .accessibilityLabel(Text(Strings.Chat.scrollToBottom(lang)))
        }
    }
}

private struct ChatScrollMeasurement: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var pinned = true
    var away = false
}
