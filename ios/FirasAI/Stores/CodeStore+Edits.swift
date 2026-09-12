import Foundation
import UIKit

extension CodeStore {
    static func editIsTerminal(_ phase: String?) -> Bool {
        ["completed", "failed", "cancelled", "canceled", "expired", "refused"].contains(phase ?? "")
    }
    static func shouldWatchCodeEdit(phase: String?, savePending: Bool) -> Bool {
        savePending || !editIsTerminal(phase)
    }
    func restoreCodeJobs(in id: String) {
        if let last = thread.messages.last(where: { $0.role == "ai" }), last.edit != nil {
            restoreCodeEdit(in: id)
        } else { restoreCodeOmnix(in: id) }
    }
    func sendCodeEdit(instruction: String, attachmentText: String) async {
        guard let id = openProjectID, let source = project, let owner = session.identityID, session.isMember,
              !id.hasPrefix("ios_"), !isBuilding(projectID: id), !codeOmnix.active.contains(id) else {
            toasts.show(lang == .arabic ? "سجّل الدخول واحفظ المشروع قبل بدء الطلب، أو انتظر انتهاء المهمة الحالية." : "Sign in and save the project before starting, or wait for the current task.", isError: true); return
        }
        if codeOmnix.owner != owner { codeOmnix.reset(owner: owner) }
        if let last = thread.messages.last(where: { $0.edit != nil }), !Self.editIsTerminal(last.editPhase) {
            restoreCodeEdit(in: id); toasts.show(Strings.Chat.busyWait(lang)); return
        }
        let generation = codeOmnix.generation
        let selection = thread.selection
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = trimmed.isEmpty && !attachmentText.isEmpty ? Strings.Code.attachmentsOnly(lang) : trimmed
        guard selection.model != .omnix, !task.isEmpty, task.utf16.count <= 60_000, attachmentText.utf16.count <= 24_000 else {
            toasts.show(OmnixCopy.tooLarge(lang), isError: true); return
        }
        codeOmnix.active.insert(id)
        var receipt: CodeEditReceipt?
        var admission = CodeRequestAdmission.preparing
        defer { if codeOmnixCurrent(owner, generation) && codeOmnix.watchers[id] == nil { codeOmnix.active.remove(id) } }
        do {
            let repository = await repositoryContext(for: task)
            guard codeOmnixCurrent(owner, generation), openProjectID == id, project == source else { throw APIError.cancelled }
            let room = 24_000 - attachmentText.utf16.count
            let repositorySlice = String(decoding: repository.utf16.prefix(room), as: UTF16.self)
            let context = attachmentText + repositorySlice
            let ref = CodeEditReceipt(owner: owner, conversationId: id, cid: IDs.cid(), baseHash: try CodeEditService.sourceHash(source))
            receipt = ref
            var user = CodeChatMessage(role: "user", content: task, at: Date().timeIntervalSince1970 * 1000)
            user.model = selection.model.rawValue
            var answer = CodeChatMessage(role: "ai", content: "", at: Date().timeIntervalSince1970 * 1000)
            answer.model = selection.model.rawValue; answer.edit = ref; answer.editPhase = "queued"
            thread.messages.append(user); thread.messages.append(answer)
            codeOmnix.eligible.insert(ref.cid); jobs.prepareExternalCompletion(ownerID: owner)
            try await persistCodeOmnix(id: id, owner: owner, generation: generation)
            let saved = try await api.getChat(id: id)
            guard codeOmnixCurrent(owner, generation), openProjectID == id, project == source,
                  let parsed = Self.parse(saved), try CodeEditService.sourceHash(parsed.project) == ref.baseHash,
                  let index = parsed.thread.messages.firstIndex(where: { $0.edit == ref }), index > 0,
                  parsed.thread.messages[index - 1].role == "user", parsed.thread.messages[index - 1].content == task else {
                throw CodeEditService.Failure.sourceChanged
            }
            guard !codeOmnix.cancelled.contains(ref.cid) else { throw APIError.cancelled }
            admission = .submitting
            let response = try await CodeEditService.submit(receipt: ref, task: task, attach: context, selection: selection, lang: lang,
                api: api, isCurrent: { self.codeOmnixCurrent(owner, generation) })
            admission = .accepted
            guard codeOmnixCurrent(owner, generation), let jobID = response.jobId else { throw APIError.cancelled }
            var bound = ref; bound.jobId = jobID
            try await updateCodeEdit(bound, phase: "queued", content: nil, generation: generation)
            if codeOmnix.cancelled.contains(ref.cid) { await stopCodeEdit(bound) }
            restoreCodeEdit(in: id)
        } catch {
            guard codeOmnixCurrent(owner, generation) else { return }
            if let receipt {
                if !admission.requiresRecovery(after: error, explicitlyRejected: CodeEditService.explicitlyRejected) {
                    try? await updateCodeEdit(receipt, phase: codeOmnix.cancelled.contains(receipt.cid) ? "cancelled" : "failed",
                        content: OmnixCopy.notStarted(lang), generation: generation)
                } else {
                    codeOmnix.notices[receipt.cid] = OmnixCopy.checking(lang)
                    restoreCodeEdit(in: id)
                }
            } else { toasts.show(Strings.Code.askFailed(lang), isError: true) }
        }
    }

