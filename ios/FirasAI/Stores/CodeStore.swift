import Foundation
import Observation

nonisolated struct CodeWorkspaceProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var files: [CodeFile]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        files: [CodeFile],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.files = files
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct CodeAttachment: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let context: String
}

private nonisolated struct CodeBuildPointer: Codable, Equatable, Sendable {
    let ownerID: String
    let jobID: String?
    let cid: String
    let projectName: String
    let prompt: String
    let attachmentContext: String
    let language: AppLanguage
    let startedAt: Date

    func with(jobID: String) -> CodeBuildPointer {
        CodeBuildPointer(
            ownerID: ownerID,
            jobID: jobID,
            cid: cid,
            projectName: projectName,
            prompt: prompt,
            attachmentContext: attachmentContext,
            language: language,
            startedAt: startedAt
        )
    }
}

@MainActor
@Observable
final class CodeStore {
    private(set) var projects: [CodeWorkspaceProject] = []
    private(set) var workspace: CodeWorkspaceProject?
    private(set) var selectedFilePath: String?
    private(set) var editorText = ""
    private(set) var attachments: [CodeAttachment] = []
    private(set) var isLoadingProjects = false
    private(set) var isReadingAttachments = false
    private(set) var isBuilding = false
    private(set) var activeJobID: String?
    private(set) var buildPhase: ChatJobPhase?
    private(set) var buildProgress: ChatJobProgress?
    private(set) var buildStartedAt: Date?
    private(set) var buildingProjectName = ""
    var errorMessage: String?

    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let repository: CodeProjectRepository
    @ObservationIgnored private var owningTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let pointerMapKey = "firas.ios.code-builds.v1"

    init(
        session: SessionStore,
        api: FirasAPI = FirasAPI(),
        defaults: UserDefaults = .standard,
        repository: CodeProjectRepository = CodeProjectRepository()
    ) {
        self.session = session
        self.api = api
        self.defaults = defaults
        self.repository = repository
    }

    var currentFile: CodeFile? {
        guard let selectedFilePath else { return nil }
        return workspace?.files.first { $0.path == selectedFilePath }
    }

    var previewHTML: String? {
        guard let files = workspace?.files else { return nil }
        return CodePreviewBuilder.html(from: files)
    }

    var canBuild: Bool { !isBuilding && !isReadingAttachments }

    func loadProjects() async {
        guard !isLoadingProjects else { return }
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        do {
            projects = try await repository.loadAll()
            if workspace == nil, !isBuilding, let first = projects.first {
                open(first)
            }
        } catch {
            errorMessage = message(for: error)
        }
    }

    func open(_ project: CodeWorkspaceProject) {
        commitEditorText()
        workspace = project
        selectFile(path: preferredEntry(in: project.files))
    }

    func showProjectLibrary() {
        commitEditorText()
        workspace = nil
        selectedFilePath = nil
        editorText = ""
    }

    func createBlank(name: String, language: AppLanguage) {
        let cleanName = normalizedName(name, fallback: language == .arabic ? "مشروع جديد" : "new-project")
        let project = CodeWorkspaceProject(
            name: cleanName,
            files: Self.blankFiles(projectName: cleanName, language: language)
        )
        workspace = project
        upsert(project)
        selectFile(path: "index.html")
        save(project)
    }

    func delete(_ project: CodeWorkspaceProject) async {
        do {
            try await repository.delete(id: project.id)
            projects.removeAll { $0.id == project.id }
            if workspace?.id == project.id {
                workspace = nil
                selectedFilePath = nil
                editorText = ""
                if let first = projects.first { open(first) }
            }
        } catch {
            errorMessage = message(for: error)
        }
    }

    func selectFile(path: String?) {
        commitEditorText()
        selectedFilePath = path
        editorText = workspace?.files.first { $0.path == path }?.content ?? ""
    }

    func updateEditorText(_ text: String) {
        editorText = text
        guard var workspace, let selectedFilePath,
              let index = workspace.files.firstIndex(where: { $0.path == selectedFilePath })
        else { return }
        workspace.files[index] = CodeFile(path: selectedFilePath, content: text)
        workspace.updatedAt = Date()
        self.workspace = workspace
        upsert(workspace)
        scheduleSave(workspace)
    }

