import Foundation
import CryptoKit

/// One file of a Firas Code project.
struct CodeFile: Codable, Sendable, Equatable, Identifiable {
    let path: String
    let content: String

    var id: String { path }

    init(path: String, content: String) {
        self.path = path
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        path = LenientJSON.string(container, "path") ?? ""
        content = LenientJSON.string(container, "content") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(path, forKey: AnyCodingKey("path"))
        try container.encode(content, forKey: AnyCodingKey("content"))
    }

    /// The extension, lowercased, without the dot.
    var ext: String {
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return "" }
        return String(path[path.index(after: dot)...]).lowercased()
    }
}

/// A project is a chat with `codeProj: true` whose `messages[0]` is one ```` ```firas-project ````
/// fence around `{name, files}`.
struct CodeProject: Codable, Sendable, Equatable {
    let name: String
    let files: [CodeFile]

    init(name: String, files: [CodeFile]) {
        self.name = name
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = LenientJSON.string(container, "name") ?? ""
        files = LenientJSON.array(container, "files", of: CodeFile.self) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(files, forKey: AnyCodingKey("files"))
    }

    /// The whole message, or a growing job `text`, decoded.
    ///
    /// File contents legitimately contain backtick fences, so the closing fence is the **last**
    /// line-level marker, never the first three backticks in the payload.
    static func decode(fromJobText text: String) throws -> CodeProject {
        let marker = "```firas-project"
        guard let markerRange = text.range(of: marker) else {
            throw CodeProjectDecodingError.missingFence
        }
        let remaining = text[markerRange.upperBound...]
        guard let closingRange = remaining.range(of: "\n```", options: .backwards) else {
            throw CodeProjectDecodingError.missingFence
        }
        let payload = String(remaining[..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try decode(fromFenceBody: payload)
    }

    /// The fence body alone (what `FirasFence` hands over).
    static func decode(fromFenceBody body: String) throws -> CodeProject {
        let payload = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payload.data(using: .utf8) else {
            throw CodeProjectDecodingError.invalidUTF8
        }
        guard let project = try? JSONDecoder().decode(CodeProject.self, from: data) else {
            throw CodeProjectDecodingError.invalidPayload
        }
        guard !project.files.isEmpty else {
            throw CodeProjectDecodingError.invalidPayload
        }
        return project
    }
}

enum CodeProjectDecodingError: Error, Sendable, Equatable {
    case missingFence
    case invalidUTF8
    case invalidPayload
}

/// Why a project could not be saved. The web shrinks the largest file instead; the native app
/// refuses and says which file is the problem.
enum CodeSaveError: Error, Sendable, Equatable {
    case tooManyFiles
    case pathTooLong(String)
    case fileTooLarge(String)
    case projectTooLarge
}

extension CodeProject {
    /// The web's `CW_BLANK_FILES` scaffold, byte for byte. It is Arabic/RTL whatever the UI
    /// language is; a project created here must be identical to one created on the web.
    static let blankFiles: [CodeFile] = [
        CodeFile(
            path: "index.html",
            content: """
            <!DOCTYPE html>
            <html lang="ar" dir="rtl">
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <title>مشروعي</title>
              <style>
                body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#faf9f5;color:#1a1a18}
                h1{font-size:clamp(28px,6vw,48px)}
              </style>
            </head>
            <body>
              <h1>ابدأ البناء 👋</h1>
            </body>
            </html>

            """
        )
    ]

    static let maximumFiles = 30
    static let maximumPathLength = 120
    static let maximumFileCharacters = 60_000
    /// `CW_PAYLOAD_MAX` — kept so a project saved here stays loadable by the web client.
    static let maximumPayloadCharacters = 180_000

    /// The caps `codeSaveFiles` enforces before a project is written into `messages[0]`.
    func validatedForSave() -> Result<CodeProject, CodeSaveError> {
        guard files.count <= Self.maximumFiles else { return .failure(.tooManyFiles) }
        for file in files {
            guard file.path.count <= Self.maximumPathLength else {
                return .failure(.pathTooLong(file.path))
            }
            guard file.content.count <= Self.maximumFileCharacters else {
                return .failure(.fileTooLarge(file.path))
            }
        }
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(.projectTooLarge)
        }
        guard json.count <= Self.maximumPayloadCharacters else {
            return .failure(.projectTooLarge)
        }
        return .success(self)
    }

    /// `messages[0].content` — one line of JSON inside the fence.
    func encodedFence() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "```firas-project\n{\"name\":\"\",\"files\":[]}\n```"
        }
        return "```firas-project\n" + json + "\n```"
    }
}