    func restoreCodeEdit(in id: String) {
        guard let owner = session.identityID, session.isMember, !id.hasPrefix("ios_"), codeOmnix.watchers[id] == nil else { return }
        let generation = codeOmnix.generation
        codeOmnix.watchers[id] = Task { [weak self] in await self?.watchCodeEdit(id: id, owner: owner, generation: generation) }
    }
    private func watchCodeEdit(id: String, owner: String, generation: Int) async {
        defer { if codeOmnixCurrent(owner, generation) { codeOmnix.watchers[id] = nil; codeOmnix.active.remove(id) } }
        while codeOmnixCurrent(owner, generation) && !Task.isCancelled {
            guard let current = await codeThread(id, owner: owner), codeOmnixCurrent(owner, generation),
                  let turn = current.messages.last(where: { $0.edit?.owner == owner && $0.edit?.conversationId == id }), var ref = turn.edit,
                  ref.isValid, Self.shouldWatchCodeEdit(phase: turn.editPhase, savePending: codeOmnix.pendingSaves.contains(ref.cid)) else { return }
            codeOmnix.active.insert(id)
            do {
                if ref.jobId.isEmpty {
                    if let found = try await CodeEditService.recover(receipt: ref, api: api), let jobID = found.jobId {
                        ref.jobId = jobID
                        try await updateCodeEdit(ref, phase: "queued", content: nil, generation: generation)
                        if codeOmnix.cancelled.contains(ref.cid) { await stopCodeEdit(ref) }
                    }
                }
                guard codeOmnixCurrent(owner, generation) else { return }
                if !ref.jobId.isEmpty {
                    let status = try await codeEditStatus(ref)
                    guard codeOmnixCurrent(owner, generation) else { return }
                    try await acceptCodeEdit(status, receipt: ref, generation: generation)
                    if Self.editIsTerminal(status.phase) { return }
                }
                await JobClock.rest(UIApplication.shared.applicationState == .background ? 10 : 2.5)
            } catch {
                guard codeOmnixCurrent(owner, generation) else { return }
                codeOmnix.notices[ref.cid] = OmnixCopy.reconnect(lang)
                if let status = (error as? APIError)?.status, [401, 403, 404].contains(status) { return }
                await JobClock.rest(5)
            }
        }
    }

