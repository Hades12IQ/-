import Foundation

/// The string mechanics behind `HTMLPreviewCard.Document`: emitting `<style>` and `<script>`
/// elements that cannot be broken out of, removing the references a srcdoc-style island can never
/// resolve, splicing markup into a head or a body, and collecting the companion fences of an
/// answer.
///
/// Kept apart from the document shapes so the shells above read as documents and this reads as
/// escaping, which is the part that has to be right.
extension HTMLPreviewCard.Document {

    // MARK: - Elements

    /// A payload containing a literal `</style>` would end the element and spill into markup.
    /// `<\/style` is the same nine characters to a CSS parser and inert to the HTML parser.
    static func styleTag(_ css: String) -> String {
        "<style>\n" + css.replacingOccurrences(of: "</style", with: "<\\/style") + "\n</style>"
    }

    /// Same guard for scripts: inside a JavaScript string `<\/script` is `</script`, and outside
    /// one `</script` was never valid JavaScript to begin with.
    static func scriptTag(_ js: String) -> String {
        "<script>\n" + js.replacingOccurrences(of: "</script", with: "<\\/script") + "\n</script>"
    }

    /// A JavaScript string literal safe to embed inside a `<script>` element. Every angle bracket
    /// and ampersand becomes its unicode escape, so nothing in the payload can close the element.
    static func jsStringLiteral(_ source: String) -> String {
        var out = "\""
        out.reserveCapacity(source.utf8.count + 16)
        for scalar in source.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += "\\u" + hex4(scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func hex4(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        var shift = 12
        while shift >= 0 {
            let index = Int((value >> UInt32(shift)) & 0xF)
            out.append(digits[index])
            shift -= 4
        }
        return out
    }

    static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - Splicing

    /// `markup` right after the `<head>` open tag, or right before `</head>` when `atEnd`.
    static func injectingIntoHead(_ html: String, markup: String, atEnd: Bool = false) -> String {
        let characters = Array(html)
        if atEnd {
            let close = indexOfIgnoringCase(characters, "</head", from: 0)
            if close < characters.count {
                return String(characters[0..<close]) + markup + String(characters[close...])
            }
        }
        let open = indexOfIgnoringCase(characters, "<head", from: 0)
        if open < characters.count {
            let tagEnd = indexOf(characters, ">", from: open)
            if tagEnd < characters.count {
                return String(characters[0...tagEnd]) + markup + String(characters[(tagEnd + 1)...])
            }
        }
        let body = indexOfIgnoringCase(characters, "<body", from: 0)
        if body < characters.count {
            return String(characters[0..<body]) + "<head>" + markup + "</head>"
                + String(characters[body...])
        }
        return markup + html
    }

    /// `markup` right before `</body>`, or appended when the document has no body close.
    static func injectingBeforeBodyEnd(_ html: String, markup: String) -> String {
        let characters = Array(html)
        let close = indexOfIgnoringCase(characters, "</body", from: 0)
        if close < characters.count {
            return String(characters[0..<close]) + markup + String(characters[close...])
        }
        return html + markup
    }

    /// Drop the `<link>` and `<script src>` elements that point at project files, the way the web
    /// strips them before painting a live build (`cwLiveStrip`). CDN and `data:` references stay:
    /// those still resolve inside the island.
    static func strippingLocalAssetTags(_ html: String) -> String {
        let a = Array(html)
        var out = ""
        out.reserveCapacity(a.count)
        var i = 0
        while i < a.count {
            guard a[i] == "<" else {
                out.append(a[i])
                i += 1
                continue
            }
            if matchesIgnoringCase(a, at: i, "<link") {
                let end = indexOf(a, ">", from: i)
                if end < a.count, isLocalStylesheetTag(String(a[i...end])) {
                    i = end + 1
                    continue
                }
            } else if matchesIgnoringCase(a, at: i, "<script") {
                let openEnd = indexOf(a, ">", from: i)
                if openEnd < a.count, isLocalScriptTag(String(a[i...openEnd])) {
                    let close = indexOfIgnoringCase(a, "</script", from: openEnd)
                    if close < a.count {
                        let closeEnd = indexOf(a, ">", from: close)
                        i = closeEnd < a.count ? closeEnd + 1 : a.count
                    } else {
                        i = a.count
                    }
                    continue
                }
            }
            out.append(a[i])
            i += 1
        }
        return out
    }

    private static func isLocalStylesheetTag(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        guard lower.contains(".css") else { return false }
        return !isExternalReference(lower)
    }

    private static func isLocalScriptTag(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        guard lower.contains("src=") else { return false }
        return !isExternalReference(lower)
    }

    private static func isExternalReference(_ lowered: String) -> Bool {
        lowered.contains("http://") || lowered.contains("https://")
            || lowered.contains("//cdn") || lowered.contains("data:")
            || lowered.contains("=\"//") || lowered.contains("='//")
    }

    // MARK: - Searching

    static func indexOf(_ a: [Character], _ needle: Character, from: Int) -> Int {
        var i = max(from, 0)
        while i < a.count {
            if a[i] == needle { return i }
            i += 1
        }
        return a.count
    }

    static func indexOfIgnoringCase(_ a: [Character], _ needle: String, from: Int) -> Int {
        var i = max(from, 0)
        while i < a.count {
            if matchesIgnoringCase(a, at: i, needle) { return i }
            i += 1
        }
        return a.count
    }

    /// ASCII-only case folding on purpose: every needle here is an HTML tag name, and
    /// `Character(c.lowercased())` would trap on the handful of glyphs whose lowercase form is two
    /// characters long.
    static func matchesIgnoringCase(_ a: [Character], at index: Int, _ needle: String) -> Bool {
        let pattern = Array(needle.lowercased())
        guard !pattern.isEmpty, index + pattern.count <= a.count else { return false }
        var k = 0
        while k < pattern.count {
            guard let raw = a[index + k].asciiValue, let target = pattern[k].asciiValue else {
                return false
            }
            let lowered = (raw >= 65 && raw <= 90) ? raw + 32 : raw
            if lowered != target { return false }
            k += 1
        }
        return true
    }

    // MARK: - Companions

    /// Every `css` and `js` fence in one answer, in the order they were written. A page split
    /// across three blocks previews as one page only because of this.
    static func companions(in markdown: String) -> [Companion] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var found: [Companion] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
                i += 1
                continue
            }
            let marker = String(trimmed.prefix(3))
            let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let name = String(info.prefix(while: { !$0.isWhitespace }))
            var body: [String] = []
            var j = i + 1
            var closed = false
            while j < lines.count {
                if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    closed = true
                    break
                }
                body.append(lines[j])
                j += 1
            }
            if closed {
                let companion = Companion(language: name, code: body.joined(separator: "\n"))
                if companion.isStylesheet || companion.isScript, !companion.code.isEmpty {
                    found.append(companion)
                }
            }
            i = closed ? j + 1 : lines.count
        }
        return found
    }

    // MARK: - Copy

    /// The specimen page and the console shell speak too, and none of it may be a bare literal.
    enum Copy {
        static let specimenHeading = LText(ar: "عنوان رئيسي", en: "Heading one")
        static let specimenBody = LText(
            ar: "فقرة نصية لمعاينة الخط والمسافات واللون.",
            en: "A paragraph of body text for type, spacing and colour."
        )
        static let specimenLink = LText(ar: "رابط", en: "A link")
        static let specimenBold = LText(ar: "عريض", en: "Bold")
        static let specimenItalic = LText(ar: "مائل", en: "Italic")
        static let specimenButton = LText(ar: "زر", en: "Button")
        static let specimenField = LText(ar: "حقل إدخال", en: "Input field")
        static let specimenItemOne = LText(ar: "عنصر أول", en: "First item")
        static let specimenItemTwo = LText(ar: "عنصر ثانٍ", en: "Second item")
        static let noOutput = LText(ar: "(لا مخرجات)", en: "(no console output)")
        static let jsonValid = LText(ar: "JSON صالح", en: "Valid JSON")
        static let jsonUnreadable = LText(ar: "تعذّرت قراءة النص.", en: "The text could not be read.")
    }
}
