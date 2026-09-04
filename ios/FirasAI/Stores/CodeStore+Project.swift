import Foundation

/// What is being built, decided from the brief alone.
///
/// The worker runs a model call for this (`codeClassify`, `server-code-brainask.md §2.3` step 3)
/// and then lets four sets of decisive nouns overrule the model's answer anyway. On the client only
/// the nouns are kept: a round trip *before the reader sees anything* is precisely what a live build
/// exists to remove, and the kind decides only which fallback skeleton is used and one sentence of
/// the per-file prompt.
enum CodeBuildKind: String, Sendable, Equatable {
    case site
    case game
    case dashboard
    case mobile
    case desktop
    case native
    case cli
    case api
    case library
    case data
    case software

    var usesBrowserPreview: Bool {
        switch self {
        case .site, .game, .dashboard: return true
        case .mobile, .desktop, .native, .cli, .api, .library, .data, .software: return false
        }
    }
}

/// One planned file: the path the build will write, and the one line the planner said it does.
struct CodeBuildStep: Sendable, Equatable {
    let path: String
    let does: String

    init(path: String, does: String) {
        self.path = path
        self.does = does
    }
}

/// The pure half of `CodeStore`: parsing a project chat, naming, path hygiene, the save-caps
/// shrink loop, the attachment fold, and every prompt the live builder sends. Nothing here touches
/// store state, so all of it is `nonisolated` and safe to run from a detached task.
extension CodeStore {

    // MARK: - Reading a project chat

