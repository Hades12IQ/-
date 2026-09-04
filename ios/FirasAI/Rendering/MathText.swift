import Foundation

/// Port of the web's `texToUnicode`: one TeX fragment → readable text.
///
/// This is the form an equation takes **before** `MathIsland` has drawn it, **if** the island can
/// never draw it, and **whenever** the expression leaves the app — a copy, a share, a PDF, a Word
/// file. It is not a typesetter and it never will be. What it owes the reader is that every symbol
/// the model wrote arrives as *something*: the right glyph where Unicode has one, an honest `_π`
/// where Unicode has no lowered π, and the command's own name only when nothing better exists.
///
/// The failure the owner reported is the one this file guards against everywhere: a command that
/// falls through to its own spelling and lands in the prose as an English word — `\square` reading
/// as "square" in the middle of an Arabic table. Every table below is therefore a list of things
/// that must never happen again, and the sweep covers mathematics, physics and chemistry because
/// he reports all three.
enum MathText {

    /// Rendering-only normalization after MathScanner has accepted a bare mathematical run.
    /// Never feed prose here, and never persist this derived form in place of the source.
    static func texForRecoveredMath(_ source: String) -> String {
        let greek: [Character: String] = [
            "α":"alpha", "β":"beta", "γ":"gamma", "δ":"delta", "ε":"epsilon", "ζ":"zeta", "η":"eta", "θ":"theta",
            "ι":"iota", "κ":"kappa", "λ":"lambda", "μ":"mu", "ν":"nu", "ξ":"xi", "π":"pi", "ρ":"rho", "σ":"sigma",
            "τ":"tau", "υ":"upsilon", "φ":"phi", "χ":"chi", "ψ":"psi", "ω":"omega", "Γ":"Gamma", "Δ":"Delta",
            "Θ":"Theta", "Λ":"Lambda", "Ξ":"Xi", "Π":"Pi", "Σ":"Sigma", "Υ":"Upsilon", "Φ":"Phi", "Ψ":"Psi", "Ω":"Omega",
            "ϑ":"vartheta", "ϕ":"varphi", "ϵ":"varepsilon"
        ]
        let symbols: [Character: String] = ["⇒":"\\Rightarrow ", "⇔":"\\Leftrightarrow ", "≤":"\\le ", "≥":"\\ge ", "≠":"\\ne ", "≈":"\\approx ", "×":"\\times ", "÷":"\\div ", "·":"\\cdot ", "−":"-", "′":"'"]
        let upper = Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁽⁾")
        let lower = Array("₀₁₂₃₄₅₆₇₈₉₊₋₍₎")
        let normal = Array("0123456789+-()")
        let chars = Array(source)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let name = greek[c] { out += "\\" + name + " "; i += 1; continue }
            if let mapped = symbols[c] { out += mapped; i += 1; continue }
            if upper.contains(c) || lower.contains(c) {
                let table = upper.contains(c) ? upper : lower
                out += upper.contains(c) ? "^{" : "_{"
                while i < chars.count, let index = table.firstIndex(of: chars[i]) {
                    out.append(normal[index])
                    i += 1
                }
                out += "}"
                continue
            }
            if c == "√" {
                var start = i + 1
                while start < chars.count, chars[start] == " " { start += 1 }
                if start < chars.count, chars[start] == "(" {
                    var depth = 1
                    var end = start + 1
                    while end < chars.count, depth > 0 {
                        if chars[end] == "(" { depth += 1 }
                        if chars[end] == ")" { depth -= 1 }
                        end += 1
                    }
                    if depth == 0 {
                        out += "\\sqrt{" + texForRecoveredMath(String(chars[(start + 1)..<(end - 1)])) + "}"
                        i = end
                        continue
                    }
                }
                if start < chars.count {
                    var end = start + 1
                    if chars[start].isNumber {
                        while end < chars.count, chars[end].isNumber || chars[end] == "." { end += 1 }
                    }
                    out += "\\sqrt{" + texForRecoveredMath(String(chars[start..<end])) + "}"
                    i = end
                    continue
                }
            }
            if MathScanner.isASCIILetter(c) {
                var end = i + 1
                while end < chars.count, MathScanner.isASCIILetter(chars[end]) { end += 1 }
                let word = String(chars[i..<end])
                out += MathScanner.recoveredFunctions.contains(word) ? "\\" + word + " " : word
                i = end
                continue
            }
            out.append(c)
            i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    /// The order of these passes is the whole design.
    ///
    /// Structure first, while the braces still say what belongs to what: styled alphabets,
    /// wrappers, two-argument macros, roots and fractions, accents. Symbols second, once nothing
    /// depends on grouping any more. Scripts last, because `x_{\pi}` has to become `x_{π}` before
    /// anything can decide whether π has a lowered form. Braces are only stripped after all of
    /// that — and an *escaped* brace is carried through the strip as a sentinel, because `\{1,2\}`
    /// is a set and losing its braces loses the sentence.
    static func unicode(_ tex: String) -> String {
        var s = stripDelimiters(tex)
        guard !s.isEmpty else { return "" }
        s = normalizing(s)
        s = expandingLetterStyles(s)
        s = unwrapping(s, macros: textMacros, depth: 0)
        s = removingMacrosWithArgument(s, names: droppedArgumentMacros)
        s = expandingTwoArgumentMacros(s)
        s = droppingOptionalArgument(s, macro: "sqrt")
        s = expandingFractions(s, depth: 0)
        s = applyingAccents(s)
        s = removingCommands(s, names: sizeCommands)
        s = spacingToSpaces(s)
        s = removingEnvironments(s)
        s = s.replacingOccurrences(of: "\\\\", with: "؛ ")
        s = unwrapping(s, macros: ["boxed"], depth: 0)
        s = mappingCommands(s)
        // The last pass that reads a command name has run, so the accents may become real marks.
        s = restoringAccents(s)
        s = applyingScripts(s)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        s = restoringBraces(s)
        s = simplifyingParentheses(s)
        return collapsingWhitespace(s)
    }

    // MARK: - Macro sets

    /// Wrappers whose braces carry no meaning of their own. `ce` and `pu` are mhchem: KaTeX draws
    /// them properly, and here `\ce{H2SO4 + 2NaOH}` at least reads as the reaction it is instead
    /// of as the word "ce" glued to a formula.
    private static let textMacros: Set<String> = [
        "text", "mathrm", "textrm", "mathbf", "textbf", "mathit", "textit", "operatorname",
        "mbox", "hbox", "texttt", "textsf", "textnormal", "textup", "textmd", "emph",
        "ce", "pu", "unit", "si"
    ]

    /// Styled alphabets. Only `\mathbb` has Unicode worth reaching for; the rest give up their
    /// braces and keep their letters.
    private static let letterStyleMacros: Set<String> = [
        "mathbb", "mathcal", "mathfrak", "mathscr", "mathsf", "mathtt", "mathnormal",
        "boldsymbol", "symbf", "symrm", "bm", "pmb"
    ]

    /// Commands that only exist to size or space something. They take no argument, so removing the
    /// command alone leaves the expression intact.
    private static let sizeCommands: Set<String> = [
        "left", "right", "middle", "big", "Big", "bigg", "Bigg",
        "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
        "limits", "nolimits", "mathstrut", "strut", "nonumber", "notag",
        "boldmath", "allowbreak", "relax", "protect"
    ]

    /// Commands whose one argument is invisible by definition — dropping the argument with the
    /// command is the *correct* reading, not a loss.
    private static let droppedArgumentMacros: Set<String> = [
        "phantom", "hphantom", "vphantom", "hspace", "vspace", "label"
    ]

    private static let twoArgumentMacros: Set<String> = [
        "binom", "dbinom", "tbinom", "stackrel", "overset", "underset"
    ]

    /// An accent is the mark, not a word: `\hat{\theta}` has to read as θ̂ and never as "hatθ".
    ///
    /// The mark itself cannot be written into the string at that point, and this is the whole
    /// reason these are sentinels. A combining character joins the grapheme *before* it, and every
    /// pass after `applyingAccents` splits the expression with `Array(s)` — so `\theta` + U+0302
    /// clusters as `\ t h e tâ`, the command scanner reads the name "thetâ", the symbol table
    /// misses, and the accent turns θ into the English word. That is precisely the failure this
    /// file exists to prevent, arriving through the fix for it. Each accent therefore travels as a
    /// Private-Use *base* character, which nothing clusters with, and `restoringAccents` exchanges
    /// it for the real mark once no pass is reading command names any more.
    private static let accents: [String: Character] = [
        "hat": "\u{E020}", "widehat": "\u{E020}",
        "bar": "\u{E021}", "overline": "\u{E021}",
        "vec": "\u{E022}", "overrightarrow": "\u{E022}",
        "dot": "\u{E023}", "ddot": "\u{E024}",
        "tilde": "\u{E025}", "widetilde": "\u{E025}",
        "check": "\u{E026}", "breve": "\u{E027}",
        "acute": "\u{E028}", "grave": "\u{E029}",
        "mathring": "\u{E02A}", "underline": "\u{E02B}"
    ]

    /// Each accent sentinel and the combining mark it stands for.
    private static let accentMarks: [Character: Character] = [
        "\u{E020}": "\u{0302}", "\u{E021}": "\u{0304}", "\u{E022}": "\u{20D7}",
        "\u{E023}": "\u{0307}", "\u{E024}": "\u{0308}", "\u{E025}": "\u{0303}",
        "\u{E026}": "\u{030C}", "\u{E027}": "\u{0306}", "\u{E028}": "\u{0301}",
        "\u{E029}": "\u{0300}", "\u{E02A}": "\u{030A}", "\u{E02B}": "\u{0332}"
    ]

    private static let blackboard: [Character: Character] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ",
        "H": "ℍ", "A": "\u{1D538}", "E": "\u{1D53C}", "F": "\u{1D53D}",
        "K": "\u{1D542}", "S": "\u{1D54A}", "T": "\u{1D54B}", "V": "\u{1D54D}",
        "1": "\u{1D7D9}"
    ]

