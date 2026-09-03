import Foundation
import UIKit

/// Everything that happens between the user tapping Send and an answer being stored.
///
/// There is exactly one path, and every entry point (a new message, a regenerate, an ask
/// submission, a plan approval, the automatic engine-failure retry) walks it in the same order:
///
///   classify → plan-turn kind → fold attachments → **put both rows on screen** →
///   search → build the prompt → persist the user turn → stream the answer in front of the reader
///   → hand the turn to the durable queue the moment they leave → land it → reconcile.
///
/// Four orderings in that list are contracts, not preferences.
///
/// 1. **The rows go in first.** Everything above the "search" step is synchronous, so the question
///    bubble and the answer's thinking row are in the transcript before a single byte leaves the
///    device — the owner's «ارسل شي ما تنزل الفقاعة مباشرة». `beginTurn` inserts and returns; the
///    network half runs in `runTurn` on its own task. A media request («اصنع صورة») is the same
///    rule with a different second half: the question lands now and the render starts behind it,
///    because «من ارسل ما يتاخر بارسال الرسالة، يضل معلس» was this method awaiting a quota read and
///    a prompt-rewriting model call before it appended anything at all.
/// 2. The user turn is written to `/api/chats` *before* the job starts, because the job saves only
///    the assistant turn (`server-chat-jobs-chats.md §3.1`) and a device that dies mid-answer would
///    otherwise leave an answer with no question.
/// 3. **Local first, server on leaving.** While the reader is here an ordinary turn is one socket —
///    `POST /api/chat`, tokens painted as the model emits them. The durable queue costs five client
///    round trips and six server-to-database ones before the first token can exist, and quantises
///    it to a poll boundary (`web-fix-send-latency.md §2.1, §2.4`); that is the difference the owner
///    remembers as "it used to be smooth". The queue is not abandoned — it is where the turn goes
///    the instant the app leaves the foreground, under the same `cid`.
/// 4. That hand-over never cancels and never doubles. One `cid` per turn, and `JobManager` refuses
///    to start a second job for a cid it already holds, so leaving twice, or leaving and coming
///    back, adopts the running job rather than paying for another one.
@MainActor
final class SendPipeline {

    /// Above this many characters of request body the durable queue answers 413, so the live
    /// stream is used instead (`JOB_PAYLOAD_MAX` is 600 000; this leaves room for the envelope).
    static let jobPayloadCeiling = 550_000
    /// The web's client-side stream ceiling (`app.js:41535`).
    static let streamCeiling: TimeInterval = 15 * 60
    /// One frame at 60 Hz. `runTurn` waits exactly this long before it starts working, which hands
    /// the run loop back to SwiftUI so the two rows `beginTurn` inserted are actually *painted*
    /// before prompt building, chat creation and the transcript PUT take the main actor again.
    static let paintGrace: TimeInterval = 1.0 / 60.0

    weak var store: ChatStore?

    let api: APIClient
    let session: SessionStore
    let jobs: JobManager
    let prefs: PreferencesStore
    let drafts: DraftStore
    let toasts: ToastCenter
    let router: Router

    /// The turn each conversation is running, so the one automatic retry can re-run it. Absent
    /// after a relaunch — a recovered job is landed, never silently re-sent.
    var contexts: [String: ChatTurnContext] = [:]
    var streamTasks: [String: Task<Void, Never>] = [:]
    /// The network half of a turn between `beginTurn` and the moment a job pointer or a stream task
    /// exists. Stop has to be able to reach a turn in that window too.
    var turnTasks: [String: Task<Void, Never>] = [:]

    /// Everything a streaming turn needs to become a durable job without asking anything again.
    /// Present only while a turn is on the socket **and** the queue would accept it; leaving the
    /// app walks this table and nothing else.
    var handoffs: [String: ChatHandoff] = [:]
    /// Turns already on their way to the queue. Home and the background notice can land in the same
    /// run-loop turn, and the second POST would only re-derive the first one's answer.
    var handingOff: Set<String> = []

    private var observingLifecycle = false

    /// Set by whoever owns media creation. A chat message classified as an image/video/song is
    /// handed over here; when nothing is wired the turn is answered as ordinary prose instead of
    /// being dropped.
    var onMediaRequest: ((MediaKind, String, String) async -> Bool)?

    /// Called once per successfully landed answer with the question that earned it, so the App
    /// layer can hand it to `MemoryStore.learn` (`plan/Stores.md`, `web-prompt-builder.md §343`).
    var onAnswerLanded: ((String, ProductKind) -> Void)?

    init(
        api: APIClient,
        session: SessionStore,
        jobs: JobManager,
        prefs: PreferencesStore,
        drafts: DraftStore,
        toasts: ToastCenter,
        router: Router
    ) {
        self.api = api
        self.session = session
        self.jobs = jobs
        self.prefs = prefs
        self.drafts = drafts
        self.toasts = toasts
        self.router = router
        ensureLifecycleObservers()
    }

