import Foundation
import SwiftUI

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

    /// The alignment every column of a delimiter row asked for.
    ///
    /// `:---` is start, `---:` is end, `:---:` is centre, and a column with no colon stays
    /// `.natural` — which is not the same thing as start: a natural column follows the direction of
    /// its own cells, so a table of Arabic terms beside their Latin identifiers keeps each column
    /// hanging off the edge its own script reads from.
    static func tableAlignments(_ line: String) -> [MDTableAlign] {
        tableCells(line).map { (spec: String) -> MDTableAlign in
            let trimmed = spec.trimmingCharacters(in: .whitespaces)
            switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
            case (true, true): return MDTableAlign.center
            case (true, false): return MDTableAlign.start
            case (false, true): return MDTableAlign.end
            case (false, false): return MDTableAlign.natural
            }
        }
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

    // MARK: - Source that nobody fenced

    /* WHY THIS EXISTS AT ALL. The code route ASKS for unfenced source. When
       `RequestClassifier.detectCodeRequest` fires, `PromptCatalog.codeSystemPrompt` REPLACES the
       whole system message with "Output ONLY the raw source code … do NOT wrap the code in Markdown
       code fences (no triple backticks) … Begin your response immediately with the first character
       of the code (e.g. <!DOCTYPE html>)". So the answer that comes back has no fence anywhere in
       it, by design — and until this existed the scanner had no reason to see it as anything but
       paragraphs. A four-hundred-line document was drawn as wrapped prose in the reading face: no
       plate, no language, no copy, no preview, no export. The web never hits this because a code
       turn there is a code WINDOW, not a message; here the same bytes arrive in the transcript. */

    /// True when this single line could open a file. Cheap on purpose: it is asked of every line of
    /// every answer, and the full scan below only runs when it says yes.
    static func bareCodeOpens(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if signatureLanguage(trimmed) != nil { return true }
        return isDeclarationLine(trimmed) || isCommentHeader(trimmed)
    }

    /// How far a run of unfenced source starting at `lines[start]` reaches, and what to label it.
    /// `nil` is the answer for every line of ordinary prose, which is most lines of most answers.
    ///
    /// WHAT IT MATCHES, written down so it can be argued with:
    ///
    /// * a **document** whose first line is `<!DOCTYPE`, `<html`, `<svg`, `<?xml`, `<?php` or a `#!`
    ///   shebang. One line is the whole proof — no sentence in either language begins that way.
    /// * a **source file** whose first line is a *shaped* declaration (`import x`, `#include <…>`,
    ///   `def name(`, `class Name {`, `const total = 0;`) and which then keeps it up: five or more
    ///   non-blank lines, four in five of them shaped like code rather than like a sentence, and at
    ///   least two of them carrying a statement.
    ///
    /// WHAT IT WILL NOT MATCH, which matters more:
    ///
    /// * any paragraph whose first strong character is Arabic — that is not a near-miss, it is the
    ///   run's terminator, so prose after a file ends the file rather than joining it;
    /// * a keyword that is only an English word. "let me explain the rest" opens with `let ` and
    ///   carries no `=`, no `;` and no `(`, so it is a sentence and is read as one;
    /// * a comment on its own. A run may OPEN on `#`, `//` or `<!--`, but only when the next line
    ///   of content is itself code — otherwise `# مقدمة` and `# Introduction` would open files;
    /// * anything at or beyond a real fence — the run stops dead at the next one, so a `firas-code`
    ///   card later in the same answer is untouched.
    static func bareCodeRun(_ lines: [String], from start: Int) -> (end: Int, lang: String?)? {
        guard start < lines.count else { return nil }
        let opener = lines[start].trimmingCharacters(in: .whitespaces)
        guard !opener.isEmpty else { return nil }
        let signature = signatureLanguage(opener)
        if signature == nil, !isDeclarationLine(opener) {
            // A comment is a WEAK opener. `# -*- coding: utf-8 -*-` opens a Python file and
            // `# مقدمة` opens a markdown answer, and to this scanner they are the same line: a
            // hash and a space. Neither one decides anything, so the next line of real content is
            // asked instead, and an answer that opens on a heading stays an answer.
            guard isCommentHeader(opener), followsRealCode(lines, after: start) else { return nil }
        }

        // The run ends where the answer stops being a file: at a fence, because a real block owns
        // itself, or at a paragraph — a line at column zero whose first strong character reads
        // right to left. The indent is load-bearing. Arabic INSIDE a generated page is always
        // nested under a tag and therefore indented; a sentence the model wrote ABOUT the page
        // starts at the margin. Vetoing every Arabic line instead would refuse to box the Arabic
        // pages this app exists to produce.
        var index = start
        var end = start
        while index < lines.count {
            let line = lines[index]
            if index > start {
                if fenceOpen(line) != nil { break }
                if leadingSpaces(line) == 0, BidiText.direction(of: line) == .rightToLeft { break }
            }
            index += 1
            if !isBlank(line) { end = index }
        }
        guard end > start else { return nil }

        // `tidyCodeArtifact` (app.js:6555) cuts a page at its LAST closer, not its first: a model
        // that finishes the document and then keeps talking is the common failure, and `</html>`
        // may legitimately appear inside the page as an escaped example.
        if let signature, let closer = signatureCloser(signature) {
            var last: Int?
            var scan = start
            while scan < end {
                if lines[scan].lowercased().contains(closer) { last = scan }
                scan += 1
            }
            if let last { end = last + 1 }
        }

        let body = Array(lines[start..<end])
        if let signature {
            // Spelt out rather than returned inline: the slot is optional and this value is not, and
            // a tuple that has to be widened on the way out is not worth a compiler round trip.
            let label: String? = signature
            return (end, label)
        }
        guard qualifiesAsSource(body) else { return nil }
        return (end, sourceLanguage(body))
    }

    // MARK: Proof by the first line alone

    /// A first line that settles the question on its own, and the language it settles it as.
    private static func signatureLanguage(_ trimmed: String) -> String? {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") { return "html" }
        if lower.hasPrefix("<svg") { return "svg" }
        if lower.hasPrefix("<?xml") { return "xml" }
        if lower.hasPrefix("<?php") { return "php" }
        if lower.hasPrefix("#!") { return shebangLanguage(lower) }
        return nil
    }

    private static func shebangLanguage(_ lower: String) -> String {
        if lower.contains("python") { return "python" }
        if lower.contains("node") { return "javascript" }
        if lower.contains("ruby") { return "ruby" }
        if lower.contains("perl") { return "perl" }
        return "bash"
    }

    /// The tag a whole document is known to end on. Only these two: an `<?xml` prolog closes on a
    /// tag this scanner cannot name, and a script has no closer at all.
    private static func signatureCloser(_ language: String) -> String? {
        switch language {
        case "html": return "</html>"
        case "svg": return "</svg>"
        default: return nil
        }
    }

    // MARK: Proof by shape

    /// Heads that declare a block. A keyword alone is never enough — see `isDeclarationLine`.
    private static let blockHeads: [String] = [
        "def ", "function ", "func ", "fn ", "sub ", "class ", "struct ", "enum ",
        "interface ", "impl ", "trait ", "record ", "protocol ", "extension ", "module ",
    ]

    /// Heads that declare a binding. Same rule: the shape decides, not the word.
    private static let bindingHeads: [String] = [
        "const ", "let ", "var ", "final ", "static ", "export ", "async ",
        "public ", "private ", "protected ", "internal ", "abstract ",
    ]

    /// One line that is a declaration rather than a sentence about one.
    ///
    /// The difference is never the keyword. `let ` opens `let total = 0;` and it opens "let me
    /// explain the rest"; what separates them is the `=`, the `(` or the brace, so those are what
    /// this asks for.
    static func isDeclarationLine(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("#include") || trimmed.hasPrefix("#define") || trimmed.hasPrefix("#import") { return true }
        if trimmed.hasPrefix("#pragma") || trimmed.hasPrefix("#!") { return true }
        if trimmed.hasPrefix("@import") || trimmed.hasPrefix("@interface") || trimmed.hasPrefix("@implementation") { return true }
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("package ") || trimmed.hasPrefix("namespace ") { return true }
        if trimmed.hasPrefix("from "), trimmed.contains(" import ") { return true }
        if trimmed.hasPrefix("using "), trimmed.hasSuffix(";") { return true }
        if trimmed.hasPrefix("require("), trimmed.contains(")") { return true }

        let opensBlock = trimmed.hasSuffix("{") || trimmed.hasSuffix(":") || trimmed.contains("(")
        if blockHeads.contains(where: { trimmed.hasPrefix($0) }) { return opensBlock }
        if bindingHeads.contains(where: { trimmed.hasPrefix($0) }) {
            return opensBlock || trimmed.contains("=") || trimmed.hasSuffix(";")
        }
        return false
    }

    /// A line that is nothing but a comment. It opens plenty of files, and it opens plenty of
    /// markdown headings, so on its own it settles nothing — `bareCodeRun` makes it ask the line
    /// after it. `#include` and `#!` are declarations, not comments, and are answered before this.
    private static func isCommentHeader(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("<!--") { return true }
        if trimmed.hasPrefix("--") { return true }
        if trimmed.hasPrefix("#") {
            let rest = trimmed.dropFirst()
            return rest.first == " " || rest.first == "-" || rest.first == "#"
        }
        return false
    }

    /// Whether the first line of real content after `start` is itself code. A run of comments keeps
    /// the question open; the first line that is not a comment answers it either way.
    private static func followsRealCode(_ lines: [String], after start: Int) -> Bool {
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { index += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isCommentHeader(trimmed) { index += 1; continue }
            return signatureLanguage(trimmed) != nil || isDeclarationLine(trimmed)
        }
        return false
    }

    /// Endings and openings that only code has. `:` is in the tail set for Python, which is also why
    /// an English line ending in a colon is never enough on its own: this only ever contributes to a
    /// ratio, and the run still has to have opened with a declaration.
    private static let sourceTails: Set<Character> = ["{", "}", ";", "(", ")", ",", "[", "]", ">", ":", "="]
    private static let sourceHeads: Set<Character> = ["<", "}", ")", "]", "#", "@", "/", "*", "."]
    private static let sourceMarks: Set<Character> = ["=", "(", ")", "{", "}", ";", ":", "<", ">", "\""]

    private static func isSourceShaped(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, let last = trimmed.last else { return false }
        // `import os` ends in a letter and starts with one, and is nonetheless the most code-shaped
        // line there is. Asking the declaration test first costs nothing and stops a file of imports
        // from failing the ratio that exists to protect prose.
        if isDeclarationLine(trimmed) { return true }
        if sourceTails.contains(last) { return true }
        if sourceHeads.contains(first) { return true }
        // A single token — `};`, `end`, `</div>` — is punctuation, never a sentence.
        if !trimmed.contains(" ") { return true }
        // An indented line carrying an operator is a statement inside something.
        if leadingSpaces(line) > 0, trimmed.contains(where: { sourceMarks.contains($0) }) { return true }
        return false
    }

    private static func isStatementLine(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return false }
        if trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}") { return true }
        if trimmed.contains("=>") || trimmed.contains("::") || trimmed.contains("->") { return true }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") { return true }
        if trimmed.contains("("), trimmed.contains(")") { return true }
        return false
    }

    /// The corroboration a run with no document signature has to earn.
    private static func qualifiesAsSource(_ lines: [String]) -> Bool {
        var total = 0
        var shaped = 0
        var strong = 0
        for line in lines {
            if isBlank(line) { continue }
            total += 1
            if isSourceShaped(line) { shaped += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isStatementLine(trimmed) || isDeclarationLine(trimmed) { strong += 1 }
        }
        guard total >= 5, strong >= 2 else { return false }
        return shaped * 5 >= total * 4
    }

    /// A label for the head of the box. It is allowed to fail: `nil` prints TEXT and the highlighter
    /// falls back to a language-agnostic pass, which is the honest answer when the file could be any
    /// of four languages. Read from the head of the run only — this runs on every render.
    private static func sourceLanguage(_ lines: [String]) -> String? {
        var text = ""
        for line in lines.prefix(60) {
            text += line
            text += "\n"
            if text.count > 4000 { break }
        }
        if text.contains("#include") { return text.contains("std::") ? "cpp" : "c" }
        if text.contains("using System") { return "csharp" }
        if text.contains("public class ") || text.contains("public static void") { return "java" }
        if text.contains("import Foundation") || text.contains("import SwiftUI") { return "swift" }
        if text.contains("let mut ") || text.contains("fn main(") { return "rust" }
        if text.contains("package main") || text.contains("func main(") { return "go" }
        if text.contains("def ") || text.contains("elif ") || text.contains("__name__") { return "python" }
        if text.contains("=>") || text.contains("function ") || text.contains("const ") { return "javascript" }
        return nil
    }
}
