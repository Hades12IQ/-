import Foundation

// Recovery remains part of the one scanner: no renderer, export, or card guesses math separately.
extension MathScanner {
    static let recoveredFunctions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "ln", "log", "exp", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh"]
    static let recoveredGreek = "αβγδεζηθικλμνξπρστυφχψωΓΔΘΛΞΠΣΥΦΨΩϑϕϵ"
    static let recoveredScripts = "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁽⁾₀₁₂₃₄₅₆₇₈₉₊₋₍₎"

    static func hasRecoveryCue(_ text: String) -> Bool {
        text.contains(where: { "=√∫∑∏⇒⇔≤≥≠≈".contains($0) || recoveredGreek.contains($0) || recoveredScripts.contains($0) })
            || recoveredFunctions.contains(where: { text.contains($0) })
    }

    static func recoveryURLend(_ s: [Character], from start: Int) -> Int? {
        // A Markdown link destination can be relative and can contain query parameters. Its
        // label still passes through the scanner, but replacing anything in the URL breaks taps.
        if start > 0, start < s.count, s[start] == "(", s[start - 1] == "]" {
            var end = start + 1
            var depth = 1
            while end < s.count, s[end] != "\n" {
                if s[end] == "\\" { end += min(2, s.count - end); continue }
                if s[end] == "(" { depth += 1 }
                if s[end] == ")" { depth -= 1 }
                end += 1
                if depth == 0 { return end }
            }
            return end
        }
        guard start < s.count, "hHwW".contains(s[start]) else { return nil }
        let head = String(s[start..<min(s.count, start + 8)]).lowercased()
        guard head.hasPrefix("https://") || head.hasPrefix("http://") || head.hasPrefix("www.") else { return nil }
        var end = start
        while end < s.count, !s[end].isWhitespace, s[end] != ")", s[end] != ">" { end += 1 }
        return end
    }

    /// Accepts only a short mathematical vocabulary, balanced groups and an unambiguous signal.
    /// Single Greek letters, ordinary words, prices and arbitrary identifiers remain prose.
    static func recoveredEnd(_ s: [Character], from start: Int) -> Int? {
        guard start < s.count else { return nil }
        if start > 0, isRecoveryLetter(s[start - 1]) || s[start - 1].isNumber || s[start - 1] == "\\" { return nil }
        guard isRecoveryLetter(s[start]) || s[start].isNumber || "−-√(".contains(s[start]) else { return nil }
        var i = start
        var groups: [Character] = []
        var relation = false
        var greek = false
        var function = false
        var operation = false
        var scripted = false
        var needsAtom = true
        var hasAtom = false
        var best: Int?
        let limit = min(s.count, start + 900)
        while i < limit {
            let c = s[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c == "\n" || c == "\r" { break }
            if isASCIILetter(c) {
                var end = i + 1
                while end < limit, isASCIILetter(s[end]) { end += 1 }
                let word = String(s[i..<end])
                if recoveredFunctions.contains(word) {
                    function = true
                    needsAtom = true
                } else if word.count == 1 || ["dv", "du", "dx", "dy", "dz", "dt", "dr", "ds", "mc"].contains(word) {
                    hasAtom = true
                    needsAtom = false
                } else { break }
                i = end
            } else if c >= "0", c <= "9" {
                i += 1
                while i < limit, s[i] >= "0", s[i] <= "9" { i += 1 }
                if i + 1 < limit, s[i] == ".", s[i + 1] >= "0", s[i + 1] <= "9" {
                    i += 1
                    while i < limit, s[i] >= "0", s[i] <= "9" { i += 1 }
                }
                hasAtom = true
                needsAtom = false
            } else if recoveredGreek.contains(c) {
                greek = true
                hasAtom = true
                needsAtom = false
                i += 1
            } else if recoveredScripts.contains(c), hasAtom, !needsAtom {
                scripted = true
                i += 1
            } else if c == "√" {
                function = true
                needsAtom = true
                i += 1
            } else if c == "(" || c == "[" || c == "{" {
                groups.append(c == "(" ? ")" : c == "[" ? "]" : "}")
                needsAtom = true
                i += 1
            } else if c == ")" || c == "]" || c == "}" {
                guard groups.last == c, !needsAtom else { break }
                groups.removeLast()
                needsAtom = false
                i += 1
            } else if "=⇒⇔≤≥≠≈".contains(c), hasAtom, !needsAtom {
                if i + 1 < limit, s[i + 1] == "=" || s[i + 1] == ">" { break }
                relation = true
                needsAtom = true
                i += 1
            } else if "+−-*/×÷·^_".contains(c) {
                guard (hasAtom && !needsAtom) || c == "-" || c == "−" || c == "+" else { break }
                operation = true
                needsAtom = true
                i += 1
            } else if (c == "′" || c == "!"), hasAtom, !needsAtom {
                operation = true
                i += 1
            } else { break }

            if groups.isEmpty, hasAtom, !needsAtom,
               relation || function || scripted || (greek && operation) { best = i }
        }
        return best
    }

    static func isRecoveredMath(_ raw: String) -> Bool {
        let chars = Array(raw)
        return !chars.isEmpty && recoveredEnd(chars, from: 0) == chars.count
    }

    /// Whole-line recovery for a block renderer. Mixed prose never becomes a display equation.
    static func displayCandidate(in line: String) -> Span? {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecoveredMath(raw) else { return nil }
        return Span(raw: raw, tex: MathText.texForRecoveredMath(raw), isDisplay: true)
    }

    private static func isRecoveryLetter(_ c: Character) -> Bool {
        isASCIILetter(c) || recoveredGreek.contains(c)
    }

    static func isASCIILetter(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }
}
