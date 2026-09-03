import Foundation

/// A whole conversation as one document — the web's `chatExportMarkdown` (`app.js:78909`), ported.
///
/// The shape is the web's, verbatim, because it is the shape people already receive from Firas: a
/// level-1 title, an italic meta line (`صُدِّر من فِراس AI · الأسئلة: ٧ · ٣ سبتمبر ٢٠٢٦`), then
/// `## ١. أنت` for each question and `### فِراس` for each answer, with every turn's own headings
/// pushed one level deeper so a user's `# heading` can never outrank the transcript.
///
/// **The owner's report — «لازم كلشي»: every turn, in order.** The document is now built from
/// `turns(_:lang:)`, one ordered array produced by a single pass over `conversation.messages`, and
/// *every* writer — Markdown, plain text, Word, HTML, the workbook, the deck, the PDF and the
/// picture — consumes that same array. Nothing downstream can decide to keep only some of it: the
/// only two things this file will not carry are an empty message and the app's own offline apology,
/// and both refuse loudly (`isApology`) rather than silently.
///
/// **Nothing is ever assembled as one enormous string.** `stream(_:lang:_:)` hands the document over
/// one chunk at a time so the text writers can append straight to a file, and `blocks(_:lang:)`
/// parses one turn at a time so the Office writers never see a megabyte-long `String`.
///
/// **Math is never flattened across the document.** `MathScanner`'s `$$…$$` pairing is unbounded,
/// so a single unbalanced `$$` in turn 2 pairs with turn 8's and swallows six turns whole. The text
/// forms flatten inside each turn; the structured form hands each turn's markdown to
/// `ExportMarkdown.blocks`, which flattens inside each *block* — tighter still, and the only way a
/// display equation survives as an equation rather than as a paragraph of symbols.
///
/// Two invisible marks and no more, and only in the *markdown* form of an Arabic document:
/// * `U+200F` (RLM) opens the *content* of a line this file composes — after `## `, after `- `,
///   before `**` — so a viewer that reads a line's base direction from its first strong character
///   gets Arabic even when the line opens on a digit.
/// * `U+2066 … U+2069` (LRI … PDI) wrap an LTR atom — a file path — so it stays one unbreakable
///   left-to-right unit inside an Arabic sentence.
///
/// `blocks(_:lang:)` carries **neither** mark: a Word run gets its direction from `w:rtl`, and an
/// RLM inside the text would additionally be miscounted as Arabic by `ExportOOXML.isRightToLeft`.
///
/// An English transcript comes out byte-clean, with neither mark in it.
enum ExportTranscript {

    private static let rlm = "\u{200F}"
    private static let lri = "\u{2066}"
    private static let pdi = "\u{2069}"

    // MARK: - One turn of the conversation

    /// One half of one exchange, already shaped: the heading it is filed under, the depth of that
    /// heading, and the markdown underneath it with the speaker's own headings pushed below.
    ///
    /// A struct and not a formatted string because four different writers need different things
    /// from it — Word wants a style name, the deck wants a slide title, the picture wants a tinted
    /// question block — and every one of them must be looking at the *same* list of turns.
    struct Turn: Sendable, Equatable {

        enum Speaker: Sendable, Equatable {
            /// The nth question, counted from one exactly as the web counts it.
            case question(Int)
            case answer
        }

        let speaker: Speaker
        /// `١. أنت` / `فِراس`, in the document's language. No invisible marks.
        let heading: String
        /// `2` for a question, `3` for an answer — the web's levels.
        let level: Int
        /// The turn's markdown. Its own headings are already nested below `level`.
        let body: String

        var isQuestion: Bool {
            if case .question = speaker { return true }
            return false
        }
    }

    /// `true` when the conversation has at least one question **and** one answer. A thread of
    /// nothing but questions is not a transcript, and the caller should not offer the export.
    static func isExportable(_ conversation: ChatConversation) -> Bool {
        var questions = 0
        var answers = 0
        for message in conversation.messages {
            guard !message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            switch message.role {
            case .user: questions += 1
            case .assistant where !isApology(message): answers += 1
            default: continue
            }
        }
        return questions > 0 && answers > 0
    }

    /// The document's own language, which is not the interface's: an Arabic conversation opened in
    /// an English session still comes out with Arabic headings.
    static func language(of conversation: ChatConversation, fallback: AppLanguage) -> AppLanguage {
        var sample = ""
        for message in conversation.messages {
            let body = message.visibleContent
            if body.hasPrefix("```firas-") { continue }
            sample += body + " "
            if sample.count > 4_000 { break }
        }
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return ExportOOXML.isRightToLeft(sample) ? .arabic : .english
    }

    // MARK: - Every turn, in order