    func addAttachments(_ urls: [URL], language: AppLanguage) {
        guard !urls.isEmpty, attachmentTask == nil else { return }
        isReadingAttachments = true
        errorMessage = nil
        attachmentTask = Task {
            defer {
                self.isReadingAttachments = false
                self.attachmentTask = nil
            }
            for url in urls {
                if Task.isCancelled { return }
                do {
                    let document = try await BrainDocumentExtractor.extract(url: url)
                    let context = String(document.contextText.prefix(48_000))
                    let attachment = CodeAttachment(
                        id: UUID().uuidString.lowercased(),
                        name: url.lastPathComponent,
                        context: context
                    )
                    self.attachments.append(attachment)
                } catch {
                    self.errorMessage = self.attachmentMessage(for: error, language: language)
                }
            }
        }
    }

    func removeAttachment(_ attachment: CodeAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func startBuild(
        projectName: String,
        prompt: String,
        language: AppLanguage
    ) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty, canBuild else { return }
        guard session.isAuthenticated, let ownerID = session.identityID else {
            errorMessage = language == .arabic
                ? "سجّل الدخول لبناء مشروع وحفظه في السحابة."
                : "Sign in to build a project and keep it running in the cloud."
            return
        }
        let cleanName = normalizedName(projectName, fallback: suggestedName(cleanPrompt, language: language))
        let attachmentContext = attachments.map {
            "[Attachment: \($0.name)]\n\($0.context)"
        }.joined(separator: "\n\n")
        let pointer = CodeBuildPointer(
            ownerID: ownerID,
            jobID: nil,
            cid: stableIdentifier(),
            projectName: cleanName,
            prompt: String(cleanPrompt.prefix(6_000)),
            attachmentContext: String(attachmentContext.prefix(80_000)),
            language: language,
            startedAt: Date()
        )

        isBuilding = true
        activeJobID = nil
        buildPhase = .queued
        buildProgress = nil
        buildStartedAt = pointer.startedAt
        buildingProjectName = pointer.projectName
        errorMessage = nil
        persist(pointer)

        // Store-owned: leaving the Code screen only removes the viewer. It
        // never cancels the durable server build.
        owningTask = Task {
            await self.enqueueAndPoll(pointer)
        }
    }

    func resumeIfNeeded() {
        guard owningTask == nil, activeJobID == nil else { return }
        guard let ownerID = session.identityID,
              let pointer = persistedPointer(for: ownerID)
        else { return }

        isBuilding = true
        activeJobID = pointer.jobID
        buildPhase = .queued
        buildStartedAt = pointer.startedAt
        buildingProjectName = pointer.projectName
        errorMessage = nil
        owningTask = Task {
            if pointer.jobID == nil {
                await self.enqueueAndPoll(pointer)
            } else {
                await self.poll(pointer)
            }
        }
    }

    func clearBuildState() {
        guard !isBuilding else { return }
        activeJobID = nil
        buildPhase = nil
        buildProgress = nil
        buildStartedAt = nil
        buildingProjectName = ""
        errorMessage = nil
    }

