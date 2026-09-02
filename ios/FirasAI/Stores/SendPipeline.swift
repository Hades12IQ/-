import Foundation

/// Everything that happens between the user tapping Send and an answer being stored.
///
/// There is exactly one path, and every entry point (a new message, a regenerate, an ask
/// submission, a plan approval, the automatic engine-failure retry) walks it in the same order:
///
///   classify → plan-turn kind → fold attachments → search → build the prompt →
///   append the user turn and **persist it** → start a durable job (or fall back to the live
///   stream) → land the answer → reconcile with the server.
///
/// Two orderings in that list are contracts, not preferences. The user turn is written to
/// `/api/chats` *before* the job starts, because the job saves only the assistant turn
/// (`server-chat-jobs-chats.md §3.1`) and a device that dies mid-answer would otherwise leave an
/// answer with no question. And the job is started through `JobManager`, never polled here, so
/// leaving the screen — or the app — cannot cancel the work.
@MainActor
final class SendPipeline {

    /// Above this many characters of request body the durable queue answers 413, so the live
    /// stream is used instead (`JOB_PAYLOAD_MAX` is 600 000; this leaves room for the envelope).
    static let jobPayloadCeiling = 550_000
    /// The web's client-side stream ceiling (`app.js:41535`).
    static let streamCeiling: TimeInterval = 15 * 60

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
            mergedFrom: nil,
            isAutoRetry: false
        )
        await startTurn(context)
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
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
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
        await startTurn(context)
    }

    /// "Continue" is a new turn that says so, seamed to the answer it follows.
    func continueAnswer(messageID: String, in id: String) async {
        guard let store else { return }
        let key = store.resolve(id)
        guard let conversation = store.conversation(key) else { return }
        let instruction = Strings.ChatStoreCopy.continueInstruction(store.lang)
        await send(text: instruction, attachments: [], in: key, product: conversation.product)
        // The seam is recorded on the row the continuation is writing, so an export can rejoin the
        // two halves later. `mergedFrom` is on the server's persist whitelist.
        guard let streamingID = store.state(for: key).streamingMessageID else { return }
        store.mutate(key) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == streamingID }) else { return }
            conversation.messages[index].mergedFrom = String(messageID.prefix(120))
        }
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
        await store.persist(key)
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

        if let task = streamTasks[key] {
            task.cancel()
            streamTasks[key] = nil
            return
        }
        guard let pointerID = state.jobPointerID else {
            await settleStopped(key: key)
            return
        }
        guard jobs.pointer(id: pointerID) != nil else {
            await settleStopped(key: key)
            return
        }
        // `cancel` answers false for a queued job the server will not touch — and delivers
        // `.cancelled` either way, which is what settles the conversation.
        _ = await jobs.cancel(jobID: pointerID)
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

