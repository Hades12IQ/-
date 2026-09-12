import Foundation

extension SendPipeline {
    func omnixIdentityDidChange(to owner: String?) {
        for task in omnixWatchers.values { task.cancel() }
        for task in omnixAdmissions.values { task.cancel() }
        for task in omnixWrites.values { task.cancel() }
        omnixWatchers = [:]; omnixAdmissions = [:]; omnixWrites = [:]; omnixCancelled = []
        omnixState.reset(owner: owner)
    }

    func refreshOmnixAccess() async throws {
        guard session.isMember, let owner = session.identityID else { throw APIError.cancelled }
        if omnixState.owner != owner { omnixIdentityDidChange(to: owner) }
        let generation = omnixState.generation
        let access = try await OmnixService.access(api: api)
        guard omnixCurrent(owner, generation) else { throw APIError.cancelled }
        omnixState.access = access; omnixState.ready = false
        guard access.status == "approved" else { return }
        let cloud = try await OmnixService.cloud(api: api)
        guard omnixCurrent(owner, generation) else { throw APIError.cancelled }
        omnixState.ready = cloud.ready && cloud.state == "ready"
    }

    func deliverOmnix(text: String, attachments: [PreparedAttachment], in key: String, product: ProductKind) {
        guard let store, let conversation = store.conversation(key), !store.state(for: key).isBusy else { return }
        guard session.isMember, let owner = session.identityID else {
            router.showSignUp(feature: "omnix"); return
        }
        guard !conversation.ephemeral else { toasts.show(OmnixCopy.temporary(store.lang), isError: true); return }
        guard product == .ai else {
            toasts.show(OmnixCopy.unavailable(store.lang), isError: true); return
        }
        if omnixState.owner != owner { omnixIdentityDidChange(to: owner) }
        let state = store.state(for: key)
        if conversation.messages.contains(where: { row in
            guard let ref = row.omnix, ref.owner == owner, ref.isValid, ref.submission != "not_admitted" else { return false }
            if ref.jobId.isEmpty { return true }
            if let job = omnixState.jobs[ref.requestKey] { return !job.isTerminal }
            return row.content.isEmpty
        }) {
            restoreOmnix(in: key)
            toasts.show(Strings.Chat.busyWait(store.lang)); return
        }
        let quote = state.pendingQuote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let full = (quote.isEmpty ? "" : PromptCatalog.quotePrefix(passages: [(text: quote, lang: store.lang.rawValue)])) + text
        let inputs: [OmnixService.Input]
        do {
            guard full.utf16.count <= 60_000 else { throw APIError.decoding("omnix_request_limit") }
            inputs = try OmnixService.inputs(attachments)
        } catch { toasts.show(OmnixCopy.tooLarge(store.lang), isError: true); return }
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !inputs.isEmpty else { return }
        let previous = conversation.messages.reversed().compactMap(\.omnix).first {
            $0.isValid && $0.owner == owner && $0.conversationId == conversation.serverID && !$0.sessionId.isEmpty
        }
        let requestKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cid = IDs.cid()
        var user = ChatMessage.user(full.isEmpty ? inputs.map(\.name).joined(separator: ", ") : full, cid: cid, lang: store.lang)
        user.tier = ModelTier.omnix.rawValue; user.status = .delivered
        user.files = attachments.isEmpty ? nil : attachments.map { FileChip(name: $0.name, kind: $0.kind) }
        var assistant = ChatMessage.assistant(cid: cid, tier: .omnix, lang: store.lang, mode: .auto)
        assistant.omnix = OmnixReceipt(owner: owner, conversationId: conversation.serverID ?? "", requestKey: requestKey,
            sessionId: previous?.sessionId ?? "")
        store.mutate(key) { chat in
            chat.messages.append(user); chat.messages.append(assistant)
            if chat.title.isEmpty { chat.title = AutoTitle.provisional(from: user.content) }
        }
        state.errorStrip = nil; state.pendingQuote = nil; state.activeCID = cid
        state.streamingMessageID = assistant.id; state.phase = .thinking
        drafts.clear(DraftStore.key(conversationID: key)); drafts.clear(DraftStore.key(newIn: product))
        let generation = omnixState.generation
        omnixAdmissions[key] = Task { [weak self] in
            await self?.admitOmnix(key: key, assistantID: assistant.id, userID: user.id,
                text: full, inputs: inputs, owner: owner, generation: generation)
        }
    }

