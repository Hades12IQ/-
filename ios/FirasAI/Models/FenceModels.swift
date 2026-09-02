import Foundation

/// The meta line of a ```` ```firas-code {json} ```` block — the single-file code deliverable in an
/// ordinary chat.
struct CodeMeta: Codable, Sendable, Equatable {
    var lang: String?
    /// The download name (`filename` on the wire).
    var name: String?
    /// The card's label (`label` on the wire).
    var title: String?
    var preview: Bool?
    var ext: String?
    /// Markdown rendered above and below the card.
    var intro: String?
    var outro: String?

    init(
        lang: String? = nil,
        name: String? = nil,
        title: String? = nil,
        preview: Bool? = nil,
        ext: String? = nil,
        intro: String? = nil,
        outro: String? = nil
    ) {
        self.lang = lang
        self.name = name
        self.title = title
        self.preview = preview
        self.ext = ext
        self.intro = intro
        self.outro = outro
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        lang = LenientJSON.string(container, "lang")
        name = LenientJSON.string(container, "filename") ?? LenientJSON.string(container, "name")
        title = LenientJSON.string(container, "label") ?? LenientJSON.string(container, "title")
        preview = LenientJSON.bool(container, "preview")
        ext = LenientJSON.string(container, "ext")
        intro = LenientJSON.string(container, "intro")
        outro = LenientJSON.string(container, "outro")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(name, forKey: AnyCodingKey("filename"))
        try container.encodeIfPresent(lang, forKey: AnyCodingKey("lang"))
        try container.encodeIfPresent(ext, forKey: AnyCodingKey("ext"))
        try container.encodeIfPresent(title, forKey: AnyCodingKey("label"))
        try container.encodeIfPresent(preview, forKey: AnyCodingKey("preview"))
        try container.encodeIfPresent(intro, forKey: AnyCodingKey("intro"))
        try container.encodeIfPresent(outro, forKey: AnyCodingKey("outro"))
    }
}

/// The body of a ```` ```firas-file ```` fence — the reference to a generated document. A durable
/// long file also carries `artifactId` and `artifactEndpoint`; the page bodies are never in the
/// chat and must be fetched part by part.
struct FileMeta: Codable, Sendable, Equatable {
    /// `pdf` | `docx` | `xlsx` | `pptx` | `csv`.
    var format: String
    /// `filename` on the wire.
    var name: String?
    var title: String?
    /// `pageCount` on the wire.
    var pages: Int?
    var jobId: String?
    var artifactId: String?
    var subtitle: String?
    var theme: String?
    var template: String?
    var artifactParts: Int?
    var artifactEndpoint: String?

    init(
        format: String,
        name: String? = nil,
        title: String? = nil,
        pages: Int? = nil,
        jobId: String? = nil,
        artifactId: String? = nil,
        subtitle: String? = nil,
        theme: String? = nil,
        template: String? = nil,
        artifactParts: Int? = nil,
        artifactEndpoint: String? = nil
    ) {
        self.format = format
        self.name = name
        self.title = title
        self.pages = pages
        self.jobId = jobId
        self.artifactId = artifactId
        self.subtitle = subtitle
        self.theme = theme
        self.template = template
        self.artifactParts = artifactParts
        self.artifactEndpoint = artifactEndpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        format = (LenientJSON.string(container, "format") ?? "").lowercased()
        name = LenientJSON.string(container, "filename") ?? LenientJSON.string(container, "name")
        title = LenientJSON.string(container, "title")
        pages = LenientJSON.int(container, "pageCount") ?? LenientJSON.int(container, "pages")
        artifactId = LenientJSON.string(container, "artifactId")
        jobId = LenientJSON.string(container, "jobId") ?? artifactId
        subtitle = LenientJSON.string(container, "subtitle")
        theme = LenientJSON.string(container, "theme")
        template = LenientJSON.string(container, "template")
        artifactParts = LenientJSON.int(container, "artifactParts")
        artifactEndpoint = LenientJSON.string(container, "artifactEndpoint")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(name, forKey: AnyCodingKey("filename"))
        try container.encodeIfPresent(title, forKey: AnyCodingKey("title"))
        try container.encodeIfPresent(subtitle, forKey: AnyCodingKey("subtitle"))
        try container.encodeIfPresent(theme, forKey: AnyCodingKey("theme"))
        try container.encodeIfPresent(template, forKey: AnyCodingKey("template"))
        try container.encodeIfPresent(pages, forKey: AnyCodingKey("pageCount"))
        try container.encode(format, forKey: AnyCodingKey("format"))
        try container.encodeIfPresent(artifactId, forKey: AnyCodingKey("artifactId"))
        try container.encodeIfPresent(artifactParts, forKey: AnyCodingKey("artifactParts"))
        try container.encodeIfPresent(artifactEndpoint, forKey: AnyCodingKey("artifactEndpoint"))
    }