    private func enqueueAndPoll(_ initialPointer: CodeBuildPointer) async {
        guard session.identityID == initialPointer.ownerID else {
            finishLocalOwnership()
            return
        }

        var recoveryAttempt = 0
        while !Task.isCancelled {
            do {
                _ = try await api.chargeUsage(product: .code, cid: initialPointer.cid)
                let joinedMessage = initialPointer.prompt + (
                    initialPointer.attachmentContext.isEmpty
                        ? "" : "\n\n" + initialPointer.attachmentContext
                )
                let request = ChatJobRequest(
                    messages: [
                        ChatMessage(
                            role: .user,
                            content: String(joinedMessage.prefix(90_000)),
                            lang: initialPointer.language.rawValue
                        )
                    ],
                    tier: .pro,
                    thinking: true,
                    cid: initialPointer.cid,
                    product: .code,
                    kind: .codeBuild,
                    languageCode: initialPointer.language.rawValue,
                    task: initialPointer.prompt,
                    name: initialPointer.projectName,
                    attach: initialPointer.attachmentContext
                )
                let start = try await startJobWithRetry(request)
                guard session.identityID == initialPointer.ownerID else {
                    finishLocalOwnership()
                    return
                }
                let pointer = initialPointer.with(jobID: start.jobId)
                persist(pointer)
                activeJobID = start.jobId
                if !start.phase.isTerminal {
                    buildPhase = start.phase
                }
                buildProgress = start.progress
                requestCompletionNotifications(language: initialPointer.language)
                if start.phase.isTerminal, let text = start.text {
                    await applyProjectIfComplete(text, pointer: pointer)
                }
                if isBuilding { await poll(pointer) }
                return
            } catch {
                guard session.identityID == initialPointer.ownerID else {
                    finishLocalOwnership()
                    return
                }

                errorMessage = message(for: error)
                guard retryable(error) else {
                    removePersistedPointer(for: initialPointer.ownerID)
                    isBuilding = false
                    activeJobID = nil
                    owningTask = nil
                    return
                }

                // Keep one durable build identity across a lost response or
                // connection. The server and usage ledger deduplicate cid.
                recoveryAttempt += 1
                isBuilding = true
                buildPhase = .queued
                do {
                    try await Task.sleep(for: recoveryDelay(attempt: recoveryAttempt))
                } catch {
                    return
                }
            }
        }
    }

