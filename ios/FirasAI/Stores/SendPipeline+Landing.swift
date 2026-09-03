import Foundation

// MARK: - Landing an answer into the transcript
//
// Split out of `SendPipeline.swift` only for file size; this is the same object.

extension SendPipeline {

    // MARK: - Landing an answer

    func complete(
        key: String,
        assistantID: String,
        cid: String,
        text: String,
        reasoning: String,
        context: ChatTurnContext?
    ) async {
        guard let store else { return }
        let state = store.state(for: key)
        let lang = store.lang
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // §1.8: the engine's own "busy, try again" sentences arrive as a normal completed answer.
        // They are never stored, and they earn exactly one silent retry.
        if trimmed.isEmpty || EngineFailureDetector.isFailure(trimmed) {
            if let context, state.autoRetryUsedForMessageID != context.userMessageID {
                state.autoRetryUsedForMessageID = context.userMessageID
                var retry = context
                retry.turnCID = IDs.cid()
                retry.isAutoRetry = true
                store.buffer(for: key).reset()
                await startTurn(retry)
                return
            }
            await failTurn(
                key: key,
                assistantID: assistantID,
                action: .toast(Strings.Errors.serverBusy),
                context: context
            )
            return
        }

        state.phase = .completing
        let tier = context?.tier ?? prefs.tier
        upsertAssistant(key: key, assistantID: assistantID, cid: cid, tier: tier, lang: lang) { row in
            if var alts = row.alts, !alts.isEmpty {
                alts.append(AnswerVersion(content: text, reasoning: reasoning.isEmpty ? nil : reasoning, tier: tier.rawValue, lang: lang.rawValue))
                if alts.count > 5 { alts.removeFirst(alts.count - 5) }
                row.alts = alts
                row.altAt = alts.count - 1
            }
            row.content = text
            row.reasoning = reasoning.isEmpty ? nil : reasoning
            row.status = .delivered
        }

        var finished: ChatMessage?
        if let conversation = store.conversation(key) {
            finished = conversation.messages.first { $0.id == assistantID }
        }
        if let finished {
            state.plan.assistantFinished(finished, ask: AskSpec.parse(finished.content))
        }
        state.settle()
        store.buffer(for: key).reset()
        store.touch(key)

        // The worker already upserted this turn by cid for a member. Re-reading first means the
        // PUT (when it is still needed) carries the server's own copy rather than replacing it.
        var serverHasTurn = false
        if session.isMember, store.conversation(key)?.serverID != nil {
            await store.refreshFromServer(key)
            let rows = store.conversation(key)?.messages ?? []
            serverHasTurn = rows.contains(where: { $0.role == .assistant && $0.cid == cid && !$0.content.isEmpty })
        }
        if !serverHasTurn {
            await store.persist(key)
        } else {
            await store.persistLocalOnly(key)
        }

        // The question that earned this answer, handed to whoever owns long-term memory. Members
        // only: the server refuses `/api/memory/learn` for guests (`server-misc.md §404`).
        if let context, session.isMember, let landed = onAnswerLanded {
            let question = store.conversation(key)?
                .messages
                .first { $0.id == context.userMessageID }?
                .content ?? ""
            if !question.isEmpty { landed(question, context.product) }
        }

        contexts[key] = nil
        await store.autoTitleIfNeeded(key)
    }