    /// Every turn, in `messages` order, handed over one at a time.
    ///
    /// **This is the one place the transcript is gathered.** One pass, forward, calling `visit` as
    /// it goes: there is no index arithmetic here, no `first` and no `last`, so a ten-turn
    /// conversation yields twenty turns — question one, answer one, question two, answer two, … —
    /// and cannot yield anything else. Every writer in this group reaches the conversation through
    /// this function and through nothing else.
    ///
    /// A closure rather than an array because only one turn's markdown is alive at a time: a
    /// three-hundred-turn conversation streams to disk without the document ever existing whole.
    static func forEachTurn(
        _ conversation: ChatConversation,
        lang: AppLanguage,
        _ visit: (Turn) throws -> Void
    ) rethrows {
        let arabic = lang == .arabic
        var asked = 0

        for message in conversation.messages {
            switch message.role {
            case .user:
                let body = question(message, lang: lang, arabic: arabic)
                guard !body.isEmpty else { continue }
                asked += 1
                let head = ArabicText.count(asked, lang) + ". " + Copy.you(lang)
                try visit(Turn(speaker: .question(asked), heading: head, level: 2, body: body))

            case .assistant:
                guard !isApology(message) else { continue }
                let body = answer(message, lang: lang, arabic: arabic)
                guard !body.isEmpty else { continue }
                try visit(Turn(speaker: .answer, heading: Copy.firas(lang), level: 3, body: body))

            default:
                continue
            }
        }
    }

    /// The same turns, collected. For callers that genuinely need the list — a test, a count, the
    /// picture's pagination — and for nobody who is only going to iterate it once.
    static func turns(_ conversation: ChatConversation, lang: AppLanguage) -> [Turn] {
        var out: [Turn] = []
        out.reserveCapacity(conversation.messages.count)
        forEachTurn(conversation, lang: lang) { out.append($0) }
        return out
    }

    /// The document's title and its meta line, before any turn.
    static func header(_ conversation: ChatConversation, lang: AppLanguage) -> (title: String, meta: String) {
        let flattened = flatten(conversation.title)
        let title = flattened.isEmpty ? Copy.untitled(lang) : flattened

        let asked = conversation.messages.reduce(into: 0) { total, message in
            guard message.role == .user else { return }
            guard !message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            total += 1
        }

        var parts: [String] = [Copy.from(lang)]
        if asked > 0 {
            parts.append(Copy.asks(lang) + ": " + ArabicText.count(asked, lang))
        }
        let day = today(lang)
        if !day.isEmpty { parts.append(day) }
        return (title: title, meta: parts.joined(separator: " \u{00B7} "))
    }

    // MARK: - Markdown

    /// The whole conversation as one markdown document, byte-identical to what the web downloads.
    ///
    /// Built through `stream`, so there is exactly one place that decides what a transcript
    /// contains and in what order.
    static func markdown(_ conversation: ChatConversation, lang: AppLanguage) -> String {
        var out = ""
        out.reserveCapacity(4_096)
        stream(conversation, lang: lang) { chunk in out += chunk }
        return out
    }

    /// The document, one chunk at a time: the header, then one chunk per turn.
    ///
    /// The chunks concatenate to exactly what `markdown` returns — that is the contract, and it is
    /// what lets `.md` and `.txt` be written straight to a file handle without a 40 MB `String`
    /// ever existing. `emit` may throw (a failed write), and the throw comes back out.
    static func stream(
        _ conversation: ChatConversation,
        lang: AppLanguage,
        _ emit: (String) throws -> Void
    ) rethrows {
        let arabic = lang == .arabic
        let head = header(conversation, lang: lang)

        var opening = "# " + lead(head.title, arabic: arabic) + head.title + "\n"
        opening += "\n"
        opening += lead(head.meta, arabic: arabic) + "*" + head.meta + "*" + "\n"
        try emit(opening)

        try forEachTurn(conversation, lang: lang) { turn in
            let marker = String(repeating: "#", count: turn.level)
            var chunk = "\n"
            chunk += marker + " " + lead(turn.heading, arabic: arabic) + heading(turn, arabic: arabic) + "\n"
            chunk += "\n"
            chunk += turn.body + "\n"
            try emit(chunk)
        }
    }

    /// The markdown spelling of a turn's heading: the question number is an LTR atom inside an
    /// Arabic line, so it travels in an isolate. The structured forms carry no isolate — see the
    /// type comment.
    private static func heading(_ turn: Turn, arabic: Bool) -> String {
        guard arabic, case .question(let number) = turn.speaker else { return turn.heading }
        let counted = ArabicText.count(number, .arabic) + "."
        return isolate(counted, arabic: true) + " " + Copy.you(.arabic)
    }

