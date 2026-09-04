import Foundation

/// The ONE math scanner.
///
/// Every pass that needs to know *where the math is* asks this type and nothing else. A second,
/// slightly different idea of what a delimiter is, is exactly how one stray `$` in the prose
/// ("التكلفة $") shifts the pairing and turns every equation after it into raw LaTeX.
///
/// `protect` replaces each accepted math run with a Private-Use-Area sentinel
/// (`U+E000` + decimal index + `U+E001`) that the markdown parser carries through untouched, and
/// hands back the raw runs (brace-balanced) so the caller can put them back — as text via
/// `restore`, or as typeset/unicode math.
enum MathScanner {

    /// Sentinels. Markdown has no meaning for the Private Use Area, and model output does not
    /// contain these in practice. `maskFirasAsk`-style passes must allocate a *different* pair.
    static let openMark: Character = "\u{E000}"
    static let closeMark: Character = "\u{E001}"

    /// The sentinel for span `index`. The trailing mark is what makes `1` and `11` unambiguous.
    static func token(_ index: Int) -> String {
        String(openMark) + String(index) + String(closeMark)
    }

    static func protect(_ text: String) -> (text: String, spans: [String]) {
        guard text.contains("$") || text.contains("\\") || hasRecoveryCue(text) else { return (text, []) }
        let chars = Array(text)
        let regions = scan(chars)
        guard !regions.isEmpty else { return (text, []) }

        var spans: [String] = []
        spans.reserveCapacity(regions.count)
        var out = ""
        out.reserveCapacity(chars.count)
        var index = 0
        var next = 0
        while index < chars.count {
            if next < regions.count, index == regions[next].start {
                let raw = String(chars[regions[next].start..<regions[next].end])
                out += token(spans.count)
                spans.append(balancedToken(raw))
                index = regions[next].end
                next += 1
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return (out, spans)
    }

    static func restore(_ text: String, spans: [String]) -> String {
        guard !spans.isEmpty, text.contains(openMark) else { return text }
        var out = text
        for (i, raw) in spans.enumerated() {
            out = out.replacingOccurrences(of: token(i), with: raw)
        }
        return out
    }

    // MARK: - Scanning

    private struct Region {
        let start: Int
        let end: Int
    }

    private static func scan(_ s: [Character], unfinished: inout (start: Int, opener: String, closer: String)?) -> [Region] {
        let n = s.count
        var math: [Region] = []
        let fences = fenceRegions(s)

        var i = 0
        var fi = 0
        while i < n {
            while fi < fences.count, i >= fences[fi].end { fi += 1 }
            if fi < fences.count, i >= fences[fi].start {
                i = fences[fi].end
                continue
            }

            let c = s[i]
            // A query string is not algebra. This also protects destinations in Markdown links.
            if let end = recoveryURLend(s, from: i) { i = end; continue }
            if c == "\\" {
                guard i + 1 < n else { break }
                let d = s[i + 1]
                // Bounded on purpose. A stray `\[` in prose that pairs with a `\]` four screens
                // later would swallow every paragraph in between — the bracket form of the stray-`$`
                // bug. Beyond the reach it is not a delimiter, it is a backslash.
                if d == "[", let e = indexOfPair(s, "\\", "]", from: i + 2, reach: displayBracketReach) {
                    if acceptsBracket(body: String(s[(i + 2)..<e]), isDisplay: true) {
                        math.append(Region(start: i, end: e + 2))
                        i = e + 2
                        continue
                    }
                }
                if d == "(", let e = indexOfPair(s, "\\", ")", from: i + 2, reach: inlineBracketReach) {
                    if acceptsBracket(body: String(s[(i + 2)..<e]), isDisplay: false) {
                        math.append(Region(start: i, end: e + 2))
                        i = e + 2
                        continue
                    }
                }
                if d == "[", unfinishedTail(s, from: i + 2, explicit: true) {
                    unfinished = (i, "\\[", "\\]")
                    i = n
                    continue
                } else if d == "(", unfinishedTail(s, from: i + 2, explicit: true) {
                    unfinished = (i, "\\(", "\\)")
                    i = n
                    continue
                }
                i += 2
                continue
            }

            if c == "`" {
                var k = i
                while k < n, s[k] == "`" { k += 1 }
                let runLength = k - i
                if let close = indexOfRun(s, "`", count: runLength, from: k) {
                    i = close + runLength
                } else {
                    i = s[k...].firstIndex(of: "\n") ?? n
                }
                continue
            }

            if c == "$" {
                if i + 1 < n, s[i + 1] == "$" {
                    // Bounded and tested exactly like the `\[…\]` branch below it. Unbounded, one
                    // unbalanced `$$` — a price, a shell prompt, a half-streamed equation — paired
                    // with the next `$$` several turns later and swallowed every paragraph between
                    // them into one equation.
                    let limit = min(n - 1, i + 2 + displayBracketReach)
                    var j = i + 2
                    var end = -1
                    while j + 1 < n, j <= limit {
                        if s[j] == "\\" { j += 2; continue }
                        if s[j] == "$", s[j + 1] == "$" { end = j; break }
                        j += 1
                    }
                    if end != -1, acceptsBracket(body: String(s[(i + 2)..<end]), isDisplay: true) {
                        math.append(Region(start: i, end: end + 2))
                        i = end + 2
                        continue
                    }
                    if end == -1, unfinishedTail(s, from: i + 2, explicit: true) {
                        unfinished = (i, "$$", "$$")
                        i = n
                        continue
                    }
                    i += 2
                    continue
                }
                var j = i + 1
                var end = -1
                while j < n {
                    if s[j] == "\\" { j += 2; continue }
                    if s[j] == "$" { end = j; break }
                    j += 1
                }
                // No partner anywhere ahead: it cannot mis-pair, so it stays a literal dollar.
                // This is also every opening delimiter of an equation still being streamed.
                if end == -1 {
                    if unfinishedTail(s, from: i + 1, explicit: false) {
                        unfinished = (i, "$", "$")
                        i = n
                        continue
                    }
                    i += 1
                    continue
                }
                let body = String(s[(i + 1)..<end])
                let after: Character? = end + 1 < n ? s[end + 1] : nil
                if acceptsInline(body: body, after: after) {
                    math.append(Region(start: i, end: end + 1))
                    i = end + 1
                    continue
                }
                i += 1
                continue
            }

            if let end = recoveredEnd(s, from: i) {
                math.append(Region(start: i, end: end))
                i = end
                continue
            }
            i += 1
        }
        return math.sorted { $0.start < $1.start }
    }

    private static func scan(_ s: [Character]) -> [Region] {
        var unfinished: (start: Int, opener: String, closer: String)?
        return scan(s, unfinished: &unfinished)
    }

    /// A derived view of an in-flight message. Neither storage nor copying should use this value.
    /// The same scan which protects completed math records an eligible unclosed tail, outside code.
    static func streamingPreview(_ markdown: String) -> String {
        guard markdown.contains("$") || markdown.contains("\\") else { return markdown }
        let chars = Array(markdown)
        var unfinished: (start: Int, opener: String, closer: String)?
        _ = scan(chars, unfinished: &unfinished)
        guard let pending = unfinished else { return markdown }
        let from = pending.start + pending.opener.count
        var body = String(chars[from...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = body.last, last == "^" || last == "_" { body.removeLast(); body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tail = Array(body)
        var commandStart = tail.count
        while commandStart > 0, isASCIILetter(tail[commandStart - 1]) { commandStart -= 1 }
        if commandStart > 0, tail[commandStart - 1] == "\\" {
            let name = String(tail[commandStart...])
            let completeCommands: Set<String> = [
                "frac", "dfrac", "tfrac", "binom", "sqrt", "text", "mathrm", "mathbf", "mathbb", "vec", "hat", "bar", "overline", "underline", "boxed",
                "int", "iint", "iiint", "oint", "sum", "prod", "lim", "infty", "partial", "nabla", "pi", "theta", "alpha", "beta", "gamma", "delta", "epsilon", "lambda", "mu", "sigma", "phi", "omega", "Delta", "Omega", "Gamma",
                "zeta", "eta", "iota", "kappa", "nu", "xi", "rho", "tau", "upsilon", "chi", "psi", "varepsilon", "vartheta", "varphi", "varrho", "varsigma", "hbar", "ell", "imath", "jmath", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "ce", "pu",
                "sin", "cos", "tan", "cot", "sec", "csc", "ln", "log", "exp", "quad", "qquad", "cdot", "times", "pm", "mp"
            ]
            if name.isEmpty || !completeCommands.contains(name) {
                body = String(tail[..<(commandStart - 1)]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        while let last = body.last, last == "^" || last == "_" { body.removeLast(); body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !body.isEmpty else { return markdown }
        body = completePreviewArguments(balancedBraces(body))
        // A started display environment remains local to this preview; never rewrite the response.
        if let regex = try? NSRegularExpression(pattern: #"\\(begin|end)\{([a-zA-Z*]+)\}"#) {
            let value = body as NSString
            var environments: [String] = []
            for match in regex.matches(in: body, range: NSRange(location: 0, length: value.length)) {
                let command = value.substring(with: match.range(at: 1))
                let name = value.substring(with: match.range(at: 2))
                if command == "begin" { environments.append(name) }
                else if environments.last == name { environments.removeLast() }
            }
            for name in environments.reversed() { body += "\\end{" + name + "}" }
        }
        guard isTypesettable(body) else { return markdown }
        return String(chars[..<pending.start]) + pending.opener + body + pending.closer
    }

    private static func unfinishedTail(_ s: [Character], from start: Int, explicit: Bool) -> Bool {
        guard start < s.count, s.count - start <= displayBracketReach else { return false }
        let raw = String(s[start...])
        if !explicit, raw.first?.isWhitespace == true { return false }
        guard !raw.contains("$"), !raw.contains("`"), !containsBlankLine(raw) else { return false }
        var body = strippingTextGroups(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !containsArabic(body) else { return false }
        // Chemical symbols and units can be long Latin runs (NaOH, H2SO4, mol). Their explicit
        // mhchem command already establishes that this is math, including a still-open argument.
        body = body.replacingOccurrences(of: #"\\(?:ce|pu)\{[^{}]*(?:\}|$)"#, with: "x", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\\(?:begin|end)\{[a-zA-Z*]+\}"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: "x", options: .regularExpression)
        let latinLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let words = body.components(separatedBy: latinLetters.inverted).filter { !$0.isEmpty }
        guard words.allSatisfy({ $0.count <= 2 || recoveredFunctions.contains($0) }) else { return false }
        if !explicit, raw.first?.isNumber == true,
           !raw.contains(where: { "\\=+−-*/^_√".contains($0) || recoveredGreek.contains($0) }) { return false }
        return true
    }

    /// TeX permits an empty argument. Filling only missing argument slots with {} shows a partial
    /// fraction/root without inventing a coefficient, denominator, or other mathematical content.
    private static func completePreviewArguments(_ body: String) -> String {
        let chars = Array(body)
        let arity = ["frac": 2, "dfrac": 2, "tfrac": 2, "binom": 2, "sqrt": 1, "text": 1, "mathrm": 1, "mathbf": 1, "mathbb": 1, "vec": 1, "hat": 1, "bar": 1, "overline": 1, "underline": 1, "boxed": 1, "ce": 1, "pu": 1]
        var additions: [Int: String] = [:]
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\" else { i += 1; continue }
            var end = i + 1
            while end < chars.count, isASCIILetter(chars[end]) { end += 1 }
            let name = String(chars[(i + 1)..<end])
            if let count = arity[name] {
                var cursor = end
                for remaining in (1...count).reversed() {
                    while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
                    if cursor == chars.count || chars[cursor] == "}" {
                        additions[cursor, default: ""] += String(repeating: "{}", count: remaining)
                        break
                    }
                    if chars[cursor] == "{" {
                        var depth = 1
                        cursor += 1
                        while cursor < chars.count, depth > 0 {
                            if chars[cursor] == "{" { depth += 1 }
                            if chars[cursor] == "}" { depth -= 1 }
                            cursor += 1
                        }
                    } else if chars[cursor] == "\\" {
                        cursor += 1
                        while cursor < chars.count, isASCIILetter(chars[cursor]) { cursor += 1 }
                    } else { cursor += 1 }
                }
            }
            i = max(i + 1, end)
        }
        var out = ""
        for index in 0...chars.count {
            out += additions[index] ?? ""
            if index < chars.count { out.append(chars[index]) }
        }
        return out
    }

    /// Fenced code blocks, by line. An UNTERMINATED fence runs to the end of the text: mid-stream
    /// that is the normal state, and treating its contents as prose would typeset the code.
    private static func fenceRegions(_ s: [Character]) -> [Region] {
        let n = s.count
        var starts: [Int] = [0]
        var i = 0
        while i < n {
            if s[i] == "\n" { starts.append(i + 1) }
            i += 1
        }
        var fences: [Region] = []
        var open: (start: Int, marker: Character, length: Int)?
        for li in 0..<starts.count {
            let a = starts[li]
            let b = li + 1 < starts.count ? starts[li + 1] : n
            guard a < b, let mark = fenceMarker(s, from: a, to: b) else { continue }
            if let o = open {
                if mark.marker == o.marker, mark.length >= o.length {
                    fences.append(Region(start: o.start, end: b))
                    open = nil
                }
            } else {
                open = (a, mark.marker, mark.length)
            }
        }
        if let o = open { fences.append(Region(start: o.start, end: n)) }
        return fences
    }

    private static func fenceMarker(_ s: [Character], from: Int, to: Int) -> (marker: Character, length: Int)? {
        var i = from
        var indent = 0
        while i < to, indent < 4, s[i] == " " || s[i] == "\t" {
            indent += 1
            i += 1
        }
        guard indent < 4, i < to else { return nil }
        let marker = s[i]
        guard marker == "`" || marker == "~" else { return nil }
        var j = i
        while j < to, s[j] == marker { j += 1 }
        let length = j - i
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    /// How far ahead a `\(` / `\[` may look for its partner. An equation longer than this is not
    /// something a chat answer produces; a backslash that stumbled into prose is.
    private static let inlineBracketReach = 900
    private static let displayBracketReach = 4000

    private static func indexOfPair(
        _ s: [Character],
        _ a: Character,
        _ b: Character,
        from: Int,
        reach: Int
    ) -> Int? {
        guard from >= 0, reach > 0 else { return nil }
        let limit = min(s.count - 1, from + reach)
        var j = from
        while j + 1 < s.count, j <= limit {
            if s[j] == a, s[j + 1] == b { return j }
            j += 1
        }
        return nil
    }

    /// The `\(…\)` / `\[…\]` twin of `acceptsInline`. The Arabic rule is the important one: Arabic
    /// left over once `\text{…}` groups are removed is a sentence that got adopted as an equation,
    /// and a red error box swallowing a paragraph is far worse than one raw formula.
    private static func acceptsBracket(body: String, isDisplay: Bool) -> Bool {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if containsArabic(strippingTextGroups(body)) { return false }
        guard !isDisplay else { return true }
        if containsBlankLine(body) { return false }
        var newlines = 0
        for c in body where c == "\n" { newlines += 1 }
        return newlines <= 2
    }

    private static func indexOfRun(_ s: [Character], _ c: Character, count: Int, from: Int) -> Int? {
        guard count > 0, from >= 0 else { return nil }
        var j = from
        while j + count <= s.count {
            var k = 0
            while k < count, s[j + k] == c { k += 1 }
            if k == count { return j }
            j += 1
        }
        return nil
    }

    // MARK: - Acceptance rules

    /// Most dollar signs in an answer are not delimiters. Every rule below is a reported bug.
    private static func acceptsInline(body: String, after: Character?) -> Bool {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        // A space right after the opening `$` is prose far more often than it is math.
        if let first = body.first, first == " " || first == "\t" || first == "\n" { return false }
        // Math never crosses a paragraph break, and rarely more than two lines.
        if containsBlankLine(body) { return false }
        var newlines = 0
        for c in body where c == "\n" { newlines += 1 }
        if newlines > 2 { return false }
        // Currency pair: "$5 for tea and $3" — digit-led on both sides of the run.
        if let first = body.first, isDigit(first), let a = after, isDigit(a) { return false }
        // Arabic reaches genuine math ONLY inside \text{…}-style groups. Arabic left over once
        // those are removed is a sentence that got adopted as an equation — rejecting it costs
        // one broken formula and saves every equation after it.
        if containsArabic(strippingTextGroups(body)) { return false }
        // Same idea for Latin prose: four or more words and not one TeX construct among them.
        let words = body.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        if words.count >= 4, !body.contains(where: { "\\^_{}=".contains($0) }) { return false }
        return true
    }

    private static func containsBlankLine(_ s: String) -> Bool {
        var sawNewline = false
        var onlySpaces = true
        for c in s {
            if c == "\n" {
                if sawNewline, onlySpaces { return true }
                sawNewline = true
                onlySpaces = true
                continue
            }
            if c != " " && c != "\t" { onlySpaces = false }
        }
        return false
    }

    private static func containsArabic(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 0x0600 && v <= 0x06FF) || (v >= 0x0750 && v <= 0x077F) { return true }
            if (v >= 0xFB50 && v <= 0xFDFF) || (v >= 0xFE70 && v <= 0xFEFF) { return true }
        }
        return false
    }

    private static let textMacros: Set<String> = [
        "text", "textrm", "textbf", "textit", "mathrm", "mbox", "operatorname"
    ]

    /// Remove `\text{…}`-family groups so the Arabic test only sees what is left as *math*.
    private static func strippingTextGroups(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        while i < a.count {
            guard a[i] == "\\" else {
                out.append(a[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < a.count, a[j].isLetter { j += 1 }
            let name = String(a[(i + 1)..<j])
            var k = j
            while k < a.count, a[k] == " " { k += 1 }
            if !name.isEmpty, textMacros.contains(name), k < a.count, a[k] == "{" {
                var m = k + 1
                while m < a.count, a[m] != "}", a[m] != "{" { m += 1 }
                if m < a.count, a[m] == "}" {
                    i = m + 1
                    continue
                }
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
    }

    private static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

    // MARK: - Brace repair

    /// Balance braces INSIDE a math token, keeping its delimiters intact — a missing closer must
    /// be added inside the math, not after the closing delimiter where it becomes literal text.
    private static func balancedToken(_ m: String) -> String {
        let pairs: [(String, String)] = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        for (l, r) in pairs where m.count >= l.count + r.count && m.hasPrefix(l) && m.hasSuffix(r) {
            let inner = String(m.dropFirst(l.count).dropLast(r.count))
            return l + balancedBraces(inner) + r
        }
        return balancedBraces(m)
    }

    /// Drops unmatched `}`, appends missing `}`. Valid LaTeX is already balanced, so this is a
    /// no-op on good input. It is deliberately NOT a general LaTeX fixer.
    private static func balancedBraces(_ tex: String) -> String {
        guard tex.contains("{") || tex.contains("}") else { return tex }
        let a = Array(tex)
        var out = ""
        var depth = 0
        for i in 0..<a.count {
            let c = a[i]
            let escaped = i > 0 && a[i - 1] == "\\"
            if c == "{", !escaped {
                depth += 1
                out.append(c)
            } else if c == "}", !escaped {
                if depth == 0 { continue }
                depth -= 1
                out.append(c)
            } else {
                out.append(c)
            }
        }
        if depth > 0 { out += String(repeating: "}", count: depth) }
        return out
    }
}

// MARK: - Complete spans

extension MathScanner {

    /// One accepted math run, split into the parts a renderer needs.
    ///
    /// `raw` is exactly what `protect` stashed (delimiters included, braces balanced), `tex` is the
    /// bare expression KaTeX is handed, and `isDisplay` is the web's `displayMode` — `$$…$$` and
    /// `\[…\]` are display, `$…$` and `\(…\)` are inline.
    struct Span: Hashable, Sendable {

        let raw: String
        let tex: String
        let isDisplay: Bool

        /// Undelimited recovery carries the original text for fallback and selected copy.
        var isRecovered: Bool { MathScanner.isRecoveredMath(raw) }

        /// Content-derived, so the same formula asked for twice is rendered once, and a block view
        /// finds the glyph a whole-message pass already produced without agreeing on an order.
        var id: String { MathScanner.identifier(tex: tex, isDisplay: isDisplay) }
    }

    /// Every **complete** math run in `text`, in reading order.
    ///
    /// Delimited runs need their closing delimiter; conservative undelimited recovery needs a
    /// complete mathematical expression. A still-open delimiter belongs to `streamingPreview`,
    /// which makes a derived string for display without changing the stored response.
    static func spans(in text: String) -> [Span] {
        protect(text).spans.compactMap { span(for: $0) }
    }

    /// Split one protected run — the strings `protect` hands back — into its parts.
    static func span(for raw: String) -> Span? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var body = trimmed
        var isDisplay = false
        if body.hasPrefix("$$"), body.hasSuffix("$$"), body.count >= 4 {
            body = String(body.dropFirst(2).dropLast(2))
            isDisplay = true
        } else if body.hasPrefix(#"\["#), body.hasSuffix(#"\]"#), body.count >= 4 {
            body = String(body.dropFirst(2).dropLast(2))
            isDisplay = true
        } else if body.hasPrefix(#"\("#), body.hasSuffix(#"\)"#), body.count >= 4 {
            body = String(body.dropFirst(2).dropLast(2))
        } else if body.hasPrefix("$"), body.hasSuffix("$"), body.count >= 2 {
            body = String(body.dropFirst().dropLast())
        }

        let bare = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let tex = body == trimmed && isRecoveredMath(trimmed) ? MathText.texForRecoveredMath(bare) : bare
        guard !tex.isEmpty else { return nil }
        return Span(raw: trimmed, tex: tex, isDisplay: isDisplay)
    }

    /// A span already known to be display or inline — `MDBlock.mathDisplay` carries bare TeX.
    static func span(tex: String, isDisplay: Bool) -> Span? {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw = isDisplay ? "$$" + trimmed + "$$" : "$" + trimmed + "$"
        return Span(raw: raw, tex: trimmed, isDisplay: isDisplay)
    }

    /// May this bare expression be handed to a typesetter *right now*?
    ///
    /// The streaming rule, enforced one last time at the point of use. `spans` already refuses a
    /// run whose closing delimiter has not arrived, but a bare expression also reaches
    /// `MathBlockView` straight from the block scanner, and mid-stream that expression can be a
    /// macro cut in half or a group that never closed. Typesetting it produces the shape the owner
    /// described — something that is briefly drawn wrong and then replaced. Leaving it as text
    /// until it is whole costs nothing: the very next tick has the rest of it.
    static func isTypesettable(_ tex: String) -> Bool {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // A bare expression never contains a delimiter. One that does came from a mis-pairing.
        if trimmed.contains("$") { return false }
        let a = Array(trimmed)
        // A trailing single backslash is a command the stream has not finished spelling.
        var trailing = 0
        var k = a.count - 1
        while k >= 0, a[k] == "\\" {
            trailing += 1
            k -= 1
        }
        if trailing % 2 == 1 { return false }
        var depth = 0
        for i in 0..<a.count {
            let escaped = i > 0 && a[i - 1] == "\\"
            if a[i] == "{", !escaped { depth += 1 }
            if a[i] == "}", !escaped {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// FNV-1a over the expression. Deliberately not `hashValue`: this identifier travels to a
    /// JavaScript bridge and back, and it has to mean the same thing on both sides of the trip.
    static func identifier(tex: String, isDisplay: Bool) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in tex.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return (isDisplay ? "d" : "i") + String(hash, radix: 16)
    }
}
