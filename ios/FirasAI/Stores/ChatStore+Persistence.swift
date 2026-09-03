import Foundation
import OSLog

// MARK: - Saving, reconciling, and the job hand-off
//
// Split out of `ChatStore.swift` only for file size; this is the same object.

extension ChatStore {

    // MARK: - Persistence

    func persist(_ id: String) async {
        let key = resolve(id)
        guard let conversation = conversations[key] else { return }
        // A single refusal at the top is what makes "never written" true instead of true in the
        // places somebody remembered (`ChatConversation.ephemeral`).
        guard !conversation.ephemeral else { return }
        if session.isMember {
            guard let serverID = conversation.serverID else { return }
            let messages = MessageSerializer.persisted(conversation)
            do {
                try await api.updateChat(id: serverID, UpdateChatRequest(messages: messages))
            } catch {
                // A failed save is not worth interrupting a turn for: the durable job still holds
                // the answer, and the next successful write sends the whole array again.
                Log.net.error("chat persist failed: \(String(describing: error), privacy: .public)")
            }
        } else if let owner = session.identityID {
            await guestChats.save(conversation, owner: owner)
        }
    }

    /// The device-only half of `persist`: used when the server already holds the turn.
    func persistLocalOnly(_ id: String) async {
        let key = resolve(id)
        guard !session.isMember, let owner = session.identityID, let conversation = conversations[key] else { return }
        guard !conversation.ephemeral else { return }
        await guestChats.save(conversation, owner: owner)
    }

    func refreshFromServer(_ id: String) async {
        let key = resolve(id)
        guard session.isMember, var conversation = conversations[key], let serverID = conversation.serverID else { return }
        guard let fetched = try? await api.getChat(id: serverID) else { return }
        conversation.messages = MessageSerializer.merge(local: conversation.messages, server: fetched.messages)
        if !fetched.title.isEmpty, !renamed.contains(key) {
            conversation.title = fetched.title
        }
        setConversation(conversation, forKey: key)
        rebuildSummaries()
    }

    func applicationDidBecomeActive() async {
        guard session.isMember else { return }
        var keys: [String] = conversations.keys.filter { jobs.isLive(conversationID: $0) }
        if let selected = router.selectedConversationID {
            let key = resolve(selected)
            if !keys.contains(key), jobs.isLive(conversationID: key) { keys.append(key) }
        }
        for key in keys {
            await refreshFromServer(key)
        }
    }

    // MARK: - Search and filtering

    func search(_ query: String) -> [ChatSummary] {
        let needle = ArabicText.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        guard !needle.isEmpty else { return summaries }
        var out = summaries.filter { ArabicText.normalize($0.title).lowercased().contains(needle) }
        guard needle.count >= 3 else { return out }
        let known = Set(out.map { $0.id })
        for row in summaries where !known.contains(row.id) {
            guard let conversation = conversations[row.id] else { continue }
            let hit = conversation.messages.contains { message in
                ArabicText.normalize(message.content).lowercased().contains(needle)
            }
            if hit { out.append(row) }
        }
        return out
    }

    func summaries(for product: ProductKind) -> [ChatSummary] {
        let target: ProductKind = (product == .studio) ? .ai : product
        return summaries.filter { $0.product == target }
    }

    // MARK: - JobObserver

