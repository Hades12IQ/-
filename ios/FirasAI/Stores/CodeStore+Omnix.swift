import Foundation
import Perception
import UIKit

@MainActor @Perceptible
final class CodeOmnixState {
    var owner: String?
    var generation = 0
    var jobs: [String: OmnixJob] = [:]
    var edits: [String: ChatJobStatus] = [:]
    var notices: [String: String] = [:]
    var active: Set<String> = []
    var stopping: Set<String> = []
    var cancelled: Set<String> = []
    var approvalBusy: Set<String> = []
    var notified: Set<String> = []
    var eligible: Set<String> = []
    var pendingSaves: Set<String> = []
    @PerceptionIgnored var watchers: [String: Task<Void, Never>] = [:]
    func reset(owner: String?) {
        for task in watchers.values { task.cancel() }
        watchers = [:]; self.owner = owner; generation += 1
        jobs = [:]; edits = [:]; notices = [:]; active = []; stopping = []; cancelled = []; approvalBusy = []; notified = []; eligible = []; pendingSaves = []
    }
}

extension CodeStore {
    func sendCodeOmnix(instruction: String, attachments: [PreparedAttachment]) async {
        guard let id = openProjectID, let source = project, let owner = session.identityID, session.isMember,
              !id.hasPrefix("ios_"), !isAsking, !isBuilding(projectID: id), !codeOmnix.active.contains(id) else {
            toasts.show(OmnixCopy.unavailable(lang), isError: true); return
        }
        if codeOmnix.owner != owner { codeOmnix.reset(owner: owner) }
        let generation = codeOmnix.generation
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count <= 60_000, !text.isEmpty || !attachments.isEmpty else {
            toasts.show(OmnixCopy.tooLarge(lang), isError: true); return
        }
        if let latest = thread.messages.reversed().compactMap(\.omnix).first(where: { $0.owner == owner && $0.conversationId == id && $0.submission != "not_admitted" }),
           codeOmnix.jobs[latest.requestKey]?.isTerminal != true {
            restoreCodeOmnix(in: id)
            toasts.show(Strings.Chat.busyWait(lang)); return
        }
        codeOmnix.active.insert(id)
        defer { if codeOmnixCurrent(owner, generation) && codeOmnix.watchers[id] == nil { codeOmnix.active.remove(id) } }
        var admission = CodeRequestAdmission.preparing
        var receipt: OmnixReceipt?
        do {
            let access = try await OmnixService.access(api: api)
            guard codeOmnixCurrent(owner, generation), access.status == "approved" else { throw APIError.cancelled }
            let cloud = try await OmnixService.cloud(api: api)
            guard codeOmnixCurrent(owner, generation), cloud.ready, cloud.state == "ready", openProjectID == id, project == source else { throw APIError.cancelled }
            let requestKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var inputs = try OmnixService.inputs(attachments)
            if !source.files.isEmpty {
                guard source.files.allSatisfy({ CodeStore.sanitizePath($0.path) == $0.path && !$0.path.contains("..") }),
                      Set(source.files.map { $0.path.lowercased() }).count == source.files.count else { throw APIError.decoding("code_project_paths_invalid") }
                let url = try await CodeExport.zip(project: source, fallbackName: "project")
                let bytes = try Data(contentsOf: url)
                inputs.append(OmnixService.Input(clientID: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    name: "firas-code-project-" + String(requestKey.prefix(8)) + ".zip", mime: "application/zip", bytes: bytes))
            }
            guard codeOmnixCurrent(owner, generation), openProjectID == id, project == source,
                  inputs.count <= 10, inputs.reduce(0, { $0 + $1.bytes.count }) <= 25 * 1024 * 1024 else { throw APIError.decoding("code_project_input_limit") }
            let previous = thread.messages.reversed().compactMap(\.omnix).first { $0.isValid && $0.owner == owner && $0.conversationId == id && !$0.sessionId.isEmpty }
            let ref = OmnixReceipt(owner: owner, conversationId: id, requestKey: requestKey, sessionId: previous?.sessionId ?? "")
            receipt = ref
            var user = CodeChatMessage(role: "user", content: text.isEmpty ? attachments.map(\.name).joined(separator: ", ") : text, at: Date().timeIntervalSince1970 * 1000)
            user.model = "omnix"
            var assistant = CodeChatMessage(role: "ai", content: "", at: Date().timeIntervalSince1970 * 1000)
            assistant.model = "omnix"; assistant.omnix = ref
            thread.messages.append(user); thread.messages.append(assistant)
            codeOmnix.eligible.insert(requestKey)
            jobs.prepareExternalCompletion(ownerID: owner)
            try await persistCodeOmnix(id: id, owner: owner, generation: generation)
            let saved = try await api.getChat(id: id)
            guard codeOmnixCurrent(owner, generation), let savedThread = Self.parse(saved)?.thread,
                  let index = savedThread.messages.firstIndex(where: { $0.omnix == ref }), index > 0,
                  savedThread.messages[index - 1].role == "user", savedThread.messages[index - 1].content == user.content else {
                throw APIError.decoding("code_omnix_save_unconfirmed")
            }
            var uploads: [String] = []
            for input in inputs {
                guard codeOmnixCurrent(owner, generation), !codeOmnix.cancelled.contains(requestKey) else { throw APIError.cancelled }
                uploads.append(try await OmnixService.upload(input, receipt: ref, api: api).id)
            }
            guard codeOmnixCurrent(owner, generation), !codeOmnix.cancelled.contains(requestKey) else { throw APIError.cancelled }
            admission = .submitting
            let job = try await OmnixService.submit(OmnixSubmission(requestKey: requestKey, text: text, product: "code", conversationId: id,
                sessionId: ref.sessionId.isEmpty ? nil : ref.sessionId, attachments: uploads.isEmpty ? nil : uploads), api: api)
            admission = .accepted
            guard codeOmnixCurrent(owner, generation) else { return }
            try await acceptCodeOmnix(job, receipt: ref, generation: generation)
            restoreCodeOmnix(in: id)
        } catch {
            guard codeOmnixCurrent(owner, generation) else { return }
            if let receipt {
                if !admission.requiresRecovery(after: error, explicitlyRejected: OmnixService.definitelyNotAdmitted) {
                    await rejectCodeOmnix(receipt, generation: generation, stopped: codeOmnix.cancelled.contains(receipt.requestKey))
                } else {
                    codeOmnix.notices[receipt.requestKey] = OmnixCopy.checking(lang)
                    restoreCodeOmnix(in: id)
                }
            } else { toasts.show(OmnixCopy.unavailable(lang), isError: true) }
        }
    }