    private func admitOmnix(key: String, assistantID: String, userID: String, text: String,
                            inputs: [OmnixService.Input], owner: String, generation: Int) async {
        defer { if omnixCurrent(owner, generation) { omnixAdmissions[key] = nil } }
        let hold = BackgroundExecutor.hold(name: "firas.omnix.admit")
        defer { hold.end() }
        guard let store else { return }
        var dispatched = false
        var receipt = store.conversation(key)?.messages.first(where: { $0.id == assistantID })?.omnix
        do {
            await JobClock.rest(Self.paintGrace)
            guard omnixCurrent(owner, generation), let initial = receipt, !omnixCancelled.contains(initial.requestKey) else { return }
            if !omnixState.ready { try await refreshOmnixAccess() }
            guard omnixCurrent(owner, generation), omnixState.access?.status == "approved", omnixState.ready else {
                throw APIError.decoding("omnix_access_unavailable")
            }
            guard let serverID = await store.ensureServerChat(key), omnixCurrent(owner, generation) else { throw APIError.cancelled }
            receipt?.conversationId = serverID
            guard let bound = receipt, bound.isValid else { throw APIError.decoding("omnix_receipt") }
            setOmnixReceipt(bound, key: key, assistantID: assistantID)
            guard !omnixCancelled.contains(bound.requestKey) else {
                await rejectOmnix(bound, key: key, stopped: true); return
            }
            // Admission requires both a successful serialized write and a receipt read-back.
            try await persistOmnix(key)
            guard omnixCurrent(owner, generation), !omnixCancelled.contains(bound.requestKey) else { return }
            let saved = try await api.getChat(id: serverID)
            guard omnixCurrent(owner, generation), !omnixCancelled.contains(bound.requestKey) else { return }
            let userContent = store.conversation(key)?.messages.first(where: { $0.id == userID })?.content
            guard let index = saved.messages.firstIndex(where: { $0.role == .assistant && $0.omnix == bound }),
                  index > 0, saved.messages[index - 1].role == .user, saved.messages[index - 1].content == userContent else {
                throw APIError.decoding("omnix_save_unconfirmed")
            }
            var uploads: [String] = []
            for input in inputs {
                let uploaded = try await OmnixService.upload(input, receipt: bound, api: api)
                guard omnixCurrent(owner, generation), !omnixCancelled.contains(bound.requestKey) else { return }
                uploads.append(uploaded.id)
            }
            dispatched = true
            let job = try await OmnixService.submit(OmnixSubmission(requestKey: bound.requestKey, text: text, product: "ai",
                conversationId: serverID, sessionId: bound.sessionId.isEmpty ? nil : bound.sessionId,
                attachments: uploads.isEmpty ? nil : uploads), api: api)
            guard omnixCurrent(owner, generation) else { return }
            try await acceptOmnix(job, receipt: bound, key: key, assistantID: assistantID)
            if omnixCancelled.contains(bound.requestKey) { _ = await stopOmnix(in: key) }
            restoreOmnix(in: key)
        } catch {
            guard omnixCurrent(owner, generation), let receipt else { return }
            if !dispatched || OmnixService.definitelyNotAdmitted(error) {
                await rejectOmnix(receipt, key: key, stopped: omnixCancelled.contains(receipt.requestKey))
            } else {
                // A lost 202 is not a failed task. Recover the saved requestKey; never POST it again.
                omnixState.notices[receipt.requestKey] = OmnixCopy.checking(store.lang)
                restoreOmnix(in: key)
            }
        }
    }

    func restoreOmnix(in id: String) {
        guard let store, session.isMember, let owner = session.identityID else { return }
        if omnixState.owner != owner { omnixIdentityDidChange(to: owner) }
        let key = store.resolve(id)
        guard omnixWatchers[key] == nil, let chat = store.conversation(key), !chat.ephemeral,
              chat.messages.contains(where: { $0.omnix?.owner == owner && $0.omnix?.isValid == true }) else { return }
        let generation = omnixState.generation
        omnixWatchers[key] = Task { [weak self] in
            await self?.watchOmnix(key: key, owner: owner, generation: generation)
        }
    }

