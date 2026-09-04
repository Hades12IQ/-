import Foundation
import Observation
import OSLog
import UIKit

/// One line of the preview console. `level` is the web's `t` key (`log|warn|error|info|ok|run`).
struct ConsoleLine: Identifiable, Sendable, Equatable {
    let id: UUID
    let level: String
    let text: String
    let at: Date

    init(id: UUID = UUID(), level: String, text: String, at: Date = Date()) {
        self.id = id
        self.level = level
        self.text = text
        self.at = at
    }

    var isError: Bool { level == "error" }
    var isWarning: Bool { level == "warn" }
}

/// Firas Code's whole model: the project list, the open project, its AI thread, the build — live
/// and durable — and every file mutation.
///
/// Three facts shape everything here.
///
/// **A project is a chat** with `codeProj: true` whose `messages[0]` is a ```` ```firas-project ````
/// fence and whose `messages[1]` is the base64 ```` ```firas-code-chat ```` thread
/// (`web-code-ux.md §0.1`, `§1`) — so the same project opens on the web, on another device, and here.
///
/// **A build happens in front of the reader.** While the workspace is on screen the app is the
/// builder: it plans the files, then streams each one from `POST /api/chat` straight into `project`,
/// so the tree fills in and the code appears as it is written. That is not a nicety — the durable
/// queue *cannot* show it. While a `codebuild` job runs, `GET /api/chat/job` answers
/// `phase:"processing", text:""` for up to two hours, because the worker publishes each checkpoint
/// to the durable out node while the poll is served from an in-memory answer that stays empty until
/// the very end (`server-code-brainask.md §0.4`). A handed-off build therefore has nothing to show,
/// which is exactly why it felt like the work had gone away.
///
/// **Leaving hands the same turn over; it never cancels it.** One `cid` is minted per build and
/// written to disk as a `CodeBuildTicket` before the first token. Every exit — Home, the app going
/// to the background, a dropped socket, a refusal, being killed outright — ends in the same call:
/// `POST /api/chat/job` with that `cid`. The queue is idempotent per owner + `cid`
/// (`server-code-brainask.md §1.5`), so that call adopts an existing job as readily as it starts a
/// new one, and a doubled build is not reachable. From that moment `JobManager` owns the turn and
/// the result lands through `JobObserver` exactly as before: `chatId: ""` on the wire, files landed
/// by this store, and the pointer never forgotten before they are written (`§3.3`).
@MainActor
@Observable
final class CodeStore: JobObserver {

    // MARK: - Frozen state

    private(set) var projects: [ChatSummary] = []
    private(set) var openProjectID: String?
    private(set) var project: CodeProject?
    private(set) var thread: CodeChatThread = CodeChatThread()
    private(set) var buildPhase: JobPhase?
    private(set) var buildElapsed: TimeInterval = 0
    var selectedPath: String?
    var consoleLines: [ConsoleLine] = []

    // MARK: - Screen state

    enum SaveState: Equatable, Sendable { case saved, editing, saving }

    private(set) var saveState: SaveState = .saved
    private(set) var isLoadingProjects = false
    private(set) var isOpening = false
    private(set) var isCreating = false
    /// Set while `askAI` is in flight so the command bar can draw its live bubble.
    private(set) var isAsking = false
    private(set) var askStartedAt: Date?
    private(set) var listError: String?
    private(set) var openError: String?
    /// The server could not be reached and the cached copy is what is on screen.
    private(set) var usingCachedCopy = false
    /// Files counted in the last checkpoint of a live build.
    private(set) var buildFileCount = 0
    private(set) var canUndoApply = false
    /// True once the last project was deleted, so the grid can say "none left" instead of the
    /// first-run line (`design-brief.md §7.9`).
    private(set) var deletedLastProject = false
    /// Projects with a build in flight **on this device**: one running in front of the reader, or
    /// one whose ticket has not reached the queue yet. Observed, because the launcher's "Working"
    /// filter reads it through `isBuilding(projectID:)`; a build the server already owns is found
    /// through `JobManager` instead.
    private(set) var pendingBuilds: Set<String> = []

    // MARK: - Dependencies

    private let api: APIClient
    private let session: SessionStore
    private let jobs: JobManager
    private let chat: ChatStore
    private let prefs: PreferencesStore
    private let toasts: ToastCenter
    private let router: Router
    private let cache: CodeProjectCache

    // MARK: - Private state

    private var records: [String: CodeProjectRecord] = [:]
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var landedFences: [String: String] = [:]
    @ObservationIgnored private var pendingDeletes: Set<String> = []
    @ObservationIgnored private var undoFiles: [CodeFile]?
    @ObservationIgnored private var activeOwnerID: String?
    @ObservationIgnored private var handoffTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var buildNames: [String: String] = [:]
    /// The build running in front of the reader, per project. At most one per project, and its
    /// existence is what tells `open`, `job(_:didProgress:)` and the elapsed timer that the copy on
    /// screen is newer than anything the cache or the server could hand them.
    ///
    /// Observed, unlike its neighbours here: the build strip has to say something different while
    /// the build is being written on this screen and while the queue owns it, and the moment the
    /// two swap is exactly the moment a row appears in — or leaves — this table.
    private var liveBuilds: [String: Task<Void, Never>] = [:]
    /// Every ticket this identity owns, mirrored in memory so the synchronous readers
    /// (`isBuilding`, `syncBuildState`) never have to await the cache actor.
    @ObservationIgnored private var tickets: [String: CodeBuildTicket] = [:]
    /// Handovers in flight. Home and the background notification can fire in the same run loop
    /// turn; the queue would answer both with the same job id, but one POST is enough.
    @ObservationIgnored private var handingOff: Set<String> = []
    /// Projects whose ticket is being written to disk but whose builder task does not exist yet.
    /// The window is one actor hop wide and nothing normally runs inside it, but a `resumeLiveBuilds`
    /// that landed there would see a ticket with no live build and hand it straight to the server —
    /// which is the one outcome this whole design exists to avoid.
    @ObservationIgnored private var startingBuilds: Set<String> = []
    /// Projects whose live build has finished writing and is being landed — cached, put in the
    /// conversation, pushed, and only then forgotten. The task still exists throughout, so without
    /// this a reader who hits Home during those four awaits would have the finished turn handed to
    /// the queue, which would build the whole project a second time and land it over the copy they
    /// had just watched being written.
    @ObservationIgnored private var finishingBuilds: Set<String> = []
    /// How many times a handover has failed on the network for a project, so the retry can back off
    /// instead of hammering a dead connection for the ticket's whole two-hour life.
    @ObservationIgnored private var handoffAttempts: [String: Int] = [:]
    @ObservationIgnored private var observingLifecycle = false
    /// Where `buildElapsed` counts from: the ticket's start while the build is live, the pointer's
    /// once the server has it. Never refreshed — the strip measures the age of the build.
    @ObservationIgnored private var buildStartedAt: Date?

    /// The web's caps. `task` carries the attachment read as well, because the frozen
    /// `ChatJobRequest` has no `attach` field; the worker reads `body.task` either way.
    static let taskCharacterCap = 6_000
    static let attachmentCharacterCap = 24_000
    static let inIDEAttachmentCap = 60_000
    static let nameCharacterCap = 80

    /// The worker's own prompt budgets, mirrored so a live file is written from the same amount of
    /// context the server would have given it (`server-code-brainask.md §2.3`).
    static let planAttachmentLimit = 6_000
    static let fileBriefLimit = 4_000
    static let fileAttachmentLimit = 8_000
    /// Up to three tail continuations per file, shown the last 2 500 characters — the worker's
    /// numbers, and the same reason: a 16 k-token answer cut mid-function is not a file.
    static let continuationRounds = 3
    static let continuationTail = 2_500
    /// How often a streaming file is written back into `project`. Fast enough to read as typing,
    /// slow enough that SwiftUI is never asked to re-lay-out a 60 000-character file per token.
    static let streamFlushInterval: TimeInterval = 0.12
    static let streamFlushCharacters = 400
    /// Longest gap between two attempts to hand a turn to the queue over a network that keeps
    /// refusing to carry it.
    static let handoffRetryCeiling: TimeInterval = 60

    /// What a connected GitHub repository is allowed to cost one in-IDE turn.
    ///
    /// The repository is context, not a second project, and the budgets say so: six files, a
    /// listing that stops well short of the server's 2 000 rows, and a wall clock that ends the
    /// gather whether or not it finished. A reader waiting on an answer must never be waiting on
    /// GitHub — a slow repository degrades to a smaller prompt, never to a longer silence.
    static let repositoryFileLimit = 6
    static let repositoryFileCharacters = 12_000
    static let repositoryBudget = 44_000
    /* THE THREE THE PURE HALF READS. `repositoryFocus` and `repositoryBlock` are `nonisolated
       static` — they touch no state and run off this actor — and a constant on a `@MainActor`
       type is isolated to it like everything else. Marked the way `DictationController.polish*`
       and `TTSPlayer.chunkLimit` are, for the same reason and by the same house rule. */
    nonisolated static let repositoryTreeRows = 300
    nonisolated static let repositoryTreeCharacters = 10_000
    /// Bytes. Past this a blob is a bundle, a lock file or a minified build product, and the one
    /// thing it is not is an answer.
    nonisolated static let repositoryFileByteCeiling = 200_000
    static let repositoryGatherDeadline: TimeInterval = 20