    /// True while there is a reader in front of the answer. A send that happens with the app already
    /// away (a notification action, a background wake) goes straight to the queue — there is nobody
    /// to stream to and no foreground left to stream in.
    var readerIsPresent: Bool {
        UIApplication.shared.applicationState != .background
    }

    // MARK: - Entry points

    func send(text: String, attachments: [PreparedAttachment], in id: String, product: ProductKind) async {
        await deliver(text: text, attachments: attachments, in: id, product: product, mergedFrom: nil)
    }

    /// The real send. `mergedFrom` is the answer a "Continue" turn is seamed to; it has to travel
    /// with the turn rather than being stamped afterwards, because the turn no longer waits around
    /// for its own network half to start.
    func deliver(
        text: String,
        attachments: [PreparedAttachment],
        in id: String,
        product: ProductKind,
        mergedFrom: String?
    ) async {
        guard let store else { return }
        let key = store.resolve(id)
        guard store.conversation(key) != nil else { return }
        let state = store.state(for: key)
        guard !state.isBusy else {
            toasts.show(Strings.Chat.busyWait(store.lang))
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = Self.fold(attachments)
        guard !trimmed.isEmpty || !folded.images.isEmpty || !folded.fileText.isEmpty else { return }

        let lang = store.lang
        let reattach = Self.reattachment(for: trimmed, state: state, hasOwnImages: !folded.images.isEmpty)
        let hasImages = !folded.images.isEmpty || !reattach.isEmpty
        let kind = RequestClassifier.classify(trimmed, hasImages: hasImages, lang: lang)

        // A render is refused for a guest before anything is written, because the server answers
        // 403 `signin_required` for every guest media request and the upsell is the same answer
        // without the round trip. This is the one branch that may leave without a bubble.
        let mediaKind = Self.mediaKind(for: kind)
        if let mediaKind, !session.isMember {
            router.showSignUp(feature: ErrorPresenter.featureKey(for: mediaKind.jobKind))
            return
        }

        // ── From here to the hand-off nothing suspends. ───────────────────────────────────────
        state.errorStrip = nil
        let cid = IDs.cid()
        var user = ChatMessage.user(trimmed, cid: cid, lang: lang)
        user.files = folded.chips.isEmpty ? nil : folded.chips
        user.imageThumbs = folded.thumbs.isEmpty ? nil : folded.thumbs
        user.images = folded.images.isEmpty ? nil : folded.images
        user.fileText = folded.fileText.isEmpty ? nil : folded.fileText
        user.intent = Self.intent(for: kind)
        user.status = .sending

        let planTurn = state.plan.userSent(user, liveMode: prefs.responseMode, product: product)
        state.lastTurnImages = folded.images.isEmpty ? reattach : folded.images

        store.mutate(key) { conversation in
            conversation.messages.append(user)
            if conversation.title.isEmpty {
                conversation.title = AutoTitle.provisional(from: trimmed)
            }
            if conversation.planSnapshotMode == nil, state.plan.snapshotMode == .plan {
                conversation.planSnapshotMode = .plan
            }
        }
        drafts.clear(DraftStore.key(conversationID: key))
        drafts.clear(DraftStore.key(newIn: product))

        let context = ChatTurnContext(
            conversationID: key,
            product: product,
            userMessageID: user.id,
            turnCID: cid,
            planTurn: planTurn,
            tier: prefs.tier,
            regenerateTargetID: nil,
            retryOf: nil,
            mergedFrom: mergedFrom,
            isAutoRetry: false
        )

        if let mediaKind, let handler = onMediaRequest {
            // The question is already on screen. `MediaStore` writes its own question and card, so
            // the second copy of the same sentence is dropped when it arrives; refusals (a spent
            // daily quota, an engine the server has not configured) leave ours standing, which is
            // exactly right — the user did ask.
            store.mutate(key) { conversation in
                guard let index = conversation.messages.firstIndex(where: { $0.id == user.id && $0.role == .user }) else { return }
                conversation.messages[index].status = .delivered
            }
            let questionID = user.id
            Task { [weak self] in
                guard let self else { return }
                let handled = await handler(mediaKind, trimmed, key)
                if handled {
                    await self.dropDuplicateQuestion(key: key, keeping: questionID, text: trimmed)
                } else {
                    // No engine for this kind. The turn becomes ordinary prose, answered from the
                    // row that is already in the transcript.
                    self.beginTurn(context)
                }
            }
            return
        }

        beginTurn(context)
    }

    /// A second answer to a question already asked. The existing row keeps its identity and gains
    /// a version; only the turn id changes, so the worker's save and our own converge again.
    func regenerate(messageID: String, in id: String, tier: ModelTier?) async {
        guard let store else { return }
        let key = store.resolve(id)
        guard let conversation = store.conversation(key) else { return }
        let state = store.state(for: key)
        guard !state.isBusy else {
            toasts.show(Strings.Chat.busyWait(store.lang))
            return
        }
        // Role-guarded on purpose: only an answer can be regenerated, and a lookup that could land
        // on the question would rewrite the question with the new answer.
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }) else { return }
        let target = conversation.messages[index]
        guard let userIndex = conversation.messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        let user = conversation.messages[userIndex]

