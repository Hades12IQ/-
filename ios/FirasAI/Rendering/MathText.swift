import Foundation

/// Port of the web's `texToUnicode`: one TeX fragment → readable text.
///
/// This is math **v1**. It produces correct glyphs, not typeset layout — a `WKWebView` KaTeX
/// island per equation inside a lazy stack is a freeze risk, so it is deliberately deferred.
/// Coverage is best-effort by design: anything it cannot map is left legible rather than dropped.
enum MathText {

    /// `$…$`, `$$…$$`, `\(…\)`, `\[…\]` → the bare TeX inside.
    static func stripDelimiters(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$"), s.hasSuffix("$$"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("\\["), s.hasSuffix("\\]"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("\\("), s.hasSuffix("\\)"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("$"), s.hasSuffix("$"), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unicode(_ tex: String) -> String {
        var s = stripDelimiters(tex)
        guard !s.isEmpty else { return "" }
        s = unwrapping(s, macros: textMacros, depth: 0)
        s = droppingOptionalArgument(s, macro: "sqrt")
        s = expandingFractions(s, depth: 0)
        s = removingCommands(s, names: sizeCommands)
        s = spacingToSpaces(s)
        s = removingEnvironments(s)
        s = s.replacingOccurrences(of: "\\\\", with: "؛ ")
        s = unwrapping(s, macros: ["boxed"], depth: 0)
        s = mappingCommands(s)
        s = applyingScripts(s)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        s = simplifyingParentheses(s)
        return collapsingWhitespace(s)
    }

    // MARK: - Tables

    private static let textMacros: Set<String> = [
        "text", "mathrm", "textrm", "mathbf", "textbf", "mathit", "textit", "operatorname"
    ]