    init(
        api: APIClient,
        session: SessionStore,
        jobs: JobManager,
        chat: ChatStore,
        prefs: PreferencesStore,
        toasts: ToastCenter,
        router: Router,
        cache: CodeProjectCache
    ) {
        self.api = api
        self.session = session
        self.jobs = jobs
        self.chat = chat
        self.prefs = prefs
        self.toasts = toasts
        self.router = router
        self.cache = cache
        // Job delivery is registered in one place only — `AppEnvironment.registerJobObservers()`,
        // which already registers this store for `.codebuild`. Registering again here would work
        // (JobManager drops a duplicate of the same object) but it splits the contract across two
        // files, and it escapes `self` from an initialiser for no gain.
    }

    // MARK: - Reading

    var lang: AppLanguage { prefs.lang }

    var isGuest: Bool { session.isGuest }

    /// The file count the launcher grid shows; `nil` until the project has been opened here once.
    func fileCount(for id: String) -> Int? {
        records[id]?.fileCount
    }

    /// True while this project is being built anywhere: in front of the reader, on its way to the
    /// queue, or on the queue.
    func isBuilding(projectID: String) -> Bool {
        pendingBuilds.contains(projectID) || jobs.pointer(forConversation: projectID) != nil
    }

    /// True only while this project is being written **here**, on this screen, by this app.
    ///
    /// The distinction is the whole point of the build strip: «يُبنى على الخادم» is a promise to a
    /// reader who is about to leave, and it was being shown to a reader watching the files land one
    /// by one in front of them — which is how a live build came to read as work that had gone away.
    func isBuildingHere(projectID: String) -> Bool {
        liveBuilds[projectID] != nil
    }

    var selectedFile: CodeFile? {
        guard let path = selectedPath else { return nil }
        return project?.files.first { $0.path == path }
    }

    var openProjectName: String {
        let name = project?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        if let id = openProjectID, let title = records[id]?.name, !title.isEmpty { return title }
        return Strings.Code.projectFallbackName(lang)
    }

    // MARK: - Projects

    /// Called as soon as the authenticated identity changes. Old credentials
    /// cannot be used after this point, so only retain old tickets for recovery.
    func identityDidChange(to ownerID: String?) {
        guard activeOwnerID != ownerID else { return }
        if let previous = activeOwnerID, let id = openProjectID, let current = project {
            let conversation = thread
            Task {
                await cache.save(current, id: id, ownerID: previous)
                await cache.saveThread(conversation, id: id, ownerID: previous)
            }
        }
        for task in liveBuilds.values { task.cancel() }
        liveBuilds = [:]
        commitTask?.cancel()
        commitTask = nil
        activeOwnerID = ownerID
        openProjectID = nil
        project = nil
        thread = CodeChatThread()
        projects = []
        records = [:]
        selectedPath = nil
        consoleLines = []
        pendingDeletes = []
        pendingBuilds = []
        tickets = [:]
        undoFiles = nil
        canUndoApply = false
        openError = nil
        listError = nil
        isOpening = false
        isLoadingProjects = false
        saveState = .saved
        clearBuildDisplay()
    }

    /// A user-initiated logout hands live work over before the cookie changes.
    func prepareForSignOut() async {
        handOffLiveBuilds()
        let pending = Array(handoffTasks.values)
        for task in pending { await task.value }
    }

    func loadProjects() async {
        identityDidChange(to: session.identityID)
        guard let ownerID = session.identityID else { return }
        isLoadingProjects = true
        listError = nil
        ensureLifecycleObservers()
        await refreshRecords()
        // The launcher is one of the two doors back into this store, so it is one of the two places
        // an unfinished build gets picked up again.
        await resumeLiveBuilds()
        guard session.identityID == ownerID else { return }

        if session.isMember {
            do {
                let all = try await api.listChats()
                guard session.identityID == ownerID else { return }
                let server = all.filter { $0.codeProj && !pendingDeletes.contains($0.id) }
                var merged = server.map { summary -> ChatSummary in
                    var row = summary
                    if row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let cached = records[row.id]?.name, !cached.isEmpty {
                        row.title = cached
                    }
                    return row
                }
                let known = Set(merged.map(\.id))
                merged.append(contentsOf: localSummaries().filter { !known.contains($0.id) })
                projects = merged
                if !merged.isEmpty { deletedLastProject = false }
            } catch {
                guard session.identityID == ownerID else { return }
                projects = localSummaries()
                if projects.isEmpty {
                    listError = presentableText(error)
                }
            }
        } else {
            projects = localSummaries()
            if !projects.isEmpty { deletedLastProject = false }
        }
        isLoadingProjects = false
    }

    func create(name: String, brief: String, attachments: [PreparedAttachment]) async -> String? {
        identityDidChange(to: session.identityID)
        guard let ownerID = session.identityID else { return nil }
        guard !isCreating else { return nil }
        guard session.isAuthenticated else {
            router.showSignUp(feature: .generic)
            return nil
        }
        isCreating = true
        defer { isCreating = false }

        let attachText = Self.attachmentText(attachments, cap: Self.attachmentCharacterCap)
        var wanted = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.isEmpty, !attachText.isEmpty {
            wanted = Strings.Code.attachmentsOnly(lang)
        }
        let projectName = Self.resolveName(typed: name, brief: wanted, lang: lang)
        let scaffold = CodeProject(name: projectName, files: CodeProject.blankFiles)

        guard let id = await mintProject(scaffold) else { return nil }
        guard session.identityID == ownerID else { return nil }
        deletedLastProject = false
        await cache.save(scaffold, id: id, ownerID: ownerID)
        await refreshRecords()
        guard session.identityID == ownerID else { return nil }
        adopt(id: id, project: scaffold, thread: CodeChatThread())
        if !projects.contains(where: { $0.id == id }) {
            projects.insert(summary(for: id, name: projectName), at: 0)
        }

        if !wanted.isEmpty {
            await startBuild(projectID: id, name: projectName, brief: wanted, attach: attachText)
        }
        return id
    }

    func open(_ id: String) async {
        identityDidChange(to: session.identityID)
        guard !id.isEmpty, let ownerID = session.identityID else { return }
        isOpening = true
        openError = nil
        usingCachedCopy = false
        ensureLifecycleObservers()
        if openProjectID != id {
            openProjectID = id
            project = nil
            thread = CodeChatThread()
            selectedPath = nil
            consoleLines = []
            canUndoApply = false
            undoFiles = nil
            saveState = .saved
        }

        // A build running in front of the reader is the newest copy of this project that exists;
        // neither the on-disk mirror nor the server's `messages[0]` may be allowed to paint over
        // the file that is being written right now. `create` opens the workspace on the same id it
        // has just started building, so this is the ordinary case, not the exotic one — and the test
        // is repeated after every await, because the build can start (or the reader can navigate)
        // inside any one of them.
        if liveBuilds[id] == nil,
           let cached = await cache.load(id: id, ownerID: ownerID),
           liveBuilds[id] == nil, session.identityID == ownerID, openProjectID == id {
            let cachedThread = await cache.loadThread(id: id, ownerID: ownerID) ?? CodeChatThread()
            if liveBuilds[id] == nil, session.identityID == ownerID, openProjectID == id {
                adopt(id: id, project: cached, thread: cachedThread)
            }
        }

        guard session.identityID == ownerID, openProjectID == id else { return }
        if liveBuilds[id] == nil, session.isMember, !id.hasPrefix("ios_") {
            do {
                let conversation = try await api.getChat(id: id)
                guard session.identityID == ownerID, openProjectID == id else { return }
                if liveBuilds[id] != nil {
                    // A build started while the fetch was in flight; the screen is already newer.
                } else if let parsed = Self.parse(conversation) {
                    adopt(id: id, project: parsed.project, thread: parsed.thread)
                    await cache.save(parsed.project, id: id, ownerID: ownerID)
                    await cache.saveThread(parsed.thread, id: id, ownerID: ownerID)
                    await refreshRecords()
                } else if project == nil {
                    // A codeProj chat whose messages[0] is not a project fence: an empty shell.
                    adopt(id: id, project: CodeProject(name: conversation.title, files: []), thread: CodeChatThread())
                }
            } catch {
                guard session.identityID == ownerID, openProjectID == id else { return }
                let status = (error as? APIError)?.status ?? 0
                if [401, 403, 404].contains(status) {
                    project = nil
                    thread = CodeChatThread()
                    selectedPath = nil
                    openError = presentableText(error)
                } else if project == nil {
                    openError = presentableText(error)
                } else {
                    usingCachedCopy = true
                }
            }
        }

        guard session.identityID == ownerID, openProjectID == id else { return }
        if liveBuilds[id] == nil, project == nil, openError == nil {
            openError = Strings.Code.workspaceMissing(lang)
        }
        // Opening a project is the other door back in: whatever happened to its build while the
        // reader was away is settled here, before the strip is drawn.
        await resumeLiveBuilds()
        syncBuildState()
        isOpening = false
    }

    /// Leaves the workspace. The launcher must never keep a half-open project alive behind it.
    ///
    /// Leaving is the handover, not a cancellation: a build running in front of the reader is given
    /// to the queue **before** the screen state goes away, so the turn is on its way to the server
    /// while the toast that says so is still on screen.
    func closeProject() {
        handOffLiveBuilds()
        commitTask?.cancel()
        commitTask = nil
        openProjectID = nil
        project = nil
        thread = CodeChatThread()
        selectedPath = nil
        consoleLines = []
        canUndoApply = false
        undoFiles = nil
        saveState = .saved
        clearBuildDisplay()
    }

