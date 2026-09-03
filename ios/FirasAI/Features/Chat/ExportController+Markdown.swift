import Foundation

/// One run of inline text inside an exported block. The exporters that write real documents —
/// Word, Excel, PowerPoint, HTML — need emphasis as *structure*, not as leftover asterisks, so the
/// markdown is read once here and every writer consumes the same runs.
struct ExportInline: Sendable, Equatable {
    var text: String
    var bold: Bool
    var italic: Bool
    var code: Bool

    init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
    }
}

/// One block of an exported document.
///
/// Deliberately smaller than `MDBlock`: a transcript renderer needs `AttributedString`, a `.docx`
/// writer needs plain runs it can put inside `<w:r>`. Nothing here touches SwiftUI, so every
/// exporter can run off the main actor.
enum ExportBlock: Sendable, Equatable {
    case heading(level: Int, spans: [ExportInline])
    case paragraph([ExportInline])
    case bullet(depth: Int, spans: [ExportInline])
    case numbered(depth: Int, number: Int, spans: [ExportInline])
    case quote([ExportInline])
    case code(language: String, body: String)
    case table(header: [String], rows: [[String]])
    case rule
}

/// Markdown → `[ExportBlock]`.
///
/// A hand-written scanner, for the same reason the transcript has one: a bare-slash regex literal
/// is off in Swift 5 language mode and `NSRegularExpression` around Arabic is a trap. Structured
/// ```` ```firas-* ```` fences are machinery, not prose — they are dropped, exactly as the web's
/// exporters drop them, so a document never carries a JSON block a reader cannot use.
enum ExportMarkdown {

    // MARK: - Blocks