    func failTurn(
        key: String,
        assistantID: String,
        action: ErrorAction,
        context: ChatTurnContext?
    ) async {
        guard let store else { return }
        let state = store.state(for: key)
        let lang = store.lang
        /* SILENTLY, because this failure is about to be PINNED. `state.fail` below writes the same
           sentence into the conversation's error strip, which sits above the transcript with a
           Retry beside it — so raising a toast as well printed one sentence twice on one screen,
           once floating over the composer and once anchored at the top. The owner saw exactly that
           and called it what it is: "كاتب فوك و جوة و مخرب الشكل". A toast is for something that
           has no home on the screen; this one has one. */
        let message = store.applyErrorAction(action, in: key, silently: true)

        store.mutate(key) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else { return }
            var row = conversation.messages[index]
            if row.content.isEmpty && (row.alts?.isEmpty ?? true) {
                // An empty placeholder is not history: drop it so the transcript ends on the
                // question, with the failure shown as a strip the user can retry from.
                conversation.messages.remove(at: index)
            } else {
                row.status = .failed(message ?? Strings.Errors.generic(lang))
                conversation.messages[index] = row
            }
        }
        state.fail(message ?? Strings.Errors.generic(lang))
        store.buffer(for: key).reset()
        contexts[key] = nil
        await store.persistLocalOnly(key)
    }

    func settleStopped(
        key: String,
        text: String = "",
        reasoning: String = "",
        assistantID: String? = nil,
        cid: String? = nil
    ) async {
        guard let store else { return }
        let state = store.state(for: key)
        let lang = store.lang
        let identifier = assistantID ?? state.streamingMessageID
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let identifier {
            if trimmed.isEmpty {
                store.mutate(key) { conversation in
                    conversation.messages.removeAll { $0.id == identifier && $0.content.isEmpty }
                }
            } else {
                upsertAssistant(
                    key: key,
                    assistantID: identifier,
                    cid: cid ?? state.activeCID ?? "",
                    tier: contexts[key]?.tier ?? prefs.tier,
                    lang: lang
                ) { row in
                    row.content = text
                    row.reasoning = reasoning.isEmpty ? nil : reasoning
                    row.status = .stopped
                }
            }
        }
        state.settle()
        store.buffer(for: key).reset()
        contexts[key] = nil
        await store.persist(key)
    }

    // MARK: - Rows

    /// Puts the streaming row in place: a fresh placeholder, or the row a regenerate replaces.
    func placeAssistantRow(context: ChatTurnContext, tier: ModelTier, lang: AppLanguage) -> String {
        guard let store else { return "" }
        let planning = Self.isPlanning(context.planTurn)
        if let targetID = context.regenerateTargetID {
            store.mutate(context.conversationID) { conversation in
                guard let index = conversation.messages.firstIndex(where: { $0.id == targetID }) else { return }
                var row = conversation.messages[index]
                var alts = row.alts ?? []
                if alts.isEmpty, !row.content.isEmpty {
                    alts.append(
                        AnswerVersion(
                            content: row.content,
                            reasoning: row.reasoning,
                            tier: row.tier,
                            lang: row.lang
                        )
                    )
                }
                row.alts = alts.isEmpty ? nil : alts
                row.content = ""
                row.reasoning = nil
                row.cid = context.turnCID
                row.tier = tier.rawValue
                row.retryOf = context.retryOf
                row.status = .streaming
                conversation.messages[index] = row
            }
            return targetID
        }
        if context.isAutoRetry, let existing = existingAssistantID(context: context) {
            store.mutate(context.conversationID) { conversation in
                guard let index = conversation.messages.firstIndex(where: { $0.id == existing }) else { return }
                conversation.messages[index].cid = context.turnCID
                conversation.messages[index].content = ""
                conversation.messages[index].status = .streaming
            }
            return existing
        }
        var assistant = ChatMessage.assistant(
            cid: context.turnCID,
            tier: tier,
            lang: lang,
            mode: planning ? .plan : .auto
        )
        assistant.retryOf = context.retryOf
        assistant.mergedFrom = context.mergedFrom
        store.mutate(context.conversationID) { conversation in
            conversation.messages.append(assistant)
        }
        return assistant.id
    }

    func existingAssistantID(context: ChatTurnContext) -> String? {
        guard let store, let conversation = store.conversation(context.conversationID) else { return nil }
        guard let userIndex = conversation.messages.firstIndex(where: { $0.id == context.userMessageID }) else { return nil }
        let after = conversation.messages[conversation.messages.index(after: userIndex)...]
        return after.first { $0.role == .assistant }?.id
    }

    /// Updates the assistant row in place, or appends it when the placeholder is gone (a job that
    /// finished after a relaunch has no row to update).
    func upsertAssistant(
        key: String,
        assistantID: String,
        cid: String,
        tier: ModelTier,
        lang: AppLanguage,
        _ body: (inout ChatMessage) -> Void
    ) {
        guard let store else { return }
        store.mutate(key) { conversation in
            if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
                var row = conversation.messages[index]
                row.cid = cid.isEmpty ? row.cid : cid
                row.tier = row.tier ?? tier.rawValue
                row.lang = row.lang ?? lang.rawValue
                body(&row)
                conversation.messages[index] = row
                return
            }
            if let index = conversation.messages.firstIndex(where: { $0.role == .assistant && $0.cid == cid && !cid.isEmpty }) {
                var row = conversation.messages[index]
                body(&row)
                conversation.messages[index] = row
                return
            }
            var row = ChatMessage.assistant(cid: cid, tier: tier, lang: lang, mode: .auto)
            body(&row)
            conversation.messages.append(row)
        }
    }

    // MARK: - Shaping the request

    static func jobRequest(
        output: PromptOutput,
        context: ChatTurnContext,
        kind: RequestKind,
        jobKind: JobKind,
        chatID: String,
        title: String,
        task: String,
        lang: AppLanguage
    ) -> ChatJobRequest {
        var sections: Int?
        var format: String?
        var pages: Int?
        switch kind {
        case .longdoc(let count):
            sections = min(120, max(3, count))
        case .longfile(let requested, let count):
            format = requested
            pages = min(10_000, max(1, count))
        default:
            break
        }
        return ChatJobRequest(
            messages: output.messages,
            tier: output.tier.rawValue,
            think: output.think,
            cid: context.turnCID,
            chatId: chatID,
            product: context.product.wireValue,
            kind: jobKind.rawValue,
            lang: lang.rawValue,
            title: String(title.prefix(160)),
            task: String(task.prefix(8_000)),
            sections: sections,
            format: format,
            pages: pages,
            targetPages: pages,
            prompt: pages == nil ? nil : String(task.prefix(8_000)),
            nokb: nil,
            agent: context.product == .agent ? true : nil
        )
    }

    static func jobKind(for kind: RequestKind) -> JobKind {
        switch kind {
        case .longdoc: return .longdoc
        case .longfile: return .longfile
        default: return .chat
        }
    }

    static func isPlanning(_ turn: PlanTurnKind) -> Bool {
        switch turn {
        case .clarifyOrPlan, .forcedPlan, .revision, .execute: return true
        case .auto: return false
        }
    }

    static func mediaKind(for kind: RequestKind) -> MediaKind? {
        switch kind {
        case .image, .imageEdit: return .image
        case .video: return .video
        case .music: return .music
        default: return nil
        }
    }

    static func intent(for kind: RequestKind) -> String {
        switch kind {
        case .chat: return "chat"
        case .code: return "code"
        case .file: return "file"
        case .image: return "image"
        case .imageEdit: return "edit-image"
        case .video: return "video"
        case .music: return "song"
        case .longdoc: return "longdoc"
        case .longfile: return "longfile"
        case .irab: return "irab"
        }
    }

    /// The web silently re-attaches the previous photos when a follow-up is about them
    /// (`audit-ios-chat.md §Major M17`). They are held in memory only.
    static func reattachment(for text: String, state: ConversationState, hasOwnImages: Bool) -> [String] {
        guard !hasOwnImages, !state.lastTurnImages.isEmpty else { return [] }
        guard RequestClassifier.refersToPreviousImage(text) else { return [] }
        return Array(state.lastTurnImages.prefix(10))
    }

    static func fold(_ attachments: [PreparedAttachment]) -> FoldedAttachments {
        var folded = FoldedAttachments()
        var texts: [String] = []
        for attachment in attachments {
            if let base64 = attachment.imageBase64, !base64.isEmpty {
                if folded.images.count < 10 { folded.images.append(base64) }
                if let thumb = attachment.thumbnailDataURL, folded.thumbs.count < 6 {
                    folded.thumbs.append(thumb)
                }
            } else if let text = attachment.text, !text.isEmpty {
                texts.append("[" + attachment.name + "]\n" + text)
            }
            if folded.chips.count < 12 {
                folded.chips.append(FileChip(name: attachment.name, kind: attachment.kind))
            }
        }
        folded.fileText = texts.joined(separator: "\n\n")
        return folded
    }
}