        state.errorStrip = nil
        let chosen = tier ?? ModelTier(rawValue: target.tier ?? "") ?? prefs.tier
        var retryOf: RetryReference?
        if let requested = tier, let previousCID = target.cid, requested.rawValue != (target.tier ?? "") {
            retryOf = RetryReference(cid: previousCID, tier: target.tier ?? prefs.tier.rawValue)
        }

        let context = ChatTurnContext(
            conversationID: key,
            product: conversation.product,
            userMessageID: user.id,
            turnCID: IDs.cid(),
            planTurn: .auto,
            tier: chosen,
            regenerateTargetID: target.id,
            retryOf: retryOf,
            mergedFrom: nil,
            isAutoRetry: false
        )
        beginTurn(context)
    }

    /// "Continue" is a new turn that says so, seamed to the answer it follows. The seam is recorded
    /// on the row the continuation writes, so an export can rejoin the two halves later;
    /// `mergedFrom` is on the server's persist whitelist.
    func continueAnswer(messageID: String, in id: String) async {
        guard let store else { return }
        let key = store.resolve(id)
        guard let conversation = store.conversation(key) else { return }
        await deliver(
            text: Strings.ChatStoreCopy.continueInstruction(store.lang),
            attachments: [],
            in: key,
            product: conversation.product,
            mergedFrom: String(messageID.prefix(120))
        )
    }

    /// The plan-mode ask panel. The summary is its own user turn: never a quote, never attachments
    /// (`web-plan-mode.md §7.7`).
    func submitAsk(answers: [String: [String]], extra: String, askMessageID: String, in id: String) async {
        guard let store else { return }
        let key = store.resolve(id)
        guard let conversation = store.conversation(key) else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == askMessageID }) else { return }
        let lang = store.lang
        let spec = AskSpec.parse(conversation.messages[index].content)
        let summary = spec?.summary(answers: answers, extra: extra, lang: lang)
            ?? extra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }

        store.mutate(key) { conversation in
            conversation.messages[index].askAnswered = true
        }
        await send(text: summary, attachments: [], in: key, product: conversation.product)
    }

    /// The Start pill. The sentence is one of the matcher's exact forms, so a chat reloaded later
    /// derives the same phase (`web-plan-mode.md §7.5–7.6`).
    func approvePlan(in id: String) async {
        guard let store else { return }
        let key = store.resolve(id)
        guard let conversation = store.conversation(key) else { return }
        await send(
            text: Strings.Chat.planApproval(store.lang),
            attachments: [],
            in: key,
            product: conversation.product
        )
    }

    func stop(in id: String) async {
        guard let store else { return }
        let key = store.resolve(id)
        let state = store.state(for: key)
        guard state.isBusy else { return }
        state.isStopping = true

        if handingOff.contains(key) {
            // The turn is mid-flight to the queue. `performHandOff` reads `isStopping` and settles
            // it there; racing it from here would settle the same turn twice.
            return
        }
        if let task = streamTasks[key] {
            // `runStream` settles the turn itself: it is the only place that knows how much of the
            // answer arrived before the socket closed.
            task.cancel()
            streamTasks[key] = nil
            handoffs[key] = nil
            return
        }
        if let pointerID = state.jobPointerID, jobs.pointer(id: pointerID) != nil {
            // `cancel` answers false for a queued job the server will not touch — and delivers
            // `.cancelled` either way, which is what settles the conversation.
            _ = await jobs.cancel(jobID: pointerID)
            return
        }
        // Still in the prologue: no socket, no pointer. The turn task is cancelled and settled from
        // here, because a cancelled task cannot make the request that saves what it has.
        if let turn = turnTasks[key] {
            turn.cancel()
            turnTasks[key] = nil
        }
        await settleStopped(key: key)
    }

    // MARK: - Leaving and coming back

    /// The two app-level moments this object needs and `AppLifecycle` does not hand it. Registered
    /// once from `init`; the block holds `self` weakly and the pipeline is built once by `ChatStore`
    /// and lives as long as the process, so there is nothing to unregister.
    private func ensureLifecycleObservers() {
        guard !observingLifecycle else { return }
        observingLifecycle = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handOffLiveTurns() }
        }
    }

    /// Leaving. Nothing is cancelled: every turn streaming in front of a reader is moved to the
    /// durable queue under its own `cid` and finishes there.
    func handOffLiveTurns() {
        for key in Array(handoffs.keys) {
            handOff(key)
        }
    }

    private func handOff(_ key: String) {
        guard let plan = handoffs[key], !handingOff.contains(key) else { return }
        guard let store, store.state(for: key).isBusy else {
            handoffs[key] = nil
            return
        }
        handingOff.insert(key)
        // The socket goes first so the two answers can never overlap. `runStream` sees the key in
        // `handingOff` and returns without settling anything.
        streamTasks[key]?.cancel()
        streamTasks[key] = nil
        Task { [weak self] in
            await self?.performHandOff(key, plan)
        }
    }

    private func performHandOff(_ key: String, _ plan: ChatHandoff) async {
        // The app is on its way out; the POST has to survive the trip.
        let hold = BackgroundExecutor.hold(name: "firas.chat.handoff." + key)
        defer {
            hold.end()
            handingOff.remove(key)
            handoffs[key] = nil
        }
        guard let store else { return }
        let state = store.state(for: key)
        let buffer = store.buffer(for: key)
        let partial = buffer.finish()

        if state.isStopping {
            await settleStopped(
                key: key,
                text: partial.text,
                reasoning: partial.reasoning,
                assistantID: plan.assistantID,
                cid: plan.context.turnCID
            )
            return
        }

        do {
            let pointer = try await jobs.startChatQueueJob(plan.request, pointer: plan.draft)
            // The worker writes its answer from the top, and `StreamBuffer.adopt` only ever grows —
            // so the half sentence that streamed has to go, or a shorter final answer would never
            // be painted over it. Nobody is looking: this is the frame after the app left.
            buffer.reset()
            state.jobPointerID = pointer.id
            state.streamingMessageID = plan.assistantID
            state.activeCID = plan.context.turnCID
            if state.phase != .completing { state.phase = .thinking }
        } catch {
            // The queue could not be reached or refused the turn. Whatever arrived on the socket is
            // the answer this turn gets — keeping it is strictly better than a lit spinner nobody
            // will ever settle.
            if !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await settleStopped(
                    key: key,
                    text: partial.text,
                    reasoning: partial.reasoning,
                    assistantID: plan.assistantID,
                    cid: plan.context.turnCID
                )
                return
            }
            let action = ErrorPresenter.present(
                error,
                feature: .generic,
                isGuest: session.isGuest,
                lang: store.lang
            )
            await failTurn(key: key, assistantID: plan.assistantID, action: action, context: plan.context)
        }
    }

    /// `MediaStore` appends its own copy of the question once its prompt pipeline has run. Ours is
    /// the one the user watched land, so the later twin goes — matched by role, by text, and by
    /// position after ours, which is the only pair those three can describe.
    private func dropDuplicateQuestion(key: String, keeping id: String, text: String) async {
        guard let store, let conversation = store.conversation(key) else { return }
        guard let mine = conversation.messages.firstIndex(where: { $0.id == id && $0.role == .user }) else { return }
        let after = conversation.messages.index(after: mine)
        guard after < conversation.messages.endIndex else { return }
        guard let twin = conversation.messages[after...].firstIndex(where: {
            $0.role == .user && $0.id != id && $0.content == text
        }) else { return }
        store.mutate(key) { conversation in
            guard twin < conversation.messages.endIndex else { return }
            guard conversation.messages[twin].role == .user, conversation.messages[twin].id != id else { return }
            conversation.messages.remove(at: twin)
        }
        await store.persist(key)
    }
}

/// One turn in flight, kept so the single automatic retry can re-run exactly the same request with
/// a fresh id.
struct ChatTurnContext: Sendable {
    let conversationID: String
    let product: ProductKind
    let userMessageID: String
    var turnCID: String
    let planTurn: PlanTurnKind
    let tier: ModelTier
    var regenerateTargetID: String?
    var retryOf: RetryReference?
    var mergedFrom: String?
    var isAutoRetry: Bool
}

/// A turn on the socket, packed for the queue.
///
/// It is built at the moment the stream starts and never rebuilt, so the hand-over asks the model
/// no questions, classifies nothing, and re-reads no transcript — it is one POST with a body that
/// was already in memory. That is what makes leaving free.
struct ChatHandoff: Sendable {
    let request: ChatJobRequest
    let draft: JobPointer
    let assistantID: String
    let context: ChatTurnContext
}

/// Attachments after they have been split into the four things a turn actually carries.
struct FoldedAttachments: Sendable {
    var images: [String] = []
    var thumbs: [String] = []
    var chips: [FileChip] = []
    var fileText: String = ""

    var isEmpty: Bool { images.isEmpty && chips.isEmpty && fileText.isEmpty }
}
