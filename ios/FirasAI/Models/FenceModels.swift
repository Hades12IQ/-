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
    var serverPdf: Bool?
    var counteddoc: Bool?
    var sha256: String?
    var pdfBytes: Int?
    var expectedItems: Int?
    var requiresSolutions: Bool?
    var solutionsAtEnd: Bool?
    var partial: Bool?
    var completedItems: Int?
    var remainingItems: Int?
    var resumeJobId: String?

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
        artifactEndpoint: String? = nil,
        serverPdf: Bool? = nil,
        counteddoc: Bool? = nil,
        sha256: String? = nil,
        pdfBytes: Int? = nil,
        expectedItems: Int? = nil,
        requiresSolutions: Bool? = nil,
        solutionsAtEnd: Bool? = nil,
        partial: Bool? = nil,
        completedItems: Int? = nil,
        remainingItems: Int? = nil,
        resumeJobId: String? = nil
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
        self.serverPdf = serverPdf
        self.counteddoc = counteddoc
        self.sha256 = sha256
        self.pdfBytes = pdfBytes
        self.expectedItems = expectedItems
        self.requiresSolutions = requiresSolutions
        self.solutionsAtEnd = solutionsAtEnd
        self.partial = partial
        self.completedItems = completedItems
        self.remainingItems = remainingItems
        self.resumeJobId = resumeJobId
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
        serverPdf = LenientJSON.bool(container, "serverPdf")
        counteddoc = LenientJSON.bool(container, "counteddoc")
        sha256 = LenientJSON.string(container, "sha256")
        pdfBytes = LenientJSON.int(container, "pdfBytes")
        expectedItems = LenientJSON.int(container, "expectedItems")
        requiresSolutions = LenientJSON.bool(container, "requiresSolutions")
        solutionsAtEnd = LenientJSON.bool(container, "solutionsAtEnd")
        partial = LenientJSON.bool(container, "partial")
        completedItems = LenientJSON.int(container, "completedItems")
        remainingItems = LenientJSON.int(container, "remainingItems")
        resumeJobId = LenientJSON.string(container, "resumeJobId")
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
        try container.encodeIfPresent(serverPdf, forKey: AnyCodingKey("serverPdf"))
        try container.encodeIfPresent(counteddoc, forKey: AnyCodingKey("counteddoc"))
        try container.encodeIfPresent(sha256, forKey: AnyCodingKey("sha256"))
        try container.encodeIfPresent(pdfBytes, forKey: AnyCodingKey("pdfBytes"))
        try container.encodeIfPresent(expectedItems, forKey: AnyCodingKey("expectedItems"))
        try container.encodeIfPresent(requiresSolutions, forKey: AnyCodingKey("requiresSolutions"))
        try container.encodeIfPresent(solutionsAtEnd, forKey: AnyCodingKey("solutionsAtEnd"))
        try container.encodeIfPresent(partial, forKey: AnyCodingKey("partial"))
        try container.encodeIfPresent(completedItems, forKey: AnyCodingKey("completedItems"))
        try container.encodeIfPresent(remainingItems, forKey: AnyCodingKey("remainingItems"))
        try container.encodeIfPresent(resumeJobId, forKey: AnyCodingKey("resumeJobId"))
    }

    /// A durable long file the client may preview and export: the fence names an artifact, the
    /// endpoint is the one route we accept, and the format is one the reader understands.
    var isDurableLongFile: Bool {
        guard !usesServerPDFDownload else { return false }
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
    case deck(DeckMeta)
    case sources([BrainSource])
    case plot(String)

    /// The fence names a card is drawn for. Order matches the web's dispatch
    /// (agent → project → image → music → video → code → file).
    static let recognisedNames: [String] = [
        "firas-agent", "firas-project", "firas-image", "firas-music", "firas-video",
        "firas-code", "firas-file", "firas-ask", "firas-deck", "firas-sources",
        "firas-code-chat", "plot"
    ]

    /// A `firas-*` fence that has been opened and not yet closed, with whatever came before it.
    ///
    /* WHILE A CARD IS BEING WRITTEN THERE IS NO CARD YET, and until this existed the reader
       watched its source code arrive instead: the engine's English style string, the JSON
       braces, every line of the lyrics. The web has hidden the same thing since app.js:3790
       for `firas-ask`, and this app hid it for `firas-ask` alone — a song, a picture and a
       clip were left to stream their own metadata at the person who asked for them. */
    struct OpenFence: Sendable, Equatable {
        /// The answer written before the fence opened. It is a real answer and stays on screen.
        let before: String
        /// The fence's name, lowercased.
        let name: String
    }

    /// The last fence left open, or `nil` when every fence in the text is closed.
    static func openFence(in markdown: String) -> OpenFence? {
        var lineStart = markdown.startIndex
        var opened: (name: String, start: String.Index)?
        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if let marker = line.first, marker == "`" || marker == "~", line.count >= 3 {
                var name = Substring(line)
                while let head = name.first, head == marker { name = name.dropFirst() }
                if opened == nil {
                    opened = (name.trimmingCharacters(in: .whitespaces).lowercased(), lineStart)
                } else {
                    opened = nil
                }
            }
            if lineEnd == markdown.endIndex { break }
            lineStart = markdown.index(after: lineEnd)
        }
        guard let opened, !opened.name.isEmpty else { return nil }
        return OpenFence(
            before: String(markdown[markdown.startIndex..<opened.start]),
            name: opened.name
        )
    }

    /// The fences whose body is one JSON object, and which can therefore be repaired when the
    /// model writes the name without its backticks. `firas-code` is deliberately absent: its body
    /// is a metadata line followed by source, not an object, and guessing where the source ends is
    /// not a repair.
    private static let jsonBodyNames: Set<String> = [
        "firas-file", "firas-image", "firas-video", "firas-music",
        "firas-agent", "firas-project", "firas-deck", "firas-sources", "firas-ask"
    ]

    /// Puts back a fence the model left off.
    ///
    /* EVERYTHING DOWNSTREAM IS KEYED ON THE FENCE. `MarkdownBlocks` calls `parse(name:body:)`
       only for a fenced block, so a metadata block written as bare text is a paragraph - and a
       paragraph is what the reader got where their document should have been: the word
       `firas-file` and a line of JSON, with no card, no Open and no file. Worse, the design
       ITSELF was written correctly inside its ```html fence, and `hidingDesign` removed it as it
       is supposed to, so the only part of the answer left on screen was the part that was never
       meant to be read.
       A prompt can make a model likely to write the backticks; it cannot make it certain. The
       marker is therefore repaired rather than demanded. A line that is EXACTLY a known name,
       outside any fence, and followed by a JSON object, gets the fence it should have had - and
       a bare word with no object after it is left exactly where it is. */
    static func fencingBareMarkers(in markdown: String) -> String {
        guard markdown.contains("firas-") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count + 4)
        var insideFence = false
        var repaired = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                out.append(line)
                index += 1
                continue
            }
            guard !insideFence, jsonBodyNames.contains(trimmed.lowercased()) else {
                out.append(line)
                index += 1
                continue
            }
            var probe = index + 1
            while probe < lines.count, lines[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                probe += 1
            }
            guard probe < lines.count,
                  lines[probe].trimmingCharacters(in: .whitespaces).hasPrefix("{"),
                  let last = objectEnd(in: lines, from: probe) else {
                out.append(line)
                index += 1
                continue
            }
            out.append("```" + trimmed.lowercased())
            out.append(contentsOf: lines[probe...last])
            out.append("```")
            repaired = true
            index = last + 1
        }
        return repaired ? out.joined(separator: "\n") : markdown
    }

    /// The index of the line on which the JSON object starting at `start` closes.
    ///
    /// Braces inside a string do not count, and neither does an escaped quote - a filename or a
    /// title is model-written text and may contain either. The scan gives up after forty lines so
    /// that an unbalanced brace in ordinary prose can never make this walk an entire answer.
    private static func objectEnd(in lines: [String], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = start
        while index < lines.count, index - start <= 40 {
            var escaped = false
            for character in lines[index] {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { inString.toggle(); continue }
                if inString { continue }
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return nil
    }

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
            /* `format` IS NOT IN THIS BLOCK, and requiring it is why asking for a file never
               produced one. The server's finished long-file reference carries `format`
               (`server-chat-jobs-chats.md §4.3`), but the metadata block the model is told to write
               for every ORDINARY file is `{filename, title, subtitle, theme, accent, template}` and
               nothing else (`web-prompt-builder.md §A.6`) — on the web the format comes from the
               REQUEST (`resolvedFileFormat`, app.js:3075), never from the answer. With the guard
               here, every one of those fences failed to parse and rendered as a block of raw JSON
               with no card, no Open and no download. The host resolves the format from the user's
               turn; this only has to recognise a real metadata block. */
            guard let data = trimmed.data(using: .utf8),
                  let meta = try? JSONDecoder().decode(FileMeta.self, from: data) else {
                return nil
            }
            let named = !meta.format.isEmpty
                || !(meta.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                || !(meta.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            guard named else { return nil }
            return .file(meta)

        case "firas-ask":
            guard let spec = AskSpec.parse(body) else { return nil }
            return .ask(spec)

        case "firas-deck":
            /* THE APP DID NOT KNOW THIS FENCE. Every presentation the model produced fell
               through to the plain-code renderer and arrived as a screenful of raw JSON.
               A body with no `slides` array still does — it is not a deck, and rendering it
               as code is the right answer for it. */
            guard let deck = DeckMeta.parse(body: body) else { return nil }
            return .deck(deck)

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
            let lineEnd = markdown[lineStart...].firstIndex(where: \.isNewline) ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let markerCount = trimmed.prefix(while: { $0 == marker }).count
                guard markerCount >= 3 else {
                    lineStart = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
                    continue
                }
                let info = String(trimmed.dropFirst(markerCount)).trimmingCharacters(in: .whitespaces)
                let name = String(info.prefix(while: { !$0.isWhitespace })).lowercased()
                if recognisedNames.contains(name) {
                    let inline = String(info.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                    let closes = closingLines(in: markdown, after: lineEnd, marker: marker, minimumCount: markerCount)
                    guard let close = (name == "firas-code" ? closes.last : closes.first) else { return nil }

                    let bodyStart = lineEnd < markdown.endIndex ? markdown.index(after: lineEnd) : markdown.endIndex
                    var body = bodyStart <= close.start ? String(markdown[bodyStart..<close.start]) : ""
                    if body.last?.isNewline == true { body.removeLast() }
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
        after searchFrom: String.Index,
        marker: Character = "`",
        minimumCount: Int = 3
    ) -> [(start: String.Index, end: String.Index)] {
        var found: [(start: String.Index, end: String.Index)] = []
        var cursor = searchFrom < markdown.endIndex ? markdown.index(after: searchFrom) : markdown.endIndex
        while cursor < markdown.endIndex {
            let lineEnd = markdown[cursor...].firstIndex(where: \.isNewline) ?? markdown.endIndex
            let line = markdown[cursor..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.count >= minimumCount && line.allSatisfy({ $0 == marker }) {
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