    private func watchOmnix(key: String, owner: String, generation: Int) async {
        defer { if omnixCurrent(owner, generation) { omnixWatchers[key] = nil } }
        guard let store else { return }
        var iteration = 0
        while omnixCurrent(owner, generation) && !Task.isCancelled {
            guard let chat = store.conversation(key), let serverID = chat.serverID else { return }
            if !readerIsPresent { await JobClock.rest(5); continue }
            let rows = chat.messages.filter { $0.role == .assistant && $0.omnix?.owner == owner && $0.omnix?.isValid == true }
            guard !rows.isEmpty else { return }
            do {
                if iteration % 8 == 0 || rows.contains(where: { $0.omnix?.jobId.isEmpty == true && $0.omnix?.submission != "not_admitted" }) {
                    let discovery = try await OmnixService.conversation(serverID, api: api)
                    guard omnixCurrent(owner, generation) else { return }
                    for row in rows {
                        guard let receipt = row.omnix else { continue }
                        if receipt.jobId.isEmpty, discovery.cancelledRequests?.contains(receipt.requestKey) == true {
                            await rejectOmnix(receipt, key: key, stopped: true)
                        } else if receipt.jobId.isEmpty, let job = discovery.jobs.first(where: receipt.accepts) {
                            // Discovery contains IDs only, even for a completed run. Bind the
                            // receipt, then fetch the full run before settling or skipping it.
                            var bound = receipt; bound.jobId = job.jobId; bound.sessionId = job.sessionId
                            setOmnixReceipt(bound, key: key, assistantID: row.id)
                            try await persistOmnix(key)
                        }
                    }
                }
                guard omnixCurrent(owner, generation) else { return }
                let current = store.conversation(key)?.messages.filter { $0.role == .assistant && $0.omnix?.owner == owner && $0.omnix?.isValid == true } ?? []
                var pending = false
                for row in current.suffix(4) {
                    guard let receipt = row.omnix, receipt.submission != "not_admitted" else { continue }
                    guard !receipt.jobId.isEmpty else {
                        pending = true
                        if store.state(for: key).activeCID == nil { activateOmnix(row, key: key) }
                        continue
                    }
                    let previous = omnixState.jobs[receipt.requestKey]
                    if previous?.needsFullRefresh == false { continue }
                    let job = try await OmnixService.job(receipt, api: api)
                    guard omnixCurrent(owner, generation) else { return }
                    try await acceptOmnix(job, receipt: receipt, key: key, assistantID: row.id)
                    if !job.isTerminal || job.result?.filesStatus == "unavailable" { pending = true }
                }
                if !pending { return }
                iteration += 1
                await JobClock.rest(2)
            } catch {
                guard omnixCurrent(owner, generation) else { return }
                if let status = (error as? APIError)?.status, status == 401 || status == 403 {
                    omnixState.jobs = [:]; omnixState.ready = false
                    store.state(for: key).fail(OmnixCopy.unavailable(store.lang)); return
                }
                for row in rows { if let receipt = row.omnix { omnixState.notices[receipt.requestKey] = OmnixCopy.reconnect(store.lang) } }
                await JobClock.rest(5)
            }
        }
    }

    func refreshOmnixReceipt(_ receipt: OmnixReceipt, in key: String) async {
        guard let owner = session.identityID, receipt.owner == owner, receipt.isValid, !receipt.jobId.isEmpty else { return }
        if omnixState.owner != owner { omnixIdentityDidChange(to: owner) }
        let generation = omnixState.generation
        do {
            let job = try await OmnixService.job(receipt, api: api)
            guard omnixCurrent(owner, generation), let row = store?.conversation(key)?.messages.first(where: { $0.omnix?.requestKey == receipt.requestKey }) else { return }
            try await acceptOmnix(job, receipt: receipt, key: key, assistantID: row.id)
            restoreOmnix(in: key)
        } catch { if omnixCurrent(owner, generation) { omnixState.notices[receipt.requestKey] = OmnixCopy.reconnect(prefs.lang) } }
    }

    private func acceptOmnix(_ job: OmnixJob, receipt: OmnixReceipt, key: String, assistantID: String) async throws {
        guard let store, session.identityID == receipt.owner, receipt.accepts(job),
              let row = store.conversation(key)?.messages.first(where: { $0.id == assistantID && $0.role == .assistant }),
              row.omnix?.requestKey == receipt.requestKey else { throw APIError.cancelled }
        var bound = receipt; bound.jobId = job.jobId; bound.sessionId = job.sessionId; bound.submission = nil
        let changed = row.omnix != bound
        if changed { setOmnixReceipt(bound, key: key, assistantID: assistantID) }
        omnixState.jobs[bound.requestKey] = job; omnixState.notices[bound.requestKey] = nil
        if job.isTerminal {
            let content = job.visibleText.isEmpty && ["cancelled", "canceled"].contains(job.state) ? OmnixCopy.stopped(store.lang) : job.visibleText
            let terminalStatus: DeliveryStatus = job.state == "completed" ? .delivered : .stopped
            let needsSave = changed || (!content.isEmpty && row.content != content) || row.status != terminalStatus
            store.mutate(key) { chat in
                guard let index = chat.messages.firstIndex(where: { $0.id == assistantID && $0.role == .assistant }) else { return }
                if !content.isEmpty { chat.messages[index].content = content }
                chat.messages[index].status = terminalStatus
            }
            if store.state(for: key).streamingMessageID == assistantID { store.state(for: key).settle() }
            if needsSave { try await persistOmnix(key) }
        } else {
            if store.state(for: key).activeCID == nil || store.state(for: key).streamingMessageID == assistantID { activateOmnix(row, key: key) }
            if changed { try await persistOmnix(key) }
        }
    }

