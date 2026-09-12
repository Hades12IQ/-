import Foundation

extension CodeStore {
    func confirmCodeReceiptDeletion(id: String, owner: String) async -> Bool {
        let generation = codeOmnix.generation
        guard codeOmnixCurrent(owner, generation) else { return false }
        let cached = await codeThread(id, owner: owner)
        let remoteThread: CodeChatThread
        do {
            let remote = try await api.getChat(id: id)
            guard codeOmnixCurrent(owner, generation), remote.id == id else { return false }
            remoteThread = Self.parse(remote)?.thread ?? CodeChatThread()
        } catch {
            guard codeOmnixCurrent(owner, generation), (error as? APIError)?.status == 404 else { return false }
            remoteThread = CodeChatThread()
        }
        let current = CodeChatThread(messages: (cached?.messages ?? []) + remoteThread.messages)
        let requests = CodeDeletionSafety.requests(thread: current, owner: owner, conversationID: id,
            completedOmnix: Set(codeOmnix.jobs.filter { $0.value.isTerminal }.map(\.key)))
        for receipt in requests.edits { codeOmnix.cancelled.insert(receipt.cid) }
        for receipt in requests.omnix { codeOmnix.cancelled.insert(receipt.requestKey) }
        return await CodeDeletionSafety.confirm(requests, isCurrent: { self.codeOmnixCurrent(owner, generation) },
            cancelEdit: { try await self.confirmEditStoppedForDeletion($0, generation: generation) },
            cancelOmnix: { try await self.confirmOmnixStoppedForDeletion($0, generation: generation) })
    }

    func confirmCodeBuildDeletion(_ pointer: JobPointer) async -> Bool {
        let generation = codeOmnix.generation
        guard pointer.kind == .codebuild, codeOmnixCurrent(pointer.ownerID, generation) else { return false }
        do {
            let initial = try await api.chatJobStatus(id: pointer.id)
            guard codeOmnixCurrent(pointer.ownerID, generation) else { return false }
            if Self.editIsTerminal(initial.phase) { return true }
            guard initial.phase != "unknown" else { return false }
            do { _ = try await api.cancelChatJob(id: pointer.id) }
            catch { if (error as? APIError)?.status != 409 { throw error } }
            for attempt in 0..<3 {
                guard codeOmnixCurrent(pointer.ownerID, generation) else { return false }
                let current = try await api.chatJobStatus(id: pointer.id)
                guard codeOmnixCurrent(pointer.ownerID, generation) else { return false }
                if Self.editIsTerminal(current.phase) { return true }
                if attempt < 2 { await JobClock.rest(2) }
            }
        } catch { return false }
        return false
    }

    private func confirmEditStoppedForDeletion(_ receipt: CodeEditReceipt, generation: Int) async throws -> Bool {
        guard let found = try await CodeEditService.recover(receipt: receipt, api: api), let jobID = found.jobId,
              codeOmnixCurrent(receipt.owner, generation) else { return false }
        var bound = receipt; bound.jobId = jobID
        let status = try await CodeEditService.status(receipt: bound, api: api)
        guard codeOmnixCurrent(receipt.owner, generation) else { return false }
        if Self.editIsTerminal(status.phase) { return true }
        guard status.phase != "unknown" else { return false }
        do { _ = try await api.cancelChatJob(id: jobID) }
        catch { if (error as? APIError)?.status != 409 { throw error } }
        for attempt in 0..<3 {
            guard codeOmnixCurrent(receipt.owner, generation) else { return false }
            let current = try await CodeEditService.status(receipt: bound, api: api)
            guard codeOmnixCurrent(receipt.owner, generation) else { return false }
            if Self.editIsTerminal(current.phase) { return true }
            if attempt < 2 { await JobClock.rest(2) }
        }
        return false
    }

    private func confirmOmnixStoppedForDeletion(_ receipt: OmnixReceipt, generation: Int) async throws -> Bool {
        var bound = receipt
        if !bound.jobId.isEmpty {
            let current = try await OmnixService.job(bound, api: api)
            guard codeOmnixCurrent(receipt.owner, generation) else { return false }
            if current.isTerminal { return true }
        }
        let result = try await OmnixService.cancel(bound, api: api)
        guard codeOmnixCurrent(receipt.owner, generation) else { return false }
        if let job = result.job {
            bound.jobId = job.jobId; bound.sessionId = job.sessionId
            if job.isTerminal { return true }
        } else if bound.jobId.isEmpty && result.cancelled == true { return true }
        guard !bound.jobId.isEmpty else { return false }
        for attempt in 0..<3 {
            guard codeOmnixCurrent(receipt.owner, generation) else { return false }
            let current = try await OmnixService.job(bound, api: api)
            guard codeOmnixCurrent(receipt.owner, generation) else { return false }
            if current.isTerminal { return true }
            if attempt < 2 { await JobClock.rest(2) }
        }
        return false
    }
}