    static func blocks(from markdown: String) -> [ExportBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [ExportBlock] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            paragraph.removeAll(keepingCapacity: true)
            let spans = inlines(from: joined)
            if !plain(spans).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(spans))
            }
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            if let marker = fenceMarker(trimmed) {
                flush()
                let info = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if let closing = fenceMarker(candidate),
                       closing.first == marker.first,
                       closing.count >= marker.count,
                       String(candidate.dropFirst(closing.count))
                        .trimmingCharacters(in: .whitespaces).isEmpty {
                        break
                    }
                    body.append(lines[cursor])
                    cursor += 1
                }
                blocks.append(contentsOf: fenceBlocks(info: info, body: body))
                index = cursor < lines.count ? cursor + 1 : cursor
                continue
            }

            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flush()
                let text = String(trimmed.dropFirst(heading)).trimmingCharacters(in: .whitespaces)
                let spans = inlines(from: text)
                if !plain(spans).isEmpty {
                    blocks.append(.heading(level: min(6, heading), spans: spans))
                }
                index += 1
                continue
            }

            if index + 1 < lines.count,
               trimmed.contains("|"),
               isTableSeparator(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if candidate.isEmpty || !candidate.contains("|") { break }
                    rows.append(cells(candidate))
                    cursor += 1
                }
                blocks.append(.table(header: header, rows: rows))
                index = cursor
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var body = Substring(candidate.dropFirst())
                    if body.first == " " { body = body.dropFirst() }
                    quoted.append(String(body))
                    cursor += 1
                }
                let spans = inlines(from: quoted.joined(separator: " "))
                if !plain(spans).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.quote(spans))
                }
                index = cursor
                continue
            }

            if let item = listItem(raw) {
                flush()
                let spans = inlines(from: item.text)
                if item.ordered {
                    blocks.append(.numbered(depth: item.depth, number: item.number, spans: spans))
                } else {
                    blocks.append(.bullet(depth: item.depth, spans: spans))
                }
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flush()
        return blocks
    }

    // MARK: - Fences

    /// `firas-code` keeps its code (its first line is the meta object); every other `firas-*`
    /// fence, and `plot`, is machinery and is dropped.
    private static func fenceBlocks(info: String, body: [String]) -> [ExportBlock] {
        let name = String(info.prefix(while: { !$0.isWhitespace })).lowercased()
        if name == "firas-code" {
            let code = body.count > 1 ? body.dropFirst().joined(separator: "\n") : ""
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.code(language: "", body: code)]
        }
        if name == "plot" || name.hasPrefix("firas-") { return [] }
        let code = body.joined(separator: "\n")
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.code(language: name, body: code)]
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for character in ["`", "~"] as [Character] {
            let run = trimmed.prefix(while: { $0 == character })
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return hashes.count
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func cells(_ line: String) -> [String] {
        var working = Substring(line.trimmingCharacters(in: .whitespaces))
        if working.first == "|" { working = working.dropFirst() }
        if working.last == "|" { working = working.dropLast() }
        return working
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { plain(inlines(from: String($0).trimmingCharacters(in: .whitespaces))) }
    }

    private struct ListItem {
        let ordered: Bool
        let depth: Int
        let number: Int
        let text: String
    }

    private static func listItem(_ raw: String) -> ListItem? {
        let indent = raw.prefix(while: { $0 == " " || $0 == "\t" })
        let spaces = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var rest = Substring(raw.dropFirst(indent.count))
        guard let first = rest.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            return ListItem(
                ordered: false,
                depth: min(3, spaces / 2),
                number: 0,
                text: String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
            )
        }

        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return ListItem(
            ordered: true,
            depth: min(3, spaces / 2),
            number: Int(digits) ?? 1,
            text: String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    // MARK: - Inline runs

    /// `**bold**`, `__bold__`, `*italic*`, `_italic_`, `` `code` ``, `[label](target)`,
    /// `![alt](src)` and `~~struck~~`. Anything unbalanced stays as literal text — a half-typed
    /// emphasis marker must never eat the rest of a paragraph.
    static func inlines(from line: String) -> [ExportInline] {
        let characters = Array(line)
        var spans: [ExportInline] = []
        var buffer = ""
        var index = 0

        func push(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
            guard !text.isEmpty else { return }
            spans.append(ExportInline(text: text, bold: bold, italic: italic, code: code))
        }

        func flushBuffer() {
            push(buffer)
            buffer = ""
        }

        while index < characters.count {
            let character = characters[index]

            if character == "`" {
                if let close = find("`", in: characters, from: index + 1) {
                    flushBuffer()
                    push(String(characters[(index + 1)..<close]), code: true)
                    index = close + 1
                    continue
                }
            }

            if character == "*" || character == "_" {
                let double = index + 1 < characters.count && characters[index + 1] == character
                let token = double ? String(repeating: String(character), count: 2) : String(character)
                if let close = findToken(token, in: characters, from: index + token.count) {
                    let inner = String(characters[(index + token.count)..<close])
                    if !inner.trimmingCharacters(in: .whitespaces).isEmpty {
                        flushBuffer()
                        for span in inlines(from: inner) {
                            push(
                                span.text,
                                bold: span.bold || double,
                                italic: span.italic || !double,
                                code: span.code
                            )
                        }
                        index = close + token.count
                        continue
                    }
                }
            }

            if character == "~", index + 1 < characters.count, characters[index + 1] == "~",
               let close = findToken("~~", in: characters, from: index + 2) {
                flushBuffer()
                for span in inlines(from: String(characters[(index + 2)..<close])) {
                    spans.append(span)
                }
                index = close + 2
                continue
            }

            if character == "!", index + 1 < characters.count, characters[index + 1] == "[" {
                if let link = readLink(characters, from: index + 1) {
                    flushBuffer()
                    push(link.label.isEmpty ? link.target : link.label)
                    index = link.end
                    continue
                }
            }

            if character == "[", let link = readLink(characters, from: index) {
                flushBuffer()
                if link.label.isEmpty {
                    push(link.target)
                } else if link.target.isEmpty || link.target.hasPrefix("#") {
                    push(link.label)
                } else {
                    push(link.label + " (" + link.target + ")")
                }
                index = link.end
                continue
            }

            buffer.append(character)
            index += 1
        }

        flushBuffer()
        return spans
    }

    private static func find(_ needle: Character, in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            if characters[index] == needle { return index }
            index += 1
        }
        return nil
    }

    private static func findToken(_ token: String, in characters: [Character], from start: Int) -> Int? {
        let needle = Array(token)
        guard !needle.isEmpty else { return nil }
        var index = start
        while index + needle.count <= characters.count {
            var matched = true
            for offset in 0..<needle.count where characters[index + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return index }
            index += 1
        }
        return nil
    }

    private struct Link {
        let label: String
        let target: String
        let end: Int
    }

    private static func readLink(_ characters: [Character], from start: Int) -> Link? {
        guard start < characters.count, characters[start] == "[" else { return nil }
        guard let close = find("]", in: characters, from: start + 1) else { return nil }
        let afterClose = close + 1
        guard afterClose < characters.count, characters[afterClose] == "(" else { return nil }
        guard let paren = find(")", in: characters, from: afterClose + 1) else { return nil }
        return Link(
            label: String(characters[(start + 1)..<close]).trimmingCharacters(in: .whitespaces),
            target: String(characters[(afterClose + 1)..<paren]).trimmingCharacters(in: .whitespaces),
            end: paren + 1
        )
    }

    // MARK: - Reading back

    static func plain(_ spans: [ExportInline]) -> String {
        spans.map(\.text).joined()
    }

    /// The document's own title: the first level-1 heading, else the first heading, else the first
    /// paragraph's opening sentence. Never a formula and never a code line.
    static func inferredTitle(_ blocks: [ExportBlock]) -> String? {
        for block in blocks {
            if case .heading(let level, let spans) = block, level <= 1 {
                let text = plain(spans).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        for block in blocks {
            if case .heading(_, let spans) = block {
                let text = plain(spans).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        for block in blocks {
            if case .paragraph(let spans) = block {
                let text = plain(spans).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return String(text.prefix(80)) }
            }
        }
        return nil
    }

    /// Every table in the document, in order — the spreadsheet writer's input.
    static func tables(_ blocks: [ExportBlock]) -> [(header: [String], rows: [[String]])] {
        var found: [(header: [String], rows: [[String]])] = []
        for block in blocks {
            if case .table(let header, let rows) = block {
                found.append((header: header, rows: rows))
            }
        }
        return found
    }
}