    /// A durable long file the client may preview and export: the fence names an artifact, the
    /// endpoint is the one route we accept, and the format is one the reader understands.
    var isDurableLongFile: Bool {
        guard let artifactId, !artifactId.isEmpty else { return false }
        guard let endpoint = artifactEndpoint, endpoint.hasPrefix("/api/chat/job/file?id=") else { return false }
        guard let pages, pages > 0 else { return false }
        return format == "pdf" || format == "docx"
    }
}

/// Every structured fence a message body may carry. Anything else renders as a plain code block.
enum FirasFence: Sendable, Equatable {
    case code(CodeMeta, body: String)
    case file(FileMeta)
    case image(MediaMeta)
    case video(MediaMeta)
    case music(MediaMeta)
    case agent(AgentJob)
    case project(CodeProject)
    case ask(AskSpec)
    case sources([BrainSource])
    case plot(String)

    /// The fence names a card is drawn for. Order matches the web's dispatch
    /// (agent → project → image → music → video → code → file).
    static let recognisedNames: [String] = [
        "firas-agent", "firas-project", "firas-image", "firas-music", "firas-video",
        "firas-code", "firas-file", "firas-ask", "firas-sources", "firas-code-chat", "plot"
    ]

    /// A body whose fence name is known, turned into a card. `nil` means "render it as code".
    static func parse(name: String, body: String) -> FirasFence? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "firas-agent":
            guard let job = AgentJob.decodeBody(body) else { return nil }
            return .agent(job)

        case "firas-project":
            guard let project = try? CodeProject.decode(fromFenceBody: body) else { return nil }
            return .project(project)

        case "firas-image", "firas-video", "firas-music":
            guard let meta = MediaMeta.parse(fenceName: name.lowercased(), body: body) else { return nil }
            switch meta.kind {
            case .image: return .image(meta)
            case .video: return .video(meta)
            case .music: return .music(meta)
            }

        case "firas-code":
            // The meta is a single JSON line, then the code.
            let (metaLine, code) = FirasFence.splitFirstLine(body)
            guard let data = metaLine.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let meta = try? JSONDecoder().decode(CodeMeta.self, from: data) else {
                return nil
            }
            return .code(meta, body: code)

        case "firas-file":
            guard let data = trimmed.data(using: .utf8),
                  let meta = try? JSONDecoder().decode(FileMeta.self, from: data),
                  !meta.format.isEmpty else {
                return nil
            }
            return .file(meta)

        case "firas-ask":
            guard let spec = AskSpec.parse(body) else { return nil }
            return .ask(spec)

        case "firas-sources":
            guard let data = trimmed.data(using: .utf8),
                  let sources = try? JSONDecoder().decode([BrainSource].self, from: data),
                  !sources.isEmpty else {
                return nil
            }
            return .sources(sources)

        case "plot":
            guard !trimmed.isEmpty else { return nil }
            return .plot(trimmed)

        default:
            return nil
        }
    }

    /// The first ```` ```firas-* ```` (or `plot`) fence in a message.
    ///
    /// `body` keeps whatever followed the name on the opening line — that is where a
    /// ```` ```firas-code {json} ```` meta object lives. A `firas-code` body is raw code that may
    /// itself contain fences, so its closing marker is the **last** one, not the first.
    static func firstFence(in markdown: String) -> (name: String, body: String, range: Range<String.Index>)? {
        var lineStart = markdown.startIndex
        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let name = String(info.prefix(while: { !$0.isWhitespace })).lowercased()
                if recognisedNames.contains(name) {
                    let inline = String(info.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                    let closes = closingLines(in: markdown, after: lineEnd)
                    guard let close = (name == "firas-code" ? closes.last : closes.first) else { return nil }

                    let bodyStart = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
                    var body = bodyStart <= close.start ? String(markdown[bodyStart..<close.start]) : ""
                    if body.hasSuffix("\n") { body.removeLast() }
                    if !inline.isEmpty {
                        body = body.isEmpty ? inline : inline + "\n" + body
                    }
                    return (name: name, body: body, range: lineStart..<close.end)
                }
            }

            lineStart = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
        }
        return nil
    }

    /// Every standalone ```` ``` ```` line after `searchFrom`, as (line start, line end).
    private static func closingLines(
        in markdown: String,
        after searchFrom: String.Index
    ) -> [(start: String.Index, end: String.Index)] {
        var found: [(start: String.Index, end: String.Index)] = []
        var cursor = searchFrom < markdown.endIndex ? markdown.index(after: searchFrom) : markdown.endIndex
        while cursor < markdown.endIndex {
            let lineEnd = markdown[cursor...].firstIndex(of: "\n") ?? markdown.endIndex
            if markdown[cursor..<lineEnd].trimmingCharacters(in: .whitespaces) == "```" {
                found.append((start: cursor, end: lineEnd))
            }
            cursor = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
        }
        return found
    }

    /// `(first line, everything after it)`.
    private static func splitFirstLine(_ text: String) -> (String, String) {
        guard let breakIndex = text.firstIndex(of: "\n") else { return (text, "") }
        let rest = text.index(after: breakIndex)
        return (String(text[text.startIndex..<breakIndex]), String(text[rest...]))
    }
}
