import Foundation

/// The pure half of `CodeStore`: parsing a project chat, naming, path hygiene, the save-caps
/// shrink loop and the attachment fold. Nothing here touches store state, so all of it is
/// `nonisolated` and safe to run from a detached task.
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

    /// The web's shrink loop: while the payload is over `CW_PAYLOAD_MAX`, cut the largest file to
    /// 80 % of its length, up to 400 passes, stopping once the largest is under 200 characters.
    nonisolated static func shrunkToFit(_ project: CodeProject) -> CodeProject {
        var files = Array(project.files.prefix(CodeProject.maximumFiles)).map { file in
            CodeFile(
                path: String(file.path.prefix(CodeProject.maximumPathLength)),
                content: String(file.content.prefix(CodeProject.maximumFileCharacters))
            )
        }
        let name = String(project.name.prefix(nameCharacterCap))
        var passes = 0
        while passes < 400, payloadSize(name: name, files: files) > CodeProject.maximumPayloadCharacters {
            passes += 1
            guard let largest = files.indices.max(by: { files[$0].content.count < files[$1].content.count }) else { break }
            let count = files[largest].content.count
            guard count > 200 else { break }
            files[largest] = CodeFile(
                path: files[largest].path,
                content: String(files[largest].content.prefix(Int(Double(count) * 0.8)))
            )
        }
        return CodeProject(name: name, files: files)
    }

    private nonisolated static func payloadSize(name: String, files: [CodeFile]) -> Int {
        guard let data = try? JSONEncoder().encode(CodeProject(name: name, files: files)),
              let json = String(data: data, encoding: .utf8) else { return Int.max }
        return json.count
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
}
