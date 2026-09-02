import SwiftUI

/// A small, strictly linear tokenizer for the languages the app actually shows.
///
/// No regular expressions: a code block can be 40 000 characters of machine-written text, and a
/// backtracking pattern over that is the classic way to freeze a transcript. Every colour comes
/// from a `FirasPalette` token so the six themes stay legible without a second skin table.
enum CodeHighlighter {

    /// Beyond this the block is drawn plain — nobody reads 40 000 characters of colour, and the
    /// tokenizer's cost stops being free.
    private static let budget = 40_000

    static func highlight(_ code: String, language: String?, palette: FirasPalette) -> AttributedString {
        let colors = Colors(palette: palette)
        guard !code.isEmpty else { return AttributedString() }
        guard code.count <= budget else { return piece(code, colors.plain) }

        switch family(for: language) {
        case .markup:
            return markup(code, colors: colors)
        case .stylesheet:
            return stylesheet(code, colors: colors)
        case .script(let spec):
            return script(code, colors: colors, spec: spec)
        case .plain:
            return piece(code, colors.plain)
        }
    }

    // MARK: - Palette

    private struct Colors {
        let plain: Color
        let comment: Color
        let keyword: Color
        let string: Color
        let number: Color
        let tag: Color
        let attribute: Color

        init(palette: FirasPalette) {
            plain = palette.textPrimary
            comment = palette.textMuted
            keyword = palette.accent
            string = palette.codeOk
            number = palette.planGold
            tag = palette.maxTierText
            attribute = palette.planDiamond
        }
    }