    func delete(_ id: String) async {
        guard let ownerID = session.identityID else { return }
        let index = projects.firstIndex { $0.id == id }
        let removed = index.map { projects[$0] }
        if let index { projects.remove(at: index) }
        if projects.isEmpty { deletedLastProject = true }
        // Deleting is the one exit that is NOT a handover: nobody wants a project they just threw
        // away to finish building on the server. The ticket outlives the seven-second undo window
        // and is dropped by `commitDelete`, so undoing inside it still keeps the build.
        liveBuilds[id]?.cancel()
        liveBuilds[id] = nil
        if openProjectID == id { closeProject() }
        pendingDeletes.insert(id)

        toasts.show(
            Strings.Code.projectDeleted(lang),
            actionTitle: Strings.Common.undo(lang)
        ) { [weak self] in
            guard let self else { return }
            self.pendingDeletes.remove(id)
            self.deletedLastProject = false
            guard let removed, !self.projects.contains(where: { $0.id == id }) else { return }
            let slot = min(index ?? 0, self.projects.count)
            self.projects.insert(removed, at: slot)
        }

        Task { [weak self] in
            await JobClock.rest(7)
            await self?.commitDelete(id, ownerID: ownerID)
        }
    }

    // MARK: - Files

    func updateFile(path: String, content: String) {
        guard let current = project else { return }
        guard let index = current.files.firstIndex(where: { $0.path == path }) else { return }
        guard current.files[index].content != content else { return }
        var files = current.files
        files[index] = CodeFile(path: path, content: content)
        project = CodeProject(name: current.name, files: files)
        saveState = .editing
        scheduleCommit()
    }

    func addFile(path: String) {
        guard let current = project else { return }
        let cleaned = Self.sanitizePath(path)
        guard !cleaned.isEmpty else {
            toasts.show(Strings.Code.invalidName(lang), isError: true)
            return
        }
        guard cleaned.count <= CodeProject.maximumPathLength else {
            toasts.show(Strings.Code.pathTooLong(lang), isError: true)
            return
        }
        guard current.files.count < CodeProject.maximumFiles else {
            toasts.show(Strings.Code.fileLimitReached(lang), isError: true)
            return
        }
        guard !current.files.contains(where: { $0.path == cleaned }) else {
            toasts.show(Strings.Code.pathTaken(lang), isError: true)
            return
        }
        var files = current.files
        files.append(CodeFile(path: cleaned, content: Self.starterContent(for: cleaned, lang: lang)))
        project = CodeProject(name: current.name, files: files)
        selectedPath = cleaned
        Haptics.select()
        commitNow()
    }

    func deleteFile(path: String) {
        guard let current = project else { return }
        guard current.files.contains(where: { $0.path == path }) else { return }
        let files = current.files.filter { $0.path != path }
        project = CodeProject(name: current.name, files: files)
        if selectedPath == path { selectedPath = files.first?.path }
        commitNow()
    }

    func renameFile(from: String, to: String) {
        guard let current = project else { return }
        guard let index = current.files.firstIndex(where: { $0.path == from }) else { return }
        let cleaned = Self.sanitizePath(to)
        guard !cleaned.isEmpty else {
            toasts.show(Strings.Code.invalidName(lang), isError: true)
            return
        }
        guard cleaned.count <= CodeProject.maximumPathLength else {
            toasts.show(Strings.Code.pathTooLong(lang), isError: true)
            return
        }
        guard cleaned != from else { return }
        guard !current.files.contains(where: { $0.path == cleaned }) else {
            toasts.show(Strings.Code.pathTaken(lang), isError: true)
            return
        }
        var files = current.files
        files[index] = CodeFile(path: cleaned, content: files[index].content)
        project = CodeProject(name: current.name, files: files)
        if selectedPath == from { selectedPath = cleaned }
        toasts.show(Strings.Code.renamed(lang))
        commitNow()
    }

    // MARK: - Saving

    func save() async {
        guard let id = openProjectID, let current = project,
              let ownerID = session.identityID, activeOwnerID == ownerID else { return }
        let conversation = thread
        commitTask?.cancel()
        commitTask = nil
        saveState = .saving

        let fitted = Self.shrunkToFit(current)
        if case .failure(let error) = fitted.validatedForSave() {
            saveState = .editing
            toasts.show(Self.saveErrorText(error, lang: lang), isError: true)
            return
        }
        if fitted != current { project = fitted }

        await cache.save(fitted, id: id, ownerID: ownerID)
        await cache.saveThread(conversation, id: id, ownerID: ownerID)
        guard session.identityID == ownerID, openProjectID == id else { return }
        records[id] = CodeProjectRecord(
            id: id,
            name: fitted.name,
            fileCount: fitted.files.count,
            updatedAt: Date().timeIntervalSince1970
        )

        if session.isMember, !id.hasPrefix("ios_") {
            do {
                try await push(project: fitted, thread: conversation, to: id)
            } catch {
                saveState = .editing
                toasts.show(Strings.Code.saveFailed(lang), isError: true)
                return
            }
        }
        if session.identityID == ownerID, openProjectID == id { saveState = .saved }
    }

    // MARK: - AI edits

    func askAI(instruction: String, attachments: [PreparedAttachment]) async -> CodeEditPlan? {
        await ask(
            instruction: instruction,
            attachmentText: Self.attachmentText(attachments, cap: Self.inIDEAttachmentCap),
            attachmentCount: attachments.count
        )
    }

    /// The whole in-IDE turn, with the attachments already folded into text.
    ///
    /// That is the only reason this is separate from `askAI`: `startBuild` reroutes a request that
    /// turns out to be a question, and by then the composer has already folded its attachments into
    /// the string the ticket would have carried. Handing that string straight through means a
    /// question asked with a file attached is answered with the file, not without it.
    private func ask(
        instruction: String,
        attachmentText: String,
        attachmentCount: Int
    ) async -> CodeEditPlan? {
        guard !isAsking, let current = project,
              let requestProjectID = openProjectID else { return nil }
        let requestOwnerID = session.identityID
        var request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.isEmpty, !attachmentText.isEmpty {
            request = Strings.Code.attachmentsOnly(lang)
        }
        guard !request.isEmpty else { return nil }

        var turn = String(request.prefix(CodeAskAI.requestLimit))
        if attachmentCount > 0 {
            turn += "\n\n" + Strings.Code.attachmentCount.fmt(lang, ArabicText.count(attachmentCount, lang))
        }
        appendThreadTurn(role: "user", text: turn)

        isAsking = true
        askStartedAt = Date()
        defer {
            isAsking = false
            askStartedAt = nil
        }

        // 1 — a document request is never a software project, and it is never charged for.
        if CodeAskAI.route(request, lang: lang) == .documentRedirect {
            appendThreadTurn(role: "ai", text: CodeAskAI.documentRedirect(lang))
            await save()
            return nil
        }

        // 2 — one Code unit, before any model call. Members are unmetered.
        guard await charge(), openProjectID == requestProjectID,
              session.identityID == requestOwnerID else { return nil }

        // 3 — the repository this session is pointed at, if there is one. It rides in with the
        // attachments because `CodeAskAI` builds both prompts and this store does not own it; the
        // block says loudly, in its first sentence, that it is context and not a second project.
        var context = attachmentText
        let repository = await repositoryContext(for: request)
        guard openProjectID == requestProjectID,
              session.identityID == requestOwnerID else { return nil }
        if !repository.isEmpty { context += repository }

        do {
            let outcome = try await CodeAskAI.run(
                api: api,
                // Re-read: the charge and the repository gather are two suspension points, and the
                // reader is free to type into a file across either of them.
                project: project ?? current,
                instruction: request,
                attachmentText: context,
                lang: lang
            )
            guard openProjectID == requestProjectID,
                  session.identityID == requestOwnerID else { return nil }
            switch outcome {
            case .redirect(let text):
                appendThreadTurn(role: "ai", text: text)
                await save()
                return nil

            case .answer(let text):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                appendThreadTurn(role: "ai", text: body.isEmpty ? Strings.Code.askFailed(lang) : body)
                await save()
                return nil

            case .plan(let plan):
                let changeCount = plan.writes.count + plan.deletes.count + plan.renames.count
                guard changeCount > 0 else {
                    appendThreadTurn(
                        role: "ai",
                        text: plan.prose.isEmpty ? Strings.Code.noChanges(lang) : plan.prose
                    )
                    toasts.show(Strings.Code.noChanges(lang))
                    await save()
                    return nil
                }
                appendThreadTurn(
                    role: "ai",
                    text: plan.prose.isEmpty ? Strings.Code.diffTitle(lang) : plan.prose,
                    n: changeCount
                )
                await save()
                return plan
            }
        } catch {
            guard openProjectID == requestProjectID,
                  session.identityID == requestOwnerID else { return nil }
            appendThreadTurn(role: "ai", text: Strings.Code.askFailed(lang))
            toasts.show(Strings.Code.askFailed(lang), isError: true)
            await save()
            return nil
        }
    }

