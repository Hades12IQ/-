import Foundation
import Observation

/// One file on its way into the library (`web-brain-ux.md §6.4`).
struct BrainImportProgress: Identifiable, Sendable, Equatable {

    enum Stage: Equatable, Sendable {
        case reading(Int, Int)
        case ocr(Int, Int)
        case uploading(Int, Int)
        case done
        case failed(String)
    }

    let id: String
    let name: String
    var stage: Stage
}

/// Firas Brain: the document library, the selection model and the ask pipeline.
///
/// Guests are first-class here (3 documents, 120 pages a day) — only the whole-document read is
/// members-only, because its 403 would pop the sign-up overlay on every question
/// (`web-brain-ux.md §7.2, §14`). The answer itself is `BrainAsker`; long member asks are handed to
/// the durable `brainask` job so they survive leaving the app (`ARCHITECTURE.md §2.4`).
@MainActor
@Observable
final class BrainStore: JobObserver {

    // MARK: - Library

    private(set) var docs: [BrainDocument] = []
    private(set) var limits: BrainLibraryLimits?
    private(set) var usage: BrainLibraryUsage?
    private(set) var isGuestLibrary: Bool = false
    private(set) var isLoadingLibrary: Bool = false
    private(set) var libraryError: String?

    /// Persisted as *excluded* ids, so a document added later arrives selected (`§5.2`).
    var excluded: Set<String> = []
    var pins: Set<String> = []
    var range: ClosedRange<Int>?
    var compareArmed: Bool = false
    var forceOCR: Bool = false

    private(set) var imports: [BrainImportProgress] = []
    private(set) var threadID: String?

    // MARK: - Ask

    private(set) var isAsking: Bool = false
    /// True while the answer is a server job: it keeps going without us, so Stop is not offered.
    /// These four are written by `BrainStore+Job.swift` as well, so they cannot be `private(set)`;
    /// nothing outside the store ever assigns them.
    var isDurableAsk: Bool = false
    var liveAnswer: String = ""
    var liveSources: [BrainSource] = []
    var pendingNotice: String?

    var activeDocIDs: [String] {
        docs.map(\.id).filter { !excluded.contains($0) }
    }

    var hasDocuments: Bool { !docs.isEmpty }

    // MARK: - Dependencies
    // Not `private`: the ask and selection halves of this type live in
    // `BrainStore+Job.swift` and `BrainStore+Selection.swift`.