    /// `messages[0]` is the project fence and `messages[1]` the thread, but a chat written by an
    /// older client can carry them anywhere, so both are found by shape rather than by index.
    nonisolated static func parse(_ conversation: ChatConversation) -> (project: CodeProject, thread: CodeChatThread)? {
        var found: CodeProject?
        var thread = CodeChatThread()
        for message in conversation.messages {
            let content = message.content
            if found == nil, content.contains("```firas-project"),
               let decoded = try? CodeProject.decode(fromJobText: content) {
                found = decoded
                continue
            }
            if content.contains("```firas-code-chat"),
               let decoded = CodeChatThread.decode(fromFence: content) {
                thread = decoded
            }
        }
        guard var project = found else { return nil }
        if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project = CodeProject(name: conversation.title, files: project.files)
        }
        return (project, thread)
    }

    // MARK: - Naming

    /// `cwDeriveName`: the typed name wins; otherwise the first clause of the brief without its
    /// build lead-in and its generic noun, cut at 48 characters on a word boundary.
    nonisolated static func resolveName(typed: String, brief: String, lang: AppLanguage) -> String {
        let manual = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return String(manual.prefix(60)) }

        var text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = text.firstIndex(where: { $0 == "\n" || $0 == "." || $0 == "،" || $0 == "," }) {
            text = String(text[..<cut])
        }
        let lowered = text.lowercased()
        for lead in nameLeadIns where lowered.hasPrefix(lead) {
            text = String(text.dropFirst(lead.count))
            break
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for noun in nameGenericNouns where text.hasPrefix(noun) {
            text = String(text.dropFirst(noun.count))
            break
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 48 {
            let clipped = String(text.prefix(48))
            if let space = clipped.lastIndex(of: " ") {
                text = String(clipped[..<space])
            } else {
                text = clipped
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Strings.Code.defaultProjectName(lang) : text
    }

    private nonisolated static var nameLeadIns: [String] {
        [
            "build me ", "build ", "create me ", "create ", "make me ", "make ",
            "design ", "write ", "develop ",
            "ابنِ ", "ابن ", "اصنع ", "أنشئ ", "انشئ ", "اعمل ", "سوّي ", "سوي ",
            "صمّم ", "صمم ", "اكتب ", "أريد ", "اريد "
        ]
    }

    private nonisolated static var nameGenericNouns: [String] {
        ["موقع ", "تطبيق ", "صفحة ", "برنامج ", "لي "]
    }

    // MARK: - Paths

    /// `cwSanitizePath`: strip leading slashes, collapse doubles, fold anything unsafe to `-`.
    nonisolated static func sanitizePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") { path.removeFirst() }
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }

        var out = ""
        var lastWasDash = false
        for character in path {
            if character.isLetter || character.isNumber || character == "." || character == "/"
                || character == "_" || character == "-" || character == " " {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".") }
        return String(out.prefix(CodeProject.maximumPathLength))
    }

    /// The entry page the preview opens on, and the file the editor lands on.
    nonisolated static func entryPath(of project: CodeProject) -> String? {
        if let index = project.files.first(where: {
            let lower = $0.path.lowercased()
            return lower.hasSuffix("index.html") || lower.hasSuffix("index.htm")
        }) {
            return index.path
        }
        if let html = project.files.first(where: { $0.ext == "html" || $0.ext == "htm" }) {
            return html.path
        }
        return project.files.first?.path
    }

    // MARK: - Save caps

    nonisolated static func localOnlyText(_ error: CodeSaveError, lang: AppLanguage) -> String {
        let detail = saveErrorText(error, lang: lang)
        return lang == .arabic
            ? "الملفات محفوظة كاملة على هذا الجهاز ويمكن تصديرها. لم تتم المزامنة: " + detail
            : "Complete files are saved on this device and can be exported. Cloud sync needs attention: " + detail
    }

    nonisolated static func saveErrorText(_ error: CodeSaveError, lang: AppLanguage) -> String {
        switch error {
        case .tooManyFiles: return Strings.Code.fileLimitReached(lang)
        case .pathTooLong: return Strings.Code.pathTooLong(lang)
        case .fileTooLarge(let path): return Strings.Code.fileTooLarge.fmt(lang, path)
        case .projectTooLarge: return Strings.Code.projectTooLarge(lang)
        }
    }

    // MARK: - Attachments

    /// Attachments are already text by the time they reach here (`PreparedAttachment.text`);
    /// image bytes never ride a job record — the 600 000-character body ceiling refuses them.
    nonisolated static func attachmentText(_ attachments: [PreparedAttachment], cap: Int) -> String {
        let blocks = attachments.compactMap { attachment -> String? in
            guard let text = attachment.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return "===== FILE: " + attachment.name + " =====\n" + text
                + "\n===== END FILE: " + attachment.name + " ====="
        }
        guard !blocks.isEmpty else { return "" }
        let header = "\n\nATTACHED FILE(S) — the user attached these to this request. "
            + "Read them and build or edit to match.\n\n"
        let joined = header + blocks.joined(separator: "\n\n")
        guard joined.count > cap else { return joined }
        let suffix = "\n[… attachment truncated to fit this request's budget]"
        let room = max(2_000, cap - suffix.count)
        return String(joined.prefix(room)) + suffix
    }

    // MARK: - The connected repository

    /// Which of a repository's files are worth spending the prompt budget on for THIS request.
    ///
    /// The ranking is deliberately blunt, because the reader's own words are nearly always the
    /// answer: a path or a file name they typed comes first, then the README, then the handful of
    /// names that give a repository its shape. Anything vendored is out — nobody has ever asked a
    /// question whose answer was in `node_modules` — and so is anything that is not text, because
    /// `GET /api/github/file` refuses it anyway and a refusal costs the same round trip.
    nonisolated static func repositoryFocus(
        request: String,
        tree: [CodeGitHubTreeEntry],
        limit: Int
    ) -> [String] {
        let lowered = request.lowercased()
        var ranked: [(path: String, rank: Int, size: Int)] = []
        var shallow: [(path: String, size: Int)] = []

        for entry in tree {
            let path = entry.path
            let lowerPath = path.lowercased()
            guard !isVendoredPath(lowerPath), isReadableSourcePath(lowerPath),
                  !CodeEngineeringGuidance.isSensitivePath(path) else { continue }
            guard entry.size <= repositoryFileByteCeiling else { continue }
            let name = entry.name.lowercased()

            var rank = -1
            if lowered.contains(lowerPath) {
                rank = 0
            } else if name.count >= 4, CodeAskAI.containsToken(lowered, name) {
                rank = 1
            } else if name.hasPrefix("readme") {
                rank = 2
            } else if repositoryEntryNames.contains(name) {
                rank = 3
            }

            if rank >= 0 {
                ranked.append((path, rank, entry.size))
            } else if lowerPath.components(separatedBy: "/").count <= 2 {
                // Nothing pointed at it, but it sits at the top of the repository, so it is at
                // least the kind of file somebody would open first.
                shallow.append((path, entry.size))
            }
        }

        // Closures, not key paths: `\.path` cannot address a tuple element.
        var chosen = ranked
            .sorted { $0.rank == $1.rank ? $0.size < $1.size : $0.rank < $1.rank }
            .map { $0.path }
        let spares = shallow.sorted { $0.size < $1.size }.map { $0.path }
        for candidate in spares {
            guard chosen.count < limit else { break }
            guard !chosen.contains(candidate) else { continue }
            chosen.append(candidate)
        }
        return Array(chosen.prefix(limit))
    }

    /// The repository, as the model sees it: the file list, then the bodies that were read.
    ///
    /// The first sentence is the one that matters. Without it the edit prompt — which orders the
    /// model to output the complete content of every file it touches — reads a repository file as
    /// one more file of the project and cheerfully copies it in.
    nonisolated static func repositoryBlock(
        repo: String,
        branch: String,
        tree: [CodeGitHubTreeEntry],
        truncated: Bool,
        files: [CodeFile]
    ) -> String {
        guard !tree.isEmpty else { return "" }
        var out = "\n\nCONNECTED GITHUB REPOSITORY — this session is pointed at " + repo
        if !branch.isEmpty { out += " on branch " + branch }
        out += ".\n"
        out += "This repository is READ-ONLY CONTEXT. Answer questions about it, and match its "
        out += "conventions when you write. NEVER output a ```file: block, a DELETE: line or a "
        out += "RENAME: line for one of its paths — the files you write belong to the project "
        out += "above, never to this repository, and nothing you output is committed anywhere.\n"
        out += "\nREPOSITORY FILES"
        if truncated { out += " (GitHub stopped listing before the end)" }
        out += ":\n"

        var rows = 0
        var listing = ""
        for entry in tree {
            guard rows < repositoryTreeRows, listing.count < repositoryTreeCharacters else { break }
            listing += entry.path + "\n"
            rows += 1
        }
        out += listing
        if tree.count > rows {
            out += "… and " + String(tree.count - rows) + " more files not listed\n"
        }

        for file in files where !file.content.isEmpty
            && !CodeEngineeringGuidance.isSensitivePath(file.path)
            && !CodeEngineeringGuidance.containsPrivateKey(file.content) {
            out += "\n===== REPO FILE: " + file.path + " =====\n"
            out += file.content
            out += "\n===== END REPO FILE: " + file.path + " =====\n"
        }
        return out
    }

    private nonisolated static func isVendoredPath(_ lowerPath: String) -> Bool {
        for segment in repositoryIgnoredSegments {
            if lowerPath.hasPrefix(segment + "/") { return true }
            if lowerPath.contains("/" + segment + "/") { return true }
        }
        return false
    }

    private nonisolated static func isReadableSourcePath(_ lowerPath: String) -> Bool {
        let name = lowerPath.components(separatedBy: "/").last ?? lowerPath
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return repositoryExtensionlessNames.contains(name)
        }
        return repositoryTextExtensions.contains(String(name[name.index(after: dot)...]))
    }

    private nonisolated static var repositoryIgnoredSegments: [String] {
        [
            "node_modules", ".git", "dist", "build", "out", "vendor", "pods", ".next", "target",
            "coverage", ".venv", "venv", "__pycache__", "deriveddata", ".yarn", ".gradle"
        ]
    }

    private nonisolated static var repositoryTextExtensions: Set<String> {
        [
            "swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "html", "htm", "css", "scss",
            "less", "md", "markdown", "txt", "yml", "yaml", "toml", "xml", "py", "rb", "go", "rs",
            "java", "kt", "kts", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "sql",
            "gradle", "cfg", "ini", "plist", "vue", "svelte"
        ]
    }

    private nonisolated static var repositoryExtensionlessNames: Set<String> {
        ["readme", "license", "dockerfile", "makefile", "procfile"]
    }

    private nonisolated static var repositoryEntryNames: Set<String> {
        [
            "readme.md", "package.json", "index.html", "index.js", "index.ts", "main.js",
            "main.ts", "app.js", "app.ts", "main.swift", "app.swift", "server.js", "server.mjs",
            "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "pubspec.yaml",
            "gemfile", "pom.xml", "build.gradle", "makefile", "dockerfile"
        ]
    }

    // MARK: - New files

    /// What a brand-new file starts with. An HTML page follows the UI language, exactly like the
    /// web's "Create index.html" starter.
    nonisolated static func starterContent(for path: String, lang: AppLanguage) -> String {
        let ext = path.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        switch ext {
        case "html", "htm":
            let direction = lang == .arabic ? "rtl" : "ltr"
            let code = lang == .arabic ? "ar" : "en"
            let title = lang == .arabic ? "صفحتي" : "My page"
            let heading = lang == .arabic ? "مرحبًا" : "Hello"
            return "<!DOCTYPE html>\n<html lang=\"" + code + "\" dir=\"" + direction + "\">\n<head>\n"
                + "  <meta charset=\"UTF-8\">\n"
                + "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
                + "  <title>" + title + "</title>\n</head>\n<body>\n  <h1>" + heading + "</h1>\n</body>\n</html>\n"
        case "css":
            return ":root {\n  color-scheme: light dark;\n}\n"
        case "js", "mjs":
            return "// " + path + "\n"
        case "json":
            return "{\n}\n"
        case "md", "markdown":
            return "# " + path + "\n"
        default:
            return ""
        }
    }

    nonisolated static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    // MARK: - The handover payload

    /// The `task` a handed-over build sends. The worker prefers `body.task` and falls back to the
    /// last user message, so the two carry the same text and an older deploy still builds the right
    /// thing (`server-code-brainask.md §2.1`). The attachment rides inside `task` because the frozen
    /// `ChatJobRequest` has no `attach` field.
    nonisolated static func jobTask(_ ticket: CodeBuildTicket) -> String {
        var task = String(ticket.brief.prefix(taskCharacterCap))
        if !ticket.attach.isEmpty {
            task += "\n\n" + String(ticket.attach.prefix(attachmentCharacterCap))
        }
        return task
    }

    // MARK: - The live build: what the request says about itself

    /// The worker measures the script of the brief and lets it overrule everything, including the
    /// `lang` field the client sent (`server-code-brainask.md §2.3` step 3). An Arabic brief must
    /// produce an Arabic, RTL project even when the app is in English, so the same measurement runs
    /// here: at least twelve letters, and one script outnumbering the other three to one.
    nonisolated static func measuredLanguage(brief: String, fallback: AppLanguage) -> AppLanguage {
        var arabic = 0
        var latin = 0
        for scalar in brief.unicodeScalars {
            if scalar.value >= 0x0600, scalar.value <= 0x06FF {
                arabic += 1
            } else if (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) {
                latin += 1
            }
        }
        guard arabic + latin >= 12 else { return fallback }
        if arabic > latin * 3 { return .arabic }
        if latin > arabic * 3 { return .english }
        return fallback
    }

    /// The worker's decisive nouns, in its own order — first hit wins (`§2.3` step 3).
    nonisolated static func buildKind(for brief: String) -> CodeBuildKind {
        let lowered = String(brief.prefix(2_000)).lowercased()
        let normalized = ArabicText.normalize(String(brief.prefix(2_000)))
        // An explicit runtime must survive incidental words such as an HTML
        // report produced by Python, or an iOS game written in Swift.
        let spec = CodeSpec.detect(brief)
        if ["swift", "kotlin"].contains(spec.lang) { return .native }
        if ["python", "rust", "go", "java", "csharp", "cpp", "c", "ruby", "php", "bash", "powershell", "sql", "r"].contains(spec.lang) {
            return .software
        }
        for (kind, latin, arabic) in kindNouns {
            for token in latin where CodeAskAI.containsToken(lowered, token) {
                return kind
            }
            for word in arabic where normalized.contains(ArabicText.normalize(word)) {
                return kind
            }
        }
        return .site
    }

    private nonisolated static var kindNouns: [(CodeBuildKind, [String], [String])] {
        [
            (.cli, ["cli", "command-line", "command line", "shell script"], ["سطر الأوامر", "سكربت", "أتمتة"]),
            (.api, ["api", "backend", "rest", "graphql", "server", "microservice"], ["واجهة برمجية", "خادم", "باك اند"]),
            (.library, ["library", "sdk", "package", "plugin"], ["مكتبة برمجية", "حزمة برمجية"]),
            (.data, ["data analysis", "data pipeline", "machine learning", "notebook", "sql"], ["تحليل بيانات", "تعلم آلي", "قاعدة بيانات"]),
            (.game,
             ["game", "arcade", "platformer", "shooter", "puzzle"],
             ["لعبة", "لعبه", "العاب", "ألعاب"]),
            (.dashboard,
             ["dashboard", "analytics panel"],
             ["لوحة تحكم", "لوحة معلومات", "داشبورد"]),
            (.mobile,
             ["ios", "android", "iphone", "app store", "play store"],
             ["تطبيق هاتف", "تطبيق جوال", "تطبيق موبايل", "تطبيق ايفون", "تطبيق أيفون",
              "تطبيق اندرويد", "تطبيق أندرويد"]),
            (.desktop,
             ["electron", "desktop app", "windows app"],
             ["برنامج كمبيوتر", "برنامج حاسوب", "برنامج ويندوز"])
        ]
    }

    /// The worker's per-kind skeleton, used only when the planner came back with fewer than two
    /// usable files (`§2.3` step 5).
    nonisolated static func skeleton(for kind: CodeBuildKind, brief: String = "") -> [String] {
        switch kind {
        case .game: return ["styles.css", "js/game.js", "js/state.js"]
        case .dashboard: return ["styles.css", "js/data.js", "js/charts.js", "js/app.js"]
        case .mobile, .desktop, .native, .cli, .api, .library, .data, .software:
            let spec = CodeSpec.detect(brief)
            return spec.lang == "html" ? ["README.md"] : [spec.filename, "README.md"]
        case .site: return ["styles.css", "js/app.js"]
        }
    }

    /// One sentence of the per-file system prompt, standing in for the worker's `CODE_KINDS` entry.
    nonisolated static func kindMandate(_ kind: CodeBuildKind) -> String {
        switch kind {
        case .site:
            return "This is a real website: real sections with real written content, a considered layout, and working navigation — never a placeholder page."
        case .game:
            return "This is a playable game: a real loop, real input handling, real scoring and real feedback. It must be fun to play the moment it opens."
        case .dashboard:
            return "This is a dashboard: generated but plausible data, real charts drawn in code or via one pinned CDN library, and filters that actually filter."
        case .mobile:
            return "This is a phone app. Honor the requested native or cross-platform stack; include its app entry, build configuration and setup instructions. Respect safe areas, accessibility and thumb-sized controls. Use a web wrapper only if it was requested."
        case .desktop:
            return "This is a desktop application. Honor the requested platform and runtime, with its build configuration, window lifecycle, keyboard actions and setup instructions. Do not substitute an HTML mockup."
        case .native:
            return "This is native application source. Use the explicitly requested platform APIs and language, correct lifecycle and state ownership, cancellation/error handling, accessibility, and real project configuration. No HTML replacement."
        case .cli:
            return "This is a command-line tool or automation. Include argument parsing, useful help, validation, exit codes, deterministic output and safe filesystem behavior."
        case .api:
            return "This is a service/API. Include concrete routes and schemas, authentication when needed, validation, bounded requests, safe errors, configuration and focused endpoint tests."
        case .library:
            return "This is a reusable library/SDK. Include a small documented API, package manifest, working usage examples and focused tests. Avoid side effects on import."
        case .data:
            return "This is a data/analysis project. Include explicit input schemas, missing-value handling, correct calculations, reproducible execution and labeled outputs; distinguish demonstration data from supplied measurements."
        case .software:
            return "This is source code in the runtime the request names. Deliver runnable source, matching dependencies and setup instructions, and relevant tests; a browser preview is not required."
        }
    }

    // MARK: - The live build: prompts

    /// The plan. One call, one JSON array, no prose — the reader is already watching the console by
    /// the time it returns.
    private nonisolated static var planSystemPrompt: String {
        #"""
        You are the architect of the software requested by the user. Plan its files and NOTHING else.

        STRICT OUTPUT FORMAT: one JSON array and nothing around it — no prose, no markdown fence:
        [{"path":"relative/path.ext","does":"one short sentence"}]

        RULES:
        - Plan the number of files the request needs, normally 1–20. Put the entry point or essential shared interfaces first. Native apps, scripts, APIs, libraries, data projects and configuration do not require any HTML file.
        - Respect the user's requested language/runtime and existing conventions. Include build/dependency configuration and README instructions when needed. For a browser-only website, use index.html with plain HTML/CSS/JS and pinned CDN libraries when useful.
        - Paths are relative, use forward slashes, contain no "..", and are at most 120 characters.
        - Plan only files you would actually write in full. A file nobody can fill is a broken project.
        - Split responsibilities when useful; do not invent unrelated files to reach a file count. Keep each file below 60000 characters and the complete project below 180000 characters without truncating source.
        """# + "\n\n" + CodeEngineeringGuidance.core
    }

    nonisolated static func planMessages(
        projectName: String,
        brief: String,
        attach: String,
        uiLang: AppLanguage
    ) -> [OutgoingMessage] {
        var user = "PROJECT: " + projectName + "\n\nBRIEF:\n" + String(brief.prefix(taskCharacterCap))
        if !attach.isEmpty {
            user += "\n\n" + String(attach.prefix(planAttachmentLimit))
        }
        user += "\n\nUI LANGUAGE: " + (uiLang == .arabic ? "Arabic" : "English")
        user += "\n\nPROJECT REQUIREMENTS: " + kindMandate(buildKind(for: brief))
        return [
            OutgoingMessage(role: "system", content: planSystemPrompt),
            OutgoingMessage(role: "user", content: user)
        ]
    }

    /// One file, streamed straight into the editor. The rules are the worker's raw-file rules plus
    /// the two the preview imposes here (no build step, no same-origin storage).
    private nonisolated static func fileSystemPrompt(kind: CodeBuildKind, uiLang: AppLanguage) -> String {
        let language = uiLang == .arabic
            ? "UI text is in ARABIC; the document must set lang=\"ar\" and dir=\"rtl\"."
            : "UI text is in ENGLISH."
        return #"""
        You are an elite senior software engineer writing ONE file of a project that is being built in front of the user, right now, on their screen.

        STRICT OUTPUT FORMAT: output the COMPLETE raw content of that one file and NOTHING else — no markdown fence, no commentary before it, no explanation after it.

        RULES:
        - Write the file from its first character to its last. NEVER write "TODO", "FIXME", "... rest of the code", "goes here", "your code here", "omitted for brevity", "remains the same" or any other placeholder — a truncated file is a broken project.
        - Match the manifest exactly: every path you reference must be one of the planned paths, spelled the same way.
        - Use the language and runtime the brief and manifest require. The app's HTML preview does not restrict the file types you can write. Browser previews have no same-origin storage; native apps and services follow their own runtime rules.
        - Keep this file complete and below 60000 characters. Match shared interfaces in the previously written files.
        """# + "\n- " + language + "\n- " + kindMandate(kind) + "\n\n" + CodeEngineeringGuidance.core
    }

    nonisolated static func fileMessages(
        step: CodeBuildStep,
        projectName: String,
        brief: String,
        attach: String,
        kind: CodeBuildKind,
        uiLang: AppLanguage,
        manifest: [CodeBuildStep],
        written: [String],
        writtenFiles: [CodeFile] = []
    ) -> [OutgoingMessage] {
        var user = "PROJECT: " + projectName + "\n\nWHAT THE USER ASKED FOR:\n"
            + String(brief.prefix(fileBriefLimit))
        if !attach.isEmpty {
            user += "\n\n" + String(attach.prefix(fileAttachmentLimit))
        }
        user += "\n\nFILE MANIFEST — the whole project, in build order:\n"
        for entry in manifest {
            user += "- " + entry.path + (entry.does.isEmpty ? "" : " — " + entry.does) + "\n"
        }
        user += "\nALREADY WRITTEN: " + (written.isEmpty ? "nothing yet" : written.joined(separator: ", "))
        var remainingContext = 24_000
        for file in writtenFiles.reversed() where remainingContext > 0 {
            guard !CodeEngineeringGuidance.isSensitivePath(file.path),
                  !CodeEngineeringGuidance.containsPrivateKey(file.content) else { continue }
            let excerpt = String(file.content.prefix(min(8_000, remainingContext)))
            remainingContext -= excerpt.count
            user += "\n\nEXISTING INTERFACE: " + file.path + "\n" + excerpt
            if excerpt.count < file.content.count { user += "\n[Excerpt; remaining source omitted from context.]" }
        }
        user += "\n\nYOUR FILE: " + step.path
            + (step.does.isEmpty ? "" : " — " + step.does)
            + "\nOutput its complete content and nothing else."
        return [
            OutgoingMessage(role: "system", content: fileSystemPrompt(kind: kind, uiLang: uiLang)),
            OutgoingMessage(role: "user", content: user)
        ]
    }

    /// The tail-continuation the worker uses when a file came back cut off (`§2.3` step 6).
    nonisolated static func fileContinuationMessages(path: String, tail: String) -> [OutgoingMessage] {
        let user = "You are FINISHING the file `" + path
            + "` from a response that was cut off. Continue from the EXACT last character below and output NOTHING but the rest of that file. Do not repeat what is already written, do not add commentary, do not open a fence.\n\n"
            + tail
        return [
            OutgoingMessage(role: "system", content: "Continue the file. Output raw file content only."),
            OutgoingMessage(role: "user", content: user)
        ]
    }

    /// Every live-build call is the same shape as an in-IDE one: `nomem`, no thinking, `product`
    /// `code` (`web-code-ux.md §6.6`). The `cid` is per call and deliberately not the build's own —
    /// the build's `cid` belongs to the durable turn and must stay unspent until the handover.
    nonisolated static func streamRequest(messages: [OutgoingMessage], tier: ModelTier) -> ChatStreamRequest {
        ChatStreamRequest(
            messages: messages,
            tier: tier.rawValue,
            think: false,
            cid: IDs.cid(),
            chatId: nil,
            product: ProductKind.code.wireValue,
            nomem: true
        )
    }

    // MARK: - The live build: reading what came back

    /// `[{path, does}]`, with the worker's repairs: paths cleaned, duplicates dropped, `index.html`
    /// forced to the front, a skeleton appended when the planner produced almost nothing, and the
    /// whole thing cut to the number of files this client can actually save.
    nonisolated static func parsePlan(_ raw: String, kind: CodeBuildKind, brief: String = "") -> [CodeBuildStep] {
        var steps: [CodeBuildStep] = []
        if let start = raw.firstIndex(of: "["),
           let end = raw.lastIndex(of: "]"),
           start < end,
           let data = String(raw[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let rows = object as? [[String: Any]] {
            for row in rows {
                let path = sanitizePath((row["path"] as? String) ?? "")
                guard !path.isEmpty, path != ".", !path.hasSuffix("/") else { continue }
                guard !steps.contains(where: { $0.path == path }) else { continue }
                let does = String(((row["does"] as? String) ?? "").prefix(200))
                steps.append(CodeBuildStep(path: path, does: does))
            }
        }

        // `index.html` is not optional: it is the file the preview opens.
        if kind.usesBrowserPreview, let index = steps.firstIndex(where: { $0.path.lowercased() == "index.html" }) {
            let entry = steps.remove(at: index)
            steps.insert(entry, at: 0)
        } else if kind.usesBrowserPreview {
            steps.insert(CodeBuildStep(path: "index.html", does: ""), at: 0)
        }
        if steps.isEmpty || (kind.usesBrowserPreview && steps.count < 2) {
            for path in skeleton(for: kind, brief: brief) where !steps.contains(where: { $0.path == path }) {
                steps.append(CodeBuildStep(path: path, does: ""))
            }
        }
        return Array(steps.prefix(CodeProject.maximumFiles))
    }

    /// The model is told not to fence the file; when it does anyway, one wrapping fence comes off —
    /// exactly what the worker does before it keeps the content (`§2.3` step 6).
    nonisolated static func strippedFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        guard let newline = text.firstIndex(of: "\n") else { return "" }
        text = String(text[text.index(after: newline)...])
        return strippedClosingFence(text)
    }

    /// The other half, for a body whose opening fence was already removed as it streamed.
    nonisolated static func strippedClosingFence(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .newlines)
        guard let close = text.range(of: "```", options: .backwards) else { return text }
        // Only a fence that closes the file — a stray ``` in the middle of a markdown file is content.
        let tail = text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.isEmpty else { return text }
        return String(text[..<close.lowerBound]).trimmingCharacters(in: .newlines)
    }

    /// The worker's `looksComplete`, minus the part this client cannot do.
    ///
    /// The worker parses JavaScript with `new Function`; there is no parser here, so the JS test is
    /// a brace count plus a plausible last character. That is deliberately *weak in one direction
    /// only*: it may ask for a continuation the file did not need (which appends nothing, because
    /// the continuation is dropped when it does not grow the body), and it never throws a file away
    /// — see `CodeStore.streamFile`, which keeps a file the count still dislikes.
    nonisolated static func looksComplete(path: String, content: String) -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let ext = path.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        switch ext {
        case "html", "htm":
            return text.lowercased().hasSuffix("</html>")
        case "css":
            return text.hasSuffix("}") && isBalanced(text)
        case "js", "mjs":
            return (text.hasSuffix("}") || text.hasSuffix(";") || text.hasSuffix(")")) && isBalanced(text)
        default:
            return true
        }
    }

    private nonisolated static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }
}
