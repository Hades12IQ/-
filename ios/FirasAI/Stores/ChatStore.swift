import Foundation
import Observation
import OSLog

/// Conversations: the list, the transcripts, and the one send path.
///
/// The store owns three parallel tables. `summaries` is what the sidebar draws; `conversations`
/// holds the transcripts that have actually been opened (members load them lazily, guests load
/// them from disk); `states` holds the volatile half of each conversation. Nothing here polls —
/// every durable turn is handed to `JobManager` and comes back through `JobObserver`, which is
/// what makes leaving the screen (or the app) harmless.
///
/// A member's conversation keeps its **local** key for the life of the app and carries the server
/// id in `serverID`. That indirection exists because a conversation is created on the server lazily,
/// on the first send (`audit-ios-chat.md §Major M13`): re-keying the table at that moment would
/// break every id already captured by a live job, a router selection and a draft.
@MainActor
@Observable
final class ChatStore: JobObserver {

    // MARK: - Published state

    private(set) var summaries: [ChatSummary] = []
    private(set) var conversations: [String: ChatConversation] = [:]
    private(set) var states: [String: ConversationState] = [:]
    private(set) var isLoadingList = false
    /// Already localized; drives the sidebar's load-error row with its Retry.
    private(set) var listError: String?
    /// Conversations whose transcript is being fetched — the transcript skeleton reads this.
    private(set) var loadingConversations: Set<String> = []

    // MARK: - Dependencies

    let api: APIClient
    let session: SessionStore
    let jobs: JobManager
    let prefs: PreferencesStore
    let drafts: DraftStore
    let guestChats: GuestChatStore
    let toasts: ToastCenter
    let router: Router
    let network: NetworkMonitor

    @ObservationIgnored let pipeline: SendPipeline
    @ObservationIgnored var buffers: [String: StreamBuffer] = [:]
    @ObservationIgnored var serverRows: [ChatSummary] = []
    @ObservationIgnored var renamed: Set<String> = []
    @ObservationIgnored var titled: Set<String> = []
    @ObservationIgnored var pendingDeletes: [String: ChatConversation] = [:]
    @ObservationIgnored var deleteTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var loadedOwner: String?

    init(
        api: APIClient,
        session: SessionStore,
        jobs: JobManager,
        prefs: PreferencesStore,
        drafts: DraftStore,
        guestChats: GuestChatStore,
        toasts: ToastCenter,
        router: Router,
        network: NetworkMonitor
    ) {
        self.api = api
        self.session = session
        self.jobs = jobs
        self.prefs = prefs
        self.drafts = drafts
        self.guestChats = guestChats
        self.toasts = toasts
        self.router = router
        self.network = network
        self.pipeline = SendPipeline(
            api: api,
            session: session,
            jobs: jobs,
            prefs: prefs,
            drafts: drafts,
            toasts: toasts,
            router: router
        )
        pipeline.store = self
    }

    /// The UI language, read by everything that files a turn on the store's behalf.
    var lang: AppLanguage { prefs.lang }

    /// The media hand-off used when a chat message asks for a picture, a clip or a song.
    var onMediaRequest: ((MediaKind, String, String) async -> Bool)? {
        get { pipeline.onMediaRequest }
        set { pipeline.onMediaRequest = newValue }
    }

    /// Fired once per landed answer with the question that earned it, for `MemoryStore.learn`.
    /// `AppEnvironment` is the only writer; the store has no `MemoryStore` of its own.
    var onAnswerLanded: ((String, ProductKind) -> Void)? {
        get { pipeline.onAnswerLanded }
        set { pipeline.onAnswerLanded = newValue }
    }

    // MARK: - The mutating door
    //
    // `summaries` and `conversations` are `private(set)`, and `private` in Swift is file-scoped, so
    // the extension that keeps this type's other half needs a way in that the rest of the app does
    // not get.

    func replaceSummaries(_ rows: [ChatSummary]) {
        summaries = rows
    }

    func setConversation(_ conversation: ChatConversation?, forKey key: String) {
        conversations[key] = conversation
    }

    // MARK: - The list

    func loadConversations() async {
        guard let owner = session.identityID else {
            summaries = []
            serverRows = []
            return
        }
        if loadedOwner != owner {
            // A different identity: nothing from the previous one may stay on screen.
            conversations = [:]
            states = [:]
            buffers = [:]
            serverRows = []
            summaries = []
            loadedOwner = owner
        }
        isLoadingList = true
        listError = nil
        defer { isLoadingList = false }

        if session.isMember {
            do {
                serverRows = try await api.listChats()
            } catch {
                listError = applyErrorAction(
                    ErrorPresenter.present(error, feature: .generic, isGuest: false, lang: lang),
                    in: nil,
                    silently: true
                ) ?? Strings.Errors.generic(lang)
            }
        } else {
            let stored = await guestChats.load(owner: owner)
            for conversation in stored {
                conversations[conversation.id] = conversation
            }
        }
        rebuildSummaries()
    }