    // MARK: - Structured blocks

    /// The whole conversation as ordered `ExportBlock`s — what Word, HTML, the workbook and the
    /// deck are built from.
    ///
    /// Parsed **one turn at a time**: peak memory is one turn's markdown, not the document's, and
    /// a `$$` opened in one answer cannot pair with a `$$` in another. The blocks come back in
    /// conversation order with each turn's heading in front of it, so a reader of the finished
    /// `.docx` walks the same path the reader of the chat walked.
    static func blocks(_ conversation: ChatConversation, lang: AppLanguage) -> [ExportBlock] {
        let head = header(conversation, lang: lang)
        var out: [ExportBlock] = []
        out.append(.heading(level: 1, spans: [ExportInline(text: head.title)]))
        out.append(.paragraph([ExportInline(text: head.meta, italic: true)]))

        forEachTurn(conversation, lang: lang) { turn in
            out.append(.heading(level: turn.level, spans: [ExportInline(text: turn.heading)]))
            // The turn's own markdown, LaTeX intact. `ExportMarkdown.blocks` flattens per block —
            // which is tighter than per turn, and is what lets a `$$…$$` come out as an equation
            // instead of as a paragraph of symbols.
            out.append(contentsOf: ExportMarkdown.blocks(from: turn.body))
        }
        return out
    }

    // MARK: - One question

    /// A question is prose plus, when the user attached something, one line naming what they
    /// attached. The web's transcript predates attachments and loses them; a reader who cannot see
    /// that a PDF was in the question cannot follow the answer to it.
    private static func question(_ message: ChatMessage, lang: AppLanguage, arabic: Bool) -> String {
        let source = message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        var names: [String] = []
        for chip in message.files ?? [] {
            let name = flatten(chip.name)
            if !name.isEmpty { names.append(isolate("`" + name + "`", arabic: arabic)) }
        }
        let pictures = (message.imageThumbs ?? []).count + (message.images ?? []).count
        if pictures > 0 {
            names.append(Copy.pictures(lang) + ": " + ArabicText.count(pictures, lang))
        }

        guard !names.isEmpty else { return nesting(source, by: 2) }
        let attached = pair(
            Copy.attached(lang),
            names.prefix(20).joined(separator: arabic ? "\u{060C} " : ", "),
            arabic: arabic
        )
        guard !source.isEmpty else { return attached }
        return nesting(source, by: 2) + "\n\n" + attached
    }

    // MARK: - One answer

    /// A structured turn is not prose: a `firas-code` block keeps its code, a file/image/video/agent
    /// reference is replaced by the one line that says what it was, and nothing ever writes a JSON
    /// meta object into a file a person is going to read.
    private static func answer(_ message: ChatMessage, lang: AppLanguage, arabic: Bool) -> String {
        let source = message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }

        guard let fence = FirasFence.firstFence(in: source),
              let parsed = FirasFence.parse(name: fence.name, body: fence.body) else {
            return nesting(source, by: 3)
        }

        var rows: [String] = []
        let before = String(source[source.startIndex..<fence.range.lowerBound])
        let after = String(source[fence.range.upperBound...])
        let rest = nesting(
            (before + "\n" + after).trimmingCharacters(in: .whitespacesAndNewlines),
            by: 3
        )

        switch parsed {
        case .code(let meta, let body):
            if let name = meta.name, !name.isEmpty {
                rows.append(pair(Copy.file(lang), isolate("`" + flatten(name) + "`", arabic: arabic), arabic: arabic))
                rows.append("")
            }
            rows.append(codeFence(body, language: meta.lang ?? ""))

        case .file(let meta):
            let name = flatten(meta.name ?? meta.title ?? "")
            rows.append(
                pair(
                    Copy.file(lang),
                    name.isEmpty ? meta.format.uppercased() : isolate("`" + name + "`", arabic: arabic),
                    arabic: arabic
                )
            )

        case .image(let meta):
            rows.append(pair(Copy.picture(lang), flatten(meta.prompt), arabic: arabic))

        case .video(let meta):
            rows.append(pair(Copy.clip(lang), flatten(meta.prompt), arabic: arabic))

        case .music(let meta):
            rows.append(pair(Copy.song(lang), flatten(meta.prompt), arabic: arabic))

        case .agent(let job):
            rows.append(pair(Copy.mission(lang), flatten(job.title), arabic: arabic))

        case .project(let project):
            rows.append(pair(Copy.project(lang), flatten(project.name), arabic: arabic))
            rows.append("")
            for file in project.files.prefix(60) {
                rows.append("- " + isolate("`" + flatten(file.path) + "`", arabic: arabic))
            }

        case .deck(let deck):
            rows.append(pair(Copy.deck(lang), flatten(deck.title), arabic: arabic))
            rows.append("")
            for slide in deck.slides.prefix(60) where !flatten(slide.title).isEmpty {
                rows.append("- " + flatten(slide.title))
            }

        case .sources, .ask, .plot:
            return nesting(source, by: 3)
        }

