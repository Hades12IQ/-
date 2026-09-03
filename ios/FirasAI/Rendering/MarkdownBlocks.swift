import Foundation

/// How a table column asked for its cells to sit.
///
/// GFM writes the markers as physical left and right (`:---`, `:---:`, `---:`). In a document whose
/// every block picks its own direction that can only mean *start* and *end*: a column marked
/// `---:` sits on the left of an Arabic table and on the right of a Latin one, and in both it is
/// the far edge — which is what the author meant by writing the marker at all.
enum MDTableAlign: Sendable, Equatable {
    case natural
    case start
    case center
    case end
}

/// One table cell: its inline-parsed text, and the alignment its column asked for.
///
/// The alignment rides on the cell rather than beside the block because `MDBlock.table` is
/// destructured as exactly two associated values in `MarkdownView`, which this scanner does not
/// own. Widening the payload types keeps that pattern match compiling; adding a third value would
/// not.
struct MDTableCell: Sendable, Equatable {
    let text: AttributedString
    let align: MDTableAlign

    init(_ text: AttributedString, align: MDTableAlign) {
        self.text = text
        self.align = align
    }

    var plain: String { String(text.characters) }
}

/// One rendered block of an answer.
indirect enum MDBlock: Sendable, Equatable, Identifiable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case list(ordered: Bool, start: Int, items: [[MDBlock]])
    case quote([MDBlock])
    case table(header: [MDTableCell], rows: [[MDTableCell]])
    case code(lang: String?, String)
    case rule
    case mathDisplay(String)
    case fence(FirasFence)
    case raw(String)

    var id: String {
        switch self {
        case .paragraph(let text):
            return "p:" + MDBlock.digest(String(text.characters))
        case .heading(let level, let text):
            return "h\(level):" + MDBlock.digest(String(text.characters))
        case .list(let ordered, let start, let items):
            return "l\(ordered ? 1 : 0)-\(start)-\(items.count):" + MDBlock.digest(items.first?.first?.id ?? "")
        case .quote(let blocks):
            return "q\(blocks.count):" + MDBlock.digest(blocks.first?.id ?? "")
        case .table(let header, let rows):
            return "t\(header.count)x\(rows.count):"
                + MDBlock.digest(header.map { $0.plain }.joined(separator: "|"))
        case .code(let lang, let body):
            return "c" + (lang ?? "") + ":" + MDBlock.digest(body)
        case .rule:
            return "hr"
        case .mathDisplay(let tex):
            return "m:" + MDBlock.digest(tex)
        case .fence:
            return "f:" + MDBlock.digest(String(describing: self).prefix(200))
        case .raw(let text):
            return "r:" + MDBlock.digest(text)
        }
    }

    /// djb2 — stable across launches, cheap, and only ever used as a view identity.
    private static func digest<S: StringProtocol>(_ s: S) -> String {
        var hash: UInt64 = 5381
        for byte in s.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }
}

/// Hand-written block scanner. `split` returns the raw chunk strings so the renderer can compare
/// them by index and re-parse only the tail; `parse` turns one chunk into one block.
enum MarkdownBlocks {

    // MARK: - Splitting

