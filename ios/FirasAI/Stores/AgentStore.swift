import Foundation
import Observation
import OSLog

/// Firas Agent missions.
///
/// The mission runs on the **server** (`kind: "agentrun"` on the durable chat queue, executed by
/// the owner's Manus subscription). This store never polls: `JobManager` owns the SSE channel and
/// the poll fallback and calls back through `JobObserver`. The screen is a viewer — there is no
/// Stop, because `POST /api/chat/cancel` is not honoured by the Manus loop
/// (`web-agent-ux.md §12`).
///
/// Contract: `server-agent.md §3–§5, §10, §12`, `web-agent-ux.md §2, §3, §5, §6, §9, §14, §15`.
@MainActor
@Observable
final class AgentStore: JobObserver {

    // MARK: - Published state

    /// The latest mission per conversation id.
    private(set) var missions: [String: AgentJob] = [:]

    /// The Manus ledger. It rides on every snapshot and on the 409/429 refusal bodies, so a
    /// dedicated fetch is only needed when nothing is being watched (`server-agent.md §12.3`).
    private(set) var credits: AgentCredits?

    /// A refusal that replaced a mission: `blockedAgent`, `creditsBlocked` or `signUpPrompt`.
    private(set) var blocked: [String: ErrorAction] = [:]

    /// The turn id of the mission drawn for a conversation, so the screen can tell whether the
    /// server has already filed that turn into the chat history.
    private(set) var missionCID: [String: String] = [:]

    /// Conversations whose mission stopped being watchable (3 h ceiling, `{job:null}`, 403).
    private(set) var stoppedConversations: Set<String> = []

    /// Conversations with a start in flight — the composer shows it, nothing else.
    private(set) var starting: Set<String> = []

