import Foundation

// The durable half of an ask: `POST /api/chat/job {kind:"brainask"}` for long member questions, and
// the `JobObserver` that lands the answer whenever it arrives — including after the app was closed
// (`ARCHITECTURE.md §2.4`, `server-code-brainask.md §3`).
extension BrainStore {


    func startDurableAsk(
        question: String,
        cid: String,
        docIDs: [String],
        lang: AppLanguage,
        conversationID: String,
        serverChatID: String
    ) async {
        let request = BrainAskJobRequest(
            task: question,
            cid: cid,
            chatId: serverChatID,
            lang: lang.rawValue,
            docIds: docIDs,
            messages: [OutgoingMessage(role: ChatRole.user.rawValue, content: question)]
        )

        do {
            let response = try await api.json(
                .post,
                "/api/chat/job",
                body: request,
                budget: .interactive,
                as: ChatJobStartResponse.self
            )

            // A replayed cid can answer `completed` on the spot.
            if JobPhase(raw: response.phase ?? "") == .completed,
               let text = response.text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await land(answer: text, cid: cid, lang: lang, in: conversationID)
                return
            }

            let jobID = (response.jobId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jobID.isEmpty else { throw APIError.decoding("brainask start returned no id") }

            let pointer = JobPointer(
                id: jobID,
                kind: .brainask,
                ownerID: session.identityID ?? "",
                cid: cid,
                conversationID: conversationID,
                serverChatID: serverChatID,
                assistantMessageID: ChatMessage.identity(role: .assistant, cid: cid),
                title: AutoTitle.provisional(from: question),
                lang: lang.rawValue,
                deadline: Date().addingTimeInterval(JobKindSpecs.spec(.brainask).deadline)
            )
            jobs.attach(pointer)
            isDurableAsk = true
            pendingNotice = Strings.Brain.queued(lang)
        } catch {
            let text = failureText(error, partial: "", lang: lang)
            await land(answer: text, cid: cid, lang: lang, in: conversationID)
        }
    }

    // MARK: - JobObserver

    func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot) {
        guard pointer.kind == .brainask, pointer.conversationID == threadID else { return }
        guard !snapshot.text.isEmpty else { return }
        pendingNotice = nil
        liveAnswer = snapshot.text
    }

    func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool {
        guard pointer.kind == .brainask else { return true }
        let lang = AppLanguage(rawValue: pointer.lang) ?? prefs.lang
        let conversationID = pointer.conversationID
        let partial = pointer.conversationID == threadID ? liveAnswer : ""

        var body: String
        switch terminal {
        case .completed(let snapshot):
            let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            body = text.isEmpty ? Strings.Brain.noHits(lang) : snapshot.text
        case .refused(let status, let error):
            if status == 429, let quota = error.quota {
                body = ErrorPresenter.quotaText(
                    product: quota.product,
                    limit: quota.limit,
                    isGuest: session.isGuest,
                    scope: error.scope,
                    lang: lang
                )
                if session.isGuest { router.showSignUp(feature: .brain) }
            } else {
                body = jobFailureText(code: error.code ?? "", partial: partial, lang: lang)
            }
        case .failed(let code, let snapshot):
            let carried = snapshot?.text ?? partial
            body = jobFailureText(code: code, partial: carried, lang: lang)
        case .cancelled:
            body = partial.isEmpty
                ? Strings.Brain.stopped(lang).trimmingCharacters(in: .whitespacesAndNewlines)
                : partial + Strings.Brain.stopped(lang)
        case .expired:
            toasts.show(Strings.Errors.timeout(prefs.lang), isError: true)
            body = partial.isEmpty ? Strings.Brain.engineFail(lang) : partial
        case .unauthorized, .forbidden:
            body = partial.isEmpty ? Strings.Brain.noHits(lang) : partial
        }

        await land(answer: body, cid: pointer.cid, lang: lang, in: conversationID)
        return true
    }

    /// `server-code-brainask.md §3.4` — the `error` string of a failed brainask job.
    func jobFailureText(code: String, partial: String, lang: AppLanguage) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix("brain_search_429") {
            if normalized.contains("guest daily limit") {
                if session.isGuest {
                    router.showSignUp(feature: .brain)
                    return Strings.Errors.guestLimitReached(lang)
                }
                return Strings.Errors.tooFast(lang)
            }
            toasts.show(Strings.Errors.tooFast(prefs.lang), isError: true)
            return partial.isEmpty ? Strings.Errors.tooFast(lang) : partial
        }
        if normalized.hasPrefix("brain_search_403") {
            return partial.isEmpty ? Strings.Brain.noHits(lang) : partial
        }
        if normalized == "brainask_no_question" {
            return Strings.Brain.engineFail(lang)
        }

        toasts.show(Strings.Brain.engineFail(prefs.lang), isError: true)
        let sentence = "\n\n_" + Strings.Brain.engineFail(lang) + "_"
        return partial.isEmpty ? Strings.Brain.engineFail(lang) : partial + sentence
    }
}
