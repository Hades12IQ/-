import Foundation

/// One drawing lifted out of a fenced block, typed well enough to title it, decide whether it is
/// cheap enough to draw on sight, and hand its source to the island.
///
/// The web is the contract. `app.js` teaches the model exactly two drawing fences and the prompt
/// rule is explicit about which one wins (`app.js:38005-38036`, `tikzRule`):
///
/// * ```` ```plot ```` (also `graph` / `funcplot`) — the mandatory one. Cartesian `y = f(x)`,
///   polar `r = f(theta)`, parametric `x = f(t)` + `y = g(t)`, 3D surfaces `z = f(x,y)`, implicit
///   equations in 2D **and** 3D, and geometry commands (`point` / `segment` / `circle` / `angle` …).
///   `app.js:8725` (`parsePlotSpec`) is the grammar; the app ports it verbatim into the island.
/// * ```` ```tikz ```` — legacy, and the prompt actively steers the model away from it. The web
///   still renders it (`app.js:7957-8200`), first through a mini interpreter that turns explicit
///   coordinates into SVG, so the app does the same.
///
/// Nothing here evaluates an expression: the real parse happens in the island, in the ported
/// JavaScript, so there is exactly one grammar. This type only classifies, and the classification
/// is only ever used to choose the card's title and its symbol — it never decides whether a figure
/// is drawn, so a mode it reads differently from the island costs a label and never a picture.
struct DiagramSpec: Sendable, Hashable, Identifiable {

    /// Which of the web's two drawing fences this came from.
    enum Kind: String, Sendable, Hashable {
        case plot
        case tikz
    }

    /// What the `plot` body turned out to describe. Mirrors `parsePlotSpec`'s own precedence:
    /// geometry → surface → implicit → polar → parametric → cartesian.
    enum Mode: String, Sendable, Hashable {
        case cartesian
        case polar
        case parametric
        case implicitCurve
        case surface
        case implicitSurface
        case geometry
        case tikz
        case unknown

        var isThreeDimensional: Bool {
            self == .surface || self == .implicitSurface
        }
    }

    let kind: Kind
    /// The fence body, normalised: a bare TikZ body is wrapped in `\begin{tikzpicture}` the way
    /// `tikzifyCodeBlock` wraps it (`app.js:8190-8196`).
    let source: String
    let mode: Mode

    /// Stable across launches — the island is keyed by it, so the same figure never reloads twice.
    var id: String {
        kind.rawValue + "." + mode.rawValue + "." + DiagramSpec.digest(source)
    }

    // MARK: - Fence names

    /// `plotifyCodeBlock` accepts these three (`app.js:12885`).
    static let plotFenceNames: Set<String> = ["plot", "graph", "funcplot"]

    /// `looksLikeTikz` (`app.js:8177`).
    static let tikzFenceNames: Set<String> = ["tikz", "tikzpicture"]

    /// Every fence name that should become a drawing rather than a code box.
    static var recognisedNames: [String] {
        plotFenceNames.sorted() + tikzFenceNames.sorted()
    }

    // MARK: - Parsing

    /// A fenced block, by name and body. `nil` means "this is not a drawing" — the caller keeps its
    /// code box.
    static func parse(name: String, body: String) -> DiagramSpec? {
        let key = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if plotFenceNames.contains(key) {
            return DiagramSpec(kind: .plot, source: trimmed, mode: classify(trimmed))
        }
        if tikzFenceNames.contains(key) {
            return DiagramSpec(kind: .tikz, source: wrappedTikz(trimmed), mode: .tikz)
        }
        // `looksLikeTikz` also accepts a tex/latex block that carries a tikzpicture environment.
        if key == "tex" || key == "latex", trimmed.contains("\\begin{tikzpicture}") {
            return DiagramSpec(kind: .tikz, source: wrappedTikz(trimmed), mode: .tikz)
        }
        return nil
    }

    /// The already-recognised `plot` fence the message parser produced.
    static func parse(fence: FirasFence) -> DiagramSpec? {
        guard case .plot(let body) = fence else { return nil }
        return parse(name: "plot", body: body)
    }