    // MARK: - Symbols

    /// One table, assembled from small ones. Small on purpose: a single literal this long is slow
    /// to type-check, and a duplicate key inside one literal is a crash rather than a warning —
    /// merging lets the groups overlap harmlessly.
    private static let symbols: [String: String] = {
        var all: [String: String] = [:]
        let tables: [[String: String]] = [
            MathText.greek, MathText.letterlike, MathText.bigOperators, MathText.binaryOperators,
            MathText.relations, MathText.sets, MathText.arrows, MathText.delimiters, MathText.misc
        ]
        for table in tables {
            all.merge(table) { _, new in new }
        }
        return all
    }()

    private static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "varkappa": "ϰ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "digamma": "ϝ",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
    ]

    /// Constants and named quantities. `\hbar`, `\ell` and `\degree` are the physics ones the owner
    /// singled out; `\square` and `\qed` are the ones that arrived as English words.
    private static let letterlike: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "ell": "ℓ", "hbar": "ℏ", "hslash": "ℏ",
        "imath": "ı", "jmath": "ȷ", "aleph": "ℵ", "beth": "ℶ", "wp": "℘", "Re": "ℜ", "Im": "ℑ",
        "mho": "℧", "prime": "′", "degree": "°", "angstrom": "Å", "celsius": "℃",
        "square": "□", "Box": "□", "blacksquare": "■", "qed": "∎", "checkmark": "✓",
        "triangle": "△", "blacktriangle": "▲", "diamond": "⋄", "Diamond": "◇", "bigstar": "★",
        "clubsuit": "♣", "spadesuit": "♠", "heartsuit": "♥", "diamondsuit": "♦",
        "flat": "♭", "natural": "♮", "sharp": "♯",
        "S": "§", "P": "¶", "dag": "†", "ddag": "‡", "pounds": "£", "permil": "‰"
    ]

    private static let bigOperators: [String: String] = [
        "sum": "Σ", "prod": "∏", "coprod": "∐",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "oiint": "∯",
        "bigcup": "⋃", "bigcap": "⋂", "bigsqcup": "⨆",
        "bigoplus": "⨁", "bigotimes": "⨂", "bigodot": "⨀",
        "bigvee": "⋁", "bigwedge": "⋀"
    ]

    private static let binaryOperators: [String: String] = [
        "times": "×", "cdot": "·", "cdotp": "·", "cdots": "⋯", "div": "÷", "pm": "±", "mp": "∓",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘", "odot": "⊙",
        "dagger": "†", "ddagger": "‡", "amalg": "⨿",
        "setminus": "∖", "smallsetminus": "∖",
        "wedge": "∧", "vee": "∨", "land": "∧", "lor": "∨", "neg": "¬", "lnot": "¬", "not": "¬",
        "bmod": "mod", "pmod": "mod",
        "sqcup": "⊔", "sqcap": "⊓", "uplus": "⊎",
        "boxtimes": "⊠", "boxplus": "⊞", "ltimes": "⋉", "rtimes": "⋊"
    ]

    private static let relations: [String: String] = [
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "leqslant": "≤", "geqslant": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "approxeq": "≊", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "asymp": "≍", "doteq": "≐", "propto": "∝",
        "ll": "≪", "gg": "≫", "lll": "⋘", "ggg": "⋙",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰",
        "perp": "⊥", "parallel": "∥", "nparallel": "∦", "mid": "∣", "nmid": "∤",
        "therefore": "∴", "because": "∵", "models": "⊨", "vdash": "⊢", "dashv": "⊣",
        "triangleq": "≜", "angle": "∠", "measuredangle": "∡", "sphericalangle": "∢",
        "nless": "≮", "ngtr": "≯", "nleq": "≰", "ngeq": "≱", "nsim": "≁", "ncong": "≇"
    ]

    private static let sets: [String: String] = [
        "in": "∈", "notin": "∉", "ni": "∋",
        "subset": "⊂", "subseteq": "⊆", "subsetneq": "⊊", "nsubseteq": "⊈",
        "supset": "⊃", "supseteq": "⊇", "supsetneq": "⊋", "nsupseteq": "⊉",
        "sqsubseteq": "⊑", "sqsupseteq": "⊒",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "complement": "∁",
        "top": "⊤", "bot": "⊥"
    ]

    /// `\rightleftharpoons` is an equilibrium, `\uparrow` is a gas leaving a beaker: the chemistry
    /// half of the sweep lives here.
    private static let arrows: [String: String] = [
        "to": "→", "rightarrow": "→", "Rightarrow": "⇒", "leftarrow": "←", "gets": "←",
        "Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔",
        "longrightarrow": "⟶", "longleftarrow": "⟵", "longleftrightarrow": "⟷",
        "Longrightarrow": "⟹", "Longleftarrow": "⟸", "Longleftrightarrow": "⟺",
        "implies": "⟹", "impliedby": "⟸", "iff": "⟺",
        "mapsto": "↦", "longmapsto": "⟼",
        "uparrow": "↑", "downarrow": "↓", "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓",
        "nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
        "hookrightarrow": "↪", "hookleftarrow": "↩",
        "rightharpoonup": "⇀", "rightharpoondown": "⇁",
        "leftharpoonup": "↼", "leftharpoondown": "↽",
        "rightleftharpoons": "⇌", "leftrightharpoons": "⇋",
        "xrightarrow": "→", "xleftarrow": "←",
        "rightsquigarrow": "⇝", "leadsto": "⇝",
        "circlearrowleft": "↺", "circlearrowright": "↻"
    ]

    private static let delimiters: [String: String] = [
        "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "vert": "|", "lvert": "|", "rvert": "|", "Vert": "‖", "lVert": "‖", "rVert": "‖",
        "lbrace": String(MathText.braceOpenMark), "rbrace": String(MathText.braceCloseMark),
        "lbrack": "[", "rbrack": "]", "lgroup": "(", "rgroup": ")",
        "backslash": "\\"
    ]

    private static let misc: [String: String] = [
        "ldots": "…", "dots": "…", "dotsc": "…", "dotsb": "…", "vdots": "⋮", "ddots": "⋱",
        "quad": " ", "qquad": "  ", "thinspace": " ", "enspace": " ", "space": " ",
        "nobreakspace": " ", "colon": ":"
    ]

    // MARK: - Scripts

    /// Unicode's superscript alphabet, which is nearly complete: `q` has no raised form, and
    /// neither do the capitals left out below. A character missing here is not dropped — the
    /// caret is kept and the character follows it, which is the honest reading.
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
        "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
        "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ",
        "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
        "z": "ᶻ",
        "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ",
        "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ",
        "U": "ᵁ", "V": "ⱽ", "W": "ᵂ"
    ]

    /// Unicode's lowered alphabet is much thinner — no capitals at all, and no b, c, d, f, g, q,
    /// w, y or z. `H_2O` works; `x_{\text{eff}}` keeps its brackets and says so.
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
        "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
        "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ",
        "x": "ₓ"
    ]

    /// A brace that survived being escaped. The brace-stripping pass near the end of `unicode`
    /// cannot tell `{` the grouping character from `\{` the set bracket, so the escaped one
    /// travels as a sentinel and comes back at the very end.
    private static let braceOpenMark: Character = "\u{E010}"
    private static let braceCloseMark: Character = "\u{E011}"

    /// `\%`, `\$`, `\&` … — an escaped literal is a character, not a command. Emitting the
    /// backslash is what put `\%` on screen next to a percentage.
    private static let escapes: [Character: String] = [
        "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
        "{": String(MathText.braceOpenMark), "}": String(MathText.braceCloseMark),
        "|": "‖", "\\": "\\"
    ]

    // MARK: - Passes

    /// The other spellings of things this file already reads. `\dfrac` is `\frac`, and `^\circ` is
    /// a degree sign rather than a raised ring nobody can lower.
    private static func normalizing(_ s: String) -> String {
        var out = s
        if out.contains("frac") {
            out = out.replacingOccurrences(of: "\\dfrac", with: "\\frac")
            out = out.replacingOccurrences(of: "\\tfrac", with: "\\frac")
            out = out.replacingOccurrences(of: "\\cfrac", with: "\\frac")
        }
        if out.contains("\\circ") {
            out = out.replacingOccurrences(of: "^{\\circ}", with: "\\degree")
            out = out.replacingOccurrences(of: "^\\circ", with: "\\degree")
        }
        return out
    }

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

    /// `\mathbb{R}` → ℝ, and every other styled alphabet down to its own letters. Without this the
    /// mapping pass reads `\mathbb` as an unknown command and writes "mathbbR".
    private static func expandingLetterStyles(_ s: String) -> String {
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
            if !name.isEmpty, letterStyleMacros.contains(name), let g = readGroup(a, k) {
                if name == "mathbb", let one = g.body.first, g.body.count == 1,
                   let mapped = blackboard[one] {
                    out.append(mapped)
                } else {
                    out += g.body
                }
                i = g.end
                continue
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
    }

    /// `\phantom{…}`, `\hspace{…}`, `\label{…}`: the argument is invisible by definition, so it
    /// leaves with its command.
    private static func removingMacrosWithArgument(_ s: String, names: Set<String>) -> String {
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
            if !name.isEmpty, names.contains(name), let g = readGroup(a, k) {
                i = g.end
                continue
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
    }

    /// `\binom{n}{k}` → `C(n, k)`; `\stackrel{\Delta}{=}` keeps the relation and drops the
    /// ornament above it, which is the part that carries the meaning.
    private static func expandingTwoArgumentMacros(_ s: String) -> String {
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
            if !name.isEmpty, twoArgumentMacros.contains(name), let first = readGroup(a, k) {
                var m = first.end
                while m < a.count, a[m] == " " { m += 1 }
                if let second = readGroup(a, m) {
                    if name.hasSuffix("binom") {
                        out += "C(" + first.body + ", " + second.body + ")"
                    } else {
                        out += second.body
                    }
                    i = second.end
                    continue
                }
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
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

    /// `\hat{x}` → x̂. The mark is a combining character, so it lands on the glyph it belongs to
    /// however that glyph was written — a letter, a digit, or a command mapped later.
    private static func applyingAccents(_ s: String) -> String {
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
            if !name.isEmpty, let mark = accents[name] {
                if let g = readGroup(a, k) {
                    out += g.body
                    out.append(mark)
                    i = g.end
                    continue
                }
                // `\vec v` and `\hat\theta`: the accent takes the next single token.
                if k < a.count, a[k] == "\\" {
                    var m = k + 1
                    while m < a.count, a[m].isLetter { m += 1 }
                    if m > k + 1 {
                        out += String(a[k..<m])
                        out.append(mark)
                        i = m
                        continue
                    }
                }
                if k < a.count, isAlphanumeric(a[k]) {
                    out.append(a[k])
                    out.append(mark)
                    i = k + 1
                    continue
                }
            }
            let step = max(j, i + 1)
            out += String(a[i..<step])
            i = step
        }
        return out
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

    /// `\begin{aligned}…\end{aligned}` and the alignment `&` that only means something inside it.
    private static func removingEnvironments(_ s: String) -> String {
        guard s.contains("\\begin") || s.contains("\\end") else { return s }
        let a = Array(s)
        var out = ""
        var i = 0
        while i < a.count {
            // An alignment `&` is a column break and reads as a space. An escaped `\&` is an
            // ampersand the reader asked for, and it survives.
            if a[i] == "&", !(i > 0 && a[i - 1] == "\\") {
                out += " "
                i += 1
                continue
            }
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
                if i + 1 < a.count, let literal = escapes[a[i + 1]] {
                    out += literal
                    i += 2
                    continue
                }
                out.append(a[i])
                i += 1
                continue
            }
            // The fallback is the command's own spelling, which is right for `\sin` and wrong for
            // everything the tables above exist to catch.
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
                if g.body.isEmpty {
                    i = g.end
                    continue
                }
                if let mapped = mapRun(g.body, table) {
                    out += mapped
                } else if g.body.count == 1 {
                    // There is no lowered π. `x_π` is honest, `x_(π)` is noise, and dropping the
                    // script altogether is the one thing that must not happen.
                    out += String(c) + g.body
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

    /// Every accent sentinel exchanged for the mark it stands for. Nothing may leave this file
    /// carrying one: `MathText.unicode` is also what a copied paragraph, a Word export and a plain
    /// text export are built from, and a Private-Use character reaches all three as an empty box.
    private static func restoringAccents(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value >= 0xE020 && $0.value <= 0xE02B }) else {
            return s
        }
        var out = ""
        out.reserveCapacity(s.count)
        for c in s { out.append(accentMarks[c] ?? c) }
        return out
    }

    private static func restoringBraces(_ s: String) -> String {
        guard s.contains(braceOpenMark) || s.contains(braceCloseMark) else { return s }
        return s
            .replacingOccurrences(of: String(braceOpenMark), with: "{")
            .replacingOccurrences(of: String(braceCloseMark), with: "}")
    }

    /// `(π)/(4)` reads worse than `π/4`. But `(x+1)/2` is NOT `x+1/2`: only a parenthesis around a
    /// single atom — one short run of letters or digits, no operator in sight — may be dropped.
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
                if clean, j < a.count, a[j] == ")", !body.isEmpty, body.count <= 3, isAtom(body) {
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

    private static func isAtom(_ s: String) -> Bool {
        for c in s {
            if c.isLetter || c.isNumber { continue }
            return false
        }
        return true
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