    func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot) {
        pipeline.progress(pointer: pointer, snapshot: snapshot)
    }

    func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool {
        await pipeline.land(pointer: pointer, terminal: terminal)
    }

    // MARK: - Internals used by SendPipeline

    func resolve(_ id: String) -> String {
        if conversations[id] != nil { return id }
        if let key = localKey(forServer: id) { return key }
        return id
    }

    func conversation(_ id: String) -> ChatConversation? {
        conversations[resolve(id)]
    }

    func mutate(_ id: String, _ body: (inout ChatConversation) -> Void) {
        let key = resolve(id)
        guard var conversation = conversations[key] else { return }
        body(&conversation)
        setConversation(conversation, forKey: key)
    }

    func buffer(for id: String) -> StreamBuffer {
        let key = resolve(id)
        if let existing = buffers[key] { return existing }
        let created = StreamBuffer(state: state(for: key))
        buffers[key] = created
        return created
    }

    /// Marks a conversation as just-changed and re-sorts the sidebar.
    func touch(_ id: String) {
        let key = resolve(id)
        guard var conversation = conversations[key] else { return }
        conversation.updatedAt = Self.timestamp()
        setConversation(conversation, forKey: key)
        rebuildSummaries()
    }

    /// One Pro-tier title call after the first answer, never for a chat the user renamed
    /// (`web-chat-ux.md §11.1`).
    func autoTitleIfNeeded(_ id: String) async {
        let key = resolve(id)
        guard let conversation = conversations[key], conversation.product == .ai else { return }
        // A temporary chat has no row for a title to land in, so this would spend a model call —
        // and one more request carrying the user's question — on a string nothing will render.
        guard !conversation.ephemeral else { return }
        guard !titled.contains(key), !renamed.contains(key) else { return }
        let answers = conversation.messages.filter { $0.role == .assistant && !$0.content.isEmpty }
        guard answers.count == 1, let first = conversation.messages.first(where: { $0.role == .user }) else { return }
        titled.insert(key)
        guard let title = await AutoTitle.generate(
            api: api,
            firstUser: first.content,
            firstAnswer: answers[0].content,
            lang: lang
        ) else { return }
        guard !renamed.contains(key), var current = conversations[key] else { return }
        current.title = title
        setConversation(current, forKey: key)
        rebuildSummaries()
        if session.isMember, let serverID = current.serverID {
            try? await api.updateChat(id: serverID, UpdateChatRequest(title: title))
        } else {
            await persistLocalOnly(key)
        }
    }

    /// Turns an `ErrorAction` into what the user sees, and answers with the sentence (already
    /// localized) so the caller can also pin it above the composer.
    @discardableResult
    func applyErrorAction(_ action: ErrorAction, in id: String?, silently: Bool = false) -> String? {
        _ = id
        switch action {
        case .toast(let text):
            let sentence = text(lang)
            if !silently { toasts.show(sentence, isError: true) }
            return sentence
        case .toastText(let sentence):
            if !silently { toasts.show(sentence, isError: true) }
            return sentence
        case .signUpPrompt(let feature):
            router.showSignUp(feature: feature)
            return nil
        case .sessionExpired:
            return Strings.Errors.sessionExpired(lang)
        case .blockedAgent:
            let sentence = Strings.Errors.agentBusy(lang)
            if !silently { toasts.show(sentence, isError: true) }
            return sentence
        case .creditsBlocked:
            let sentence = Strings.Errors.agentCreditsSpent(lang)
            if !silently { toasts.show(sentence, isError: true) }
            return sentence
        case .hideFeature:
            return Strings.Errors.featureUnavailable(lang)
        case .silent:
            return nil
        }
    }

    // MARK: - Private

    /// Re-derives the plan cycle only for a conversation that has no cycle of its own.
    ///
    /// `phase == .none` is not by itself proof of that: a cycle whose opening reply has not landed
    /// yet sits at `.none` while still holding `originID`, and re-deriving from the stored messages
    /// would throw that id away — which is what makes an approved plan execute against the approval
    /// sentence instead of the request. `isArmed` is exactly that distinction.
    func ensureState(for key: String, conversation: ChatConversation) {
        let state = state(for: key)
        if case .none = state.plan.phase, !state.plan.isArmed {
            state.plan = PlanCycle.derive(from: conversation.messages, snapshot: conversation.planSnapshotMode)
        }
    }

    func undoDelete(_ key: String) {
        deleteTasks[key]?.cancel()
        deleteTasks[key] = nil
        guard let restored = pendingDeletes.removeValue(forKey: key) else { return }
        setConversation(restored, forKey: key)
        if let serverID = restored.serverID, !serverRows.contains(where: { $0.id == serverID }) {
            serverRows.append(restored.summary)
        }
        rebuildSummaries()
    }

    func commitDelete(_ key: String) async {
        guard let conversation = pendingDeletes.removeValue(forKey: key) else { return }
        deleteTasks[key] = nil
        if session.isMember, let serverID = conversation.serverID {
            try? await api.deleteChat(id: serverID)
        } else if let owner = session.identityID {
            await guestChats.delete(conversation.id, owner: owner)
        }
    }

    func localKey(forServer id: String) -> String? {
        for (key, conversation) in conversations where conversation.serverID == id {
            return key
        }
        return nil
    }

    /// The sidebar's rows: the server's list, rekeyed onto local ids, plus every local
    /// conversation that has something in it.
    func rebuildSummaries() {
        var byKey: [String: ChatSummary] = [:]
        for row in serverRows {
            let key = localKey(forServer: row.id) ?? row.id
            byKey[key] = ChatSummary(
                id: key,
                title: row.title,
                updatedAt: row.updatedAt,
                createdAt: row.createdAt,
                pinned: row.pinned,
                agent: row.agent,
                codeProj: row.codeProj,
                brainNb: row.brainNb,
                messageCount: conversations[key]?.messages.count
            )
        }
        // Temporary conversations are excluded here, in the one function the whole sidebar, the
        // search and every "all chats" surface are built from — six surfaces, one answer.
        for (key, conversation) in conversations where !conversation.messages.isEmpty && !conversation.ephemeral {
            let existing = byKey[key]
            let title = conversation.title.isEmpty ? (existing?.title ?? "") : conversation.title
            let updated = Swift.max(conversation.updatedAt ?? "", existing?.updatedAt ?? "")
            byKey[key] = ChatSummary(
                id: key,
                title: title,
                updatedAt: updated,
                createdAt: conversation.createdAt ?? existing?.createdAt,
                pinned: conversation.pinned || (existing?.pinned ?? false),
                agent: conversation.agent,
                codeProj: conversation.codeProj,
                brainNb: conversation.brainNb,
                messageCount: conversation.messages.count
            )
        }
        let ordered = byKey.values.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        replaceSummaries(ordered)
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// `^[A-Za-z0-9_-]{8,120}$` — the pattern that makes `POST /api/chats` idempotent.
    static func clientID(for conversationID: String) -> String? {
        let filtered = conversationID.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        var value = String(filtered.prefix(120))
        guard !value.isEmpty else { return nil }
        while value.count < 8 { value += "0" }
        return value
    }
}
