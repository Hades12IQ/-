import Foundation

/// Line-level classification for the block scanner: which markdown construct a single line opens,
/// and how one table row splits into cells. Kept beside `MarkdownBlocks` rather than inside it so
/// neither file grows past the point where the whole scanner fits on a screen.
extension MarkdownBlocks {

    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for c in line {
            if c == " " { count += 1 } else if c == "\t" { count += 4 } else { break }
        }
        return count
    }

    static func dropping(_ line: String, upTo width: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while removed < width, index < line.endIndex, line[index] == " " {
            removed += 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    static func startsBlock(_ line: String) -> Bool {
        if fenceOpen(line) != nil { return true }
        if displayMathOpens(line) { return true }
        if isRule(line) { return true }
        if headingLevel(line) != nil { return true }
        if isQuote(line) { return true }
        if listMarker(line) != nil { return true }
        return false
    }

    static func fenceOpen(_ line: String) -> (marker: Character, length: Int, info: String)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, i < 3, chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }
        let marker = chars[i]
        guard marker == "`" || marker == "~" else { return nil }
        var j = i
        while j < chars.count, chars[j] == marker { j += 1 }
        let length = j - i
        guard length >= 3 else { return nil }
        let info = String(chars[j...]).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return (marker, length, info)
    }

    /// The first whitespace-delimited word of a fence's info string — the language tag, or the
    /// `firas-*` card name. Whatever follows it on the same line is the inline meta object, which
    /// is where the web puts ```` ```firas-code {json} ````.
    static func fenceName(_ info: String) -> String {
        String(info.prefix(while: { !$0.isWhitespace }))
    }

    static func displayMathOpens(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("$$")
    }

    static func displayMathClosesOnSameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$$"), trimmed.count >= 4 else { return false }
        return trimmed.hasSuffix("$$")
    }

    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for c in trimmed {
            if c == first { count += 1 } else if c == " " || c == "\t" { continue } else { return false }
        }
        return count >= 3
    }

    static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, i < 3, chars[i] == " " { i += 1 }
        var h = i
        while h < chars.count, chars[h] == "#" { h += 1 }
        let level = h - i
        guard level >= 1, level <= 6 else { return nil }
        if h < chars.count, chars[h] != " ", chars[h] != "\t" { return nil }
        var text = String(chars[h...]).trimmingCharacters(in: .whitespaces)
        // A closing `###` sequence only counts when a space precedes it — `C#` is a heading word.
        if text.hasSuffix("#") {
            var tail = Array(text)
            var end = tail.count
            while end > 0, tail[end - 1] == "#" { end -= 1 }
            if end > 0, tail[end - 1] == " " {
                tail = Array(tail[0..<end])
                text = String(tail).trimmingCharacters(in: .whitespaces)
            } else if end == 0 {
                text = ""
            }
        }
        return (level, text)
    }

    static func isQuote(_ line: String) -> Bool {
        let chars = Array(line)
        var i = 0
        while i < chars.count, i < 3, chars[i] == " " { i += 1 }
        return i < chars.count && chars[i] == ">"
    }

    static func strippingQuoteMarker(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count, i < 3, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == ">" else { return line }
        i += 1
        if i < chars.count, chars[i] == " " { i += 1 }
        return String(chars[i...])
    }

    static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, number: Int, width: Int)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        let indent = i
        guard i < chars.count else { return nil }

        if chars[i] == "-" || chars[i] == "*" || chars[i] == "+" {
            guard i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\t" else { return nil }
            var width = i + 2
            while width < chars.count, chars[width] == " " { width += 1 }
            return (indent, false, 0, width)
        }

        var d = i
        while d < chars.count, chars[d] >= "0", chars[d] <= "9" { d += 1 }
        guard d > i, d - i <= 9, d < chars.count, chars[d] == "." || chars[d] == ")" else { return nil }
        guard d + 1 < chars.count, chars[d + 1] == " " || chars[d + 1] == "\t" else { return nil }
        let number = Int(String(chars[i..<d])) ?? 1
        var width = d + 2
        while width < chars.count, chars[width] == " " { width += 1 }
        return (indent, true, number, width)
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        for c in trimmed where !(c == "-" || c == ":" || c == "|" || c == " " || c == "\t") {
            return false
        }
        return true
    }

    /// Split one table row. The math scanner is asked first so a `|` inside `$…$` is not a cell
    /// boundary — the same authority the rest of the pipeline uses.
    static func tableCells(_ line: String) -> [String] {
        let (protectedLine, spans) = MathScanner.protect(line)
        let chars = Array(protectedLine)
        var cells: [String] = []
        var current = ""
        var insideCode = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" {
                current.append("|")
                i += 2
                continue
            }
            if c == "`" {
                insideCode.toggle()
                current.append(c)
                i += 1
                continue
            }
            if c == "|", !insideCode {
                cells.append(current)
                current = ""
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        cells.append(current)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { MathScanner.restore($0.trimmingCharacters(in: .whitespaces), spans: spans) }
    }
}