    /// The conversation whose mission is live right now, if any.
    var liveConversationID: String? {
        for pointer in jobs.pointers where pointer.kind == .agentrun {
            switch pointer.lastPhase {
            case .queued, .processing, .reconnecting:
                return pointer.conversationID
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Dependencies

    @ObservationIgnored let api: APIClient
    @ObservationIgnored let session: SessionStore
    @ObservationIgnored let jobs: JobManager
    @ObservationIgnored let chat: ChatStore
    @ObservationIgnored let prefs: PreferencesStore
    @ObservationIgnored let toasts: ToastCenter
    @ObservationIgnored let router: Router
    @ObservationIgnored private var artifactCache: [String: URL] = [:]

    init(
        api: APIClient,
        session: SessionStore,
        jobs: JobManager,
        chat: ChatStore,
        prefs: PreferencesStore,
        toasts: ToastCenter,
        router: Router
    ) {
        self.api = api
        self.session = session
        self.jobs = jobs
        self.chat = chat
        self.prefs = prefs
        self.toasts = toasts
        self.router = router
        // `AppEnvironment.registerJobObservers()` is the single registration site, so a store
        // never hands `self` out before the environment finishes building.
    }

    // MARK: - Starting a mission

    func start(task: String, attachments: [PreparedAttachment], in conversationID: String) async {
        await launch(task: task, attachments: attachments, in: conversationID, recordUserTurn: true)
    }

    /* STOPPING A MISSION. The composer used to draw an hourglass here and say the mission
       runs on the server and cannot be stopped. The Manus run cannot, but the JOB can: a
       mission is a chat-queue job like any other, its pointer id is the mission cid, and
       `JobManager.cancel` already delivers a `.cancelled` terminal — which this store
       handles, marking the conversation stopped. The machinery was all here; the button
       simply never called it. «زين الايقاف شلون اوقفه ادعي عليه؟» */
    func stop(in conversationID: String) async {
        guard let pointer = jobs.pointer(forConversation: conversationID),
              pointer.kind == .agentrun else {
            // No job to cancel. If this conversation has a mission of its own it is one the queue
            // has already forgotten, so settle it locally rather than leaving a composer that says
            // it is busy forever; if it has none, there is nothing here to stop.
            if missions[conversationID] != nil {
                stoppedConversations.insert(conversationID)
            }
            return
        }
        Haptics.stop()
        _ = await jobs.cancel(jobID: pointer.id)
    }

    /// The web's Resume: it starts a **brand new charged mission** from the conversation's last
    /// user message; nothing is resumed server-side (`web-agent-ux.md §7.4`).
    func resume(in conversationID: String) async {
        let history = chat.conversations[conversationID]?.messages ?? []
        guard let lastUser = history.last(where: { $0.role == .user }) else { return }
        let text = lastUser.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await launch(task: text, attachments: [], in: conversationID, recordUserTurn: false)
    }

    private func launch(
        task: String,
        attachments: [PreparedAttachment],
        in conversationID: String,
        recordUserTurn: Bool
    ) async {
        let lang = prefs.lang
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !starting.contains(conversationID) else { return }

        guard session.isMember else {
            blocked[conversationID] = .signUpPrompt(.agent)
            router.showSignUp(feature: .agent)
            return
        }
        if let live = liveAgentPointer() {
            presentLocalBusy(live, requestedIn: conversationID, lang: lang)
            return
        }

        starting.insert(conversationID)
        defer { starting.remove(conversationID) }

        guard let serverChatID = await chat.ensureServerChat(conversationID), !serverChatID.isEmpty else {
            toasts.show(Strings.Errors.serverBusy(lang), isError: true)
            return
        }

        let cid = IDs.cid()
        if recordUserTurn {
            let turn = ChatMessage(role: .user, content: trimmed, lang: lang.rawValue, cid: IDs.cid())
            await chat.appendUserTurn(turn, in: conversationID)
        }

        guard await charge(cid: cid, in: conversationID, lang: lang) else { return }

        blocked[conversationID] = nil
        stoppedConversations.remove(conversationID)
        missionCID[conversationID] = cid

        let history = chat.conversations[conversationID]?.messages ?? []
        let previousFinal = missions[conversationID]?.final ?? ""
        let title = Self.missionTitle(from: trimmed)

        missions[conversationID] = AgentJob(
            id: cid,
            phase: .queued,
            presentation: .task,
            title: title,
            task: trimmed,
            lang: lang.rawValue,
            surface: AgentActivity(startedAt: Date().timeIntervalSince1970 * 1000)
        )

        let folded = await foldedTask(
            base: trimmed,
            attachments: attachments,
            history: history,
            previousFinal: previousFinal,
            lang: lang
        )

        let request = ChatJobRequest(
            messages: [OutgoingMessage(role: "user", content: folded)],
            // Web parity: the Agent route always sends `max` (`web-agent-ux.md §1`,
            // `audit-ios-agent-code.md A13`). The Manus worker ignores `tier`, but the assistant
            // turn this job files into chat history carries it, and a mission read on the web must
            // look identical to one read here.
            tier: ModelTier.max.rawValue,
            think: false,
            cid: cid,
            chatId: serverChatID,
            product: ProductKind.agent.wireValue,
            kind: JobKind.agentrun.rawValue,
            lang: lang.rawValue,
            title: title,
            task: folded
        )
        let draft = JobPointer(
            id: cid,
            kind: .agentrun,
            ownerID: session.identityID ?? "",
            cid: cid,
            conversationID: conversationID,
            serverChatID: serverChatID,
            title: title,
            lang: lang.rawValue,
            deadline: Date().addingTimeInterval(JobKindSpecs.spec(.agentrun).deadline)
        )

        do {
            _ = try await jobs.startChatQueueJob(request, pointer: draft)
        } catch {
            handleStartFailure(error, task: trimmed, title: title, cid: cid, in: conversationID, lang: lang)
        }
    }

    /// `POST /api/usage/charge` — 403 stops with the sign-in sheet, 429 stops with the credits
    /// card, and every other failure **fails open** exactly as the web does (`§12.1`).
    private func charge(cid: String, in conversationID: String, lang: AppLanguage) async -> Bool {
        do {
            _ = try await api.usageCharge(product: .agent, units: 1, cid: cid)
            return true
        } catch let error as APIError {
            guard let status = error.status else { return true }
            switch status {
            case 401, 403:
                blocked[conversationID] = .signUpPrompt(.agent)
                router.showSignUp(feature: .agent)
                return false
            case 429:
                let server = error.server
                blocked[conversationID] = .creditsBlocked(server?.credits ?? credits)
                let text = ErrorPresenter.quotaText(
                    product: server?.quota?.product ?? "agent",
                    limit: server?.quota?.limit,
                    lang: lang
                )
                toasts.show(text, isError: true)
                return false
            default:
                return true
            }
        } catch {
            return true
        }
    }

    private func handleStartFailure(
        _ error: Error,
        task: String,
        title: String,
        cid: String,
        in conversationID: String,
        lang: AppLanguage
    ) {
        let action = ErrorPresenter.present(error, feature: .agent, isGuest: session.isGuest, lang: lang)
        if let apiError = error as? APIError, let serverCredits = apiError.server?.credits {
            credits = serverCredits
        }
        switch action {
        case .blockedAgent(let activeJob, let jobCredits):
            blocked[conversationID] = .blockedAgent(activeJob, jobCredits ?? credits)
            missions[conversationID] = nil
            attachToActiveJob(activeJob, requestedIn: conversationID, lang: lang)
        case .creditsBlocked(let jobCredits):
            let resolved = jobCredits ?? credits
            let held = resolved?.held ?? 0
            blocked[conversationID] = held > 0 ? .blockedAgent(nil, resolved) : .creditsBlocked(resolved)
            missions[conversationID] = nil
            let sentence = held > 0 ? Strings.Errors.agentCreditsReserved : Strings.Errors.agentCreditsSpent
            toasts.show(sentence(lang), isError: true)
        case .signUpPrompt(let feature):
            blocked[conversationID] = .signUpPrompt(feature)
            missions[conversationID] = nil
            router.showSignUp(feature: feature)
        case .hideFeature:
            missions[conversationID] = nil
            blocked[conversationID] = .hideFeature(.agent)
        case .toast(let text):
            missions[conversationID] = Self.unavailableMission(task: task, title: title, cid: cid, lang: lang)
            toasts.show(text(lang), isError: true)
        case .toastText(let text):
            missions[conversationID] = Self.unavailableMission(task: task, title: title, cid: cid, lang: lang)
            toasts.show(text, isError: true)
        case .sessionExpired, .silent:
            missions[conversationID] = Self.unavailableMission(task: task, title: title, cid: cid, lang: lang)
        }
    }

    // MARK: - One mission at a time

    private func liveAgentPointer() -> JobPointer? {
        let horizon = Date().addingTimeInterval(-JobKindSpecs.spec(.agentrun).deadline)
        return jobs.pointers.first { pointer in
            guard pointer.kind == .agentrun, pointer.startedAt > horizon else { return false }
            switch pointer.lastPhase {
            case .queued, .processing, .reconnecting: return true
            default: return false
            }
        }
    }

    /// The client pre-check (`web-agent-ux.md §2.1.2`): the send is cancelled, the draft stays.
    private func presentLocalBusy(_ pointer: JobPointer, requestedIn conversationID: String, lang: AppLanguage) {
        if pointer.conversationID == conversationID {
            toasts.show(Strings.Agent.busySameChat(lang), isError: true)
            return
        }
        let known = chat.conversations[pointer.conversationID] != nil
            || chat.summaries.contains(where: { $0.id == pointer.conversationID })
        if known {
            toasts.show(Strings.Agent.busyOtherChat(lang))
            router.select(conversationID: pointer.conversationID, product: .agent)
            return
        }
        toasts.show(Strings.Agent.busyUnknownChat(lang), isError: true)
    }

    /// 409 `agent_busy`: adopt the mission that already holds the credits and open it.
    private func attachToActiveJob(_ activeJob: AgentActiveJob?, requestedIn conversationID: String, lang: AppLanguage) {
        guard let activeJob, let jobID = activeJob.jobId, !jobID.isEmpty else {
            toasts.show(Strings.Agent.anotherRunning(lang), isError: true)
            return
        }
        let serverChatID = activeJob.chatId ?? ""
        let localID = chat.conversations.first(where: { $0.value.serverID == serverChatID })?.key
            ?? (serverChatID.isEmpty ? nil : serverChatID)

        if jobs.pointer(id: jobID) == nil {
            let pointer = JobPointer(
                id: jobID,
                kind: .agentrun,
                ownerID: session.identityID ?? "",
                cid: activeJob.cid ?? jobID,
                conversationID: localID ?? conversationID,
                serverChatID: serverChatID.isEmpty ? nil : serverChatID,
                title: activeJob.title ?? "",
                lang: lang.rawValue,
                deadline: Date().addingTimeInterval(JobKindSpecs.spec(.agentrun).deadline),
                lastPhase: .processing
            )
            jobs.attach(pointer)
        }
        if let localID, localID != conversationID {
            missionCID[localID] = activeJob.cid ?? jobID
            toasts.show(Strings.Agent.openedRunning(lang))
            router.select(conversationID: localID, product: .agent)
        } else {
            toasts.show(Strings.Agent.anotherRunning(lang), isError: true)
        }
    }

    // MARK: - Credits

    func refreshCredits() async {
        guard session.isAuthenticated else { return }
        guard liveConversationID == nil || credits == nil else { return }
        do {
            credits = try await api.agentCredits()
        } catch {
            // Silent: the chip keeps the last known figure, or stays hidden.
            Log.net.debug("agent credits refresh failed")
        }
    }

    // MARK: - Artifacts

    func artifactURL(jobID: String, index: Int, download: Bool) async -> URL? {
        guard !jobID.isEmpty, index >= 0 else { return nil }
        let key = jobID + "#" + String(index) + "#" + (download ? "1" : "0")
        if let cached = artifactCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        do {
            let result = try await api.agentArtifact(jobID: jobID, index: index, download: download)
            let stored = await Self.persistArtifact(
                temporary: result.url,
                jobID: jobID,
                index: index,
                filename: result.filename,
                download: download
            )
            if let stored { artifactCache[key] = stored }
            return stored
        } catch {
            let lang = prefs.lang
            let action = ErrorPresenter.present(error, feature: .agent, isGuest: session.isGuest, lang: lang)
            if case .toast(let text) = action {
                toasts.show(text(lang), isError: true)
            } else {
                toasts.show(Strings.Agent.viewerFailed(lang), isError: true)
            }
            return nil
        }
    }

    // MARK: - JobObserver

    func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot) {
        guard pointer.kind == .agentrun, let job = snapshot.agent else { return }
        adopt(job, in: pointer.conversationID, cid: pointer.cid)
    }

    func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool {
        guard pointer.kind == .agentrun else { return false }
        let conversationID = pointer.conversationID
        let lang = prefs.lang

        switch terminal {
        case .completed(let snapshot):
            if let job = snapshot.agent { adopt(job, in: conversationID, cid: pointer.cid) }
        case .failed(let code, let partial):
            if let job = partial?.agent { adopt(job, in: conversationID, cid: pointer.cid) }
            applyFailure(code: code, in: conversationID, lang: lang)
        case .refused(let status, let server):
            if let serverCredits = server.credits { credits = serverCredits }
            applyRefusal(status: status, server: server, in: conversationID, lang: lang)
        case .cancelled, .expired, .forbidden, .unauthorized:
            stoppedConversations.insert(conversationID)
        }

        if pointer.serverChatID != nil {
            await chat.refreshFromServer(conversationID)
        }
        return true
    }

    // MARK: - Snapshot adoption

    /// Never shorten what is already drawn: an out-of-order snapshot (a poll answering after a
    /// newer stream frame) is dropped rather than rendered (`web-agent-ux.md §15`).
    private func adopt(_ job: AgentJob, in conversationID: String, cid: String) {
        if let existing = missions[conversationID], !Self.isNewer(job, than: existing) { return }
        missions[conversationID] = job
        missionCID[conversationID] = cid
        if let jobCredits = job.credits { credits = jobCredits }
        if job.phase.isTerminal { stoppedConversations.remove(conversationID) }
        if job.phase != .fail { blocked[conversationID] = nil }
    }

    nonisolated private static func isNewer(_ candidate: AgentJob, than existing: AgentJob) -> Bool {
        if candidate.id != existing.id { return true }
        if existing.phase.isTerminal && !candidate.phase.isTerminal { return false }
        if candidate.phase.isTerminal && !existing.phase.isTerminal { return true }
        let newEvents = candidate.surface?.events.count ?? 0
        let oldEvents = existing.surface?.events.count ?? 0
        if newEvents < oldEvents { return false }
        if (candidate.surface?.endedAt ?? 0) < (existing.surface?.endedAt ?? 0) { return false }
        if candidate.steps.count < existing.steps.count { return false }
        if !existing.final.isEmpty && candidate.final.count < existing.final.count { return false }
        return true
    }

    private func applyFailure(code: String, in conversationID: String, lang: AppLanguage) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let held = credits?.held ?? 0
        switch normalized {
        case "agent_busy", "credits_reserved":
            blocked[conversationID] = .blockedAgent(nil, credits)
        case "credits_exhausted":
            blocked[conversationID] = held > 0 ? .blockedAgent(nil, credits) : .creditsBlocked(credits)
        case "account_required", "signin_required":
            blocked[conversationID] = .signUpPrompt(.agent)
        default:
            let action = ErrorPresenter.presentJobTerminal(
                .failed(code: normalized, partial: nil),
                kind: .agentrun,
                isGuest: session.isGuest,
                lang: lang
            )
            if case .toast(let text) = action { toasts.show(text(lang), isError: true) }
        }
    }

    private func applyRefusal(status: Int, server: ServerError, in conversationID: String, lang: AppLanguage) {
        let action = ErrorPresenter.presentJobTerminal(
            .refused(status: status, error: server),
            kind: .agentrun,
            isGuest: session.isGuest,
            lang: lang
        )
        switch action {
        case .blockedAgent(let activeJob, let jobCredits):
            blocked[conversationID] = .blockedAgent(activeJob, jobCredits ?? credits)
        case .creditsBlocked(let jobCredits):
            blocked[conversationID] = .creditsBlocked(jobCredits ?? credits)
        case .signUpPrompt(let feature):
            blocked[conversationID] = .signUpPrompt(feature)
        case .hideFeature:
            blocked[conversationID] = .hideFeature(.agent)
        case .toast(let text):
            toasts.show(text(lang), isError: true)
        case .toastText(let text):
            toasts.show(text, isError: true)
        case .sessionExpired, .silent:
            break
        }
    }

    // MARK: - Export

    func exportMarkdown(conversationID: String) -> String {
        guard let job = missions[conversationID] else { return "" }
        return Self.markdown(for: job, lang: prefs.lang)
    }
}
