import Foundation

// MARK: - Turn delivery and the request itself
//
// Split out of `SendPipeline.swift` only for file size; this is the same object.

extension SendPipeline {


    // MARK: - Job delivery

    func progress(pointer: JobPointer, snapshot: JobSnapshot) {
        guard let store else { return }
        let key = store.resolve(pointer.conversationID)
        let state = store.state(for: key)
        state.jobPointerID = pointer.id
        if state.streamingMessageID == nil {
            state.streamingMessageID = pointer.assistantMessageID
                ?? ChatMessage.identity(role: .assistant, cid: pointer.cid)
            state.activeCID = pointer.cid
        }
        let buffer = store.buffer(for: key)
        buffer.adopt(text: snapshot.text, reasoning: snapshot.reasoning)
        if snapshot.phase == .queued && buffer.isEmpty {
            state.phase = .thinking
        } else {
            state.phase = buffer.text.isEmpty ? .thinking : .streaming
        }
    }

    /// Returns true only once the result is in the store's model and persisted — the manager drops
    /// the pointer on that answer, and a dropped pointer is unrecoverable.
    func land(pointer: JobPointer, terminal: JobTerminal) async -> Bool {
        guard let store else { return false }
        var key = store.resolve(pointer.conversationID)
        if store.conversation(key) == nil {
            // After a relaunch the transcript is not in memory. A member's copy is fetched under
            // the SERVER id (the local key means nothing to `/api/chats/:id`); a guest's comes
            // back off disk under the local one.
            let serverID = pointer.serverChatID ?? ""
            if !serverID.isEmpty {
                await store.open(serverID)
                if store.conversation(serverID) != nil { key = store.resolve(serverID) }
            } else if !session.isMember {
                await store.open(key)
            }
        }
        guard store.conversation(key) != nil else {
            // Nothing on this device to land into. For a member the worker already filed the turn
            // in the chat, so the answer is not lost and the pointer may go.
            return session.isMember
        }
        let state = store.state(for: key)
        let buffer = store.buffer(for: key)
        let assistantID = pointer.assistantMessageID
            ?? ChatMessage.identity(role: .assistant, cid: pointer.cid)
        let context = contexts[key]
        let lang = store.lang

        switch terminal {
        case .completed(let snapshot):
            buffer.adopt(text: snapshot.text, reasoning: snapshot.reasoning)
            let final = buffer.finish()
            if state.isStopping {
                await settleStopped(key: key, text: final.text, reasoning: final.reasoning, assistantID: assistantID, cid: pointer.cid)
                return true
            }
            await complete(
                key: key,
                assistantID: assistantID,
                cid: pointer.cid,
                text: final.text,
                reasoning: final.reasoning,
                context: context
            )
            return true

        case .cancelled:
            let final = buffer.finish()
            await settleStopped(key: key, text: final.text, reasoning: final.reasoning, assistantID: assistantID, cid: pointer.cid)
            return true

        case .refused, .failed, .expired:
            if case .expired = terminal, session.isMember {
                // The record may be gone while the answer is safely in the chat.
                await store.refreshFromServer(key)
                if let stored = store.conversation(key)?.messages.first(where: { $0.cid == pointer.cid && $0.role == .assistant }),
                   !stored.content.isEmpty {
                    buffer.reset()
                    state.settle()
                    return true
                }
            }
            let action = ErrorPresenter.presentJobTerminal(
                terminal,
                kind: pointer.kind,
                isGuest: session.isGuest,
                lang: lang
            )
            await failTurn(key: key, assistantID: assistantID, action: action, context: context)
            return true

        case .unauthorized, .forbidden:
            // The manager keeps (401) or forgets (403) the pointer itself; the conversation simply
            // stops waiting.
            state.settle()
            return true
        }
    }

    // MARK: - The one path

