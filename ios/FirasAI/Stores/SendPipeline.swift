import Foundation

/// Everything that happens between the user tapping Send and an answer being stored.
///
/// There is exactly one path, and every entry point (a new message, a regenerate, an ask
/// submission, a plan approval, the automatic engine-failure retry) walks it in the same order:
///
///   classify → plan-turn kind → fold attachments → **put both rows on screen** →
///   search → build the prompt → persist the user turn → start a durable job (or fall back to the
///   live stream) → land the answer → reconcile with the server.
///
/// Three orderings in that list are contracts, not preferences.
///
/// 1. **The rows go in first.** Everything above the "search" step is synchronous, so the question
///    bubble and the answer's thinking row are in the transcript before a single byte leaves the
///    device — the owner's «ارسل شي ما تنزل الفقاعة مباشرة» was this pipeline building the prompt,
///    creating the server chat and PUTting the transcript while still holding the main actor, so
///    SwiftUI had no frame in which to draw the bubble. `beginTurn` now inserts and returns; the
///    network half runs in `runTurn` on its own task.
/// 2. The user turn is written to `/api/chats` *before* the job starts, because the job saves only
///    the assistant turn (`server-chat-jobs-chats.md §3.1`) and a device that dies mid-answer would
///    otherwise leave an answer with no question.
/// 3. The job is started through `JobManager`, never polled here, so leaving the screen — or the
///    app — cannot cancel the work.
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
    /// It is the difference between a bubble that appears on the tap and one that appears when the
    /// request has been dispatched; against a turn measured in seconds it costs nothing.
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

    /// Set by whoever owns media creation. A chat message classified as an image/video/song is
    /// handed over here; when nothing is wired the turn is answered as ordinary prose instead of
    /// being dropped.
    var onMediaRequest: ((MediaKind, String, String) async -> Bool)?

    /// Called once per successfully landed answer with the question that earned it, so the App
    /// layer can hand it to `MemoryStore.learn` (`plan/Stores.md`, `web-prompt-builder.md §343`).
    /// The store itself has no `MemoryStore` in its frozen initialiser, so this is the seam.
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

        // The one await that may precede the rows, and it is the branch that never files them: a
        // media request is answered by `MediaStore`, which writes its own question and placeholder.
        if let mediaKind = Self.mediaKind(for: kind) {
            if !session.isMember {
                // The server answers 403 `signin_required` for every guest media request; asking
                // first is the same answer without the round trip.
                router.showSignUp(feature: ErrorPresenter.featureKey(for: mediaKind.jobKind))
                return
            }
            if let handler = onMediaRequest {
                let handled = await handler(mediaKind, trimmed, key)
                if handled { return }
            }
        }

        // ── From here to `beginTurn` nothing suspends. ────────────────────────────────────────
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
        // The answered flag rides the same PUT the turn itself makes; saving it first would put one
        // more round trip in front of the bubble.
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

        if let task = streamTasks[key] {
            // `runStream` settles the turn itself: it is the only place that knows how much of the
            // answer arrived before the socket closed.
            task.cancel()
            streamTasks[key] = nil
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

/// Attachments after they have been split into the four things a turn actually carries.
struct FoldedAttachments: Sendable {
    var images: [String] = []
    var thumbs: [String] = []
    var chips: [FileChip] = []
    var fileText: String = ""

    var isEmpty: Bool { images.isEmpty && chips.isEmpty && fileText.isEmpty }
}
