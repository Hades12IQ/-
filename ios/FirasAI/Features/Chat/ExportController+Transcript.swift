import Foundation

/// A whole conversation as one document — the web's `chatExportMarkdown` (`app.js:78710`), ported.
///
/// The shape is the web's, verbatim, because it is the shape people already receive from Firas: a
/// level-1 title, an italic meta line (`صُدِّر من فِراس AI · الأسئلة: ٧ · ٣ سبتمبر ٢٠٢٦`), then
/// `## ١. أنت` for each question and `### فِراس` for each answer, with every turn's own headings
/// pushed one level deeper so a user's `# heading` can never outrank the transcript.
///
/// Two invisible marks and no more, and only for an Arabic document:
/// * `U+200F` (RLM) opens the *content* of a line this file composes — after `## `, after `- `,
///   before `**` — so a viewer that reads a line's base direction from its first strong character
///   gets Arabic even when the line opens on a digit.
/// * `U+2066 … U+2069` (LRI … PDI) wrap an LTR atom — a question number — so it stays one
///   unbreakable left-to-right unit inside an Arabic sentence.
///
/// An English transcript comes out byte-clean, with neither mark in it.
enum ExportTranscript {

    private static let rlm = "\u{200F}"
    private static let lri = "\u{2066}"
    private static let pdi = "\u{2069}"

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

    static func markdown(_ conversation: ChatConversation, lang: AppLanguage) -> String {
        let arabic = lang == .arabic
        var out: [String] = []

        let title = flatten(conversation.title)
        let heading = title.isEmpty ? Copy.untitled(lang) : title
        out.append("# " + lead(heading, arabic: arabic) + heading)

        let questions = conversation.messages.filter { message in
            message.role == .user
                && !message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        var meta: [String] = [Copy.from(lang)]
        if questions > 0 {
            meta.append(Copy.asks(lang) + ": " + isolate(ArabicText.count(questions, lang), arabic: arabic))
        }
        let day = today(lang)
        if !day.isEmpty { meta.append(day) }
        let metaLine = meta.joined(separator: " \u{00B7} ")
        out.append("")
        out.append(lead(metaLine, arabic: arabic) + "*" + metaLine + "*")

        var index = 0
        for message in conversation.messages {
            let body = message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case .user:
                guard !body.isEmpty else { continue }
                index += 1
                let head = isolate(ArabicText.count(index, lang) + ".", arabic: arabic)
                    + " " + Copy.you(lang)
                out.append("")
                out.append("## " + lead(head, arabic: arabic) + head)
                out.append("")
                out.append(nesting(body, by: 2))

            case .assistant:
                guard !isApology(message) else { continue }
                let piece = answer(message, lang: lang, arabic: arabic)
                guard !piece.isEmpty else { continue }
                out.append("")
                out.append("### " + lead(Copy.firas(lang), arabic: arabic) + Copy.firas(lang))
                out.append("")
                out.append(piece)

            default:
                continue
            }
        }

        return out.joined(separator: "\n") + "\n"
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

    /// `CHAT_MD_L` (`app.js:78592`), verbatim in both languages.
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
        static let empty = LText(ar: "لا نص في هذه الرسالة.", en: "This message has no text.")
        /// No web twin: the site's transcript predates songs and missions in the same file.
        static let song = LText(ar: "أغنية", en: "Song")
        static let mission = LText(ar: "مهمة", en: "Mission")
    }
}