        if !rest.isEmpty { rows.append(rest) }
        let joined = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? lead(Copy.empty(lang), arabic: arabic) + "*" + Copy.empty(lang) + "*" : joined
    }

    /// A fence long enough for its own body: a README or an HTML page with a sample in it carries
    /// its own backticks, and a three-backtick wrapper around one of those spills the rest of the
    /// file into the document as prose.
    private static func codeFence(_ code: String, language: String) -> String {
        var length = 3
        var run = 0
        for character in code {
            if character == "`" {
                run += 1
                if run >= length { length = run + 1 }
            } else {
                run = 0
            }
        }
        let bar = String(repeating: "`", count: length)
        return bar + language + "\n" + code + "\n" + bar
    }

    // MARK: - Markdown shaping

    /// Heading levels pushed `deeper` steps down, fence-aware. `h6` is the floor.
    static func nesting(_ markdown: String, by deeper: Int) -> String {
        guard deeper > 0 else { return markdown }
        let pad = String(repeating: "#", count: deeper)
        let ceiling = 6 - deeper
        var fence: Character?
        var out: [String] = []

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let backticks = trimmed.prefix(while: { $0 == "`" })
            let tildes = trimmed.prefix(while: { $0 == "~" })
            let marker: Character? = backticks.count >= 3 ? "`" : (tildes.count >= 3 ? "~" : nil)
            if let marker {
                if fence == nil {
                    fence = marker
                } else if fence == marker {
                    fence = nil
                }
                out.append(line)
                continue
            }
            if fence != nil {
                out.append(line)
                continue
            }
            let hashes = trimmed.prefix(while: { $0 == "#" })
            if !hashes.isEmpty, hashes.count <= ceiling,
               trimmed.dropFirst(hashes.count).first == " " {
                out.append(pad + line)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// `**label:** value` — never `value label`. Arabic agrees a counted or qualified noun with what
    /// follows it four different ways; putting the label first sidesteps the agreement, and the
    /// direction mark is decided by the label alone so a Latin path cannot outvote it.
    private static func pair(_ label: String, _ value: String, arabic: Bool) -> String {
        guard !value.isEmpty else { return lead(label, arabic: arabic) + "**" + label + "**" }
        return lead(label, arabic: arabic) + "**" + label + ":** " + value
    }

    private static func lead(_ text: String, arabic: Bool) -> String {
        guard arabic, ExportOOXML.isRightToLeft(text) else { return "" }
        return rlm
    }

    private static func isolate(_ value: String, arabic: Bool) -> String {
        arabic ? lri + value + pdi : value
    }

    private static func flatten(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The app's own offline apology is not an answer, and a transcript that quotes it back reads
    /// as the product apologising to itself.
    private static func isApology(_ message: ChatMessage) -> Bool {
        switch message.status {
        case .queuedOffline, .failed:
            return true
        case .delivered, .sending, .streaming, .stopped:
            return message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func today(_ lang: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang == .arabic ? "ar" : "en_GB")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM y")
        return formatter.string(from: Date())
    }

    // MARK: - Copy

    /// `CHAT_MD_L` (`app.js:78791`), verbatim in both languages.
    private enum Copy {
        static let you = LText(ar: "أنت", en: "You")
        static let firas = LText(ar: "فِراس", en: "Firas")
        static let from = LText(ar: "صُدِّر من فِراس AI", en: "Exported from Firas AI")
        static let untitled = LText(ar: "محادثة بلا عنوان", en: "Untitled conversation")
        static let asks = LText(ar: "الأسئلة", en: "Questions")
        static let file = LText(ar: "ملف", en: "File")
        static let picture = LText(ar: "صورة", en: "Picture")
        static let clip = LText(ar: "مقطع", en: "Clip")
        static let project = LText(ar: "مشروع", en: "Project")
        static let deck = LText(ar: "عرض تقديمي", en: "Presentation")
        static let empty = LText(ar: "لا نص في هذه الرسالة.", en: "This message has no text.")
        /// No web twin: the site's transcript predates songs, missions and attachments.
        static let song = LText(ar: "أغنية", en: "Song")
        static let mission = LText(ar: "مهمة", en: "Mission")
        static let attached = LText(ar: "مُرفَق", en: "Attached")
        static let pictures = LText(ar: "صور", en: "Images")
    }
}
