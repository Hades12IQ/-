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

    @State private var showsChip = false
    /// How many rows the transcript held last time it followed the tail. A change means a new turn
    /// arrived, which is the only moment the follow is allowed to animate.
    @State private var lastRowCount = 0
    /// The newest QUESTION this view has already seen. A different one means the reader just sent,
    /// which is the one event allowed to overrule where they were reading. See `follow`.
    @State private var lastUserID: String?
    /// Raised for as long as a jump the reader asked for is landing. Nothing may rewrite `showsChip`
    /// while it is up: that write re-evaluates this whole body, and re-evaluating it underneath a
    /// scroll that is still settling is how the transcript ends up parked below its own content.
    @State private var isJumping = false

    private static let bottomAnchor = "firas.transcript.bottom"
    /// The reader counts as "at the bottom" inside this many points (`design-brief.md §7.1`).
    private static let pinnedThreshold: CGFloat = 48
    /// The jump chip appears only once they are properly away from the end — far enough that
    /// scrolling back by hand is a chore, which is the only case where it earns its place.
    private static let chipThreshold: CGFloat = 220
    /// How long the viewport keeps moving after the keyboard is told to leave. Every jump is made
    /// twice, once now and once after this, because the first is measured against a height that is
    /// still growing.
    private static let settleDelay: Double = 0.32

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
            /* THE BOTTOM IS THE ANCHOR, and this is the fix the timers were only approximating.
               A media turn is not its final height when it is built: the cover arrives from disk
               or the network, an equation becomes a bitmap when the island finishes drawing it, a
               table remeasures once its widest cell is known. Every one of those changes the
               content size AFTER a scroll aimed at it, and a scroll offset that was correct for
               the old size can end up past the end of the new one — nothing intersects the
               viewport, so the LazyVStack builds nothing, so the height never grows back to clamp
               it. That is the empty conversation, and chasing it with delayed re-scrolls is a
               race against a download.
               `defaultScrollAnchor(.bottom)` makes the scroll view keep the bottom edge pinned
               across a content-size change, which is the guarantee the timers could not give. It
               also opens a conversation at its end, which is what `seed` was for.
               The settle passes stay: this anchors, and they correct. Both are cheap and neither
               moves a reader who has scrolled away, because the follow logic checks that first. */
            .defaultScrollAnchor(.bottom)
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
                    messages: conversation?.messages ?? [],
                    motionOn: motionOn
                )
            }
            .onAppear {
                seed(proxy: proxy, messages: conversation?.messages ?? [])
            }
            /* A conversation opened from the drawer replaces this view's INPUT, not this view: the
               screen around it is the same one, so `onAppear` does not run again and every piece of
               `@State` here would still be describing the conversation the reader just left. */
            .onChange(of: conversationID) { _, _ in
                seed(proxy: proxy, messages: record?.messages ?? [])
            }
            .overlay(alignment: .bottom) {
                jumpChip(palette: palette, lang: lang, motionOn: motionOn, proxy: proxy)
            }
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

    /// What "something moved" means for the follow decision: a new row, or the live tail growing.
    private func scrollSignature(_ conversation: ChatConversation?, state: ConversationState?) -> Int {
        let messages = conversation?.messages.count ?? 0
        let live = state?.liveText.utf8.count ?? 0
        let last = conversation?.messages.last?.content.utf8.count ?? 0
        return messages &* 1_000_003 &+ live &+ last
    }

    /// The baseline every scroll decision is measured against, and the opening position.
    ///
    /// `follow` reads a question it has not seen before as "the reader just sent", so whatever is
    /// already in the transcript when this view starts looking at it has to be written down first —
    /// otherwise opening a conversation with fifty turns in it counts as fifty-first. (A transcript
    /// that is still on its way from the network seeds as empty and then does read as a send when it
    /// lands. That is harmless: a conversation that has just loaded belongs at its end.)
    ///
    /// The two flags are only written when they are actually set. `@State` invalidates on assignment
    /// and does not compare, and this runs inside `onAppear`.
    private func seed(proxy: ScrollViewProxy, messages: [ChatMessage]) {
        lastRowCount = messages.count
        lastUserID = TranscriptView.latestUserID(messages)
        if isJumping { isJumping = false }
        if showsChip { showsChip = false }
        proxy.scrollTo(TranscriptView.bottomAnchor, anchor: .bottom)

        /* AND AGAIN, TWICE, AFTER THE CONTENT HAS FINISHED CHANGING SIZE.
           One scroll is right only for a conversation whose rows are their final height the
           moment they are built. A song, a picture or a clip is a cover that arrives from disk
           or the network; an equation is a bitmap that lands when the island finishes drawing
           it; a table remeasures when its widest cell is known. Every one of those changes the
           height of the thing this scroll was aimed at, AFTER it was aimed - and the owner's
           description is exactly what that looks like: «من ادخل لمحادثة بيها اغنية او صورة او
           فيديو تكون فارغة الا اصعد فوق، كانه نزلني جوة اكثر».
           Two more passes, unanimated like the first, at the settle beat and then at four times
           it. Unanimated is what makes this safe to repeat: a scroll that already landed is a
           no-op, so the extra passes cost nothing and cannot fight a reader who has started
           scrolling - `isAtBottom` is false by then and the follow logic leaves them alone. */
        let anchor = TranscriptView.bottomAnchor
        Task {
            await JobClock.rest(TranscriptView.settleDelay)
            proxy.scrollTo(anchor, anchor: .bottom)
            await JobClock.rest(TranscriptView.settleDelay * 3)
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    /// Called on every scroll frame, so it writes nothing unless a boundary was actually crossed:
    /// storing the raw offset would re-evaluate this body at scroll frequency.
    private func apply(distance: CGFloat, motionOn: Bool) {
        let clamped = max(0, distance)
        let pinned = clamped <= TranscriptView.pinnedThreshold
        if let state = liveState, state.isAtBottom != pinned {
            state.isAtBottom = pinned
        }
        /* `!isJumping` is load-bearing, not tidiness. Every frame of a jump that started three
           thousand points up is still "far from the bottom", so without it this would put the chip
           back the instant it was pressed and then take it away again a frame later — two writes to
           `@State`, two rebuilds of the ScrollView and the LazyVStack inside it, both landing while
           the scroll is still coming to rest. */
        let visible = !isJumping && clamped > TranscriptView.chipThreshold
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
    private func follow(proxy: ScrollViewProxy, messages: [ChatMessage], motionOn: Bool) {
        let rowCount = messages.count
        let isNewRow = rowCount != lastRowCount
        if isNewRow { lastRowCount = rowCount }

        /* SENDING IS AN EXPLICIT ACT, and it always wins. Reading further up the conversation
           correctly stops a STREAMING answer from yanking the page around — that is what
           `isAtBottom` protects. But a message the reader just typed is not the answer arriving;
           they asked for it, and leaving them stranded above their own question is the complaint:
           "اذا اني فوق بالمحادثة، من ارسل رسالة خلي ينزلني تحت يم الرسالة".

           WHY THE NEWEST QUESTION AND NOT THE LAST ROW'S ROLE. This used to ask whether the row
           count had moved and the last row was a `.user`, and that condition could not fire for an
           ordinary send. `SendPipeline.send` appends the question and then calls `beginTurn`, which
           calls `placeAssistantRow`, and its own comment says the stretch between them never
           suspends: both rows are in the store before SwiftUI evaluates a single body. So the count
           jumps by two and the last row is the empty ASSISTANT placeholder — `lastRole == .user`
           was false every time, the guard fell through to `isAtBottom`, and a reader who had
           scrolled up was left exactly where they were. (It did fire for image and video requests,
           where `beginTurn` is behind an `await` — which is why this looked like it worked.)
           Comparing the id of the newest question instead is indifferent to how many rows arrive
           on the same frame, and it stays false for a regenerate, which adds no question at all. */
        let newestQuestion = TranscriptView.latestUserID(messages)
        let sentByReader = newestQuestion != lastUserID
        if sentByReader { lastUserID = newestQuestion }

        let wasPinned = liveState?.isAtBottom ?? true
        guard sentByReader || wasPinned else { return }

        if sentByReader {
            liveState?.isAtBottom = true
            /* The composer puts the keyboard away on the same frame it sends (`fieldFocused =
               false`), so the scroll view is about to get a few hundred points of height back.
               Scrolling once, now, would land against the viewport it has while that is still
               happening — the new turn ends up under the composer. `jump` scrolls again once it
               has stopped moving. */
            jump(proxy: proxy, motionOn: motionOn)
            return
        }
        scroll(proxy: proxy, animated: isNewRow && motionOn)
    }

    /// Takes the reader to the end and keeps them there while the viewport settles. The one path
    /// for both jumps a person asks for: the chip, and their own message being sent.
    private func jump(proxy: ScrollViewProxy, motionOn: Bool) {
        isJumping = true
        if showsChip {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                showsChip = false
            }
        }
        scroll(proxy: proxy, animated: false)
        Task {
            await JobClock.rest(TranscriptView.settleDelay)
            scroll(proxy: proxy, animated: false)
            isJumping = false
        }
    }

    /// `animated` is for a step, never for a journey.
    ///
    /// THE BLACK TRANSCRIPT LIVED HERE. `withAnimation { proxy.scrollTo(…) }` does not jump the
    /// content offset; it drives it through every point in between. Over a conversation the reader
    /// has scrolled to the top of, that means the `LazyVStack` builds and throws away every row in
    /// the thread inside a third of a second, while its content height is remeasured under an
    /// offset that was aimed at the height it had when the animation started — and `standard` is a
    /// spring damped 0.85, so it carries that offset PAST the end before coming back. What settled
    /// was an offset below everything the stack had kept. Nothing intersected the viewport, so the
    /// stack built nothing, so the height never grew back to clamp the offset: an empty scroll view
    /// with the top bar and the composer still drawn around it, exactly as the owner photographed
    /// it, and a drag upwards the only thing that could recover it —
    /// «ينزلني تحت و المحادثة تصير سوداء الا ارجع اصعد».
    ///
    /// So a long jump is never animated. Following a growing answer still is: the reader is already
    /// pinned, the distance is a few points a tick, and no row is built or destroyed to cover it.
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
                   full height back, so the bottom it scrolls to is the bottom the reader sees;
                   `jump` scrolls a second time once that height has stopped changing. */
                Keyboard.dismiss()
                liveState?.isAtBottom = true
                jump(proxy: proxy, motionOn: motionOn)
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