    /// An ordinary fenced code block, by its language tag. Same rule as `tikzifyCodeBlock`: a bare
    /// `\begin{tikzpicture}` in a `tex` block is a drawing too.
    static func parse(codeLanguage: String?, body: String) -> DiagramSpec? {
        guard let codeLanguage, !codeLanguage.isEmpty else { return nil }
        return parse(name: codeLanguage, body: body)
    }

    /// `\begin{tikzpicture} … \end{tikzpicture}` around a bare body (`app.js:8193`).
    private static func wrappedTikz(_ body: String) -> String {
        if body.contains("\\begin{tikzpicture}") || body.contains("\\begin {tikzpicture}") {
            return body
        }
        return "\\begin{tikzpicture}\n" + body + "\n\\end{tikzpicture}"
    }

    // MARK: - Classification

    /// The shape verbs `parseShapeSpec` answers to (`app.js:8698-8710`). One of them at the head of
    /// any line makes the whole block a geometry figure, exactly as in `parsePlotSpec`.
    private static let shapeWords: Set<String> = [
        "point", "text", "label", "vector", "segment", "seg", "line", "ray", "circle", "ellipse",
        "arc", "angle", "triangle", "rectangle", "rect", "square", "polygon", "poly", "quad",
        "quadrilateral",
    ]

    /// Function and constant names stripped before looking for a bare variable letter — otherwise
    /// the `x` inside `exp(` and the `t` inside `sqrt` would answer for the variable itself. This is
    /// `hasVar`'s strip list (`app.js:8740`), longest first so `arcsin` is removed before `sin`.
    private static let strippedNames: [String] = [
        "arcsin", "arccos", "arctan", "asinh", "acosh", "atanh", "sinh", "cosh", "tanh", "asin",
        "acos", "atan", "sin", "cos", "tan", "sec", "cosec", "csc", "cotan", "cot", "ctg", "tg",
        "exp", "ln", "log10", "log2", "log", "lg", "sqrt", "cbrt", "abs", "sign", "floor", "ceil",
        "round", "theta", "tau", "pi",
    ].sorted { $0.count > $1.count }

    static func classify(_ body: String) -> Mode {
        let lines = body
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
        guard !lines.isEmpty else { return .unknown }

        if lines.contains(where: { isShapeLine($0) }) { return .geometry }

        var sawSurface = false
        var implicitIsThreeDimensional: Bool?
        var sawPolar = false
        var sawParametricX = false
        var sawParametricY = false
        var sawCartesian = false

        for line in lines {
            let lower = line.lowercased()

            guard let assignment = splitAssignment(lower) else {
                // No `=` at all: either a bare `-4..4` domain line or something we cannot read.
                if !isRangeText(lower) { sawCartesian = true }
                continue
            }

            let rhs = assignment.rhs.trimmingCharacters(in: .whitespaces)
            // `y: -3..3`, `x = -4..4`, `domain = -4..4`, `theta = 0..2*pi` — a domain, never a
            // curve, and the test has to come BEFORE the head is read: `domain` and `theta` are
            // not single letters, so inside the `plainHead` branch they were never reached and
            // every spec that spelled its range that way was read as carrying a cartesian curve.
            if isRangeText(rhs) { continue }
            if let head = plainHead(assignment.lhs) {
                switch head {
                case "z":
                    if (containsVariable("x", in: rhs) || containsVariable("y", in: rhs))
                        && !containsVariable("z", in: rhs) {
                        sawSurface = true
                        continue
                    }
                case "r":
                    if mentionsParameter(rhs) {
                        sawPolar = true
                        continue
                    }
                case "x":
                    if mentionsParameter(rhs) {
                        sawParametricX = true
                        continue
                    }
                case "y":
                    if mentionsParameter(rhs) && sawParametricX {
                        sawParametricY = true
                        continue
                    }
                default:
                    break
                }
                sawCartesian = true
                continue
            }

            // Not a `letter =` line, one `=` in it: an implicit equation. 3D as soon as a free z
            // appears anywhere in it (`app.js:8770-8776`).
            if assignment.count == 1 {
                let isThreeDimensional = containsVariable("z", in: lower)
                let qualifies = isThreeDimensional
                    ? (containsVariable("x", in: lower) || containsVariable("y", in: lower))
                    : (containsVariable("x", in: lower) && containsVariable("y", in: lower))
                if qualifies {
                    if implicitIsThreeDimensional == nil {
                        implicitIsThreeDimensional = isThreeDimensional
                    }
                    continue
                }
            }
            sawCartesian = true
        }

        if sawSurface { return .surface }
        if let isThreeDimensional = implicitIsThreeDimensional {
            return isThreeDimensional ? .implicitSurface : .implicitCurve
        }
        if sawPolar { return .polar }
        if sawParametricX && sawParametricY { return .parametric }
        if sawCartesian { return .cartesian }
        return .unknown
    }