    func apply(_ plan: CodeEditPlan, selected: Set<String>) {
        guard let current = project else { return }
        var files = current.files
        undoFiles = files

        for rename in plan.renames where selected.contains(rename.to) || selected.contains(rename.from) {
            guard let index = files.firstIndex(where: { $0.path == rename.from }) else { continue }
            files[index] = CodeFile(path: rename.to, content: files[index].content)
        }
        for block in plan.writes where selected.contains(block.path) {
            if let index = files.firstIndex(where: { $0.path == block.path }) {
                files[index] = CodeFile(path: block.path, content: block.content)
            } else if files.count < CodeProject.maximumFiles {
                files.append(CodeFile(path: block.path, content: block.content))
            }
        }
        for path in plan.deletes where selected.contains(path) {
            files.removeAll { $0.path == path }
        }

        project = CodeProject(name: current.name, files: files)
        if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = files.first?.path
        }
        canUndoApply = true
        saveState = .editing
        Haptics.select()
        toasts.show(
            Strings.Code.diffApplied(lang),
            actionTitle: Strings.Common.undo(lang)
        ) { [weak self] in
            self?.undoLastApply()
        }
        commitNow()
    }

    func undoLastApply() {
        guard let restored = undoFiles, let current = project else { return }
        undoFiles = nil
        canUndoApply = false
        project = CodeProject(name: current.name, files: restored)
        if selectedPath == nil || !restored.contains(where: { $0.path == selectedPath }) {
            selectedPath = restored.first?.path
        }
        toasts.show(Strings.Code.diffUndone(lang))
        commitNow()
    }

    // MARK: - The connected repository

    /// Reads the repository this session is pointed at, sized to what one question is worth.
    ///
    /// Every failure here is silent and partial on purpose: no repository, an account that has been
    /// unlinked, a tree that would not load, a blob the server refused — each of those subtracts
    /// context from the prompt and nothing else. The reader asked a question about their code; they
    /// did not ask for a report on GitHub's availability, and an answer with four of six files in
    /// front of it is worth more than an error.
    private func repositoryContext(for request: String) async -> String {
        guard let projectID = openProjectID, !projectID.isEmpty else { return "" }
        let github = CodeGitHubModel.shared
        guard let link = github.link(for: projectID), !link.repo.isEmpty, github.isConnected else {
            return ""
        }

        note("run", Strings.CodeRepo.contextReading.fmt(lang, link.label), projectID: projectID)
        await github.loadTree(api: api, repo: link.repo, ref: link.branch)
        guard openProjectID == projectID,
              github.treeKey == CodeGitHubModel.refKey(repo: link.repo, ref: link.branch) else { return "" }
        let tree = github.tree
        guard !tree.isEmpty else { return "" }

        let wanted = Self.repositoryFocus(request: request, tree: tree, limit: Self.repositoryFileLimit)
        var bodies: [CodeFile] = []
        var used = 0
        let deadline = Date().addingTimeInterval(Self.repositoryGatherDeadline)
        for path in wanted {
            guard Date() < deadline else { break }
            let room = Swift.min(Self.repositoryFileCharacters, Self.repositoryBudget - used)
            // A few hundred characters of a source file is not context, it is a tease.
            guard room > 400 else { break }
            guard let body = await github.readFile(
                api: api,
                repo: link.repo,
                ref: link.branch,
                path: path
            ) else { continue }
            guard openProjectID == projectID else { return "" }
            guard !CodeEngineeringGuidance.containsPrivateKey(body) else { continue }
            let slice = String(body.prefix(room))
            guard !slice.isEmpty else { continue }
            used += slice.count
            /* A CUT FILE SAYS SO. `repositoryBlock` closes every body with «END REPO FILE», which
               a model reads as a promise that the whole file was above it — and a 4 000-line
               source file arrives here as its first 12 000 characters. Answering confidently
               about the part it never saw is worse than not having read the file at all. The
               attachment path has said this since it was written; the repository path must too. */
            var shown = slice
            if slice.count < body.count {
                shown += "\n[… truncated: only the first "
                shown += String(slice.count)
                shown += " characters of this file were read]"
            }
            bodies.append(CodeFile(path: path, content: shown))
        }

        note(
            "ok",
            Strings.CodeRepo.contextRead.fmt(lang, Strings.Code.fileCount(bodies.count, lang)),
            projectID: projectID
        )
        return Self.repositoryBlock(
            repo: link.repo,
            branch: link.branch,
            tree: tree,
            truncated: github.treeTruncated,
            files: bodies
        )
    }

    /// Copies one file out of the connected repository into this project.
    ///
    /// Deliberately not a git operation. The project is the thing that is previewed, edited and
    /// built; a repository file becomes part of it only when the reader says so, and going back
    /// the other way is what `POST /api/github/commit` is for.
    @discardableResult
    func importFile(path: String, content: String) -> Bool {
        guard let current = project else { return false }
        let cleaned = Self.sanitizePath(path)
        guard !cleaned.isEmpty else {
            toasts.show(Strings.Code.invalidName(lang), isError: true)
            return false
        }
        guard cleaned.count <= CodeProject.maximumPathLength else {
            toasts.show(Strings.Code.pathTooLong(lang), isError: true)
            return false
        }

        /* NOT A SILENT CUT. A repository blob is read up to 400 000 bytes and this project's
           per-file ceiling is 60 000 characters, so the old `prefix` handed the reader half a
           file under a tick — half an HTML page that then previews, builds and deploys as though
           it were whole. `validatedForSave` refuses a file this size anyway; saying so here is
           the same answer one step earlier, and it leaves the project untouched. */
        guard content.count <= CodeProject.maximumFileCharacters else {
            toasts.show(Strings.Code.fileTooLarge.fmt(lang, cleaned), isError: true)
            return false
        }
        let body = content
        var files = current.files
        if let index = files.firstIndex(where: { $0.path == cleaned }) {
            files[index] = CodeFile(path: cleaned, content: body)
        } else {
            guard files.count < CodeProject.maximumFiles else {
                toasts.show(Strings.Code.fileLimitReached(lang), isError: true)
                return false
            }
            files.append(CodeFile(path: cleaned, content: body))
        }

        project = CodeProject(name: current.name, files: files)
        selectedPath = cleaned
        Haptics.select()
        toasts.show(Strings.CodeRepo.fileImported.fmt(lang, cleaned))
        commitNow()
        return true
    }

    // MARK: - Share and export

    func share() async -> URL? {
        guard session.isMember else {
            router.showSignUp(feature: .share)
            return nil
        }
        guard let id = openProjectID, !id.hasPrefix("ios_") else {
            toasts.show(Strings.Code.shareFailed(lang), isError: true)
            return nil
        }
        await save()
        toasts.show(Strings.Code.shareCreating(lang))
        do {
            let info = try await api.createShare(ShareCreateRequest(chatId: id))
            guard !info.id.isEmpty else {
                toasts.show(Strings.Code.shareFailed(lang), isError: true)
                return nil
            }
            toasts.show(Strings.Code.shareCopied(lang))
            return info.url
        } catch let error as APIError {
            switch error.status ?? 0 {
            case 409: toasts.show(Strings.Code.shareLimit(lang), isError: true)
            case 429: toasts.show(Strings.Code.shareBusy(lang), isError: true)
            default: toasts.show(Strings.Code.shareFailed(lang), isError: true)
            }
            return nil
        } catch {
            toasts.show(Strings.Code.shareFailed(lang), isError: true)
            return nil
        }
    }

    func exportZip() async -> URL? {
        guard let current = project, !current.files.isEmpty else {
            toasts.show(Strings.Code.exportFailed(lang), isError: true)
            return nil
        }
        let fallback = openProjectName
        do {
            return try await CodeExport.zip(project: current, fallbackName: fallback)
        } catch {
            toasts.show(Strings.Code.exportFailed(lang), isError: true)
            return nil
        }
    }

    // MARK: - Console

    func appendConsole(_ line: ConsoleLine) {
        consoleLines.append(line)
        if consoleLines.count > 400 {
            consoleLines.removeFirst(consoleLines.count - 400)
        }
    }

    func clearConsole() {
        consoleLines = []
    }

    /// The error rows the "fix it with AI" action feeds back into the command bar.
    var recentErrorText: String {
        consoleLines.filter { $0.isError }.suffix(12).map(\.text).joined(separator: "\n")
    }

    // MARK: - Building

    /// Starts a build — when a build is what was asked for. It runs **here**, in front of the
    /// reader, and is written to disk as a ticket first so that every way out of this screen still
    /// ends with the turn on the server.
    ///
    /// Nothing about this method awaits the build itself: the two disk writes are the only
    /// suspensions, and the builder is a task, so the composer gets its screen back immediately.
    /// The one exception is a request that turns out to be a question — that is answered inline,
    /// and this call does not return until it has been.
    func startBuild(projectID: String, name: String, brief: String, attach: String) async {
        /* A QUESTION IS NOT A BUILD.

           The session composer sends the first message of an untouched session here, because an
           untouched session usually does need building. But «شنو هذا؟» is not a brief, and answering
           it by minting a two-hour queue ticket is exactly what «ما يردلي اذا طلبت منه شي» describes:
           the message vanished, the strip lit, and the server built a website nobody asked for.

           The routing is the web's own (`web-code-ux.md §6.2`) and it is applied before every build
           guard below, because none of them are about this request: a question is answered here and
           now, on this screen, with no ticket, no queue and no second build to collide with. */
        let wanted = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if openProjectID == projectID, project != nil, !wanted.isEmpty {
            switch CodeAskAI.route(wanted, lang: lang) {
            case .question, .documentRedirect:
                _ = await ask(instruction: wanted, attachmentText: attach, attachmentCount: 0)
                return
            case .edit:
                break
            }
        }

        guard let owner = session.identityID, !owner.isEmpty else {
            toasts.show(Strings.Errors.sessionExpired(lang), isError: true)
            return
        }
        // One build per project, wherever it is running. A second one would race the first into the
        // same files and, once both were handed over, bill two builds for one brief. The composer
        // clears its draft either way, so a refusal has to say something.
        guard liveBuilds[projectID] == nil,
              !handingOff.contains(projectID),
              !startingBuilds.contains(projectID),
              tickets[projectID] == nil,
              jobs.pointer(forConversation: projectID) == nil else {
            toasts.show(Strings.Code.stillBuilding(lang))
            return
        }
        ensureLifecycleObservers()

        let ticket = CodeBuildTicket(
            projectID: projectID,
            cid: IDs.cid(),
            ownerID: owner,
            name: String(name.prefix(Self.nameCharacterCap)),
            brief: String(brief.prefix(Self.taskCharacterCap)),
            attach: String(attach.prefix(Self.attachmentCharacterCap)),
            lang: lang.rawValue,
            startedAt: Date().timeIntervalSince1970
        )
        startingBuilds.insert(projectID)
        tickets[projectID] = ticket
        pendingBuilds.insert(projectID)
        // Before a single token leaves the device. A build whose ticket is not on disk is a build
        // that a crash, or a task the system kills behind another app, loses outright.
        await cache.saveTicket(ticket)
        /* The reader's own words, in the conversation, before anything else happens. A build used
           to say nothing at all here — the message was swallowed, the strip lit, and the thread
           stayed on its empty-state question, so the only evidence the app had heard anything was a
           progress bar. This suspension deliberately sits INSIDE the `startingBuilds` window: a
           `resumeLiveBuilds` landing here must not read a ticket with no builder as a dead build
           and hand it straight to the queue. */
        if openProjectID == projectID, !wanted.isEmpty {
            appendThreadTurn(role: "user", text: wanted)
            await cache.saveThread(thread, id: projectID, ownerID: ticket.ownerID)
        }
        startingBuilds.remove(projectID)
        beginBuildDisplay(projectID: projectID, startedAt: Date(timeIntervalSince1970: ticket.startedAt))

        liveBuilds[projectID] = Task { [weak self] in
            await self?.runLiveBuild(ticket)
        }
    }

    /// Retry after a failed build: a new `cid`, the same brief.
    func rebuild(brief: String) async {
        guard let id = openProjectID else { return }
        await startBuild(projectID: id, name: openProjectName, brief: brief, attach: "")
    }

    // MARK: - Building: the live path

    /// Plan, then write each file with its tokens landing in `project` as they arrive.
    ///
    /// Every failure here has the same answer, and it is never an error message: the turn goes to
    /// the durable queue under the same `cid` and finishes there. A dropped socket in the middle of
    /// file three is not a failed build.
    private func runLiveBuild(_ ticket: CodeBuildTicket) async {
        let projectID = ticket.projectID
        defer { liveBuilds[projectID] = nil }

        let uiLang = Self.measuredLanguage(
            brief: ticket.brief,
            fallback: AppLanguage(rawValue: ticket.lang) ?? lang
        )
        let kind = Self.buildKind(for: ticket.brief)
        note("run", Strings.Code.planningHeadline(lang), projectID: projectID)

        let steps: [CodeBuildStep]
        do {
            let raw = try await CodeAskAI.complete(
                api: api,
                messages: Self.planMessages(
                    projectName: ticket.name,
                    brief: ticket.brief,
                    attach: ticket.attach,
                    uiLang: uiLang
                ),
                tier: .ultra
            )
            steps = Self.parsePlan(raw, kind: kind, brief: ticket.brief)
        } catch {
            if Task.isCancelled { return }
            handOff(ticket)
            return
        }
        if Task.isCancelled { return }
        // `parsePlan` guarantees `index.html` plus a per-kind skeleton, so this only fires if the
        // plan came back as something that is not a plan at all.
        guard !steps.isEmpty else {
            handOff(ticket)
            return
        }

        var built: [CodeFile] = []
        for step in steps {
            if Task.isCancelled { return }
            let content: String
            do {
                content = try await streamFile(
                    step,
                    ticket: ticket,
                    kind: kind,
                    uiLang: uiLang,
                    manifest: steps,
                    written: built
                )
            } catch {
                if Task.isCancelled { return }
                handOff(ticket)
                return
            }
            if Task.isCancelled { return }
            guard !content.isEmpty else {
                // The worker skips an empty file rather than failing the build; so do we. The row
                // it left in the tree goes with it.
                showLiveFiles(built, projectID: projectID, name: ticket.name, select: nil)
                continue
            }
            built.append(CodeFile(path: step.path, content: content))
            buildFileCount = built.count
            note("log", Strings.Code.buildingHeadline(lang) + " · " + step.path, projectID: projectID)
            // A checkpoint per file, so being killed mid-build still leaves the reader everything
            // they watched being written.
            await cache.save(CodeProject(name: ticket.name, files: built), id: projectID, ownerID: ticket.ownerID)
        }

        if Task.isCancelled { return }
        guard !built.isEmpty else {
            handOff(ticket)
            return
        }
        await finishLiveBuild(built, ticket: ticket)
    }

    /// One file. The tokens go into `project` on a fixed cadence, which is the whole feature: the
    /// tree gains the file the moment it starts and the editor fills with it as it is written.
    private func streamFile(
        _ step: CodeBuildStep,
        ticket: CodeBuildTicket,
        kind: CodeBuildKind,
        uiLang: AppLanguage,
        manifest: [CodeBuildStep],
        written: [CodeFile]
    ) async throws -> String {
        var body = ""
        var pending = ""
        var lastFlush = Date()
        var leadChecked = false
        var leadStripped = false
        var rounds = 0

        var live = written
        live.append(CodeFile(path: step.path, content: ""))
        showLiveFiles(live, projectID: ticket.projectID, name: ticket.name, select: step.path)

        var messages = Self.fileMessages(
            step: step,
            projectName: ticket.name,
            brief: ticket.brief,
            attach: ticket.attach,
            kind: kind,
            uiLang: uiLang,
            manifest: manifest,
            written: written.map(\.path),
            writtenFiles: written
        )

        while true {
            let lengthAtStart = body.count
            let stream = await api.chatStream(Self.streamRequest(messages: messages, tier: .ultra))
            for try await frame in stream {
                try Task.checkCancellation()
                if frame.isDone { break }
                guard let delta = CodeAskAI.deltaContent(frame.data), !delta.isEmpty else { continue }
                pending += delta
                let now = Date()
                guard pending.count >= Self.streamFlushCharacters
                        || now.timeIntervalSince(lastFlush) >= Self.streamFlushInterval else { continue }
                body += pending
                pending = ""
                lastFlush = now
                // The opening fence, if the model produced one anyway, is removed once — while the
                // body is still a few hundred characters — so the reader never watches ```html sit
                // at line 1 for a minute. The closing one is dealt with at the end.
                if !leadChecked, let newline = body.firstIndex(of: "\n") {
                    leadChecked = true
                    if body[..<newline].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        body = String(body[body.index(after: newline)...])
                        leadStripped = true
                    }
                }
                live[live.count - 1] = CodeFile(path: step.path, content: body)
                showLiveFiles(live, projectID: ticket.projectID, name: ticket.name, select: nil)
            }
            body += pending
            pending = ""
            live[live.count - 1] = CodeFile(path: step.path, content: body)
            showLiveFiles(live, projectID: ticket.projectID, name: ticket.name, select: nil)

            let sofar = leadStripped ? Self.strippedClosingFence(body) : Self.strippedFence(body)
            // A continuation that added nothing will add nothing next time either; three rounds of
            // that is three requests spent to learn the same thing once.
            let stalled = rounds > 0 && body.count == lengthAtStart
            guard !stalled,
                  rounds < Self.continuationRounds,
                  !sofar.isEmpty,
                  !Self.looksComplete(path: step.path, content: sofar) else {
                // A file the brace count still dislikes is KEPT. The worker can parse JavaScript and
                // drops a file that will not parse; there is no parser here, and a naive count is not
                // evidence enough to throw away work the reader watched being written.
                if !sofar.isEmpty, !Self.looksComplete(path: step.path, content: sofar) {
                    note("warn", step.path, projectID: ticket.projectID)
                }
                return EngineFailureDetector.isFailure(sofar) ? "" : sofar
            }
            rounds += 1
            messages = Self.fileContinuationMessages(
                path: step.path,
                tail: String(body.suffix(Self.continuationTail))
            )
        }
    }

    /// Writes the files a live build has produced into the open project. Only for the project on
    /// screen: a build the reader has navigated away from has nothing to paint, and painting it
    /// anyway would write one project's files over another's.
    private func showLiveFiles(_ files: [CodeFile], projectID: String, name: String, select: String?) {
        guard openProjectID == projectID else { return }
        let current = project?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        project = CodeProject(name: current.isEmpty ? name : current, files: files)
        // The editor follows the file being written, but only when it opens: the reader is free to
        // click another file mid-build and must not be dragged back on the next token.
        if let select { selectedPath = select }
    }

    /// The end of a live build: shrink to the save caps, land the files, push them to the project
    /// chat, and only then forget the ticket. Land before forget, the same rule as the durable path.
    private func finishLiveBuild(_ files: [CodeFile], ticket: CodeBuildTicket) async {
        let projectID = ticket.projectID
        guard session.identityID == ticket.ownerID else { return }
        finishingBuilds.insert(projectID)
        defer { finishingBuilds.remove(projectID) }
        let fitted = Self.shrunkToFit(CodeProject(name: ticket.name, files: files))
        if case .failure(let error) = fitted.validatedForSave() {
            toasts.show(Self.saveErrorText(error, lang: lang), isError: true)
        }

        await cache.save(fitted, id: projectID, ownerID: ticket.ownerID)
        guard session.identityID == ticket.ownerID else { return }
        records[projectID] = CodeProjectRecord(
            id: projectID,
            name: fitted.name,
            fileCount: fitted.files.count,
            updatedAt: Date().timeIntervalSince1970
        )

        if openProjectID == projectID {
            project = fitted
            if selectedPath == nil || !fitted.files.contains(where: { $0.path == selectedPath }) {
                selectedPath = Self.entryPath(of: fitted)
            }
        }

        // The build's last word, in the conversation the reader has been watching. It is written
        // BEFORE the push so the server's `messages[1]` carries it too, and it takes the file count
        // as its chip — «ملفات: ٧» beside «جاهز» is the answer to "did anything actually happen".
        let conversation = await appendBuildTurn(
            Strings.CodeBuild.doneTurn(lang),
            n: fitted.files.count,
            projectID: projectID,
            ownerID: ticket.ownerID
        )

        var pushed = true
        if session.isMember, session.identityID == ticket.ownerID, !projectID.hasPrefix("ios_") {
            do {
                try await push(project: fitted, thread: conversation, to: projectID)
            } catch {
                // The files are on disk and on screen; only the server copy is behind, and the next
                // edit's save carries it. The ticket still goes: re-running the whole build to
                // recover one PUT would be a far worse trade.
                pushed = false
            }
        }

        await cache.deleteTicket(projectID: projectID)
        tickets[projectID] = nil
        pendingBuilds.remove(projectID)
        if openProjectID == projectID {
            clearBuildDisplay()
            saveState = pushed ? .saved : .editing
            note("ok", Strings.Code.serverDone(lang), projectID: projectID)
        }
        if !pushed { toasts.show(Strings.Code.saveFailed(lang), isError: true) }
        announceReady(projectID: projectID, name: ticket.name)
    }

    // MARK: - Building: the handover

    /// Leaving — Home, or the app going to the background. Nothing is cancelled: every build
    /// running in front of a reader is moved to the queue under its own `cid` and finishes there.
    func handOffLiveBuilds() {
        for ticket in Array(tickets.values) {
            guard liveBuilds[ticket.projectID] != nil else { continue }
            // A build that has already written its last file is not work in flight: its ticket is
            // still on disk only because the files are still being landed.
            guard !finishingBuilds.contains(ticket.projectID) else { continue }
            handOff(ticket)
        }
    }

    /// Moves one turn from the live path to the durable queue.
    ///
    /// Safe to call as often as anything likes: the first call wins, and the queue would answer a
    /// second POST of the same `cid` with the same job anyway. The POST itself runs in a fresh
    /// top-level task because the caller is very often the live build being cancelled in the same
    /// breath, and a cancelled task cannot make the request that saves the turn.
    private func handOff(_ ticket: CodeBuildTicket) {
        let projectID = ticket.projectID
        guard session.identityID == ticket.ownerID else { return }
        guard !handingOff.contains(projectID) else { return }
        handingOff.insert(projectID)
        liveBuilds[projectID]?.cancel()
        liveBuilds[projectID] = nil
        handoffTasks[projectID] = Task { @MainActor [weak self] in
            await self?.performHandOff(ticket)
        }
    }

    private func performHandOff(_ ticket: CodeBuildTicket) async {
        let projectID = ticket.projectID
        // The app may be on its way out; the POST has to survive the trip.
        let hold = BackgroundExecutor.hold(name: "firas.code.handoff." + projectID)
        defer {
            hold.end()
            handingOff.remove(projectID)
            handoffTasks[projectID] = nil
        }

        guard session.identityID == ticket.ownerID else { return }

        let task = Self.jobTask(ticket)
        let request = ChatJobRequest(
            messages: [OutgoingMessage(role: "user", content: task, images: nil)],
            tier: ModelTier.pro.rawValue,
            think: false,
            cid: ticket.cid,
            // Always empty: a real id makes the worker append the raw fence as a third message
            // into the project chat (`server-code-brainask.md §2.1`).
            chatId: "",
            product: ProductKind.code.wireValue,
            kind: JobKind.codebuild.rawValue,
            lang: ticket.lang,
            title: ticket.name,
            task: task
        )
        let started = Date(timeIntervalSince1970: ticket.startedAt)
        let draft = JobPointer(
            id: ticket.cid,
            kind: .codebuild,
            ownerID: ticket.ownerID,
            cid: ticket.cid,
            conversationID: projectID,
            projectID: projectID,
            title: ticket.name,
            lang: ticket.lang,
            startedAt: started,
            deadline: started.addingTimeInterval(JobKindSpecs.spec(.codebuild).deadline)
        )

        do {
            let pointer = try await jobs.startChatQueueJob(request, pointer: draft)
            buildNames[pointer.id] = ticket.name
            var handed = ticket
            handed.handedOff = true
            handed.jobID = pointer.id
            await cache.saveTicket(handed)
            guard session.identityID == ticket.ownerID else { return }
            tickets[projectID] = handed
            handoffAttempts[projectID] = nil
            pendingBuilds.remove(projectID)      // the spine answers for it from here on
            if openProjectID == projectID {
                buildStartedAt = pointer.startedAt
                buildPhase = pointer.lastPhase
                startElapsedTimer()
            }
            // A toast is gone in four seconds and the reader may not even be looking at the app.
            // The conversation is where they will look next, so the conversation is told as well.
            _ = await appendBuildTurn(Strings.CodeBuild.movedTurn(lang), n: nil, projectID: projectID, ownerID: ticket.ownerID)
            toasts.show(Strings.Code.serverKeep(lang))
        } catch {
            guard session.identityID == ticket.ownerID else { return }
            guard let status = (error as? APIError)?.status else {
                // Transport, not refusal. The ticket stays exactly where it is, and this is the one
                // path on which "leaving must not lose the work" rests when the network is down —
                // so it does not merely wait for the next foreground, it keeps asking. The ticket's
                // own two-hour ceiling ends the attempts; nothing else does.
                if openProjectID == projectID { buildPhase = .reconnecting }
                Log.ui.error("code build handover could not reach the queue")
                let attempt = (handoffAttempts[projectID] ?? 0) + 1
                handoffAttempts[projectID] = attempt
                let delay = Swift.min(Self.handoffRetryCeiling, 5 * Double(attempt))
                Task { [weak self] in
                    await JobClock.rest(delay)
                    await self?.resumeLiveBuilds()
                }
                return
            }
            // A refusal is final for this `cid`; a retry has to mint a new one, which is the
            // reader's decision (`rebuild`), not ours.
            await cache.deleteTicket(projectID: projectID)
            tickets[projectID] = nil
            pendingBuilds.remove(projectID)
            handoffAttempts[projectID] = nil
            if openProjectID == projectID { clearBuildDisplay() }
            _ = await appendBuildTurn(Strings.CodeBuild.refusedTurn(lang), n: nil, projectID: projectID, ownerID: ticket.ownerID)
            present(refusal: error, status: status)
        }
    }

    /// Coming back — a foreground, the launcher, or opening a project. Every unfinished build is put
    /// where it belongs, and none of the four cases starts a second one.
    func resumeLiveBuilds() async {
        guard let owner = session.identityID, !owner.isEmpty else { return }
        let rows = await cache.tickets()
        guard session.identityID == owner else { return }
        let mine = rows.filter { $0.ownerID == owner }

        for ticket in mine {
            let projectID = ticket.projectID
            tickets[projectID] = ticket
            // 1 — about to be written, being written in front of the reader, or already on its way
            // to the queue.
            if liveBuilds[projectID] != nil
                || startingBuilds.contains(projectID)
                || handingOff.contains(projectID) { continue }
            // 2 — the spine already holds it; `JobManager` polls, notifies and delivers.
            if jobs.pointer(forConversation: projectID) != nil
                || jobs.pointers.contains(where: { $0.cid == ticket.cid }) {
                pendingBuilds.remove(projectID)
                continue
            }
            // 3 — either the app was killed mid-build, or the pointer table lost the row. The same
            // `cid` adopts the existing job when the server has one and starts it when it does not.
            pendingBuilds.insert(projectID)
            handOff(ticket)
        }

        // 4 — a ticket that is gone from disk is a build that landed. Nothing is left lit.
        let known = Set(mine.map(\.projectID))
        for projectID in Array(tickets.keys) where !known.contains(projectID) {
            guard liveBuilds[projectID] == nil,
                  !startingBuilds.contains(projectID),
                  !handingOff.contains(projectID) else { continue }
            tickets[projectID] = nil
            pendingBuilds.remove(projectID)
        }
    }

    /// The two app-level moments this store needs and `AppLifecycle` does not hand it. Registered
    /// once, lazily, from the three doors into Firas Code; the blocks hold `self` weakly and this
    /// store is built once by `AppEnvironment` and lives as long as the process, so there is
    /// nothing to unregister.
    private func ensureLifecycleObservers() {
        guard !observingLifecycle else { return }
        observingLifecycle = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handOffLiveBuilds() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.resumeLiveBuilds() }
        }
    }

    // MARK: - JobObserver

    func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot) {
        guard pointer.kind == .codebuild, session.identityID == pointer.ownerID,
              let projectID = pointer.projectID else { return }
        // A build still running in front of the reader owns this project's files. (Only reachable
        // if a pointer and a live build coexist, which the start guard prevents — but a checkpoint
        // landing over a file being typed is bad enough to be worth the one line.)
        guard liveBuilds[projectID] == nil else { return }
        if openProjectID == projectID {
            buildPhase = snapshot.phase
            buildStartedAt = pointer.startedAt
            buildElapsed = Date().timeIntervalSince(pointer.startedAt)
            startElapsedTimer()
        }
        guard !snapshot.text.isEmpty, landedFences[pointer.id] != snapshot.text else { return }
        guard let checkpoint = try? CodeProject.decode(fromJobText: snapshot.text),
              !checkpoint.files.isEmpty else { return }
        landedFences[pointer.id] = snapshot.text
        buildFileCount = checkpoint.files.count
        Task { [weak self] in
            _ = await self?.land(checkpoint, into: projectID, pointer: pointer)
        }
    }

    func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool {
        guard pointer.kind == .codebuild else { return false }
        guard session.identityID == pointer.ownerID else { return false }
        guard let projectID = pointer.projectID else { return true }
        // The server's answer is the authority for this project from here on.
        liveBuilds[projectID]?.cancel()
        liveBuilds[projectID] = nil
        let name = buildNames[pointer.id] ?? tickets[projectID]?.name ?? pointer.title
        var landedAnything = landedFences[pointer.id] != nil
        var landedCount: Int?

        if let snapshot = terminal.snapshot,
           let finished = try? CodeProject.decode(fromJobText: snapshot.text),
           !finished.files.isEmpty {
            // Land before forget: a false answer here buys another 15 × 4 s of retries.
            guard await land(finished, into: projectID, pointer: pointer) else { return false }
            landedAnything = true
            landedCount = finished.files.count
        }

        if openProjectID == projectID { clearBuildDisplay() }
        landedFences[pointer.id] = nil
        buildNames[pointer.id] = nil
        // The pointer and the ticket are forgotten in the same breath, and only now: the ticket is
        // what would otherwise re-hand this turn to the queue on the next foreground.
        await cache.deleteTicket(projectID: projectID)
        tickets[projectID] = nil
        pendingBuilds.remove(projectID)

        // The queue's own last word, said in the same place the live path says it. After the land,
        // not before: `land` may answer `false` and be retried, and a turn appended on every retry
        // would fill the conversation with the same sentence.
        //
        // A refusal is not a stumble: «أعد الطلب بتفاصيل أكثر» is advice that cannot work when the
        // server said no to the request itself, and following it spends another attempt on the
        // same answer. `announce` already shows the server's own reason as a toast; this is the
        // copy of it that survives the four seconds.
        let lastWord: String
        if landedAnything {
            lastWord = Strings.CodeBuild.doneTurn(lang)
        } else if case .refused = terminal {
            lastWord = Strings.CodeBuild.refusedTurn(lang)
        } else {
            lastWord = Strings.CodeBuild.failedTurn(lang)
        }
        _ = await appendBuildTurn(lastWord, n: landedCount, projectID: projectID, ownerID: pointer.ownerID)
        announce(projectID: projectID, name: name, landed: landedAnything, terminal: terminal)
        return true
    }

    // MARK: - Landing

    private func land(_ built: CodeProject, into projectID: String, pointer: JobPointer) async -> Bool {
        guard session.identityID == pointer.ownerID else { return false }
        let named = CodeProject(
            name: built.name.isEmpty ? pointer.title : built.name,
            files: built.files
        )
        let fitted = Self.shrunkToFit(named)
        if case .failure(let error) = fitted.validatedForSave() {
            toasts.show(Self.saveErrorText(error, lang: lang), isError: true)
            return true                                   // nothing left to try; release the pointer
        }

        await cache.save(fitted, id: projectID, ownerID: pointer.ownerID)
        guard session.identityID == pointer.ownerID else { return false }
        records[projectID] = CodeProjectRecord(
            id: projectID,
            name: fitted.name,
            fileCount: fitted.files.count,
            updatedAt: Date().timeIntervalSince1970
        )

        if session.isMember, !projectID.hasPrefix("ios_") {
            let existing: CodeChatThread
            if openProjectID == projectID {
                existing = thread
            } else {
                existing = await cache.loadThread(id: projectID, ownerID: pointer.ownerID) ?? CodeChatThread()
            }
            do {
                try await push(project: fitted, thread: existing, to: projectID)
            } catch {
                return false
            }
        }

        if openProjectID == projectID {
            project = fitted
            if selectedPath == nil || !fitted.files.contains(where: { $0.path == selectedPath }) {
                selectedPath = Self.entryPath(of: fitted)
            }
            saveState = .saved
        }
        return true
    }

    private func announce(projectID: String, name: String, landed: Bool, terminal: JobTerminal) {
        guard landed else {
            if case .refused(let status, let server) = terminal {
                let action = ErrorPresenter.present(
                    APIError.http(status: status, server: server, raw: ""),
                    feature: .generic,
                    isGuest: session.isGuest,
                    lang: lang
                )
                if case .toast(let text) = action {
                    toasts.show(text(lang), isError: true)
                    return
                }
                if case .toastText(let text) = action {
                    toasts.show(text, isError: true)
                    return
                }
            }
            toasts.show(Strings.Code.serverFailed.fmt(lang, displayName(name)), isError: true)
            return
        }
        announceReady(projectID: projectID, name: name)
    }

    /// The same two sentences whichever engine finished the build: the reader who is looking at the
    /// project is told it is done, and the reader who is somewhere else is offered a way back.
    private func announceReady(projectID: String, name: String) {
        if openProjectID == projectID {
            toasts.show(Strings.Code.serverDone(lang))
        } else {
            toasts.show(
                Strings.Code.serverReady.fmt(lang, displayName(name)),
                actionTitle: Strings.Code.serverOpen(lang),
                duration: 9
            ) { [weak self] in
                self?.router.open(.code(projectID: projectID))
            }
        }
    }

    private func displayName(_ name: String) -> String {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((raw.isEmpty ? Strings.Code.projectFallbackName(lang) : raw).prefix(40))
    }

    /// The one place a build is allowed to end badly: the queue itself refused the turn.
    private func present(refusal error: Error, status: Int) {
        switch ErrorPresenter.present(error, feature: .generic, isGuest: session.isGuest, lang: lang) {
        case .toast(let text):
            toasts.show(text(lang), isError: true)
        case .toastText(let text):
            toasts.show(text, isError: true)
        case .signUpPrompt(let feature):
            router.showSignUp(feature: feature)
        case .sessionExpired:
            toasts.show(Strings.Errors.sessionExpired(lang), isError: true)
        case .blockedAgent, .creditsBlocked, .hideFeature:
            toasts.show(Strings.Code.buildRefused(lang), isError: true)
        case .silent:
            // `silent` is for a status nobody needs to read about; a build that is not going to
            // happen is not one of those.
            Log.ui.error("code build refused with status \(status, privacy: .public)")
            toasts.show(Strings.Code.buildRefused(lang), isError: true)
        }
    }

    /// One console row for the project on screen. A build the reader is not watching narrates to
    /// nobody, and the console is cleared when a project is opened anyway.
    private func note(_ level: String, _ text: String, projectID: String) {
        guard openProjectID == projectID else { return }
        appendConsole(ConsoleLine(level: level, text: text))
    }

    // MARK: - Persistence

    private func push(project: CodeProject, thread: CodeChatThread, to id: String) async throws {
        var messages: [PersistedMessage] = [
            PersistedMessage(
                role: ChatRole.assistant.rawValue,
                content: project.encodedFence(),
                lang: lang.rawValue,
                reasoning: ""
            )
        ]
        // Never before `messages[0]` exists (`web-code-ux.md §1.3`).
        if !thread.messages.isEmpty {
            messages.append(
                PersistedMessage(
                    role: ChatRole.assistant.rawValue,
                    content: thread.encodedFence(),
                    lang: lang.rawValue,
                    reasoning: ""
                )
            )
        }
        try await api.updateChat(
            id: id,
            UpdateChatRequest(title: String(project.name.prefix(Self.nameCharacterCap)), messages: messages)
        )
    }

    private func mintProject(_ scaffold: CodeProject) async -> String? {
        guard session.isMember else { return IDs.localConversationID() }
        let clientID = "ios" + IDs.cid() + IDs.cid()
        let request = CreateChatRequest(
            title: String(scaffold.name.prefix(Self.nameCharacterCap)),
            messages: [
                PersistedMessage(
                    role: ChatRole.assistant.rawValue,
                    content: scaffold.encodedFence(),
                    lang: lang.rawValue,
                    reasoning: ""
                )
            ],
            agent: false,
            codeProj: true,
            brainNb: false,
            id: clientID
        )
        do {
            let conversation = try await api.createChat(request)
            let id = conversation.id.isEmpty ? "c_" + clientID : conversation.id
            await chat.loadConversations()
            return id
        } catch {
            toasts.show(presentableText(error), isError: true)
            return nil
        }
    }

    private func commitDelete(_ id: String, ownerID: String) async {
        guard pendingDeletes.contains(id), session.identityID == ownerID else { return }
        pendingDeletes.remove(id)
        // `cache.delete` drops the build ticket with the project; the in-memory mirror goes here.
        await cache.delete(id: id, ownerID: ownerID)
        records[id] = nil
        tickets[id] = nil
        pendingBuilds.remove(id)
        guard session.isMember, !id.hasPrefix("ios_") else { return }
        do {
            try await api.deleteChat(id: id)
            await chat.loadConversations()
        } catch {
            Log.ui.error("code project delete failed")
        }
    }

    /// One Code unit per AI edit, exactly where the web charges it. A transport failure fails
    /// **open** — a dead network must not look like a spent quota.
    private func charge() async -> Bool {
        do {
            _ = try await api.usageCharge(product: .code, units: 1, cid: IDs.cid())
            return true
        } catch let error as APIError {
            switch error.status ?? 0 {
            case 429:
                let limit = error.server?.quota?.limit ?? error.server?.limit ?? 0
                toasts.show(
                    Strings.Code.dailyLimit.fmt(lang, ArabicText.count(limit, lang)),
                    isError: true
                )
                if session.isGuest { router.showSignUp(feature: .generic) }
                return false
            case 401, 403:
                if session.isGuest { router.showSignUp(feature: .generic) }
                return false
            default:
                return true
            }
        } catch {
            return true
        }
    }

    // MARK: - Plumbing

    private func appendThreadTurn(role: String, text: String, n: Int? = nil) {
        var messages = thread.messages
        messages.append(
            CodeChatMessage(
                role: role,
                content: String(text.prefix(CodeChatThread.maximumTurnCharacters)),
                at: Date().timeIntervalSince1970 * 1000,
                n: n
            )
        )
        if messages.count > CodeChatThread.maximumTurns {
            messages.removeFirst(messages.count - CodeChatThread.maximumTurns)
        }
        thread = CodeChatThread(messages: messages)
    }

    /// One assistant turn about the build, in the project's own conversation, and the conversation
    /// it now belongs to.
    ///
    /// A build can finish for a reader who is looking at it, a reader who is somewhere else in the
    /// app, and a reader who is not in the app at all. Only the first has `thread` loaded, so the
    /// other two are served through the cached copy — otherwise the record of a build that finished
    /// while the reader was away simply would not exist when they came back to read it.
    private func appendBuildTurn(_ text: String, n: Int?, projectID: String, ownerID: String) async -> CodeChatThread {
        guard !projectID.isEmpty else { return thread }
        if openProjectID == projectID, session.identityID == ownerID {
            appendThreadTurn(role: "ai", text: text, n: n)
            await cache.saveThread(thread, id: projectID, ownerID: ownerID)
            return thread
        }

        var stored = await cache.loadThread(id: projectID, ownerID: ownerID) ?? CodeChatThread()
        stored.messages.append(
            CodeChatMessage(
                role: "ai",
                content: String(text.prefix(CodeChatThread.maximumTurnCharacters)),
                at: Date().timeIntervalSince1970 * 1000,
                n: n
            )
        )
        if stored.messages.count > CodeChatThread.maximumTurns {
            stored.messages.removeFirst(stored.messages.count - CodeChatThread.maximumTurns)
        }
        await cache.saveThread(stored, id: projectID, ownerID: ownerID)
        return stored
    }

    private func adopt(id: String, project incoming: CodeProject, thread incomingThread: CodeChatThread) {
        openProjectID = id
        project = incoming
        thread = incomingThread
        if selectedPath == nil || !incoming.files.contains(where: { $0.path == selectedPath }) {
            selectedPath = Self.entryPath(of: incoming)
        }
        canUndoApply = undoFiles != nil
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            await JobClock.rest(0.9)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        Task { [weak self] in await self?.save() }
    }

    /// Lights the build strip for a build that is about to start in front of the reader.
    private func beginBuildDisplay(projectID: String, startedAt: Date) {
        guard openProjectID == projectID else { return }
        buildStartedAt = startedAt
        buildPhase = .processing
        buildFileCount = 0
        buildElapsed = Date().timeIntervalSince(startedAt)
        startElapsedTimer()
    }

    private func clearBuildDisplay() {
        buildPhase = nil
        buildElapsed = 0
        buildFileCount = 0
        buildStartedAt = nil
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    /// Reconciles the strip with wherever this project's build actually is: in front of the reader,
    /// on its way to the queue, on the queue, or nowhere.
    private func syncBuildState() {
        guard let id = openProjectID else {
            clearBuildDisplay()
            return
        }
        if liveBuilds[id] != nil || startingBuilds.contains(id) || handingOff.contains(id) {
            buildPhase = .processing
            buildStartedAt = tickets[id].map { Date(timeIntervalSince1970: $0.startedAt) } ?? buildStartedAt ?? Date()
        } else if let pointer = jobs.pointer(forConversation: id) {
            buildPhase = pointer.lastPhase
            buildStartedAt = pointer.startedAt
        } else if let ticket = tickets[id] {
            // A ticket with neither a live build nor a pointer: the handover has not landed yet.
            buildPhase = .reconnecting
            buildStartedAt = Date(timeIntervalSince1970: ticket.startedAt)
        } else {
            clearBuildDisplay()
            return
        }
        buildElapsed = Date().timeIntervalSince(buildStartedAt ?? Date())
        startElapsedTimer()
    }

    private func startElapsedTimer() {
        guard elapsedTask == nil else { return }
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                await JobClock.rest(1)
                guard let self else { return }
                guard let id = self.openProjectID, self.buildPhase?.isLive == true else {
                    self.elapsedTask = nil
                    return
                }
                guard self.liveBuilds[id] != nil
                        || self.handingOff.contains(id)
                        || self.tickets[id] != nil
                        || self.jobs.pointer(forConversation: id) != nil else {
                    self.clearBuildDisplay()
                    return
                }
                self.buildElapsed = Date().timeIntervalSince(self.buildStartedAt ?? Date())
            }
        }
    }

    private func refreshRecords() async {
        guard let ownerID = session.identityID else { records = [:]; return }
        let rows = await cache.records(ownerID: ownerID)
        guard session.identityID == ownerID else { return }
        var map: [String: CodeProjectRecord] = [:]
        for row in rows { map[row.id] = row }
        records = map
    }

    private func localSummaries() -> [ChatSummary] {
        records.values
            .filter { $0.isLocal && !pendingDeletes.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { summary(for: $0.id, name: $0.name) }
    }

    private func summary(for id: String, name: String) -> ChatSummary {
        ChatSummary(
            id: id,
            title: name,
            updatedAt: Self.timestamp(),
            createdAt: nil,
            pinned: false,
            agent: false,
            codeProj: true,
            brainNb: false,
            messageCount: nil
        )
    }

    private func presentableText(_ error: Error) -> String {
        switch ErrorPresenter.present(error, feature: .generic, isGuest: session.isGuest, lang: lang) {
        case .toast(let text): return text(lang)
        case .toastText(let text): return text
        case .sessionExpired: return Strings.Errors.sessionExpired(lang)
        default: return Strings.Errors.generic(lang)
        }
    }
}