    private func poll(_ pointer: CodeBuildPointer) async {
        guard let jobID = pointer.jobID else { return }
        activeJobID = jobID
        var failures = 0
        var unknowns = 0
        var terminalWithoutProject = 0
        let pollingBegan = Date()

        while !Task.isCancelled {
            guard session.identityID == pointer.ownerID else {
                finishLocalOwnership()
                return
            }

            do {
                let status = try await api.chatJobStatus(id: jobID)
                failures = 0
                if !status.phase.isTerminal {
                    buildPhase = status.phase
                    buildProgress = status.progress
                }

                if status.phase == .unknown {
                    unknowns += 1
                    if unknowns >= 3 {
                        throw APIError.invalidResponse
                    }
                } else {
                    unknowns = 0
                }

                if status.phase.isTerminal {
                    if status.phase.succeeded {
                        if let text = status.text, !text.isEmpty {
                            await applyProjectIfComplete(text, pointer: pointer)
                            if !isBuilding { return }
                        }
                        terminalWithoutProject += 1
                        if terminalWithoutProject > 15 {
                            await finishFailed(
                                pointer,
                                message: "The build finished without a readable Firas project."
                            )
                            return
                        }
                    } else {
                        await finishFailed(pointer, message: status.error ?? "The build did not finish.")
                        return
                    }
                }
            } catch {
                failures += 1
                if failures >= 3 { errorMessage = message(for: error) }
            }

            let elapsed = Date().timeIntervalSince(pollingBegan)
            let delay: Duration
            if terminalWithoutProject > 0 {
                delay = .seconds(4)
            } else if elapsed < 25 {
                delay = .milliseconds(850)
            } else if elapsed < 180 {
                delay = .milliseconds(1_500)
            } else {
                delay = .seconds(3)
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func applyProjectIfComplete(
        _ text: String,
        pointer: CodeBuildPointer
    ) async {
        guard let project = try? CodeProject.decode(fromJobText: text), !project.files.isEmpty else {
            return
        }
        guard await FirasCompletionCue.prepareForReveal(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid
        ),
        !Task.isCancelled,
        session.identityID == pointer.ownerID
        else { return }

        let workspace = CodeWorkspaceProject(
            name: normalizedName(project.name, fallback: pointer.projectName),
            files: project.files
        )
        self.workspace = workspace
        upsert(workspace)
        selectFile(path: preferredEntry(in: workspace.files))
        do {
            try await repository.save(workspace)
        } catch {
            errorMessage = message(for: error)
        }
        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid,
            chatID: nil,
            outcome: .completed
        )
        removePersistedPointer(for: pointer.ownerID)
        isBuilding = false
        activeJobID = nil
        buildPhase = .completed
        buildProgress = nil
        owningTask = nil
        attachments = []
    }

    private func finishFailed(_ pointer: CodeBuildPointer, message: String) async {
        guard await FirasCompletionCue.prepareForReveal(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid
        ),
        !Task.isCancelled,
        session.identityID == pointer.ownerID
        else { return }

        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid,
            chatID: nil,
            outcome: .failed
        )
        removePersistedPointer(for: pointer.ownerID)
        isBuilding = false
        activeJobID = nil
        buildPhase = .failed
        owningTask = nil
        errorMessage = message
    }

    private func startJobWithRetry(_ request: ChatJobRequest) async throws -> ChatJobStartResponse {
        let delays: [Duration] = [.milliseconds(350), .milliseconds(800)]
        for attempt in 0...delays.count {
            do {
                return try await api.startChatJob(request)
            } catch {
                guard attempt < delays.count, retryable(error) else { throw error }
                try await Task.sleep(for: delays[attempt])
            }
        }
        throw APIError.transport(code: -1, message: "The Code build could not be queued.")
    }

    private func retryable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .transport:
            true
        case .httpStatus(let code, _):
            (500...599).contains(code)
        case .invalidResponse, .decoding:
            true
        case .invalidURL, .invalidRequest, .encoding:
            false
        }
    }

    private func recoveryDelay(attempt: Int) -> Duration {
        switch attempt {
        case ...1: .seconds(2)
        case 2: .seconds(4)
        case 3: .seconds(8)
        default: .seconds(15)
        }
    }

    private func requestCompletionNotifications(language: AppLanguage) {
        Task {
            _ = await NotificationCoordinator.shared.requestAuthorizationIfNeeded(
                context: .durableJobStarted,
                preferredLanguageCode: language.rawValue
            )
        }
    }

    private func commitEditorText() {
        guard var workspace, let selectedFilePath,
              let index = workspace.files.firstIndex(where: { $0.path == selectedFilePath }),
              workspace.files[index].content != editorText
        else { return }
        workspace.files[index] = CodeFile(path: selectedFilePath, content: editorText)
        workspace.updatedAt = Date()
        self.workspace = workspace
        upsert(workspace)
        save(workspace)
    }

    private func scheduleSave(_ project: CodeWorkspaceProject) {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(550))
                try await self.repository.save(project)
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = self.message(for: error)
            }
        }
    }

    private func save(_ project: CodeWorkspaceProject) {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await self.repository.save(project)
            } catch {
                self.errorMessage = self.message(for: error)
            }
        }
    }

    private func upsert(_ project: CodeWorkspaceProject) {
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func preferredEntry(in files: [CodeFile]) -> String? {
        files.first { $0.path.lowercased().hasSuffix("index.html") }?.path
            ?? files.first?.path
    }

    private func normalizedName(_ value: String, fallback: String) -> String {
        let clean = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return String((clean.isEmpty ? fallback : clean).prefix(80))
    }

    private func suggestedName(_ prompt: String, language: AppLanguage) -> String {
        let words = prompt.split(whereSeparator: { $0.isWhitespace }).prefix(5)
        let name = words.joined(separator: " ")
        if !name.isEmpty { return String(name.prefix(56)) }
        return language == .arabic ? "مشروع فِراس" : "Firas project"
    }

    private func stableIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func finishLocalOwnership() {
        isBuilding = false
        activeJobID = nil
        buildPhase = nil
        buildProgress = nil
        owningTask = nil
        errorMessage = nil
    }

    private func pointerMap() -> [String: CodeBuildPointer] {
        guard let data = defaults.data(forKey: Self.pointerMapKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CodeBuildPointer].self, from: data)) ?? [:]
    }

    private func persistedPointer(for ownerID: String) -> CodeBuildPointer? {
        pointerMap()[ownerID]
    }

    private func persist(_ pointer: CodeBuildPointer) {
        var map = pointerMap()
        map[pointer.ownerID] = pointer
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.pointerMapKey)
    }

    private func removePersistedPointer(for ownerID: String) {
        var map = pointerMap()
        map.removeValue(forKey: ownerID)
        if map.isEmpty {
            defaults.removeObject(forKey: Self.pointerMapKey)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.pointerMapKey)
        }
    }

    private func attachmentMessage(for error: Error, language: AppLanguage) -> String {
        guard let extraction = error as? BrainExtractionError else { return message(for: error) }
        switch extraction {
        case .officeNeedsExport(let kind):
            return language == .arabic
                ? "صدّر ملف \(kind.rawValue.uppercased()) إلى PDF أو نص قبل إرفاقه."
                : "Export the \(kind.rawValue.uppercased()) file as PDF or text before attaching it."
        case .emptyDocument:
            return language == .arabic
                ? "لم يُعثر على نص قابل للقراءة في المرفق."
                : "No readable text was found in the attachment."
        case .unreadableDocument:
            return language == .arabic ? "تعذّرت قراءة المرفق." : "The attachment could not be read."
        case .unsupportedType(let ext):
            return language == .arabic
                ? "نوع المرفق .\(ext) غير مدعوم."
                : ".\(ext) attachments are not supported."
        }
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "تعذّر الاتصال بالخادم."
        }
        return error.localizedDescription
    }

    private static func blankFiles(projectName: String, language: AppLanguage) -> [CodeFile] {
        let heading = language == .arabic ? "مرحباً من \(projectName)" : "Hello from \(projectName)"
        return [
            CodeFile(
                path: "index.html",
                content: """
                <!doctype html>
                <html lang="\(language.rawValue)" dir="\(language == .arabic ? "rtl" : "ltr")">
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>\(projectName)</title>
                  <link rel="stylesheet" href="styles.css">
                </head>
                <body>
                  <main><h1>\(heading)</h1></main>
                  <script src="app.js"></script>
                </body>
                </html>
                """
            ),
            CodeFile(
                path: "styles.css",
                content: "body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: system-ui, sans-serif; background: #101312; color: #f2f2ee; }"
            ),
            CodeFile(path: "app.js", content: "console.log('Firas Code ready');")
        ]
    }
}