    // MARK: - Line helpers

    private static func isShapeLine(_ line: String) -> Bool {
        var word = ""
        for character in line {
            if character.isLetter {
                word.append(character)
            } else {
                break
            }
        }
        guard !word.isEmpty else { return false }
        return shapeWords.contains(word.lowercased())
    }

    /// `(everything before the first `=`, everything after it, how many `=` the line carries)`.
    private static func splitAssignment(_ line: String) -> (lhs: String, rhs: String, count: Int)? {
        guard let first = line.firstIndex(of: "=") else { return nil }
        let count = line.reduce(into: 0) { total, character in
            if character == "=" { total += 1 }
        }
        let lhs = String(line[line.startIndex..<first])
        let rhs = String(line[line.index(after: first)...])
        return (lhs: lhs, rhs: rhs, count: count)
    }

    /// `y`, `z`, `r`, `f(x)`, `x(t)`, `r(theta)` → the single leading letter. Anything else → `nil`,
    /// which is what makes `x^2 + y^2` read as an implicit equation instead of an assignment.
    private static func plainHead(_ lhs: String) -> String? {
        var text = ""
        for character in lhs where !character.isWhitespace {
            text.append(character)
        }
        // A `domain:` / `x:` / `theta:` prefix ends in a colon; keep the letter before it.
        if text.hasSuffix(":") { text.removeLast() }
        guard let head = text.first, head.isLetter else { return nil }
        let rest = text.dropFirst()
        if rest.isEmpty { return String(head) }
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        let inner = rest.dropFirst().dropLast()
        let isArgumentList = inner.allSatisfy { $0.isLetter || $0 == "," || $0 == " " }
        return isArgumentList ? String(head) : nil
    }

    /// `-4..4`, `0 to 6`, `domain: -3..3` — a range, not an expression.
    private static func isRangeText(_ text: String) -> Bool {
        text.contains("..") || text.contains(" to ")
    }

    /// The `theta | θ | \bt\b` test the polar and parametric branches use (`app.js:8760-8767`).
    private static func mentionsParameter(_ text: String) -> Bool {
        if text.contains("theta") || text.contains("θ") { return true }
        return containsStandalone("t", in: text)
    }

    /// `t` as its own identifier — not the `t` inside `sqrt`, `atan` or `text`.
    private static func containsStandalone(_ needle: Character, in text: String) -> Bool {
        let characters = Array(text)
        for index in characters.indices where characters[index] == needle {
            let before = index > 0 ? characters[index - 1] : " "
            let after = index + 1 < characters.count ? characters[index + 1] : " "
            let beforeIsWord = before.isLetter || before.isNumber || before == "_"
            let afterIsWord = after.isLetter || after.isNumber || after == "_"
            if !beforeIsWord && !afterIsWord { return true }
        }
        return false
    }

    /// A free `x` / `y` / `z` in the text, with every function and constant name removed first.
    private static func containsVariable(_ variable: Character, in text: String) -> Bool {
        stripped(text).contains(variable)
    }

    private static func stripped(_ text: String) -> String {
        let lower = text
            .lowercased()
            .replacingOccurrences(of: "²", with: "^")
            .replacingOccurrences(of: "³", with: "^")
        let characters = Array(lower)
        var out = ""
        out.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            var matched = false
            for name in strippedNames {
                let letters = Array(name)
                guard index + letters.count <= characters.count else { continue }
                if Array(characters[index..<(index + letters.count)]) == letters {
                    out.append(" ")
                    index += letters.count
                    matched = true
                    break
                }
            }
            if !matched {
                out.append(characters[index])
                index += 1
            }
        }
        return out
    }

    // MARK: - Identity

    /// djb2 — the same cheap stable digest `MDBlock` uses for view identity.
    private static func digest<S: StringProtocol>(_ text: S) -> String {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }
}