    func startTurn(_ context: ChatTurnContext) async {
        guard let store, let conversation = store.conversation(context.conversationID) else { return }
        guard let userIndex = conversation.messages.firstIndex(where: { $0.id == context.userMessageID }) else { return }
        let key = context.conversationID
        let user = conversation.messages[userIndex]
        let state = store.state(for: key)
        let lang = store.lang
        contexts[key] = context

        let history = Array(conversation.messages[..<userIndex])
        let ownImages = user.images ?? []
        let reattach = ownImages.isEmpty
            ? Self.reattachment(for: user.content, state: state, hasOwnImages: false)
            : []
        let hasImages = !ownImages.isEmpty || !reattach.isEmpty
        let kind = RequestClassifier.classify(user.content, hasImages: hasImages, lang: lang)

        var searchContext: String?
        var searchWasEmpty = false
        let trigger = SearchContext.trigger(
            for: user.content,
            toggleOn: prefs.webSearchEnabled,
            hasImages: hasImages
        )
        if trigger != .none {
            state.phase = .searching
            let result = await SearchContext.run(api: api, text: user.content, trigger: trigger, lang: lang)
            searchContext = result.context
            searchWasEmpty = result.wasEmpty
        }

        let input = PromptInput(
            tier: context.tier,
            product: context.product,
            mode: state.plan.snapshotMode == .plan ? .plan : prefs.responseMode,
            lang: lang,
            thinkToggle: prefs.thinkingEnabled,
            kind: kind,
            planTurn: context.planTurn,
            askRounds: state.plan.askRounds,
            searchContext: searchContext,
            searchWasEmpty: searchWasEmpty,
            history: history,
            lastUser: user,
            reattachImages: reattach.isEmpty ? nil : reattach,
            explicitSearch: trigger == .explicit
        )
        let output = PromptBuilder.build(input)

        let assistantID = placeAssistantRow(context: context, tier: output.tier, lang: lang)
        state.streamingMessageID = assistantID
        state.activeCID = context.turnCID
        state.phase = .thinking
        store.buffer(for: key).reset()
        store.mutate(key) { conversation in
            if let index = conversation.messages.firstIndex(where: { $0.id == context.userMessageID }) {
                conversation.messages[index].status = .delivered
            }
        }

        var serverChatID = store.conversation(key)?.serverID
        if !context.isAutoRetry {
            if session.isMember, serverChatID == nil {
                serverChatID = await store.ensureServerChat(key)
            }
            // Before the job, never after: the queue saves the assistant turn only.
            await store.persist(key)
        }

        let payload = output.messages.reduce(0) { $0 + $1.content.count }
            + ownImages.reduce(0) { $0 + $1.count }
            + reattach.reduce(0) { $0 + $1.count }
        let canQueue = !hasImages && payload <= Self.jobPayloadCeiling
            && (session.isGuest || serverChatID != nil)

        var useStream = !canQueue
        if canQueue {
            let jobKind = Self.jobKind(for: kind)
            let request = Self.jobRequest(
                output: output,
                context: context,
                kind: kind,
                jobKind: jobKind,
                chatID: serverChatID ?? "",
                title: store.conversation(key)?.title ?? "",
                task: user.content,
                lang: lang
            )
            let draft = JobPointer(
                id: context.turnCID,
                kind: jobKind,
                ownerID: session.identityID ?? "",
                cid: context.turnCID,
                conversationID: key,
                serverChatID: serverChatID,
                assistantMessageID: assistantID,
                title: store.conversation(key)?.title ?? "",
                lang: lang.rawValue,
                startedAt: Date(),
                deadline: Date().addingTimeInterval(JobKindSpecs.spec(jobKind).deadline)
            )
            do {
                let pointer = try await jobs.startChatQueueJob(request, pointer: draft)
                state.jobPointerID = pointer.id
                if state.phase == .thinking || state.phase == .searching {
                    state.phase = .thinking
                }
                return
            } catch {
                let status = (error as? APIError)?.status
                if status == 413 || status == 404 || status == 501 {
                    // This backend has no queue, or the body is too big for it: the live stream
                    // still answers, it just cannot be resumed.
                    useStream = true
                } else {
                    let action = ErrorPresenter.present(
                        error,
                        feature: .generic,
                        isGuest: session.isGuest,
                        lang: lang
                    )
                    await failTurn(key: key, assistantID: assistantID, action: action, context: context)
                    return
                }
            }
        }

        guard useStream else { return }
        let request = ChatStreamRequest(
            messages: output.messages,
            tier: output.tier.rawValue,
            think: output.think,
            cid: context.turnCID,
            chatId: serverChatID,
            product: context.product.wireValue,
            nomem: nil,
            nokb: nil,
            agent: context.product == .agent ? true : nil
        )
        let task = Task { [weak self] () -> Void in
            await self?.runStream(request, key: key, assistantID: assistantID, context: context)
        }
        streamTasks[key] = task
    }

    func runStream(
        _ request: ChatStreamRequest,
        key: String,
        assistantID: String,
        context: ChatTurnContext
    ) async {
        guard let store else { return }
        let state = store.state(for: key)
        let buffer = store.buffer(for: key)
        let lang = store.lang
        var failure: Error?
        let ceiling = Date().addingTimeInterval(Self.streamCeiling)

        do {
            let stream = await api.chatStream(request)
            for try await frame in stream {
                if Task.isCancelled { break }
                if Date() >= ceiling { break }
                if frame.isDone { break }
                guard let delta = StreamBuffer.delta(fromData: frame.data) else { continue }
                buffer.append(content: delta.content, reasoning: delta.reasoning)
                state.phase = buffer.text.isEmpty ? .thinking : .streaming
            }
        } catch is CancellationError {
            failure = nil
        } catch {
            failure = error
        }

        streamTasks[key] = nil
        let final = buffer.finish()

        if state.isStopping || Task.isCancelled {
            // Settling has to leave this task: Stop cancelled it, and a cancelled task cannot make
            // the request that saves the partial answer. A fresh top-level task does not inherit
            // that cancellation.
            let stoppedText = final.text
            let stoppedReasoning = final.reasoning
            let turnCID = context.turnCID
            Task { [weak self] in
                await self?.settleStopped(
                    key: key,
                    text: stoppedText,
                    reasoning: stoppedReasoning,
                    assistantID: assistantID,
                    cid: turnCID
                )
            }
            return
        }
        if let failure {
            let action = ErrorPresenter.present(failure, feature: .generic, isGuest: session.isGuest, lang: lang)
            await failTurn(key: key, assistantID: assistantID, action: action, context: context)
            return
        }
        await complete(
            key: key,
            assistantID: assistantID,
            cid: context.turnCID,
            text: final.text,
            reasoning: final.reasoning,
            context: context
        )
    }
}