    private static let sizeCommands: Set<String> = ["left", "right", "big", "Big", "bigg", "Bigg"]

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "int": "∫", "oint": "∮", "iint": "∬", "sum": "Σ", "prod": "∏", "infty": "∞",
        "partial": "∂", "nabla": "∇", "times": "×", "cdot": "·", "cdotp": "·", "cdots": "⋯",
        "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "leftrightarrow": "↔", "mapsto": "↦", "in": "∈", "notin": "∉",
        "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "emptyset": "∅", "forall": "∀", "exists": "∃", "angle": "∠", "perp": "⊥",
        "parallel": "∥", "degree": "°", "ldots": "…", "dots": "…", "quad": " ", "qquad": "  "
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
        "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
        "8": "₈", "9": "₉", "+": "₊", "-": "₋", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ",
        "i": "ᵢ", "n": "ₙ", "x": "ₓ"
    ]

    // MARK: - Passes

    /// `\text{a}` → `a`. Runs until nothing changes so nested wrappers collapse too.
    private static func unwrapping(_ s: String, macros: Set<String>, depth: Int) -> String {
        guard depth < 8, s.contains("\\") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        var changed = false
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
            if !name.isEmpty, macros.contains(name), let g = readGroup(a, k) {
                out += g.body
                i = g.end
                changed = true
                continue
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return changed ? unwrapping(out, macros: macros, depth: depth + 1) : out
    }

    /// `\sqrt[3]{x}` → `\sqrt{x}` (an n-th root becomes a plain root rather than nonsense).
    private static func droppingOptionalArgument(_ s: String, macro: String) -> String {
        let needle = "\\" + macro
        guard s.contains(needle) else { return s }
        let a = Array(s)
        let m = Array(needle)
        var out = ""
        var i = 0
        while i < a.count {
            if a[i] == "\\", i + m.count <= a.count, Array(a[i..<(i + m.count)]) == m {
                out += needle
                var k = i + m.count
                var spaces = ""
                while k < a.count, a[k] == " " {
                    spaces.append(" ")
                    k += 1
                }
                if k < a.count, a[k] == "[" {
                    var j = k + 1
                    while j < a.count, a[j] != "]" { j += 1 }
                    i = j < a.count ? j + 1 : a.count
                    continue
                }
                out += spaces
                i = k
                continue
            }
            out.append(a[i])
            i += 1
        }
        return out
    }

    /// `\frac` and `\sqrt` need a BALANCED-brace reader, not a regex: `[^{}]*` cannot describe an
    /// argument that itself contains braces, and real problems are full of them.
    private static func expandingFractions(_ s: String, depth: Int) -> String {
        guard depth <= 12, s.contains("\\") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        while i < a.count {
            guard let hit = nextFractionOrRoot(a, from: i) else {
                out += String(a[i...])
                break
            }
            out += String(a[i..<hit.index])
            var k = hit.index + 5
            while k < a.count, a[k] == " " { k += 1 }

            if k >= a.count || a[k] != "{" {
                // `\frac12` shorthand, or a bare command we leave alone.
                if hit.isFraction, k + 1 < a.count, isDigit(a[k]), isDigit(a[k + 1]) {
                    out += String(a[k]) + "/" + String(a[k + 1])
                    i = k + 2
                    continue
                }
                out += String(a[hit.index..<min(hit.index + 5, a.count)])
                i = min(hit.index + 5, a.count)
                continue
            }

            guard let first = readGroup(a, k) else {
                out += String(a[hit.index...])
                break
            }
            if !hit.isFraction {
                out += "√(" + expandingFractions(first.body, depth: depth + 1) + ")"
                i = first.end
                continue
            }
            var m = first.end
            while m < a.count, a[m] == " " { m += 1 }
            if m < a.count, a[m] == "{", let second = readGroup(a, m) {
                out += "(" + expandingFractions(first.body, depth: depth + 1) + ")/("
                    + expandingFractions(second.body, depth: depth + 1) + ")"
                i = second.end
            } else {
                out += "(" + expandingFractions(first.body, depth: depth + 1) + ")/"
                i = first.end
            }
        }
        return out
    }

    private static func nextFractionOrRoot(_ a: [Character], from: Int) -> (index: Int, isFraction: Bool)? {
        let frac = Array("\\frac")
        let root = Array("\\sqrt")
        var i = from
        while i + 5 <= a.count {
            if a[i] == "\\" {
                let slice = Array(a[i..<(i + 5)])
                if slice == frac { return (i, true) }
                if slice == root { return (i, false) }
            }
            i += 1
        }
        return nil
    }

    private static func removingCommands(_ s: String, names: Set<String>) -> String {
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
            if !name.isEmpty, names.contains(name) {
                var k = j
                while k < a.count, a[k] == " " { k += 1 }
                i = k
                continue
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
    }

    /// `\quad`, `\qquad`, `\,`, `\;`, `\:`, `\!` and `\<space>` all become one space.
    private static func spacingToSpaces(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        while i < a.count {
            guard a[i] == "\\", i + 1 < a.count else {
                out.append(a[i])
                i += 1
                continue
            }
            let next = a[i + 1]
            if next == "\\" {
                out += "\\\\"
                i += 2
                continue
            }
            if next == "," || next == ";" || next == ":" || next == "!"
                || next == " " || next == "\t" || next == "\n" {
                out += " "
                i += 2
                continue
            }
            var j = i + 1
            while j < a.count, a[j].isLetter { j += 1 }
            let name = String(a[(i + 1)..<j])
            if name == "quad" || name == "qquad" {
                out += " "
                i = j
                continue
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
    }

    private static func removingEnvironments(_ s: String) -> String {
        guard s.contains("\\begin") || s.contains("\\end") else { return s }
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
            if name == "begin" || name == "end", j < a.count, a[j] == "{" {
                var k = j + 1
                while k < a.count, a[k] != "}" { k += 1 }
                out += " "
                i = k < a.count ? k + 1 : a.count
                continue
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
    }

    private static func mappingCommands(_ s: String) -> String {
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
            if name.isEmpty {
                out.append(a[i])
                i += 1
                continue
            }
            out += symbols[name] ?? name
            i = j
        }
        return out
    }

    private static func applyingScripts(_ s: String) -> String {
        guard s.contains("^") || s.contains("_") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        while i < a.count {
            let c = a[i]
            guard c == "^" || c == "_" else {
                out.append(c)
                i += 1
                continue
            }
            let table = c == "^" ? superscripts : subscripts
            var k = i + 1
            while k < a.count, a[k] == " " { k += 1 }
            if k < a.count, a[k] == "{", let g = readGroup(a, k) {
                if let mapped = mapRun(g.body, table) {
                    out += mapped
                } else {
                    out += String(c) + "(" + g.body + ")"
                }
                i = g.end
                continue
            }
            if k < a.count, isAlphanumeric(a[k]) {
                if let sym = table[a[k]] {
                    out.append(sym)
                } else {
                    out += String(c) + String(a[k])
                }
                i = k + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// `(π)/(4)` reads worse than `π/4` — drop parentheses that wrap a single short atom.
    private static func simplifyingParentheses(_ s: String) -> String {
        guard s.contains("(") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        while i < a.count {
            if a[i] == "(" {
                var j = i + 1
                var body = ""
                var clean = true
                while j < a.count, a[j] != ")" {
                    if a[j] == "(" || a[j] == " " || a[j] == "\t" || a[j] == "\n" {
                        clean = false
                        break
                    }
                    body.append(a[j])
                    j += 1
                }
                if clean, j < a.count, a[j] == ")", !body.isEmpty, body.count <= 3 {
                    out += body
                    i = j + 1
                    continue
                }
            }
            out.append(a[i])
            i += 1
        }
        return out
    }

    private static func collapsingWhitespace(_ s: String) -> String {
        var out = ""
        var lastWasSpace = false
        for c in s {
            if c == " " || c == "\t" || c == "\n" {
                if lastWasSpace { continue }
                out.append(" ")
                lastWasSpace = true
            } else {
                out.append(c)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Small helpers

    private static func readGroup(_ a: [Character], _ i: Int) -> (body: String, end: Int)? {
        guard i < a.count, a[i] == "{" else { return nil }
        var depth = 0
        var j = i
        while j < a.count {
            if a[j] == "{" {
                depth += 1
            } else if a[j] == "}" {
                depth -= 1
                if depth == 0 { return (String(a[(i + 1)..<j]), j + 1) }
            }
            j += 1
        }
        return nil
    }

    private static func mapRun(_ run: String, _ table: [Character: Character]) -> String? {
        var out = ""
        for c in run {
            guard let mapped = table[c] else { return nil }
            out.append(mapped)
        }
        return out
    }

    private static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

    private static func isAlphanumeric(_ c: Character) -> Bool {
        (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }
}