    static func split(_ markdown: String, streaming: Bool) -> [String] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }
        let lines = normalized.components(separatedBy: "\n")

        var chunks: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }

            if let fence = fenceOpen(line) {
                // A `firas-code` body is raw code that may itself contain fences, so its closing
                // marker is the LAST one — the same rule `FirasFence.firstFence` applies.
                let wantsLastCloser = fenceName(fence.info).lowercased() == "firas-code"
                var j = i + 1
                var closeIndex: Int?
                while j < lines.count {
                    if let close = fenceOpen(lines[j]), close.marker == fence.marker,
                       close.length >= fence.length, close.info.isEmpty {
                        closeIndex = j
                        if !wantsLastCloser { break }
                    }
                    j += 1
                }
                if let end = closeIndex {
                    chunks.append(lines[i...end].joined(separator: "\n"))
                    i = end + 1
                } else {
                    // Mid-stream an open fence is the normal state: hand it back whole so it can
                    // be drawn as plain text until the closer arrives.
                    var body = lines[i...].joined(separator: "\n")
                    if !streaming {
                        body += "\n" + String(repeating: String(fence.marker), count: fence.length)
                    }
                    chunks.append(body)
                    i = lines.count
                }
                continue
            }

            if displayMathOpens(line) {
                if displayMathClosesOnSameLine(line) {
                    chunks.append(line)
                    i += 1
                    continue
                }
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if lines[j].contains("$$") {
                        closed = true
                        break
                    }
                    j += 1
                }
                if closed {
                    chunks.append(lines[i...j].joined(separator: "\n"))
                    i = j + 1
                } else {
                    chunks.append(lines[i...].joined(separator: "\n"))
                    i = lines.count
                }
                continue
            }

            if isRule(line) {
                chunks.append(line)
                i += 1
                continue
            }

            if headingLevel(line) != nil {
                chunks.append(line)
                i += 1
                continue
            }

            if isQuote(line) {
                var j = i + 1
                while j < lines.count {
                    if isQuote(lines[j]) { j += 1; continue }
                    if isBlank(lines[j]) || startsBlock(lines[j]) { break }
                    j += 1
                }
                chunks.append(lines[i..<j].joined(separator: "\n"))
                i = j
                continue
            }

            if listMarker(line) != nil {
                var j = i + 1
                while j < lines.count {
                    let candidate = lines[j]
                    if isBlank(candidate) {
                        var k = j + 1
                        while k < lines.count, isBlank(lines[k]) { k += 1 }
                        if k < lines.count, listMarker(lines[k]) != nil || leadingSpaces(lines[k]) >= 2 {
                            j = k
                            continue
                        }
                        break
                    }
                    if listMarker(candidate) != nil || leadingSpaces(candidate) >= 2 {
                        j += 1
                        continue
                    }
                    if startsBlock(candidate) { break }
                    j += 1
                }
                chunks.append(lines[i..<j].joined(separator: "\n"))
                i = j
                continue
            }

            if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                var j = i + 2
                while j < lines.count, !isBlank(lines[j]), lines[j].contains("|") { j += 1 }
                chunks.append(lines[i..<j].joined(separator: "\n"))
                i = j
                continue
            }

            var j = i + 1
            while j < lines.count {
                let candidate = lines[j]
                if isBlank(candidate) || startsBlock(candidate) { break }
                if candidate.contains("|"), j + 1 < lines.count, isTableDelimiter(lines[j + 1]) { break }
                j += 1
            }
            chunks.append(lines[i..<j].joined(separator: "\n"))
            i = j
        }
        return chunks
    }

    // MARK: - Parsing

    static func parse(_ chunk: String, lang: AppLanguage) -> MDBlock {
        parse(chunk, lang: lang, depth: 0)
    }

    private static func parse(_ chunk: String, lang: AppLanguage, depth: Int) -> MDBlock {
        let lines = chunk.components(separatedBy: "\n")
        guard let first = lines.first, depth < 6 else { return .raw(chunk) }

        if let fence = fenceOpen(first) {
            let rawName = fenceName(fence.info)
            let name = rawName.lowercased()
            // `split` closes a `firas-code` chunk on the LAST marker because its body is raw code
            // that may contain fences; the two scanners must agree or the body is cut in half.
            let wantsLastCloser = name == "firas-code"
            var closeIndex: Int?
            var j = 1
            while j < lines.count {
                if let close = fenceOpen(lines[j]), close.marker == fence.marker,
                   close.length >= fence.length, close.info.isEmpty {
                    closeIndex = j
                    if !wantsLastCloser { break }
                }
                j += 1
            }
            guard let end = closeIndex else { return .raw(chunk) }
            let body = end > 1 ? lines[1..<end].joined(separator: "\n") : ""
            // Whatever followed the name on the opening line belongs to the fence body: a
            // ```firas-code {json} card carries its meta object there, and dropping it turned
            // every code card into a plain block labelled "firas-code".
            let inlineMeta = String(fence.info.dropFirst(rawName.count))
                .trimmingCharacters(in: .whitespaces)
            let fenceBody: String
            if inlineMeta.isEmpty {
                fenceBody = body
            } else {
                fenceBody = body.isEmpty ? inlineMeta : inlineMeta + "\n" + body
            }
            if !name.isEmpty, name.hasPrefix("firas-") || name == "plot" {
                if let parsedFence = FirasFence.parse(name: name, body: fenceBody) {
                    return .fence(parsedFence)
                }
                // A malformed or not-yet-supported card still has to show its contents, but it
                // must not be labelled with the fence name — "FIRAS-CODE" is not a language.
                return .code(lang: nil, body)
            }
            return .code(lang: name.isEmpty ? nil : name, body)
        }

        if displayMathOpens(first) {
            let joined = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if joined.hasPrefix("$$"), joined.hasSuffix("$$"), joined.count >= 4 {
                return .mathDisplay(String(joined.dropFirst(2).dropLast(2)))
            }
            return .raw(chunk)
        }

        if lines.count == 1, isRule(first) { return .rule }

        if lines.count == 1, let heading = headingLevel(first) {
            return .heading(level: heading.level, MarkdownInline.structured(heading.text, lang: lang))
        }

        if isQuote(first) {
            let inner = lines.map { strippingQuoteMarker($0) }.joined(separator: "\n")
            let blocks = split(inner, streaming: false).map { parse($0, lang: lang, depth: depth + 1) }
            return .quote(blocks.isEmpty ? [.paragraph(AttributedString())] : blocks)
        }

        if let marker = listMarker(first) {
            let items = listItems(lines, baseIndent: marker.indent, lang: lang, depth: depth)
            return .list(ordered: marker.ordered, start: marker.ordered ? marker.number : 1, items: items)
        }

        if lines.count >= 2, first.contains("|"), isTableDelimiter(lines[1]) {
            let aligns = tableAlignments(lines[1])
            let header = tableRow(first, aligns: aligns, lang: lang)
            var rows: [[MDTableCell]] = []
            var j = 2
            while j < lines.count {
                if isBlank(lines[j]) { j += 1; continue }
                rows.append(tableRow(lines[j], aligns: aligns, lang: lang))
                j += 1
            }
            return .table(header: header, rows: rows)
        }

        return .paragraph(MarkdownInline.structured(chunk, lang: lang))
    }

    /// One row of a table. A ragged row — fewer cells than the delimiter declared — simply runs out
    /// of alignments; the view fills the gap, because a missing cell still belongs to a column.
    private static func tableRow(_ line: String, aligns: [MDTableAlign], lang: AppLanguage) -> [MDTableCell] {
        let raw = tableCells(line)
        var cells: [MDTableCell] = []
        cells.reserveCapacity(raw.count)
        for (index, text) in raw.enumerated() {
            let align = index < aligns.count ? aligns[index] : MDTableAlign.natural
            cells.append(MDTableCell(MarkdownInline.structured(text, lang: lang), align: align))
        }
        return cells
    }

    private static func listItems(_ lines: [String], baseIndent: Int, lang: AppLanguage, depth: Int) -> [[MDBlock]] {
        var items: [[MDBlock]] = []
        var current: [String] = []
        var currentWidth = 0

        func closeItem() {
            guard !current.isEmpty else { return }
            let body = current.joined(separator: "\n")
            let blocks = split(body, streaming: false).map { parse($0, lang: lang, depth: depth + 1) }
            items.append(blocks.isEmpty ? [.paragraph(AttributedString())] : blocks)
            current = []
        }

        for line in lines {
            if let marker = listMarker(line), marker.indent <= baseIndent + 1 {
                closeItem()
                currentWidth = marker.width
                current.append(String(line.dropFirst(min(marker.width, line.count))))
                continue
            }
            if current.isEmpty {
                if isBlank(line) { continue }
                current.append(line)
                continue
            }
            current.append(dropping(line, upTo: currentWidth))
        }
        closeItem()
        return items
    }
}
