import Foundation
import Observation
import OSLog

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

/// Firas Code's whole model: the project list, the open project, its AI thread, the server build
/// and every file mutation.
///
/// Two facts shape everything here. **A project is a chat** with `codeProj: true` whose
/// `messages[0]` is a ```` ```firas-project ```` fence and whose `messages[1]` is the base64
/// ```` ```firas-code-chat ```` thread (`web-code-ux.md §0.1`, `§1`) — so the same project opens on
/// the web, on another device, and here. And **a build is a server job**: the app hands it to the
/// queue with `chatId: ""` and lands the files itself, which is why leaving the app cannot lose a
/// build and why a pointer is never forgotten before the files are written (`§3.3`).
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
    @ObservationIgnored private var buildNames: [String: String] = [:]

    /// The web's caps. `task` carries the attachment read as well, because the frozen
    /// `ChatJobRequest` has no `attach` field; the worker reads `body.task` either way.
    static let taskCharacterCap = 6_000
    static let attachmentCharacterCap = 24_000
    static let inIDEAttachmentCap = 60_000
    static let nameCharacterCap = 80

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

    /// True while the durable queue is still building this project.
    func isBuilding(projectID: String) -> Bool {
        jobs.pointer(forConversation: projectID) != nil
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

    func loadProjects() async {
        isLoadingProjects = true
        listError = nil
        await refreshRecords()

        if session.isMember {
            do {
                let all = try await api.listChats()
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
        deletedLastProject = false
        await cache.save(scaffold, id: id)
        await refreshRecords()
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
        guard !id.isEmpty else { return }
        isOpening = true
        openError = nil
        usingCachedCopy = false
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

        if let cached = await cache.load(id: id) {
            let cachedThread = await cache.loadThread(id: id) ?? CodeChatThread()
            adopt(id: id, project: cached, thread: cachedThread)
        }

        if session.isMember, !id.hasPrefix("ios_") {
            do {
                let conversation = try await api.getChat(id: id)
                if let parsed = Self.parse(conversation) {
                    adopt(id: id, project: parsed.project, thread: parsed.thread)
                    await cache.save(parsed.project, id: id)
                    await cache.saveThread(parsed.thread, id: id)
                    await refreshRecords()
                } else if project == nil {
                    // A codeProj chat whose messages[0] is not a project fence: an empty shell.
                    adopt(id: id, project: CodeProject(name: conversation.title, files: []), thread: CodeChatThread())
                }
            } catch {
                if project == nil {
                    openError = presentableText(error)
                } else {
                    usingCachedCopy = true
                }
            }
        }

        if project == nil, openError == nil {
            openError = Strings.Code.workspaceMissing(lang)
        }
        syncBuildState()
        isOpening = false
    }

    /// Leaves the workspace. The launcher must never keep a half-open project alive behind it.
    func closeProject() {
        commitTask?.cancel()
        commitTask = nil
        elapsedTask?.cancel()
        elapsedTask = nil
        openProjectID = nil
        project = nil
        thread = CodeChatThread()
        selectedPath = nil
        consoleLines = []
        buildPhase = nil
        buildElapsed = 0
        buildFileCount = 0
        canUndoApply = false
        undoFiles = nil
        saveState = .saved
    }

    func delete(_ id: String) async {
        let index = projects.firstIndex { $0.id == id }
        let removed = index.map { projects[$0] }
        if let index { projects.remove(at: index) }
        if projects.isEmpty { deletedLastProject = true }
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
            await self?.commitDelete(id)
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
        guard let id = openProjectID, let current = project else { return }
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

        await cache.save(fitted, id: id)
        await cache.saveThread(thread, id: id)
        records[id] = CodeProjectRecord(
            id: id,
            name: fitted.name,
            fileCount: fitted.files.count,
            updatedAt: Date().timeIntervalSince1970
        )

        if session.isMember, !id.hasPrefix("ios_") {
            do {
                try await push(project: fitted, thread: thread, to: id)
            } catch {
                saveState = .editing
                toasts.show(Strings.Code.saveFailed(lang), isError: true)
                return
            }
        }
        saveState = .saved
    }

    // MARK: - AI edits

    func askAI(instruction: String, attachments: [PreparedAttachment]) async -> CodeEditPlan? {
        guard !isAsking, let current = project else { return nil }
        let attachText = Self.attachmentText(attachments, cap: Self.inIDEAttachmentCap)
        var request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.isEmpty, !attachText.isEmpty {
            request = Strings.Code.attachmentsOnly(lang)
        }
        guard !request.isEmpty else { return nil }

        var turn = String(request.prefix(CodeAskAI.requestLimit))
        if !attachments.isEmpty {
            turn += "\n\n" + Strings.Code.attachmentCount.fmt(lang, ArabicText.count(attachments.count, lang))
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
        guard await charge() else { return nil }

        do {
            let outcome = try await CodeAskAI.run(
                api: api,
                project: current,
                instruction: request,
                attachmentText: attachText,
                lang: lang
            )
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

    func startBuild(projectID: String, name: String, brief: String, attach: String) async {
        guard let owner = session.identityID, !owner.isEmpty else {
            toasts.show(Strings.Errors.sessionExpired(lang), isError: true)
            return
        }
        let cid = IDs.cid()
        var task = String(brief.prefix(Self.taskCharacterCap))
        if !attach.isEmpty {
            task += "\n\n" + String(attach.prefix(Self.attachmentCharacterCap))
        }

        let request = ChatJobRequest(
            messages: [OutgoingMessage(role: "user", content: task, images: nil)],
            tier: ModelTier.pro.rawValue,
            think: false,
            cid: cid,
            // Always empty: a real id makes the worker append the raw fence as a third message
            // into the project chat (`server-code-brainask.md §2.1`).
            chatId: "",
            product: ProductKind.code.wireValue,
            kind: JobKind.codebuild.rawValue,
            lang: lang.rawValue,
            title: String(name.prefix(Self.nameCharacterCap)),
            task: task
        )
        let spec = JobKindSpecs.spec(.codebuild)
        let started = Date()
        let draft = JobPointer(
            id: cid,
            kind: .codebuild,
            ownerID: owner,
            cid: cid,
            conversationID: projectID,
            projectID: projectID,
            title: String(name.prefix(Self.nameCharacterCap)),
            lang: lang.rawValue,
            startedAt: started,
            deadline: started.addingTimeInterval(spec.deadline)
        )

        do {
            let pointer = try await jobs.startChatQueueJob(request, pointer: draft)
            buildNames[pointer.id] = name
            if openProjectID == projectID {
                buildPhase = pointer.lastPhase
                buildElapsed = 0
                startElapsedTimer()
            }
            toasts.show(Strings.Code.serverKeep(lang))
        } catch {
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
                break
            }
        }
    }

    /// Retry after a failed build: a new `cid`, the same brief.
    func rebuild(brief: String) async {
        guard let id = openProjectID else { return }
        await startBuild(projectID: id, name: openProjectName, brief: brief, attach: "")
    }

    // MARK: - JobObserver

    func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot) {
        guard pointer.kind == .codebuild, let projectID = pointer.projectID else { return }
        if openProjectID == projectID {
            buildPhase = snapshot.phase
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
        guard let projectID = pointer.projectID else { return true }
        let name = buildNames[pointer.id] ?? pointer.title
        var landedAnything = landedFences[pointer.id] != nil

        if let snapshot = terminal.snapshot,
           let finished = try? CodeProject.decode(fromJobText: snapshot.text),
           !finished.files.isEmpty {
            // Land before forget: a false answer here buys another 15 × 4 s of retries.
            guard await land(finished, into: projectID, pointer: pointer) else { return false }
            landedAnything = true
        }

        if openProjectID == projectID {
            buildPhase = nil
            buildElapsed = 0
            elapsedTask?.cancel()
            elapsedTask = nil
        }
        landedFences[pointer.id] = nil
        buildNames[pointer.id] = nil

        announce(projectID: projectID, name: name, landed: landedAnything, terminal: terminal)
        return true
    }

    // MARK: - Landing

    private func land(_ built: CodeProject, into projectID: String, pointer: JobPointer) async -> Bool {
        let named = CodeProject(
            name: built.name.isEmpty ? pointer.title : built.name,
            files: built.files
        )
        let fitted = Self.shrunkToFit(named)
        if case .failure(let error) = fitted.validatedForSave() {
            toasts.show(Self.saveErrorText(error, lang: lang), isError: true)
            return true                                   // nothing left to try; release the pointer
        }

        await cache.save(fitted, id: projectID)
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
                existing = await cache.loadThread(id: projectID) ?? CodeChatThread()
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
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = String((raw.isEmpty ? Strings.Code.projectFallbackName(lang) : raw).prefix(40))

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
            toasts.show(Strings.Code.serverFailed.fmt(lang, display), isError: true)
            return
        }

        if openProjectID == projectID {
            toasts.show(Strings.Code.serverDone(lang))
        } else {
            toasts.show(
                Strings.Code.serverReady.fmt(lang, display),
                actionTitle: Strings.Code.serverOpen(lang),
                duration: 9
            ) { [weak self] in
                self?.router.open(.code(projectID: projectID))
            }
        }
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

    private func commitDelete(_ id: String) async {
        guard pendingDeletes.contains(id) else { return }
        pendingDeletes.remove(id)
        await cache.delete(id: id)
        records[id] = nil
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

    private func syncBuildState() {
        guard let id = openProjectID, let pointer = jobs.pointer(forConversation: id) else {
            buildPhase = nil
            buildElapsed = 0
            elapsedTask?.cancel()
            elapsedTask = nil
            return
        }
        buildPhase = pointer.lastPhase
        buildElapsed = Date().timeIntervalSince(pointer.startedAt)
        startElapsedTimer()
    }

    private func startElapsedTimer() {
        guard elapsedTask == nil else { return }
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                await JobClock.rest(1)
                guard let self else { return }
                guard let id = self.openProjectID,
                      let pointer = self.jobs.pointer(forConversation: id) else {
                    self.buildPhase = nil
                    self.elapsedTask = nil
                    return
                }
                self.buildElapsed = Date().timeIntervalSince(pointer.startedAt)
            }
        }
    }

    private func refreshRecords() async {
        let rows = await cache.records()
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
