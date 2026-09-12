import SwiftUI
import Perception

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

    @State private var textSelection = FirasTextSelection()

    init(env: AppEnvironment, conversationID: String, product: ProductKind) {
        self.env = env
        self.conversationID = conversationID
        self.product = product
    }

    var body: some View {
        return WithPerceptionTracking {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        let motionOn = FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
        let latestUserID = Self.latestUserID(record?.messages ?? [])
        return Group {
            if #available(iOS 18.0, *), !TranscriptScrollCompatibility.forceLegacy {
                ModernChatTranscriptScroll(conversationID: conversationID, latestUserID: latestUserID,
                    palette: palette, lang: lang, motionOn: motionOn, onPinned: updatePinned,
                    content: transcriptContent(motionOn: motionOn))
            } else {
                LegacyTranscriptScroll(identity: conversationID, latestUserID: latestUserID,
                    motionOn: motionOn, pinnedThreshold: 48, chipThreshold: 220, onPinned: updatePinned) { jump in
                    ChatTranscriptJumpButton(palette: palette, lang: lang, action: jump)
                } content: {
                    transcriptContent(motionOn: motionOn)
                }
            }
        }
        .environment(\.firasTextSelection, textSelection)
        .firasOnChange(of: textSelection.request) { _, request in
            guard let request else { return }
            env.chat.state(for: conversationID).pendingQuote = String(request.text.prefix(8_000))
        }
            }
    }

    private func updatePinned(_ pinned: Bool) {
        if liveState?.isAtBottom != pinned { liveState?.isAtBottom = pinned }
    }

    private func transcriptContent(motionOn: Bool) -> some View {
        return WithPerceptionTracking {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let conversation = record {
                rows(conversation.messages, state: liveState, motionOn: motionOn)
                if let preparation = liveState?.mediaPreparation,
                   !preparation.hasCard(in: conversation.messages) {
                    FirasActivityLabel(text: preparation.label(env.prefs.lang), palette: env.prefs.palette, motionOn: motionOn)
                        .padding(.top, rhythm.pair)
                }
            } else {
                SkeletonView(kind: .transcript, palette: env.prefs.palette, motionOn: motionOn)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .readingColumn(env.prefs.contentWidth)
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
        return WithPerceptionTracking {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        let scale = env.prefs.fontScale
        let latestAssistant = TranscriptView.latestAssistantID(messages)
        let gaps = rhythm
        let firstID = messages.first?.id

        ForEach(messages) { message in
            WithPerceptionTracking {
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
                .legacyTranscriptRowAnchor(message.id)
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
                .legacyTranscriptRowAnchor(message.id)
            }

                }}
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
        return WithPerceptionTracking {
        if !isFirst {
            Color.clear.frame(height: height)
        }
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

}