    @ObservationIgnored let api: APIClient
    @ObservationIgnored let session: SessionStore
    @ObservationIgnored let jobs: JobManager
    @ObservationIgnored private let chat: ChatStore
    @ObservationIgnored let prefs: PreferencesStore
    @ObservationIgnored let toasts: ToastCenter
    @ObservationIgnored let router: Router
    @ObservationIgnored private let asker: BrainAsker
    @ObservationIgnored let defaults: UserDefaults

    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var importPipelines: [String: BrainImportPipeline] = [:]
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored var pinSeen: Set<String> = []
    @ObservationIgnored var pinSeenSeeded = false
    @ObservationIgnored var rangeKey: String = ""
    @ObservationIgnored private var pendingDelta = ""
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored var selectionLoadedFor: String?
    @ObservationIgnored private var askLanguage: AppLanguage = .arabic
    @ObservationIgnored private var askFinalText: String?
    @ObservationIgnored private var askFailure: Error?

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
        self.asker = BrainAsker(api: api)
        self.defaults = UserDefaults.standard
    }

    // MARK: - Library loading

    func loadLibrary() async {
        loadSelectionIfNeeded()
        isLoadingLibrary = true
        libraryError = nil
        do {
            let response = try await api.brainDocs()
            docs = response.docs
            limits = response.limits
            usage = response.used
            isGuestLibrary = response.guest
            applyPins()
            dropRangeIfSelectionChanged()
        } catch {
            if docs.isEmpty {
                libraryError = Strings.Brain.libraryLoadFailed(prefs.lang)
            }
            present(error)
        }
        isLoadingLibrary = false
    }

    func deleteDoc(id: String) async {
        do {
            try await api.brainDeleteDoc(id: id)
        } catch {
            present(error)
        }
        docs.removeAll { $0.id == id }
        excluded.remove(id)
        pins.remove(id)
        pinSeen.remove(id)
        persistSelection()
        dropRangeIfSelectionChanged()
        await loadLibrary()
    }


    // MARK: - Asking

    func ask(_ question: String, outline: Bool, in conversationID: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return }
        guard !activeDocIDs.isEmpty else {
            toasts.show(Strings.Brain.noSources(prefs.lang))
            return
        }

        let lang: AppLanguage = BidiText.isArabicDominant(trimmed) ? .arabic : .english
        let cid = IDs.cid()
        let docIDs = activeDocIDs
        let compare = compareArmed && docIDs.count == 2
        compareArmed = false

        threadID = conversationID
        askLanguage = lang
        isAsking = true
        isDurableAsk = false
        stopRequested = false
        liveAnswer = ""
        liveSources = []
        pendingNotice = Strings.Brain.thinking(lang)
        pendingDelta = ""
        lastFlush = .distantPast

        await chat.appendUserTurn(ChatMessage.user(trimmed, cid: cid, lang: lang), in: conversationID)
        let serverChatID = await chat.ensureServerChat(conversationID)
        let history = chat.conversations[conversationID]?.messages ?? []

        if session.isMember, !compare, docIDs.count > 2, let serverChatID, !serverChatID.isEmpty {
            await startDurableAsk(
                question: trimmed,
                cid: cid,
                docIDs: docIDs,
                lang: lang,
                conversationID: conversationID,
                serverChatID: serverChatID
            )
            return
        }

        let turn = BrainAsker.Turn(
            question: trimmed,
            outline: outline,
            docIDs: docIDs,
            range: range,
            compare: compare,
            isMember: session.isMember,
            lang: lang,
            cid: cid,
            history: history
        )

        askFinalText = nil
        askFailure = nil

        let events = asker.run(turn)
        // The collector is the cancellable half: Stop cancels it, and the landing below still runs
        // on this (uncancelled) task so a stopped answer is still filed and persisted.
        let collector = Task { [weak self] () -> Void in
            await self?.collect(events)
        }
        askTask = collector
        await collector.value
        askTask = nil

        await finishLiveAsk(cid: cid, lang: lang, in: conversationID)
    }

    func stopAsk() {
        guard isAsking, !isDurableAsk else { return }
        stopRequested = true
        Haptics.stop()
        askTask?.cancel()
    }

    private func collect(_ events: AsyncStream<BrainAsker.Event>) async {
        for await event in events {
            switch event {
            case .pending(let notice):
                flushDelta()
                pendingNotice = notice(askLanguage)
            case .delta(let piece):
                pendingNotice = nil
                pendingDelta += piece
                if Date().timeIntervalSince(lastFlush) >= 0.1 { flushDelta() }
            case .sources(let sources):
                liveSources = sources
            case .done(let text):
                flushDelta()
                askFinalText = text
            case .failed(let error):
                flushDelta()
                askFailure = error
            }
        }
        flushDelta()
    }

    private func finishLiveAsk(cid: String, lang: AppLanguage, in conversationID: String) async {
        let finalText = askFinalText
        let failure = askFailure
        askFinalText = nil
        askFailure = nil

        var body: String
        if let failure {
            body = failureText(failure, partial: liveAnswer, lang: lang)
        } else if let finalText, !finalText.isEmpty {
            body = finalText
        } else if stopRequested {
            body = liveAnswer.isEmpty
                ? Strings.Brain.stopped(lang).trimmingCharacters(in: .whitespacesAndNewlines)
                : liveAnswer + Strings.Brain.stopped(lang)
        } else {
            body = liveAnswer.isEmpty ? Strings.Brain.engineFail(lang) : liveAnswer
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = Strings.Brain.engineFail(lang)
        }

        await land(answer: body, cid: cid, lang: lang, in: conversationID)
    }

    private func flushDelta() {
        guard !pendingDelta.isEmpty else { return }
        liveAnswer += pendingDelta
        pendingDelta = ""
        lastFlush = Date()
    }

    /// `web-brain-ux.md §7.8` — a partial answer is never replaced by the failure sentence, the
    /// failure is appended to it.
    func failureText(_ error: Error, partial: String, lang: AppLanguage) -> String {
        let action = ErrorPresenter.present(
            error,
            feature: .brain,
            isGuest: session.isGuest,
            lang: prefs.lang
        )
        handle(action)

        if let apiError = error as? APIError {
            if apiError.status == 429, let quota = apiError.server?.quota {
                return ErrorPresenter.quotaText(
                    product: quota.product,
                    limit: quota.limit,
                    isGuest: session.isGuest,
                    scope: apiError.server?.scope,
                    lang: lang
                )
            }
            if apiError.status == 403 {
                return partial.isEmpty ? Strings.Brain.noHits(lang) : partial
            }
        }

        if error is CancellationError {
            return partial.isEmpty
                ? Strings.Brain.stopped(lang).trimmingCharacters(in: .whitespacesAndNewlines)
                : partial + Strings.Brain.stopped(lang)
        }

        let sentence = "\n\n_" + Strings.Brain.engineFail(lang) + "_"
        return partial.isEmpty ? Strings.Brain.engineFail(lang) : partial + sentence
    }

    func land(answer: String, cid: String, lang: AppLanguage, in conversationID: String) async {
        var message = ChatMessage.assistant(cid: cid, tier: .pro, lang: lang, mode: .auto)
        message.content = answer
        message.status = .delivered
        await chat.appendAssistantTurn(message, in: conversationID)
        await chat.persist(conversationID)

        isAsking = false
        isDurableAsk = false
        stopRequested = false
        liveAnswer = ""
        liveSources = []
        pendingNotice = nil
    }

    // MARK: - Passages

    func passage(docID: String, index: Int) async -> BrainPassage? {
        do {
            return try await api.brainPassage(docID: docID, index: index, window: 2)
        } catch {
            return nil
        }
    }

    // MARK: - Errors

    func present(_ error: Error) {
        handle(ErrorPresenter.present(error, feature: .brain, isGuest: session.isGuest, lang: prefs.lang))
    }

    private func handle(_ action: ErrorAction) {
        switch action {
        case .toast(let text):
            toasts.show(text(prefs.lang), isError: true)
        case .toastText(let text):
            toasts.show(text, isError: true)
        case .signUpPrompt(let feature):
            router.showSignUp(feature: feature)
        case .sessionExpired, .blockedAgent, .creditsBlocked, .hideFeature, .silent:
            break
        }
    }

    // MARK: - Import

    /// One file at a time through `BrainImportPipeline` (extraction, the OCR rule, part splitting
    /// and the sequential POSTs). Everything expensive happens inside the pipeline's detached task;
    /// the store owns the progress row and the toasts (`web-brain-ux.md §6`).
    func importFile(url: URL) async {
        let importID = IDs.cid()
        let lang = prefs.lang
        beginImport(id: importID, name: url.lastPathComponent)

        let pipeline = BrainImportPipeline(api: api)
        importPipelines[importID] = pipeline
        defer { importPipelines[importID] = nil }

        do {
            let outcome = try await pipeline.run(
                url: url,
                forceVision: forceOCR,
                visionLeft: limits?.visionLeft ?? 0,
                lang: lang,
                onStage: { [weak self] stage in
                    self?.setImportStage(importID, stage)
                }
            )
            setImportStage(importID, .done)
            if let notice = outcome.notice, !notice.isEmpty {
                toasts.show(notice)
            }
            toasts.show(Strings.Brain.indexed(lang) + " · " + outcome.title)
            Haptics.attach()
            endImport(id: importID)
            await loadLibrary()
        } catch let failure as BrainImportError {
            if let message = failure.message {
                setImportStage(importID, .failed(message(lang)))
                toasts.show(message(lang), isError: true)
            }
            endImport(id: importID)
            if failure != .cancelled { await loadLibrary() }
        } catch is CancellationError {
            endImport(id: importID)
        } catch {
            setImportStage(importID, .failed(Strings.Brain.readFail(lang)))
            present(error)
            endImport(id: importID)
            await loadLibrary()
        }
    }

    func cancelImport(id: String) {
        importPipelines[id]?.cancel()
        importPipelines[id] = nil
        imports.removeAll { $0.id == id }
    }

    private func setImportStage(_ id: String, _ stage: BrainImportProgress.Stage) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        imports[index].stage = stage
    }

    private func beginImport(id: String, name: String) {
        imports.append(BrainImportProgress(id: id, name: name, stage: .reading(0, 0)))
    }

    private func endImport(id: String) {
        imports.removeAll { $0.id == id }
    }
}
