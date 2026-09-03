import SwiftUI

/// A strictly linear, byte-level tokenizer for the languages the app actually shows.
///
/// No regular expressions and no `Array(String)`: a fenced block can be two thousand lines of
/// machine-written text, and both a backtracking pattern and grapheme-breaking that much text are
/// classic ways to freeze a transcript. The scanner walks the UTF-8 bytes and only ever splits on
/// ASCII, which is safe because every continuation byte of a multi-byte scalar is `>= 0x80` and can
/// never be mistaken for a delimiter — Arabic inside a string or a comment stays in one run.
///
/// Output is coalesced: consecutive bytes of the same tone become a single `AttributedString`
/// append instead of one per token, which is what keeps an 80 KB listing under a frame.
///
/// Every colour comes from a `FirasPalette` token so the six themes stay legible without a second
/// skin table. Language tables and family resolution live in `CodeHighlighter+Languages.swift`.
enum CodeHighlighter {

    /// Above this the listing is drawn plain. 300 KB is far past a 2 000-line file; beyond it
    /// nobody is reading colour, and the tokenizer's cost stops being free.
    static let byteBudget = 300_000

    // MARK: - Language description

    /// One scripting language, described by the handful of facts the scanner needs.
    struct Spec: Sendable {
        let keywords: Set<String>
        let types: Set<String>
        let lineComments: [String]
        let blockOpen: String?
        let blockClose: String?
        let tripleQuote: Bool
        let backtick: Bool
        let preprocessor: Bool
        let caseInsensitive: Bool
        let capitalsAreTypes: Bool

        init(
            keywords: Set<String>,
            types: Set<String> = [],
            lineComments: [String] = ["//"],
            blockOpen: String? = "/*",
            blockClose: String? = "*/",
            tripleQuote: Bool = false,
            backtick: Bool = false,
            preprocessor: Bool = false,
            caseInsensitive: Bool = false,
            capitalsAreTypes: Bool = false
        ) {
            self.keywords = keywords
            self.types = types
            self.lineComments = lineComments
            self.blockOpen = blockOpen
            self.blockClose = blockClose
            self.tripleQuote = tripleQuote
            self.backtick = backtick
            self.preprocessor = preprocessor
            self.caseInsensitive = caseInsensitive
            self.capitalsAreTypes = capitalsAreTypes
        }
    }

    enum Family {
        case markup
        case stylesheet
        case script(Spec)
        case plain
    }

    // MARK: - Entry point

    static func highlight(_ code: String, language: String?, palette: FirasPalette) -> AttributedString {
        guard !code.isEmpty else { return AttributedString() }
        let tones = Tones(palette: palette)
        let bytes = Array(code.utf8)
        guard bytes.count <= byteBudget else {
            var flat = AttributedString(code)
            flat.foregroundColor = tones.color(.plain)
            return flat
        }

        var emitter = Emitter(tones: tones)
        let whole = 0..<bytes.count
        switch family(for: language) {
        case .markup:
            scanMarkup(bytes, whole, into: &emitter)
        case .stylesheet:
            scanStyles(bytes, whole, into: &emitter)
        case .script(let spec):
            scanScript(bytes, whole, spec: spec, into: &emitter)
        case .plain:
            emitter.add(code, .plain)
        }
        return emitter.finish()
    }

    // MARK: - Script scanner

    static func scanScript(_ b: [UInt8], _ range: Range<Int>, spec: Spec, into e: inout Emitter) {
        var i = range.lowerBound
        let end = range.upperBound
        let lower = range.lowerBound

        while i < end {
            let c = b[i]

            if spec.preprocessor, c == Byte.hash, startsLine(b, i, lower) {
                let stop = lineEnd(b, i, end)
                e.add(text(b, i, stop), .keyword)
                i = stop
                continue
            }

            if let open = spec.blockOpen, let close = spec.blockClose, matches(b, i, end, open) {
                let found = find(b, i + open.utf8.count, end, close)
                let stop = found < end ? found + close.utf8.count : end
                e.add(text(b, i, stop), .comment)
                i = stop
                continue
            }

            if hasLineComment(b, i, end, spec) {
                let stop = lineEnd(b, i, end)
                e.add(text(b, i, stop), .comment)
                i = stop
                continue
            }

            if spec.tripleQuote, isTripleQuote(b, i, end) {
                let quote = b[i]
                var j = i + 3
                while j + 2 < end, !(b[j] == quote && b[j + 1] == quote && b[j + 2] == quote) { j += 1 }
                let stop = j + 2 < end ? j + 3 : end
                e.add(text(b, i, stop), .string)
                i = stop
                continue
            }

            if c == Byte.doubleQuote || c == Byte.singleQuote || (spec.backtick && c == Byte.backtick) {
                let stop = stringEnd(b, i, end, quote: c, multiline: c == Byte.backtick)
                e.add(text(b, i, stop), .string)
                i = stop
                continue
            }

            if isDigit(c), i == lower || !isIdentifierPart(b[i - 1]) {
                var j = i
                while j < end, isNumberPart(b[j]) { j += 1 }
                e.add(text(b, i, j), .number)
                i = j
                continue
            }

            if isIdentifierStart(c) {
                var j = i
                while j < end, isIdentifierPart(b[j]) { j += 1 }
                let word = text(b, i, j)
                let key = spec.caseInsensitive ? word.lowercased() : word
                if spec.keywords.contains(key) {
                    e.add(word, .keyword)
                } else if spec.types.contains(key) || (spec.capitalsAreTypes && isUpperLetter(c)) {
                    e.add(word, .type)
                } else {
                    e.add(word, .plain)
                }
                i = j
                continue
            }

            // Everything else — whitespace, brackets, operators — in one run, so a page of
            // indentation is one append and not four thousand.
            var j = i + 1
            while j < end, isFillerByte(b[j]) { j += 1 }
            e.add(text(b, i, j), .punct)
            i = j
        }
    }