    func open(_ id: String) async {
        let key = resolve(id)
        if let existing = conversations[key] {
            ensureState(for: key, conversation: existing)
            return
        }
        guard session.isMember else {
            // A guest's transcripts all arrive with the list; nothing else can produce one.
            guard let owner = session.identityID else { return }
            let stored = await guestChats.load(owner: owner)
            for conversation in stored where conversations[conversation.id] == nil {
                conversations[conversation.id] = conversation
            }
            if let conversation = conversations[key] {
                ensureState(for: key, conversation: conversation)
                rebuildSummaries()
            }
            return
        }

        loadingConversations.insert(key)
        defer { loadingConversations.remove(key) }
        do {
            let fetched = try await api.getChat(id: key)
            let row = serverRows.first { $0.id == key }
            let conversation = ChatConversation(
                id: key,
                serverID: key,
                title: fetched.title,
                messages: fetched.messages,
                pinned: row?.pinned ?? false,
                agent: row?.agent ?? false,
                codeProj: row?.codeProj ?? false,
                brainNb: row?.brainNb ?? false,
                createdAt: row?.createdAt,
                updatedAt: row?.updatedAt
            )
            conversations[key] = conversation
            ensureState(for: key, conversation: conversation)
            rebuildSummaries()
        } catch {
            let message = applyErrorAction(
                ErrorPresenter.present(error, feature: .generic, isGuest: session.isGuest, lang: lang),
                in: key,
                silently: true
            )
            state(for: key).errorStrip = message ?? Strings.Errors.generic(lang)
        }
    }

    /// A conversation that exists only here until the first send.
    func newConversation(product: ProductKind, flags: (agent: Bool, codeProj: Bool, brainNb: Bool)) -> String {
        let id = IDs.localConversationID()
        let conversation = ChatConversation(
            id: id,
            serverID: nil,
            title: "",
            messages: [],
            pinned: false,
            agent: flags.agent,
            codeProj: flags.codeProj,
            brainNb: flags.brainNb,
            createdAt: Self.timestamp(),
            updatedAt: Self.timestamp()
        )
        conversations[id] = conversation
        _ = state(for: id)
        _ = product
        return id
    }

    /// Creates the server record on demand. `nil` for guests — and for a member whose creation
    /// failed, which is the cue to answer over the live stream instead of losing the turn.
    func ensureServerChat(_ id: String) async -> String? {
        let key = resolve(id)
        guard session.isMember, var conversation = conversations[key] else { return nil }
        // The refusal that keeps `serverID` nil forever, which is in turn what disqualifies a
        // temporary conversation from the durable job path below it.
        guard !conversation.ephemeral else { return nil }
        if let serverID = conversation.serverID { return serverID }
        let title = conversation.title.isEmpty ? Strings.Chat.newChat(lang) : conversation.title
        let request = CreateChatRequest(
            title: title,
            messages: MessageSerializer.persisted(conversation),
            agent: conversation.agent ? true : nil,
            codeProj: conversation.codeProj ? true : nil,
            brainNb: conversation.brainNb ? true : nil,
            id: Self.clientID(for: key)
        )
        do {
            let created = try await api.createChat(request)
            conversation.serverID = created.id
            conversations[key] = conversation
            rebuildSummaries()
            return created.id
        } catch {
            _ = applyErrorAction(
                ErrorPresenter.present(error, feature: .generic, isGuest: false, lang: lang),
                in: key,
                silently: true
            )
            return nil
        }
    }

    func state(for id: String) -> ConversationState {
        let key = resolve(id)
        if let existing = states[key] { return existing }
        let created = ConversationState(conversationID: key)
        if let conversation = conversations[key] {
            created.plan = PlanCycle.derive(
                from: conversation.messages,
                snapshot: conversation.planSnapshotMode
            )
        }
        states[key] = created
        return created
    }

    // MARK: - Sending (every entry point walks `SendPipeline`)

    func send(text: String, attachments: [PreparedAttachment], in id: String, product: ProductKind) async {
        await pipeline.send(text: text, attachments: attachments, in: id, product: product)
    }

    func stop(in id: String) async {
        await pipeline.stop(in: id)
    }

    func regenerate(messageID: String, in id: String, tier: ModelTier?) async {
        await pipeline.regenerate(messageID: messageID, in: id, tier: tier)
    }

    func continueAnswer(messageID: String, in id: String) async {
        await pipeline.continueAnswer(messageID: messageID, in: id)
    }

    func submitAsk(answers: [String: [String]], extra: String, askMessageID: String, in id: String) async {
        await pipeline.submitAsk(answers: answers, extra: extra, askMessageID: askMessageID, in: id)
    }

    func approvePlan(in id: String) async {
        await pipeline.approvePlan(in: id)
    }

    func selectVersion(messageID: String, index: Int, in id: String) {
        let key = resolve(id)
        mutate(key) { conversation in
            guard let position = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            guard let alts = conversation.messages[position].alts, !alts.isEmpty else { return }
            let clamped = min(max(index, 0), alts.count - 1)
            conversation.messages[position].altAt = clamped
            conversation.messages[position].content = alts[clamped].content
            conversation.messages[position].reasoning = alts[clamped].reasoning
        }
        Task { [weak self] in
            await self?.persist(key)
        }
    }

