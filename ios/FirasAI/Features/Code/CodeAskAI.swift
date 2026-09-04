import Foundation

/// The in-IDE model call: routing, prompts and the continuation loop (`web-code-ux.md §6.2–§6.6`).
///
/// Everything here is pure and nonisolated so `CodeStore.askAI` can run it inside a `Task`. Only
/// three of the web's six routes are ported, exactly as the report's minimum spec asks: the
/// document redirect, the read-only question, and the single-shot surgical edit with continuation.
/// The game loop, the Improve loop and plan-then-build all need an in-tab sandbox runner.
enum CodeAskAI {

    // MARK: - Types

    enum Route: Sendable, Equatable {
        case documentRedirect
        case question
        case edit
    }

    enum Outcome: Sendable {
        /// The request was a document, not a project — answer verbatim, charge nothing.
        case redirect(String)
        /// A read-only answer for the thread.
        case answer(String)
        /// Files to write, delete or rename, for the diff review.
        case plan(CodeEditPlan)
    }

    enum Failure: Error, Sendable {
        case engineBusy
        case emptyAnswer
    }

    /// `req = instruction.slice(0, 24000)`.
    static let requestLimit = 24_000
    /// Total budget for the file bodies in one prompt.
    static let fileBudget = 90_000
    /// Per-file slice inside that budget.
    static let perFileLimit = 15_000
    /// Per-file slice for a read-only question.
    static let perFileQuestionLimit = 12_000
    /// `while the parse reports an unterminated block …, up to 4 rounds`.
    static let continuationRounds = 4
    static let continuationTail = 8_000

    // MARK: - Routing

    static func route(_ instruction: String, lang: AppLanguage) -> Route {
        let text = String(instruction.prefix(requestLimit)).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
        if mentionsDocumentFormat(text), isDocumentKind(RequestClassifier.classify(text, hasImages: false, lang: lang)) {
            return .documentRedirect
        }
        return isQuestion(text) ? .question : .edit
    }

    static func tier(for route: Route) -> ModelTier {
        route == .question ? .pro : .max
    }

    private static func isDocumentKind(_ kind: RequestKind) -> Bool {
        switch kind {
        case .file(_, _): return true
        case .longfile(_, _): return true
        case .longdoc(_): return true
        default: return false
        }
    }

    /// The web's document-format screen. Arabic terms are plain substrings (never a `\b` next to
    /// an Arabic letter); the Latin ones are token-matched.
    static func mentionsDocumentFormat(_ text: String) -> Bool {
        let lowered = text.lowercased()
        for token in latinDocumentTokens where containsToken(lowered, token) {
            return true
        }
        let normalized = ArabicText.normalize(text)
        for word in arabicDocumentWords where normalized.contains(ArabicText.normalize(word)) {
            return true
        }
        return false
    }

    /// `cwIsQuestion`: an edit verb always wins; otherwise a question word or a trailing `?`/`؟`.
    static func isQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased()
        for verb in latinEditVerbs where containsToken(lowered, verb) {
            return false
        }
        let normalized = ArabicText.normalize(text)
        for verb in arabicEditVerbs where containsToken(normalized, ArabicText.normalize(verb)) {
            return false
        }
        for word in latinQuestionWords where containsToken(lowered, word) {
            return true
        }
        for word in arabicQuestionWords where containsToken(normalized, ArabicText.normalize(word)) {
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("?") || trimmed.hasSuffix("؟")
    }