    func restoreCodeOmnix(in id: String) {
        guard session.isMember, let owner = session.identityID, !id.hasPrefix("ios_"), !id.isEmpty else { return }
        if codeOmnix.owner != owner { codeOmnix.reset(owner: owner) }
        guard codeOmnix.watchers[id] == nil else { return }
        let generation = codeOmnix.generation
        codeOmnix.watchers[id] = Task { [weak self] in
            await self?.watchCodeOmnix(id: id, owner: owner, generation: generation)
        }
    }

    private func watchCodeOmnix(id: String, owner: String, generation: Int) async {
        defer {
            if codeOmnixCurrent(owner, generation) { codeOmnix.watchers[id] = nil; codeOmnix.active.remove(id) }
        }
        while codeOmnixCurrent(owner, generation) && !Task.isCancelled {
            guard let current = await codeThread(id, owner: owner), codeOmnixCurrent(owner, generation),
                  let ref = current.messages.reversed().compactMap(\.omnix).first(where: { $0.owner == owner && $0.conversationId == id && $0.isValid }),
                  ref.submission != "not_admitted" else { return }
            do {
                var receipt = ref
                if receipt.jobId.isEmpty {
                    codeOmnix.active.insert(id)
                    let found = try await OmnixService.conversation(id, api: api)
                    guard codeOmnixCurrent(owner, generation) else { return }
                    if found.cancelledRequests?.contains(receipt.requestKey) == true {
                        await rejectCodeOmnix(receipt, generation: generation, stopped: true); return
                    }
                    if let job = found.jobs.first(where: receipt.accepts) {
                        receipt.jobId = job.jobId; receipt.sessionId = job.sessionId
                        try await updateCodeOmnix(receipt, text: nil, generation: generation)
                    }
                }
                if !receipt.jobId.isEmpty {
                    let job = try await OmnixService.job(receipt, api: api)
                    guard codeOmnixCurrent(owner, generation) else { return }
                    try await acceptCodeOmnix(job, receipt: receipt, generation: generation)
                    if job.isTerminal && !job.needsFullRefresh { return }
                }
                await JobClock.rest(UIApplication.shared.applicationState == .background ? 10 : 2.5)
            } catch {
                guard codeOmnixCurrent(owner, generation) else { return }
                codeOmnix.notices[ref.requestKey] = OmnixCopy.reconnect(lang)
                if let status = (error as? APIError)?.status, [401, 403, 404].contains(status) { return }
                await JobClock.rest(5)
            }
        }
    }