    // MARK: - Markup scanner

    static func scanMarkup(_ b: [UInt8], _ range: Range<Int>, into e: inout Emitter) {
        var i = range.lowerBound
        let end = range.upperBound

        while i < end {
            guard b[i] == Byte.less else {
                var j = i
                while j < end, b[j] != Byte.less { j += 1 }
                e.add(text(b, i, j), .plain)
                i = j
                continue
            }

            if matches(b, i, end, "<!--") {
                let found = find(b, i + 4, end, "-->")
                let stop = found < end ? found + 3 : end
                e.add(text(b, i, stop), .comment)
                i = stop
                continue
            }

            var j = i + 1
            var isClosing = false
            if j < end, b[j] == Byte.slash {
                isClosing = true
                j += 1
            }
            let nameStart = j
            while j < end, isTagNamePart(b[j]) { j += 1 }
            let name = text(b, nameStart, j).lowercased()
            e.add(text(b, i, j), .tag)

            var k = j
            while k < end, b[k] != Byte.greater {
                let d = b[k]
                if d == Byte.doubleQuote || d == Byte.singleQuote {
                    var m = k + 1
                    while m < end, b[m] != d { m += 1 }
                    let stop = m < end ? m + 1 : end
                    e.add(text(b, k, stop), .string)
                    k = stop
                    continue
                }
                if isTagNamePart(d) {
                    var m = k
                    while m < end, isTagNamePart(b[m]) { m += 1 }
                    e.add(text(b, k, m), .attribute)
                    k = m
                    continue
                }
                e.add(text(b, k, k + 1), .punct)
                k += 1
            }
            if k < end {
                e.add(">", .tag)
                k += 1
            }
            i = k

            // An embedded stylesheet or script is highlighted as CSS or JavaScript rather than as
            // markup text — the whole point of previewing a one-file page.
            guard !isClosing, name == "script" || name == "style" else { continue }
            let closer = name == "script" ? "</script" : "</style"
            let close = findIgnoringCase(b, i, end, closer)
            if close > i {
                if name == "script" {
                    scanScript(b, i..<close, spec: embeddedScriptSpec, into: &e)
                } else {
                    scanStyles(b, i..<close, into: &e)
                }
            }
            i = max(i, close)
        }
    }

    // MARK: - Stylesheet scanner

    static func scanStyles(_ b: [UInt8], _ range: Range<Int>, into e: inout Emitter) {
        var i = range.lowerBound
        let end = range.upperBound
        var insideBlock = false
        var afterColon = false

        while i < end {
            let c = b[i]

            if c == Byte.slash, matches(b, i, end, "/*") {
                let found = find(b, i + 2, end, "*/")
                let stop = found < end ? found + 2 : end
                e.add(text(b, i, stop), .comment)
                i = stop
                continue
            }

            if c == Byte.doubleQuote || c == Byte.singleQuote {
                var j = i + 1
                while j < end, b[j] != c, b[j] != Byte.newline { j += 1 }
                let stop = j < end && b[j] == c ? j + 1 : j
                e.add(text(b, i, stop), .string)
                i = stop
                continue
            }

            if c == Byte.at, !insideBlock {
                var j = i + 1
                while j < end, isCSSNamePart(b[j]) { j += 1 }
                e.add(text(b, i, j), .keyword)
                i = j
                continue
            }

            if c == Byte.openBrace {
                insideBlock = true
                afterColon = false
                e.add("{", .punct)
                i += 1
                continue
            }
            if c == Byte.closeBrace {
                insideBlock = false
                afterColon = false
                e.add("}", .punct)
                i += 1
                continue
            }
            if c == Byte.colon, insideBlock {
                afterColon = true
                e.add(":", .punct)
                i += 1
                continue
            }
            if c == Byte.semicolon {
                afterColon = false
                e.add(";", .punct)
                i += 1
                continue
            }

            if isDigit(c), afterColon {
                var j = i
                while j < end, isDigit(b[j]) || b[j] == Byte.dot || b[j] == Byte.percent { j += 1 }
                while j < end, isLowerLetter(b[j]) { j += 1 }
                e.add(text(b, i, j), .number)
                i = j
                continue
            }

            if isCSSNameStart(c) {
                var j = i
                while j < end, isCSSNamePart(b[j]) || b[j] == Byte.dot || b[j] == Byte.hash { j += 1 }
                if j == i { j = i + 1 }
                let tone: Tone = insideBlock ? (afterColon ? .plain : .attribute) : .tag
                e.add(text(b, i, j), tone)
                i = j
                continue
            }

            var j = i + 1
            while j < end, isCSSFillerByte(b[j]) { j += 1 }
            e.add(text(b, i, j), .punct)
            i = j
        }
    }
}