    // MARK: - Editing the list

    func rename(_ id: String, title: String) async {
        let key = resolve(id)
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty, var conversation = conversations[key] else { return }
        renamed.insert(key)
        conversation.title = clean
        conversations[key] = conversation
        rebuildSummaries()
        if session.isMember, let serverID = conversation.serverID {
            try? await api.updateChat(id: serverID, UpdateChatRequest(title: clean))
        } else {
            await persistLocalOnly(key)
        }
    }

    func pin(_ id: String, _ pinned: Bool) async {
        let key = resolve(id)
        guard var conversation = conversations[key] else {
            guard let index = summaries.firstIndex(where: { $0.id == key }) else { return }
            var row = summaries[index]
            row.pinned = pinned
            summaries[index] = row
            if let serverIndex = serverRows.firstIndex(where: { $0.id == key }) {
                serverRows[serverIndex].pinned = pinned
            }
            if session.isMember {
                try? await api.updateChat(id: key, UpdateChatRequest(pinned: pinned))
            }
            return
        }
        conversation.pinned = pinned
        conversations[key] = conversation
        if let serverIndex = serverRows.firstIndex(where: { $0.id == (conversation.serverID ?? key) }) {
            serverRows[serverIndex].pinned = pinned
        }
        rebuildSummaries()
        if session.isMember, let serverID = conversation.serverID {
            try? await api.updateChat(id: serverID, UpdateChatRequest(pinned: pinned))
        } else {
            await persistLocalOnly(key)
        }
    }

    /// Removed instantly, deleted seven seconds later — the web's `UNDO_MS` (`web-chat-ux.md §11`).
    func delete(_ id: String) async {
        let key = resolve(id)
        guard let conversation = conversations[key] ?? summaries.first(where: { $0.id == key }).map({ row in
            ChatConversation(
                id: row.id,
                serverID: row.id,
                title: row.title,
                messages: [],
                pinned: row.pinned,
                agent: row.agent,
                codeProj: row.codeProj,
                brainNb: row.brainNb,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }) else { return }

        conversations[key] = nil
        states[key] = nil
        buffers[key] = nil
        serverRows.removeAll { $0.id == (conversation.serverID ?? key) }
        pendingDeletes[key] = conversation
        rebuildSummaries()
        if router.selectedConversationID == key { router.selectedConversationID = nil }
        drafts.clear(DraftStore.key(conversationID: key))

        toasts.show(
            Strings.ChatStoreCopy.deleted(lang),
            actionTitle: Strings.Common.undo(lang),
            duration: 7
        ) { [weak self] in
            self?.undoDelete(key)
        }
        deleteTasks[key]?.cancel()
        deleteTasks[key] = Task { [weak self] in
            await JobClock.rest(7)
            guard let self, !Task.isCancelled else { return }
            await self.commitDelete(key)
        }
    }

    /// Throws a temporary conversation away — no undo toast, no server call, no disk write.
    ///
    /// `delete(_:)` is the wrong door for this: it offers seven seconds of undo, and a mode whose
    /// promise is that nothing is recoverable cannot end with a button that recovers it. Ending is
    /// irreversible by construction here, because there is no record to undo back to.
    func discardTemporary(_ id: String) async {
        let key = resolve(id)
        guard let conversation = conversations[key], conversation.ephemeral else { return }
        // Abort a reply still writing into the record before the record goes, or the stream
        // finalizes into a conversation nothing points at any more.
        if states[key]?.isBusy == true {
            await stop(in: key)
        }
        conversations[key] = nil
        states[key] = nil
        buffers[key] = nil
        pendingDeletes[key] = nil
        deleteTasks[key]?.cancel()
        deleteTasks[key] = nil
        serverRows.removeAll { $0.id == key }
        // The unsent question is the most sensitive string this mode handles. `flush` rewrites the
        // draft file immediately, so a draft saved earlier in the conversation goes with it.
        drafts.clear(DraftStore.key(conversationID: key))
        drafts.flush()
        if router.selectedConversationID == key { router.selectedConversationID = nil }
        rebuildSummaries()
    }

    // MARK: - Turns filed by other stores

    func appendAssistantTurn(_ message: ChatMessage, in id: String) async {
        let key = resolve(id)
        guard conversations[key] != nil else { return }
        mutate(key) { conversation in
            if let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
                conversation.messages[index] = message
            } else {
                conversation.messages.append(message)
            }
        }
        touch(key)
        await persist(key)
    }

    func appendUserTurn(_ message: ChatMessage, in id: String) async {
        let key = resolve(id)
        guard conversations[key] != nil else { return }
        mutate(key) { conversation in
            conversation.messages.append(message)
            if conversation.title.isEmpty {
                conversation.title = AutoTitle.provisional(from: message.content)
            }
        }
        touch(key)
        await persist(key)
    }
}