    /// `@path` mentions resolved against the project, in the order they were typed.
    static func mentionedPaths(in text: String, files: [CodeFile]) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while let at = text.range(of: "@", range: index..<text.endIndex) {
            var cursor = at.upperBound
            var token = ""
            while cursor < text.endIndex, !text[cursor].isWhitespace, text[cursor] != "@" {
                token.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            index = cursor
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)»\"'"))
            guard !cleaned.isEmpty else { continue }
            if let match = matchPath(cleaned, in: files), !found.contains(match) {
                found.append(match)
            }
            if cursor == text.endIndex { break }
        }
        return found
    }

    /// Fuzzy matches for the `@` popup: whole path first, then basename, then a contains pass.
    static func suggestions(for token: String, files: [CodeFile], limit: Int = 8) -> [String] {
        let needle = token.lowercased()
        guard !needle.isEmpty else { return Array(files.prefix(limit)).map { $0.path } }
        var ranked: [(String, Int)] = []
        for file in files {
            let path = file.path.lowercased()
            let name = basename(of: path)
            if path == needle { ranked.append((file.path, 0)) }
            else if name.hasPrefix(needle) { ranked.append((file.path, 1)) }
            else if path.hasPrefix(needle) { ranked.append((file.path, 2)) }
            else if path.contains(needle) { ranked.append((file.path, 3)) }
        }
        return ranked.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    static func matchPath(_ token: String, in files: [CodeFile]) -> String? {
        let needle = token.lowercased()
        if let exact = files.first(where: { $0.path.lowercased() == needle }) { return exact.path }
        if let named = files.first(where: { basename(of: $0.path.lowercased()) == needle }) { return named.path }
        return nil
    }

    private static func basename(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    // MARK: - Copy

    /// `codeDeliverableRedirectText`, verbatim (`web-code-ux.md §6.2.1`).
    static let documentRedirect = LText(
        ar: "لإنشاء **مستند جاهز للتحميل** مثل PDF أو Word، افتح **فِراس جات** والصق طلبك هناك. أمّا الكود الذي يُنشئ هذه الملفات أو يعالجها فيمكننا بناؤه هنا ضمن المشروع.",
        en: "For a **finished downloadable document** such as PDF or Word, open **Firas Chat** and paste your request there. Code that creates or processes those files can be built here in the project."
    )

    // MARK: - Prompts

    /// The file-block contract, verbatim from `web-code-ux.md §6.3`.
    static let editSystemPrompt: String = #"""
    You are an elite senior software engineer editing an existing project. You are given every file of the project and one request.

    STRICT OUTPUT FORMAT: first ONE short summary line in the user's language that NAMES exactly which file(s) it will touch and why; then for EVERY added or modified file exactly one fenced block:
    ```file:relative/path.ext
    <the COMPLETE new file content>
    ```
    To delete a file output a line: DELETE: relative/path.ext
    To rename a file output a line: RENAME: old/path.ext -> new/path.ext

    RULES:
    - Output the COMPLETE new content of every file you touch, from its first character to its last. NEVER write "TODO", "FIXME", "... rest of the code", "goes here", "your code here", "omitted for brevity", "remains the same", "keep existing" or any other placeholder — a truncated file is a broken project.
    - Touch only the files the request needs. A file you do not output is left exactly as it is.
    - Keep every existing feature working: the project must still run after your edit.
    - Match the existing project's language, runtime and build tools. The no-build browser preview is only for HTML projects; it does not restrict the source languages or dependency manifests you can produce.
    - Browser previews run sandboxed without same-origin access. Native applications, services and scripts are delivered as source with their own build/run instructions.
    - Do not explain your work after the blocks. The summary line before them is the whole explanation.
    """# + "\n\n" + CodeEngineeringGuidance.core

    static let questionSystemPrompt: String = #"""
    You are answering a question about an existing code project. This turn is READ-ONLY.

    - Answer in the user's own language, concretely, naming the files, functions and selectors involved.
    - Quote at most a few short lines of code when they carry the answer.
    - NEVER output a ```file: block, a DELETE: line or a RENAME: line — you are not editing anything in this turn.
    - If the project does not contain what the question assumes, say so plainly instead of inventing it.
    """#

    static func editMessages(
        project: CodeProject,
        instruction: String,
        attachmentText: String,
        focusPaths: [String]
    ) -> [OutgoingMessage] {
        let request = String(instruction.prefix(requestLimit))
        var user = "PROJECT: " + project.name + "\n\nCURRENT FILES:\n"
        user += filesBlock(project: project, focusPaths: focusPaths, perFile: perFileLimit)
        user += "\n\nUSER REQUEST:\n" + request
        if !attachmentText.isEmpty { user += "\n\n" + attachmentText }
        if !focusPaths.isEmpty {
            user += "\n\nFOCUS FILES — the user @-referenced these; make the change here unless the request clearly needs other files: "
                + focusPaths.joined(separator: ", ")
        }
        return [
            OutgoingMessage(role: "system", content: editSystemPrompt),
            OutgoingMessage(role: "user", content: user)
        ]
    }

    static func questionMessages(
        project: CodeProject,
        instruction: String,
        attachmentText: String
    ) -> [OutgoingMessage] {
        let request = String(instruction.prefix(requestLimit))
        var user = "PROJECT: " + project.name + "\n\nCURRENT FILES:\n"
        user += filesBlock(project: project, focusPaths: [], perFile: perFileQuestionLimit)
        user += "\n\nQUESTION:\n" + request
        if !attachmentText.isEmpty { user += "\n\n" + attachmentText }
        return [
            OutgoingMessage(role: "system", content: questionSystemPrompt),
            OutgoingMessage(role: "user", content: user)
        ]
    }

    static func continuationMessages(path: String, tail: String) -> [OutgoingMessage] {
        let user = "You are FINISHING the file `" + path
            + "` from a response that was cut off. Continue from the EXACT last character below, and output NOTHING but the rest of that file followed by a closing fence. Do not repeat what is already written, do not restate the summary, do not open a new fence.\n\n"
            + tail
        return [
            OutgoingMessage(role: "system", content: editSystemPrompt),
            OutgoingMessage(role: "user", content: user)
        ]
    }

    /// `===== path (FOCUS) =====` blocks, mentioned files first, within the total budget.
    static func filesBlock(project: CodeProject, focusPaths: [String], perFile: Int) -> String {
        let focused = project.files.filter { focusPaths.contains($0.path) }
        let rest = project.files.filter { !focusPaths.contains($0.path) }
        var output = ""
        var used = 0
        for file in focused + rest {
            let isFocus = focusPaths.contains(file.path)
            let header = "===== " + file.path + (isFocus ? " (FOCUS)" : "") + " =====\n"
            guard !CodeEngineeringGuidance.isSensitivePath(file.path),
                  !CodeEngineeringGuidance.containsPrivateKey(file.content) else { continue }
            var body = String(file.content.prefix(perFile))
            if body.count < file.content.count {
                body += "\n[TRUNCATED SOURCE: the rest was not provided; do not replace this file from this excerpt.]"
            }
            let cost = header.count + body.count + 2
            if used + cost > fileBudget { break }
            used += cost
            output += header + body + "\n\n"
        }
        return output
    }

    // MARK: - Running

    static func run(
        api: APIClient,
        project: CodeProject,
        instruction: String,
        attachmentText: String,
        lang: AppLanguage
    ) async throws -> Outcome {
        switch route(instruction, lang: lang) {
        case .documentRedirect:
            return .redirect(documentRedirect(lang))

        case .question:
            let answer = try await complete(
                api: api,
                messages: questionMessages(
                    project: project,
                    instruction: instruction,
                    attachmentText: attachmentText
                ),
                tier: .pro
            )
            return .answer(strippingFileBlocks(answer))

        case .edit:
            let focus = mentionedPaths(in: instruction, files: project.files)
            var answer = try await complete(
                api: api,
                messages: editMessages(
                    project: project,
                    instruction: instruction,
                    attachmentText: attachmentText,
                    focusPaths: focus
                ),
                tier: .max
            )
            var rounds = 0
            while rounds < continuationRounds, let open = openBlock(in: answer) {
                rounds += 1
                let tail = String(open.content.suffix(continuationTail))
                let more = try await complete(
                    api: api,
                    messages: continuationMessages(path: open.path, tail: tail),
                    tier: .max
                )
                if more.isEmpty { break }
                answer += more
            }
            // A closing fence invented here made an incomplete file look safe
            // to apply. Leave it open: the parser drops incomplete writes.
            return .plan(CodeEditPlan.parse(answer))
        }
    }

    /// One `POST /api/chat` with `nomem:true, think:false` (`web-code-ux.md §6.6`), accumulated
    /// from the OpenAI-style SSE frames. A 200 body that is an engine-busy notice is a failure.
    static func complete(
        api: APIClient,
        messages: [OutgoingMessage],
        tier: ModelTier
    ) async throws -> String {
        let request = ChatStreamRequest(
            messages: messages,
            tier: tier.rawValue,
            think: false,
            cid: IDs.cid(),
            chatId: nil,
            product: "code",
            nomem: true
        )
        var text = ""
        let stream = await api.chatStream(request)
        for try await frame in stream {
            let payload = frame.data
            if payload == "[DONE]" { break }
            if let delta = deltaContent(payload) { text += delta }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyAnswer }
        guard !EngineFailureDetector.isFailure(trimmed) else { throw Failure.engineBusy }
        return text
    }

    static func deltaContent(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else {
            return nil
        }
        return delta["content"] as? String
    }

    // MARK: - Answer shaping

    /// An unterminated ```` ```file: ```` block at the end of an answer, if any.
    static func openBlock(in answer: String) -> (path: String, content: String)? {
        var openPath: String?
        var body: [String] = []
        for rawLine in answer.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if openPath != nil {
                if trimmed.hasPrefix("```") {
                    openPath = nil
                    body = []
                } else {
                    body.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```file:") {
                var path = String(trimmed.dropFirst("```file:".count)).trimmingCharacters(in: .whitespaces)
                path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
                while path.hasPrefix("/") { path.removeFirst() }
                openPath = path.isEmpty ? nil : path
                body = []
            }
        }
        guard let path = openPath else { return nil }
        return (path, body.joined(separator: "\n"))
    }

    /// A read-only answer must not carry edits; strip any the model leaked anyway.
    static func strippingFileBlocks(_ answer: String) -> String {
        var kept: [String] = []
        var inside = false
        for rawLine in answer.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if inside {
                if trimmed.hasPrefix("```") { inside = false }
                continue
            }
            if trimmed.hasPrefix("```file:") { inside = true; continue }
            if trimmed.uppercased().hasPrefix("DELETE:") { continue }
            if trimmed.uppercased().hasPrefix("RENAME:") { continue }
            kept.append(rawLine)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Token matching

    /// A whole-token contains test that works for both scripts — the JS `\b` is unusable next to
    /// Arabic letters (`ARCHITECTURE §3.14`).
    static func containsToken(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == haystack.startIndex {
                beforeOK = true
            } else {
                beforeOK = !isWordCharacter(haystack[haystack.index(before: range.lowerBound)])
            }
            let afterOK: Bool
            if range.upperBound == haystack.endIndex {
                afterOK = true
            } else {
                afterOK = !isWordCharacter(haystack[range.upperBound])
            }
            if beforeOK && afterOK { return true }
            start = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: - Word lists (`web-code-ux.md §6.2`)

    private static let latinDocumentTokens = [
        "pdf", "word", "docx", "powerpoint", "pptx", "excel", "xlsx", "csv", "slide", "slides",
        "deck", "presentation", "report", "whitepaper", "ebook", "booklet", "brochure"
    ]

    private static let arabicDocumentWords = [
        "مستند", "وثيقة", "تقرير", "عرض تقديمي", "شرائح", "بوربوينت", "وورد", "اكسل", "كتيب", "بحث"
    ]

    private static let latinEditVerbs = [
        "add", "change", "edit", "modify", "delete", "remove", "create", "make", "build", "fix",
        "repair", "improve", "refactor", "rename", "move", "update", "implement", "convert",
        "replace", "split", "extract", "style", "set", "write", "generate", "redesign"
    ]

    private static let arabicEditVerbs = [
        "أضف", "اضف", "أضيف", "اضيف", "نضيف", "ضيف", "غيّر", "غير", "تغيير", "عدّل", "عدل",
        "تعديل", "احذف", "امسح", "حذف", "اصنع", "اعمل", "سوّي", "سوي", "أنشئ", "انشئ", "اجعل",
        "خلّي", "خلي", "صلّح", "صلح", "أصلح", "اصلح", "إصلاح", "حسّن", "حسن", "تحسين", "طوّر",
        "طور", "تطوير", "انقل", "بدّل", "بدل", "استبدل", "لوّن", "لون", "اكتب", "ولّد", "ولد",
        "قسّم", "قسم"
    ]

    private static let latinQuestionWords = [
        "explain", "what", "why", "how", "where", "which", "who", "when", "difference",
        "describe", "summarize", "summarise", "does", "do"
    ]

    private static let arabicQuestionWords = [
        "اشرح", "إشرح", "وضّح", "وضح", "فسّر", "فسر", "لخّص", "لخص", "ما هو", "ما هي", "ماهو",
        "ماهي", "شنو", "شلون", "كيف يعمل", "كيف تعمل", "وين", "أين", "لماذا", "ليش",
        "ما الفرق", "ما وظيفة", "عرّفني", "عرفني", "نبذة", "من يستدعي"
    ]
}