/// One turn of the Firas Code side thread. On the wire the keys are the web's `text` / `ts`.
struct CodeChatMessage: Codable, Sendable, Equatable, Identifiable {
    var id: String
    /// `"user"` or `"ai"`.
    var role: String
    var content: String
    /// Epoch milliseconds.
    var at: Double?
    /// How many files the AI turn changed — drawn as a chip.
    var n: Int?
    var applied: Bool?

    init(role: String, content: String, at: Double? = nil, n: Int? = nil, applied: Bool? = nil) {
        self.id = UUID().uuidString
        self.role = role
        self.content = content
        self.at = at
        self.n = n
        self.applied = applied
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        role = LenientJSON.string(container, "role") ?? "user"
        content = LenientJSON.string(container, "text") ?? LenientJSON.string(container, "content") ?? ""
        at = LenientJSON.double(container, "ts") ?? LenientJSON.double(container, "at")
        n = LenientJSON.int(container, "n")
        applied = LenientJSON.bool(container, "applied")
        // Old web turns have no id. Derive one from their original wire data so
        // reopening a session does not give every rendered answer a new identity.
        let legacy = role + "|" + String(at ?? 0) + "|" + content
        id = LenientJSON.string(container, "id")
            ?? SHA256.hash(data: Data(legacy.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(role, forKey: AnyCodingKey("role"))
        try container.encode(content, forKey: AnyCodingKey("text"))
        try container.encodeIfPresent(n, forKey: AnyCodingKey("n"))
        try container.encodeIfPresent(applied, forKey: AnyCodingKey("applied"))
        try container.encodeIfPresent(at, forKey: AnyCodingKey("ts"))
    }
}

/// `messages[1]` of a project chat: ```` ```firas-code-chat ```` around **base64 of the JSON**
/// `{"turns":[…]}`. Never create it before `messages[0]` exists.
struct CodeChatThread: Codable, Sendable, Equatable {
    var messages: [CodeChatMessage]

    /// Keep the last 40 turns; a turn's text is capped at `CW_TURN_MAX`; the encoded body must fit
    /// `CW_THREAD_BUDGET`.
    static let maximumTurns = 40
    static let maximumTurnCharacters = 90_000
    static let threadBudgetCharacters = 120_000

    init(messages: [CodeChatMessage] = []) {
        self.messages = Self.uniquelyIdentified(messages)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        messages = LenientJSON.array(container, "turns", of: CodeChatMessage.self)
            ?? LenientJSON.array(container, "messages", of: CodeChatMessage.self)
            ?? []
        messages = Self.uniquelyIdentified(messages)
    }

    private static func uniquelyIdentified(_ turns: [CodeChatMessage]) -> [CodeChatMessage] {
        var seen = Set<String>()
        return turns.map { turn in
            var copy = turn
            var duplicate = 0
            while !seen.insert(copy.id).inserted {
                duplicate += 1
                copy.id = turn.id + "-" + String(duplicate)
            }
            return copy
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(messages, forKey: AnyCodingKey("turns"))
    }

    /// Decodes the fence body (the base64 blob), or a whole ```` ```firas-code-chat ```` message.
    static func decode(fromFence fence: String) -> CodeChatThread? {
        var body = fence.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            guard let parsed = FirasFence.firstFence(in: body), parsed.name == "firas-code-chat" else {
                return nil
            }
            body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !compact.isEmpty else { return nil }
        guard let data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) else { return nil }
        return try? JSONDecoder().decode(CodeChatThread.self, from: data)
    }

    /// The trimmed thread, base64-encoded inside its fence.
    func encodedFence() -> String {
        var kept = Array(messages.suffix(Self.maximumTurns)).map { turn -> CodeChatMessage in
            var copy = turn
            if copy.content.count > Self.maximumTurnCharacters {
                copy.content = String(copy.content.prefix(Self.maximumTurnCharacters))
            }
            return copy
        }

        var encoded = Self.base64(of: CodeChatThread(messages: kept))
        // Drop the oldest turns first, never the newest.
        while encoded.count > Self.threadBudgetCharacters, kept.count > 1 {
            kept.removeFirst()
            encoded = Self.base64(of: CodeChatThread(messages: kept))
        }
        // A single turn that is still too big is trimmed 30 % at a time.
        var guardCounter = 0
        while encoded.count > Self.threadBudgetCharacters, kept.count == 1, guardCounter < 40 {
            guardCounter += 1
            let text = kept[0].content
            guard text.count > 40 else { break }
            kept[0].content = String(text.prefix(Int(Double(text.count) * 0.7)))
            encoded = Self.base64(of: CodeChatThread(messages: kept))
        }

        return "```firas-code-chat\n" + encoded + "\n```"
    }

    private static func base64(of thread: CodeChatThread) -> String {
        guard let data = try? JSONEncoder().encode(thread) else { return "" }
        return data.base64EncodedString()
    }
}

/// One ```` ```file:relative/path ```` block of an AI edit answer.
struct CodeFileBlock: Sendable, Equatable {
    let path: String
    let content: String

    init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// The parsed result of a follow-up edit: files to write, files to delete, files to rename, and
/// the one-line summary the model put before the first block.
struct CodeEditPlan: Sendable, Equatable {
    var writes: [CodeFileBlock]
    var deletes: [String]
    var renames: [(from: String, to: String)]
    var prose: String

    init(
        writes: [CodeFileBlock] = [],
        deletes: [String] = [],
        renames: [(from: String, to: String)] = [],
        prose: String = ""
    ) {
        self.writes = writes
        self.deletes = deletes
        self.renames = renames
        self.prose = prose
    }

    var isEmpty: Bool { writes.isEmpty && deletes.isEmpty && renames.isEmpty }

    // Tuples are not Equatable on their own.
    static func == (lhs: CodeEditPlan, rhs: CodeEditPlan) -> Bool {
        guard lhs.writes == rhs.writes,
              lhs.deletes == rhs.deletes,
              lhs.prose == rhs.prose,
              lhs.renames.count == rhs.renames.count else { return false }
        for (left, right) in zip(lhs.renames, rhs.renames) where left.from != right.from || left.to != right.to {
            return false
        }
        return true
    }

    /// Bodies the model filled with a placeholder instead of the real file.
    private static let placeholderMarkers = [
        "todo", "fixme", "... rest of", "rest of the code", "goes here", "your code here",
        "continue here", "omitted for brevity", "remains the same", "keep existing",
        "placeholder content", "same as before"
    ]

    /// `cwParseFileBlocks`: ```` ```file:path ```` blocks plus `DELETE:` and `RENAME:` lines.
    /// An unterminated trailing block is dropped — the caller asks for a continuation instead.
    static func parse(_ answer: String) -> CodeEditPlan {
        var writes: [String: String] = [:]
        var order: [String] = []
        var deletes: [String] = []
        var renames: [(from: String, to: String)] = []
        var proseLines: [String] = []

        var openPath: String?
        var openBody: [String] = []
        var sawBlock = false

        for rawLine in answer.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let path = openPath {
                if trimmed.hasPrefix("```") {
                    var body = openBody.joined(separator: "\n")
                    if body.hasSuffix("\n") { body.removeLast() }
                    if !isPlaceholder(body) {
                        if writes[path] == nil { order.append(path) }
                        writes[path] = body
                    }
                    openPath = nil
                    openBody = []
                } else {
                    openBody.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```file:") {
                sawBlock = true
                let raw = String(trimmed.dropFirst("```file:".count)).trimmingCharacters(in: .whitespaces)
                let cleaned = normalizedPath(raw)
                if cleaned.isEmpty { continue }
                openPath = cleaned
                openBody = []
                continue
            }

            if trimmed.uppercased().hasPrefix("DELETE:") {
                let path = normalizedPath(String(trimmed.dropFirst("DELETE:".count)))
                if !path.isEmpty { deletes.append(path) }
                continue
            }

            if trimmed.uppercased().hasPrefix("RENAME:") {
                let body = String(trimmed.dropFirst("RENAME:".count))
                let parts = body.components(separatedBy: "->")
                if parts.count == 2 {
                    let from = normalizedPath(parts[0])
                    let to = normalizedPath(parts[1])
                    if !from.isEmpty, !to.isEmpty { renames.append((from: from, to: to)) }
                }
                continue
            }

            if !sawBlock { proseLines.append(line) }
        }

        let prose = proseLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CodeEditPlan(
            writes: order.compactMap { path in writes[path].map { CodeFileBlock(path: path, content: $0) } },
            deletes: deletes,
            renames: renames,
            prose: String(prose.prefix(2_000))
        )
    }

    private static func normalizedPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
        while path.hasPrefix("/") { path.removeFirst() }
        return String(path.prefix(CodeProject.maximumPathLength))
    }

    /// A body that is only an ellipsis or a "same as before" note is not a file.
    private static func isPlaceholder(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "…" || trimmed == "..." { return true }
        guard trimmed.count <= 80 else { return false }
        let folded = trimmed
            .replacingOccurrences(of: "//", with: " ")
            .replacingOccurrences(of: "/*", with: " ")
            .replacingOccurrences(of: "*/", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .replacingOccurrences(of: "<!--", with: " ")
            .replacingOccurrences(of: "-->", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if folded == "…" || folded == "..." { return true }
        return placeholderMarkers.contains { folded == $0 || folded.hasPrefix($0) }
    }
}