    func refreshCodeOmnix(_ receipt: OmnixReceipt) async {
        let generation = codeOmnix.generation
        guard codeOmnixCurrent(receipt.owner, generation) else { return }
        guard !receipt.jobId.isEmpty else { restoreCodeOmnix(in: receipt.conversationId); return }
        do {
            let job = try await OmnixService.job(receipt, api: api)
            guard codeOmnixCurrent(receipt.owner, generation) else { return }
            try await acceptCodeOmnix(job, receipt: receipt, generation: generation)
            if !job.isTerminal { restoreCodeOmnix(in: receipt.conversationId) }
        } catch { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.notices[receipt.requestKey] = OmnixCopy.reconnect(lang) } }
    }

    private func acceptCodeOmnix(_ job: OmnixJob, receipt: OmnixReceipt, generation: Int) async throws {
        guard codeOmnixCurrent(receipt.owner, generation), receipt.accepts(job) else { throw APIError.cancelled }
        var bound = receipt; bound.jobId = job.jobId; bound.sessionId = job.sessionId; bound.submission = nil
        if job.isTerminal {
            let text = ["cancelled", "canceled"].contains(job.state) && job.visibleText.isEmpty ? OmnixCopy.stopped(lang) : job.visibleText
            try await updateCodeOmnix(bound, text: text, generation: generation)
            guard codeOmnixCurrent(receipt.owner, generation) else { throw APIError.cancelled }
            codeOmnix.active.remove(bound.conversationId)
            if codeOmnix.eligible.contains(bound.requestKey), !codeOmnix.cancelled.contains(bound.requestKey),
               !codeOmnix.notified.contains(bound.requestKey), ["completed", "failed"].contains(job.state) {
                codeOmnix.notified.insert(bound.requestKey)
                let pointer = JobPointer(id: job.jobId, kind: .codebuild, ownerID: bound.owner, cid: bound.requestKey,
                    conversationID: bound.conversationId, serverChatID: bound.conversationId, projectID: bound.conversationId,
                    title: "omnix 1", lang: lang.rawValue, deadline: .distantFuture)
                let terminal: JobTerminal = job.state == "completed"
                    ? .completed(JobSnapshot(pointerID: job.jobId, phase: .completed, text: text))
                    : .failed(code: "omnix_run_failed", partial: nil)
                await jobs.notifyExternalCompletion(pointer, terminal: terminal)
            }
        } else {
            codeOmnix.active.insert(bound.conversationId); codeOmnix.eligible.insert(bound.requestKey)
            if receipt != bound { try await updateCodeOmnix(bound, text: nil, generation: generation) }
        }
        guard codeOmnixCurrent(receipt.owner, generation) else { throw APIError.cancelled }
        codeOmnix.jobs[bound.requestKey] = job; codeOmnix.notices[bound.requestKey] = nil
    }

    func stopCodeOmnix(_ receipt: OmnixReceipt) async {
        let generation = codeOmnix.generation
        guard codeOmnixCurrent(receipt.owner, generation), receipt.submission != "not_admitted", codeOmnix.jobs[receipt.requestKey]?.isTerminal != true else { return }
        codeOmnix.stopping.insert(receipt.requestKey)
        codeOmnix.cancelled.insert(receipt.requestKey)
        do {
            let result = try await OmnixService.cancel(receipt, api: api)
            guard codeOmnixCurrent(receipt.owner, generation) else { return }
            if let job = result.job { try await acceptCodeOmnix(job, receipt: receipt, generation: generation) }
            else if result.cancelled == true { await rejectCodeOmnix(receipt, generation: generation, stopped: true) }
            restoreCodeOmnix(in: receipt.conversationId)
        } catch {
            if codeOmnixCurrent(receipt.owner, generation) {
                codeOmnix.notices[receipt.requestKey] = OmnixCopy.reconnect(lang)
                codeOmnix.stopping.remove(receipt.requestKey)
            }
        }
    }

    func approveCodeOmnix(_ receipt: OmnixReceipt, approval: OmnixApproval, choice: String) async {
        let generation = codeOmnix.generation
        guard codeOmnixCurrent(receipt.owner, generation), approval.choices.contains(choice), choice == "deny" || approval.commandComplete,
              !codeOmnix.approvalBusy.contains(receipt.requestKey),
              codeOmnix.jobs[receipt.requestKey]?.result?.approval?.requestId == approval.requestId else { return }
        codeOmnix.approvalBusy.insert(receipt.requestKey)
        defer { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.approvalBusy.remove(receipt.requestKey) } }
        do {
            try await OmnixService.approve(receipt, request: OmnixApprovalRequest(requestId: approval.requestId, choice: choice), api: api)
            guard codeOmnixCurrent(receipt.owner, generation) else { return }
            await refreshCodeOmnix(receipt)
        } catch { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.notices[receipt.requestKey] = OmnixCopy.reconnect(lang) } }
    }

    private func rejectCodeOmnix(_ receipt: OmnixReceipt, generation: Int, stopped: Bool) async {
        guard receipt.jobId.isEmpty, codeOmnixCurrent(receipt.owner, generation) else { return }
        var ref = receipt; ref.submission = "not_admitted"
        do { try await updateCodeOmnix(ref, text: (stopped ? OmnixCopy.stopped : OmnixCopy.notStarted)(lang), generation: generation) }
        catch { if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.notices[ref.requestKey] = OmnixCopy.reconnect(lang) } }
        if codeOmnixCurrent(receipt.owner, generation) { codeOmnix.active.remove(receipt.conversationId) }
    }
    func codeThread(_ id: String, owner: String) async -> CodeChatThread? {
        if openProjectID == id { return thread }
        return await cache.loadThread(id: id, ownerID: owner)
    }
    private func updateCodeOmnix(_ receipt: OmnixReceipt, text: String?, generation: Int) async throws {
        guard codeOmnixCurrent(receipt.owner, generation), var current = await codeThread(receipt.conversationId, owner: receipt.owner),
              codeOmnixCurrent(receipt.owner, generation), let index = current.messages.firstIndex(where: {
                  $0.role == "ai" && $0.omnix?.owner == receipt.owner && $0.omnix?.requestKey == receipt.requestKey
              }), let previous = current.messages[index].omnix,
              previous.jobId.isEmpty || previous.jobId == receipt.jobId,
              previous.sessionId.isEmpty || previous.sessionId == receipt.sessionId else { throw APIError.cancelled }
        let changed = previous != receipt || text.map { current.messages[index].content != $0 } == true
        current.messages[index].omnix = receipt
        if let text { current.messages[index].content = text }
        if openProjectID == receipt.conversationId { thread = current }
        await cache.saveThread(current, id: receipt.conversationId, ownerID: receipt.owner)
        // A prior save failure must be retried even when the in-memory text already matches.
        if changed || codeOmnix.jobs[receipt.requestKey]?.isTerminal != true {
            try await persistCodeOmnix(id: receipt.conversationId, owner: receipt.owner, generation: generation)
        }
    }
    func persistCodeOmnix(id: String, owner: String, generation: Int) async throws {
        guard codeOmnixCurrent(owner, generation), let current = openProjectID == id ? project : await cache.load(id: id, ownerID: owner),
              let conversation = await codeThread(id, owner: owner), codeOmnixCurrent(owner, generation),
              !id.hasPrefix("ios_"), case .success = current.validatedForSave() else { throw APIError.cancelled }
        guard await cache.save(current, id: id, ownerID: owner) else { throw APIError.decoding("code_cache_write_failed") }
        await cache.saveThread(conversation, id: id, ownerID: owner)
        guard codeOmnixCurrent(owner, generation) else { throw APIError.cancelled }
        try await push(project: current, thread: conversation, to: id)
        guard codeOmnixCurrent(owner, generation) else { throw APIError.cancelled }
    }
    func codeOmnixCurrent(_ owner: String, _ generation: Int) -> Bool {
        session.isMember && session.identityID == owner && codeOmnix.owner == owner && codeOmnix.generation == generation
    }
}