    @discardableResult func stopOmnix(in key: String) async -> Bool {
        guard let store, let owner = session.identityID,
              store.state(for: key).isBusy,
              let row = store.conversation(key)?.messages.last(where: {
                  guard let ref = $0.omnix else { return false }
                  return $0.id == store.state(for: key).streamingMessageID && $0.role == .assistant && ref.owner == owner
                      && ref.submission != "not_admitted" && omnixState.jobs[ref.requestKey]?.isTerminal != true
              }), let receipt = row.omnix else { return false }
        omnixCancelled.insert(receipt.requestKey)
        store.state(for: key).isStopping = true
        let generation = omnixState.generation
        if receipt.conversationId.isEmpty {
            omnixAdmissions[key]?.cancel()
            await rejectOmnix(receipt, key: key, stopped: true); return true
        }
        do {
            let result = try await OmnixService.cancel(receipt, api: api)
            guard omnixCurrent(owner, generation) else { return true }
            if let job = result.job { try await acceptOmnix(job, receipt: receipt, key: key, assistantID: row.id) }
            else if result.cancelled == true { await rejectOmnix(receipt, key: key, stopped: true) }
            restoreOmnix(in: key)
        } catch {
            if omnixCurrent(owner, generation) {
                omnixState.notices[receipt.requestKey] = OmnixCopy.reconnect(store.lang)
                restoreOmnix(in: key)
            }
        }
        return true
    }

    func approveOmnix(_ receipt: OmnixReceipt, approval: OmnixApproval, choice: String, in key: String) async {
        guard session.identityID == receipt.owner, approval.choices.contains(choice),
              choice == "deny" || approval.commandComplete, !omnixState.approvalBusy.contains(receipt.requestKey),
              omnixState.jobs[receipt.requestKey]?.result?.approval?.requestId == approval.requestId else { return }
        omnixState.approvalBusy.insert(receipt.requestKey)
        defer { omnixState.approvalBusy.remove(receipt.requestKey) }
        do {
            try await OmnixService.approve(receipt, request: OmnixApprovalRequest(requestId: approval.requestId, choice: choice), api: api)
            await refreshOmnixReceipt(receipt, in: key)
        } catch {
            if session.identityID == receipt.owner { omnixState.notices[receipt.requestKey] = OmnixCopy.reconnect(prefs.lang) }
        }
    }

    private func rejectOmnix(_ receipt: OmnixReceipt, key: String, stopped: Bool) async {
        guard let store, session.identityID == receipt.owner else { return }
        store.mutate(key) { chat in
            guard let index = chat.messages.firstIndex(where: { $0.omnix?.requestKey == receipt.requestKey && $0.role == .assistant }),
                  chat.messages[index].omnix?.jobId.isEmpty == true else { return }
            chat.messages[index].omnix?.submission = "not_admitted"
            chat.messages[index].content = (stopped ? OmnixCopy.stopped : OmnixCopy.notStarted)(store.lang)
            chat.messages[index].status = .stopped
        }
        store.state(for: key).settle()
        do { try await persistOmnix(key) }
        catch { if session.identityID == receipt.owner { omnixState.notices[receipt.requestKey] = OmnixCopy.reconnect(store.lang) } }
    }

    /// Each write waits for this conversation's prior write, then takes a fresh snapshot.
    /// A slow terminal-file refresh can never overwrite the receipt of a newer send.
    private func persistOmnix(_ key: String) async throws {
        guard let owner = session.identityID else { throw APIError.cancelled }
        let generation = omnixState.generation
        let previous = omnixWrites[key]
        let write = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self, !Task.isCancelled, self.omnixCurrent(owner, generation), let store = self.store else { throw APIError.cancelled }
            await store.persistLocalOnly(key)
            guard !Task.isCancelled, self.omnixCurrent(owner, generation), let latest = store.conversation(key),
                  !latest.ephemeral, let serverID = latest.serverID else { throw APIError.cancelled }
            try await self.api.updateChat(id: serverID, UpdateChatRequest(messages: MessageSerializer.persisted(latest)))
            guard self.omnixCurrent(owner, generation) else { throw APIError.cancelled }
        }
        omnixWrites[key] = write
        try await write.value
    }
    private func setOmnixReceipt(_ receipt: OmnixReceipt, key: String, assistantID: String) {
        store?.mutate(key) { chat in
            guard let index = chat.messages.firstIndex(where: { $0.id == assistantID && $0.role == .assistant }) else { return }
            chat.messages[index].omnix = receipt
        }
    }
    private func activateOmnix(_ row: ChatMessage, key: String) {
        guard let store else { return }
        let state = store.state(for: key)
        state.activeCID = row.cid; state.streamingMessageID = row.id; state.phase = .thinking
    }
    private func omnixCurrent(_ owner: String, _ generation: Int) -> Bool {
        session.isMember && session.identityID == owner && omnixState.owner == owner && omnixState.generation == generation
    }
}