actor CodeProjectRepository {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("FirasAI/CodeProjects", isDirectory: true)
        }
    }

    func loadAll() throws -> [CodeWorkspaceProject] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let project = try? decoder.decode(CodeWorkspaceProject.self, from: data)
            else { return nil }
            return project
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ project: CodeWorkspaceProject) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: url(for: project.id), options: .atomic)
    }

    func delete(id: String) throws {
        try ensureDirectory()
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: String) -> URL {
        let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safeID + ".json", isDirectory: false)
    }
}

private nonisolated enum CodePreviewBuilder {
    static func html(from files: [CodeFile]) -> String? {
        guard let entry = files.first(where: { $0.path.lowercased().hasSuffix("index.html") })
            ?? files.first(where: { $0.path.lowercased().hasSuffix(".html") })
        else { return nil }
        var html = entry.content
        let lookup = files.reduce(into: [String: String]()) { result, file in
            let key = normalized(file.path)
            if result[key] == nil { result[key] = file.content }
        }

        html = replacingMatches(
            in: html,
            pattern: #"<link\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>"#
        ) { match, source in
            guard let reference = capture(1, from: match, in: source),
                  reference.lowercased().hasSuffix(".css"),
                  let content = resolved(reference, lookup: lookup)
            else { return matchText(match, in: source) }
            return "<style>\n\(content)\n</style>"
        }

        html = replacingMatches(
            in: html,
            pattern: #"<script\b[^>]*src=[\"']([^\"']+)[\"'][^>]*>\s*</script>"#
        ) { match, source in
            guard let reference = capture(1, from: match, in: source),
                  let content = resolved(reference, lookup: lookup)
            else { return matchText(match, in: source) }
            return "<script>\n\(content)\n</script>"
        }
        return html
    }

    private static func resolved(_ reference: String, lookup: [String: String]) -> String? {
        let clean = normalized(reference.split(separator: "?", maxSplits: 1).first.map(String.init) ?? reference)
        if let exact = lookup[clean] { return exact }
        let basename = clean.split(separator: "/").last.map(String.init)
        return lookup.first { key, _ in key.split(separator: "/").last.map(String.init) == basename }?.value
    }

    private static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))
            .lowercased()
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        let source = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: source.length))
        var result = value
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(match, source))
        }
        return result
    }

    private static func capture(
        _ index: Int,
        from match: NSTextCheckingResult,
        in source: NSString
    ) -> String? {
        guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else { return nil }
        return source.substring(with: match.range(at: index))
    }

    private static func matchText(_ match: NSTextCheckingResult, in source: NSString) -> String {
        source.substring(with: match.range)
    }
}