    private static func piece(_ text: String, _ color: Color) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = color
        return a
    }

    // MARK: - Language families

    private struct ScriptSpec {
        let keywords: Set<String>
        let lineComment: String?
        let blockComment: Bool
        let tripleQuote: Bool
        let backtick: Bool
    }

    private enum Family {
        case markup
        case stylesheet
        case script(ScriptSpec)
        case plain
    }

    private static func family(for language: String?) -> Family {
        let key = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "html", "htm", "xml", "svg", "vue", "xhtml":
            return .markup
        case "css", "scss", "less":
            return .stylesheet
        case "json", "jsonc", "json5":
            return .script(ScriptSpec(keywords: jsonKeywords, lineComment: "//", blockComment: true,
                                      tripleQuote: false, backtick: false))
        case "js", "javascript", "jsx", "mjs", "cjs":
            return .script(ScriptSpec(keywords: jsKeywords, lineComment: "//", blockComment: true,
                                      tripleQuote: false, backtick: true))
        case "ts", "typescript", "tsx":
            return .script(ScriptSpec(keywords: jsKeywords.union(tsKeywords), lineComment: "//", blockComment: true,
                                      tripleQuote: false, backtick: true))
        case "swift":
            return .script(ScriptSpec(keywords: swiftKeywords, lineComment: "//", blockComment: true,
                                      tripleQuote: true, backtick: false))
        case "py", "python", "python3":
            return .script(ScriptSpec(keywords: pythonKeywords, lineComment: "#", blockComment: false,
                                      tripleQuote: true, backtick: false))
        case "bash", "sh", "shell", "zsh", "console":
            return .script(ScriptSpec(keywords: bashKeywords, lineComment: "#", blockComment: false,
                                      tripleQuote: false, backtick: false))
        default:
            return .plain
        }
    }

    private static let jsonKeywords: Set<String> = ["true", "false", "null"]

    private static let jsKeywords: Set<String> = [
        "await", "async", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "from",
        "function", "get", "if", "import", "in", "instanceof", "let", "new", "of", "return",
        "set", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
        "while", "with", "yield", "true", "false", "null", "undefined"
    ]

    private static let tsKeywords: Set<String> = [
        "abstract", "any", "as", "boolean", "declare", "enum", "implements", "interface", "is",
        "keyof", "namespace", "never", "number", "private", "protected", "public", "readonly",
        "string", "type", "unknown"
    ]

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
        "indirect", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
        "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "return",
        "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while"
    ]

    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
        "True", "try", "while", "with", "yield"
    ]

    private static let bashKeywords: Set<String> = [
        "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "fi",
        "for", "function", "if", "in", "local", "return", "set", "source", "then", "unset",
        "until", "while"
    ]

    // MARK: - Script tokenizer

    private static func script(_ code: String, colors: Colors, spec: ScriptSpec) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        let a = Array(code)
        var i = 0

        func flush() {
            if buffer.isEmpty { return }
            out.append(piece(buffer, colors.plain))
            buffer = ""
        }

        while i < a.count {
            let c = a[i]

            if spec.blockComment, c == "/", i + 1 < a.count, a[i + 1] == "*" {
                flush()
                var j = i + 2
                while j + 1 < a.count, !(a[j] == "*" && a[j + 1] == "/") { j += 1 }
                let end = j + 1 < a.count ? j + 2 : a.count
                out.append(piece(String(a[i..<end]), colors.comment))
                i = end
                continue
            }

            if let marker = spec.lineComment, matches(a, at: i, marker) {
                flush()
                var j = i
                while j < a.count, a[j] != "\n" { j += 1 }
                out.append(piece(String(a[i..<j]), colors.comment))
                i = j
                continue
            }

            if spec.tripleQuote, c == "\"", i + 2 < a.count, a[i + 1] == "\"", a[i + 2] == "\"" {
                flush()
                var j = i + 3
                while j + 2 < a.count, !(a[j] == "\"" && a[j + 1] == "\"" && a[j + 2] == "\"") { j += 1 }
                let end = j + 2 < a.count ? j + 3 : a.count
                out.append(piece(String(a[i..<end]), colors.string))
                i = end
                continue
            }

            if c == "\"" || c == "'" || (spec.backtick && c == "`") {
                flush()
                let quote = c
                let multiline = quote == "`"
                var j = i + 1
                while j < a.count {
                    if a[j] == "\\" { j += 2; continue }
                    if a[j] == quote { j += 1; break }
                    if !multiline, a[j] == "\n" { break }
                    j += 1
                }
                let end = min(j, a.count)
                out.append(piece(String(a[i..<end]), colors.string))
                i = end
                continue
            }

            if isDigit(c), !isIdentifierPart(i > 0 ? a[i - 1] : " ") {
                flush()
                var j = i
                while j < a.count, isDigit(a[j]) || a[j] == "." || a[j] == "_"
                    || a[j] == "x" || (a[j] >= "a" && a[j] <= "f") || (a[j] >= "A" && a[j] <= "F") {
                    j += 1
                }
                out.append(piece(String(a[i..<j]), colors.number))
                i = j
                continue
            }

            if isIdentifierStart(c) {
                var j = i
                while j < a.count, isIdentifierPart(a[j]) { j += 1 }
                let word = String(a[i..<j])
                if spec.keywords.contains(word) {
                    flush()
                    out.append(piece(word, colors.keyword))
                } else {
                    buffer += word
                }
                i = j
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    // MARK: - Markup tokenizer

    private static func markup(_ code: String, colors: Colors) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        let a = Array(code)
        var i = 0

        func flush() {
            if buffer.isEmpty { return }
            out.append(piece(buffer, colors.plain))
            buffer = ""
        }

        while i < a.count {
            if a[i] == "<", i + 3 < a.count, a[i + 1] == "!", a[i + 2] == "-", a[i + 3] == "-" {
                flush()
                var j = i + 4
                while j + 2 < a.count, !(a[j] == "-" && a[j + 1] == "-" && a[j + 2] == ">") { j += 1 }
                let end = j + 2 < a.count ? j + 3 : a.count
                out.append(piece(String(a[i..<end]), colors.comment))
                i = end
                continue
            }

            if a[i] == "<" {
                flush()
                var j = i + 1
                if j < a.count, a[j] == "/" { j += 1 }
                let nameStart = j
                while j < a.count, isTagNamePart(a[j]) { j += 1 }
                out.append(piece(String(a[i..<nameStart]), colors.tag))
                out.append(piece(String(a[nameStart..<j]), colors.tag))
                i = j
                // Attributes until the tag closes.
                while i < a.count, a[i] != ">" {
                    if a[i] == "\"" || a[i] == "'" {
                        let quote = a[i]
                        var k = i + 1
                        while k < a.count, a[k] != quote { k += 1 }
                        let end = k < a.count ? k + 1 : a.count
                        out.append(piece(String(a[i..<end]), colors.string))
                        i = end
                        continue
                    }
                    if isTagNamePart(a[i]) {
                        var k = i
                        while k < a.count, isTagNamePart(a[k]) { k += 1 }
                        out.append(piece(String(a[i..<k]), colors.attribute))
                        i = k
                        continue
                    }
                    out.append(piece(String(a[i]), colors.tag))
                    i += 1
                }
                if i < a.count {
                    out.append(piece(">", colors.tag))
                    i += 1
                }
                continue
            }

            buffer.append(a[i])
            i += 1
        }
        flush()
        return out
    }

    // MARK: - Stylesheet tokenizer

    private static func stylesheet(_ code: String, colors: Colors) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        let a = Array(code)
        var i = 0
        var insideBlock = false
        var afterColon = false

        func flush() {
            if buffer.isEmpty { return }
            out.append(piece(buffer, insideBlock && !afterColon ? colors.attribute : colors.plain))
            buffer = ""
        }

        while i < a.count {
            let c = a[i]

            if c == "/", i + 1 < a.count, a[i + 1] == "*" {
                flush()
                var j = i + 2
                while j + 1 < a.count, !(a[j] == "*" && a[j + 1] == "/") { j += 1 }
                let end = j + 1 < a.count ? j + 2 : a.count
                out.append(piece(String(a[i..<end]), colors.comment))
                i = end
                continue
            }

            if c == "\"" || c == "'" {
                flush()
                let quote = c
                var j = i + 1
                while j < a.count, a[j] != quote, a[j] != "\n" { j += 1 }
                let end = j < a.count ? j + 1 : a.count
                out.append(piece(String(a[i..<end]), colors.string))
                i = end
                continue
            }

            if c == "@", !insideBlock {
                flush()
                var j = i + 1
                while j < a.count, isTagNamePart(a[j]) { j += 1 }
                out.append(piece(String(a[i..<j]), colors.keyword))
                i = j
                continue
            }

            if c == "{" {
                flush()
                insideBlock = true
                afterColon = false
                out.append(piece("{", colors.plain))
                i += 1
                continue
            }
            if c == "}" {
                flush()
                insideBlock = false
                afterColon = false
                out.append(piece("}", colors.plain))
                i += 1
                continue
            }
            if c == ":", insideBlock {
                flush()
                afterColon = true
                out.append(piece(":", colors.plain))
                i += 1
                continue
            }
            if c == ";" {
                flush()
                afterColon = false
                out.append(piece(";", colors.plain))
                i += 1
                continue
            }

            if !insideBlock, buffer.isEmpty, isTagNamePart(c) || c == "." || c == "#" {
                var j = i
                while j < a.count, isTagNamePart(a[j]) || a[j] == "." || a[j] == "#" || a[j] == "-" { j += 1 }
                out.append(piece(String(a[i..<j]), colors.tag))
                i = j
                continue
            }

            if isDigit(c), afterColon {
                flush()
                var j = i
                while j < a.count, isDigit(a[j]) || a[j] == "." || a[j] == "%" { j += 1 }
                while j < a.count, a[j] >= "a", a[j] <= "z" { j += 1 }
                out.append(piece(String(a[i..<j]), colors.number))
                i = j
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    // MARK: - Character helpers

    private static func matches(_ a: [Character], at index: Int, _ marker: String) -> Bool {
        let m = Array(marker)
        guard !m.isEmpty, index + m.count <= a.count else { return false }
        var k = 0
        while k < m.count {
            if a[index + k] != m[k] { return false }
            k += 1
        }
        return true
    }

    private static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" || c == "$"
    }

    private static func isIdentifierPart(_ c: Character) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    private static func isTagNamePart(_ c: Character) -> Bool {
        isIdentifierPart(c) || c == "-" || c == ":"
    }
}