// MARK: - Copy

/// What a build says for itself — on the strip while it runs, and in the conversation when it
/// changes hands or ends.
///
/// A build used to be silent in the thread: the reader's message went in and nothing came back, so
/// the only evidence anything had happened was a progress strip that, worse, claimed the work was
/// on the server while it was being written on the screen. These four sentences and one strip line
/// are the whole difference between a build that answers and a build that disappears.
///
/// It is its own namespace, in the file that owns the behaviour, because
/// `Localization/Strings+Code.swift` belongs to another engineer this wave — the same reason
/// `Strings.CodeUI` lives in `Features/Code`.
extension Strings {

    enum CodeBuild {

        /// The strip, while the app itself is writing the files. The promise is the same one
        /// `Strings.Code.serverKeep` makes — but in the tense that is actually true right now.
        static let hereLine = LText(
            ar: "يُبنى أمامك الآن — وإن غادرت أكمله الخادم ووجدته جاهزًا حين تعود",
            en: "Being built here, now — leave and the server finishes it, ready when you are back"
        )

        static let doneTurn = LText(
            ar: "جاهز. افتح «الملفات والمعاينة» لتراه يعمل.",
            en: "Ready. Open Files & preview to see it running."
        )
        static let movedTurn = LText(
            ar: "انتقل البناء إلى الخادم ليكمل هناك — أغلق التطبيق إن شئت، سيصلك إشعار حين ينتهي.",
            en: "The build moved to the server to finish there — close the app if you like, you will be told when it lands."
        )
        static let failedTurn = LText(
            ar: "تعثّر البناء ولم ينزل أي ملف. أعد الطلب، ويفضّل بتفاصيل أكثر عمّا تريده.",
            en: "The build did not finish and no files landed. Ask again — with more detail about what you want, if you can."
        )
        static let refusedTurn = LText(
            ar: "لم يُقبل هذا الطلب. جرّب صياغة أخرى، أو تحقّق من رصيدك اليومي.",
            en: "That request was not accepted. Try wording it differently, or check your daily allowance."
        )
    }
}