    func refreshCodeEdit(_ receipt: CodeEditReceipt) async {
        let generation = codeOmnix.generation
        guard codeOmnixCurrent(receipt.owner, generation) else { return }
        guard !receipt.jobId.isEmpty else { restoreCodeEdit(in: receipt.conversationId); return }
        do {
            let status = try await codeEditStatus(receipt)
            guard codeOmnixCurrent(receipt.owner, generation) else { return }
            try await acceptCodeEdit(status, receipt: receipt, generation: generation)
            if !Self.editIsTerminal(status.phase) { restoreCodeEdit(in: receipt.conversationId) }
        } catch { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.notices[receipt.cid] = OmnixCopy.reconnect(lang) } }
    }

    private func codeEditStatus(_ receipt: CodeEditReceipt) async throws -> ChatJobStatus {
        let status = try await CodeEditService.status(receipt: receipt, api: api)
        guard status.phase == "unknown" || status.phase == "expired" else { return status }
        guard session.identityID == receipt.owner else { throw APIError.cancelled }
        let saved = try await api.getChat(id: receipt.conversationId)
        guard session.identityID == receipt.owner, saved.id == receipt.conversationId else { throw APIError.cancelled }
        if let result = saved.messages.last(where: { $0.role == .assistant && $0.cid == receipt.cid && $0.content.hasPrefix("```firas-code-edit\n") }) {
            return ChatJobStatus(phase: "completed", text: result.content)
        }
        return status
    }

    private func acceptCodeEdit(_ status: ChatJobStatus, receipt: CodeEditReceipt, generation: Int) async throws {
        guard codeOmnixCurrent(receipt.owner, generation) else { throw APIError.cancelled }
        if Self.editIsTerminal(status.phase) {
            var text = status.phase == "completed" ? (lang == .arabic ? "اكتملت المهمة. يمكنك مراجعة المقترح." : "The task is complete. You can review the proposal.") : Strings.Code.askFailed(lang)
            if status.phase == "completed", let source = openProjectID == receipt.conversationId ? project : await cache.load(id: receipt.conversationId, ownerID: receipt.owner),
               let proposal = try? CodeEditService.proposal(text: status.text, source: source, expectedBaseHash: receipt.baseHash), !proposal.prose.isEmpty {
                text = proposal.prose
            }
            if ["cancelled", "canceled"].contains(status.phase) { text = OmnixCopy.stopped(lang) }
            try await updateCodeEdit(receipt, phase: status.phase, content: text, generation: generation)
            guard codeOmnixCurrent(receipt.owner, generation) else { throw APIError.cancelled }
            codeOmnix.active.remove(receipt.conversationId)
            if codeOmnix.eligible.contains(receipt.cid), !codeOmnix.notified.contains(receipt.cid), !codeOmnix.cancelled.contains(receipt.cid), ["completed", "failed"].contains(status.phase) {
                codeOmnix.notified.insert(receipt.cid)
                let pointer = JobPointer(id: receipt.jobId, kind: .codebuild, ownerID: receipt.owner, cid: receipt.cid,
                    conversationID: receipt.conversationId, serverChatID: receipt.conversationId, projectID: receipt.conversationId,
                    title: "Firas Code", lang: lang.rawValue, deadline: .distantFuture)
                let terminal: JobTerminal = status.phase == "completed" ? .completed(JobSnapshot(pointerID: receipt.jobId, phase: .completed, text: text)) : .failed(code: "code_edit_failed", partial: nil)
                await jobs.notifyExternalCompletion(pointer, terminal: terminal)
            }
        } else if status.phase != "unknown" {
            codeOmnix.eligible.insert(receipt.cid)
        }
        guard codeOmnixCurrent(receipt.owner, generation) else { throw APIError.cancelled }
        codeOmnix.edits[receipt.cid] = status; codeOmnix.notices[receipt.cid] = nil
    }

    func stopCodeEdit(_ receipt: CodeEditReceipt) async {
        let generation = codeOmnix.generation
        guard codeOmnixCurrent(receipt.owner, generation), !Self.editIsTerminal(codeOmnix.edits[receipt.cid]?.phase) else { return }
        codeOmnix.cancelled.insert(receipt.cid); codeOmnix.stopping.insert(receipt.cid)
        defer { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.stopping.remove(receipt.cid) } }
        do {
            var bound = receipt
            if bound.jobId.isEmpty, let recovered = try await CodeEditService.recover(receipt: bound, api: api), let jobID = recovered.jobId {
                bound.jobId = jobID
                try await updateCodeEdit(bound, phase: "queued", content: nil, generation: generation)
            }
            guard codeOmnixCurrent(receipt.owner, generation) else { return }
            if !bound.jobId.isEmpty { _ = try await api.cancelChatJob(id: bound.jobId) }
            await refreshCodeEdit(bound)
        } catch { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.notices[receipt.cid] = OmnixCopy.reconnect(lang) } }
    }

    private func updateCodeEdit(_ receipt: CodeEditReceipt, phase: String, content: String?, generation: Int) async throws {
        guard receipt.isValid, codeOmnixCurrent(receipt.owner, generation), var current = await codeThread(receipt.conversationId, owner: receipt.owner),
              codeOmnixCurrent(receipt.owner, generation), let index = current.messages.firstIndex(where: { $0.role == "ai" && $0.edit?.cid == receipt.cid && $0.edit?.owner == receipt.owner }),
              let previous = current.messages[index].edit, previous.baseHash == receipt.baseHash,
              previous.jobId.isEmpty || previous.jobId == receipt.jobId else { throw APIError.cancelled }
        current.messages[index].edit = receipt; current.messages[index].editPhase = phase
        if let content { current.messages[index].content = content }
        codeOmnix.pendingSaves.insert(receipt.cid)
        if openProjectID == receipt.conversationId { thread = current }
        await cache.saveThread(current, id: receipt.conversationId, ownerID: receipt.owner)
        try await persistCodeOmnix(id: receipt.conversationId, owner: receipt.owner, generation: generation)
        guard codeOmnixCurrent(receipt.owner, generation) else { throw APIError.cancelled }
        codeOmnix.pendingSaves.remove(receipt.cid)
    }
}
