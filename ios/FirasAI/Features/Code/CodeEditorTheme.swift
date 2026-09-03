import SwiftUI
import UIKit

/// The editor skin and its tokenizer.
///
/// `CodeHighlighter` (Rendering) paints read-only `AttributedString` code blocks from palette
/// tokens; the editor is a `UITextView` and needs `UIColor` over `NSRange`, plus gutter, caret,
/// active-line and selection colours that a transcript never has. The hexes are the web editor's
/// CodeMirror skin (`design-brief.md §7.9`, `web-code-ux.md §5.3`) so a file looks the same on
/// both clients.
struct CodeEditorTheme {

    /// One coloured span, in UTF-16 offsets so it can be handed to `NSTextStorage` directly.
    struct Token {
        let range: NSRange
        let color: UIColor
    }

    let background: UIColor
    let plain: UIColor
    let comment: UIColor
    let keyword: UIColor
    let string: UIColor
    let number: UIColor
    let tag: UIColor
    let attribute: UIColor
    let definition: UIColor
    let builtin: UIColor
    let cursor: UIColor
    let gutterBackground: UIColor
    let gutterText: UIColor
    let gutterActiveText: UIColor
    let activeLine: UIColor
    let selection: UIColor

    // MARK: - Skins

    /// The web's dark editor skin, byte for byte.
    static let dark = CodeEditorTheme(
        background: hex(0x1B1B19),
        plain: hex(0xD8D5CB),
        comment: hex(0x7A776A),
        keyword: hex(0xE39A72),
        string: hex(0x8FC9A8),
        number: hex(0xE0B35E),
        tag: hex(0xE08B66),
        attribute: hex(0x6FB8AB),
        definition: hex(0x9BA8E8),
        builtin: hex(0xC4A7F5),
        cursor: hex(0xE39A72),
        gutterBackground: hex(0x242422),
        gutterText: hex(0x6E6B60),
        gutterActiveText: hex(0xD8D5CB),
        activeLine: hex(0x282824),
        selection: hex(0x3A382E)
    )

    /// The light family's skin — same hues, darkened until they pass on paper white.
    static let light = CodeEditorTheme(
        background: hex(0xFFFFFF),
        plain: hex(0x1A1A18),
        comment: hex(0x8A877B),
        keyword: hex(0xA8480F),
        string: hex(0x1F6B44),
        number: hex(0x8A5A0B),
        tag: hex(0xA33C16),
        attribute: hex(0x156F62),
        definition: hex(0x3B4AA8),
        builtin: hex(0x6B34B0),
        cursor: hex(0xA8480F),
        gutterBackground: hex(0xF0EEE6),
        gutterText: hex(0x8A877B),
        gutterActiveText: hex(0x1A1A18),
        activeLine: hex(0xF6F4EC),
        selection: hex(0xD9E7E1)
    )

    /// Only the `light` theme is a light family (`ARCHITECTURE §2.7`).
    static func skin(for theme: FirasTheme) -> CodeEditorTheme {
        theme.isLight ? light : dark
    }

    // MARK: - Language

    /// `cwLangLabel` (`web-code-ux.md §5.3`) — what the status bar calls this file.
    static func languageLabel(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "js", "mjs", "jsx": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "json": return "JSON"
        case "py": return "Python"
        case "xml": return "XML"
        case "svg": return "SVG"
        case "md": return "Markdown"
        case "txt", "": return "Text"
        default: return ext.uppercased()
        }
    }

    /// The `CodeHighlighter` language key for the same extension, so a read-only block and the
    /// editor agree about what a file is.
    static func highlighterLanguage(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "html", "htm", "xml", "svg", "vue": return "html"
        case "css", "scss", "less": return "css"
        case "js", "mjs", "jsx": return "js"
        case "ts", "tsx": return "ts"
        case "json": return "json"
        case "py": return "python"
        case "swift": return "swift"
        case "sh", "bash", "zsh": return "bash"
        default: return nil
        }
    }

    // MARK: - Tokenizing

    /// Above this the file is drawn plain: a linear scan is cheap, but re-attributing a
    /// quarter-million characters on every 150 ms tick is not.
    static let highlightBudget = 60_000

    /// Colour spans for `code`, in UTF-16 offsets. Empty when the file is too large or the
    /// language is unknown — the caller then paints everything `plain`.
    func tokens(in code: String, ext: String) -> [Token] {
        guard !code.isEmpty, code.count <= Self.highlightBudget else { return [] }

        let characters = Array(code)
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        var running = 0
        for (index, character) in characters.enumerated() {
            offsets[index] = running
            running += character.utf16.count
        }
        offsets[characters.count] = running

        var lexer = Lexer(characters: characters, offsets: offsets, theme: self)
        switch Self.family(for: ext) {
        case .markup:
            lexer.scanMarkup()
        case .stylesheet:
            lexer.scanStylesheet()
        case .script(let spec):
            lexer.scanScript(spec)
        case .markdown:
            lexer.scanMarkdown()
        case .plain:
            return []
        }
        return lexer.tokens
    }

    // MARK: - Families

    private struct ScriptSpec {
        let keywords: Set<String>
        let builtins: Set<String>
        let lineComment: String?
        let blockComment: Bool
        let tripleQuote: Bool
        let backtick: Bool
    }

    private enum Family {
        case markup
        case stylesheet
        case script(ScriptSpec)
        case markdown
        case plain
    }

    private static func family(for ext: String) -> Family {
        switch ext.lowercased() {
        case "html", "htm", "xml", "svg", "vue", "xhtml":
            return .markup
        case "css", "scss", "less":
            return .stylesheet
        case "json", "jsonc", "json5":
            return .script(ScriptSpec(keywords: ["true", "false", "null"], builtins: [],
                                      lineComment: "//", blockComment: true,
                                      tripleQuote: false, backtick: false))
        case "js", "mjs", "cjs", "jsx":
            return .script(ScriptSpec(keywords: jsKeywords, builtins: jsBuiltins,
                                      lineComment: "//", blockComment: true,
                                      tripleQuote: false, backtick: true))
        case "ts", "tsx":
            return .script(ScriptSpec(keywords: jsKeywords.union(tsKeywords), builtins: jsBuiltins,
                                      lineComment: "//", blockComment: true,
                                      tripleQuote: false, backtick: true))
        case "py":
            return .script(ScriptSpec(keywords: pythonKeywords, builtins: pythonBuiltins,
                                      lineComment: "#", blockComment: false,
                                      tripleQuote: true, backtick: false))
        case "swift":
            return .script(ScriptSpec(keywords: swiftKeywords, builtins: [],
                                      lineComment: "//", blockComment: true,
                                      tripleQuote: true, backtick: false))
        case "sh", "bash", "zsh":
            return .script(ScriptSpec(keywords: bashKeywords, builtins: [],
                                      lineComment: "#", blockComment: false,
                                      tripleQuote: false, backtick: false))
        case "md", "markdown":
            return .markdown
        default:
            return .plain
        }
    }

    private static let jsKeywords: Set<String> = [
        "await", "async", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "from",
        "function", "get", "if", "import", "in", "instanceof", "let", "new", "of", "return",
        "set", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
        "while", "with", "yield", "true", "false", "null", "undefined"
    ]

    private static let jsBuiltins: Set<String> = [
        "console", "document", "window", "Math", "JSON", "Object", "Array", "String", "Number",
        "Boolean", "Promise", "Map", "Set", "Date", "RegExp", "fetch", "localStorage",
        "setTimeout", "setInterval", "requestAnimationFrame"
    ]

    private static let tsKeywords: Set<String> = [
        "abstract", "any", "as", "boolean", "declare", "enum", "implements", "interface", "is",
        "keyof", "namespace", "never", "number", "private", "protected", "public", "readonly",
        "string", "type", "unknown"
    ]

    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
        "True", "try", "while", "with", "yield"
    ]

    private static let pythonBuiltins: Set<String> = [
        "abs", "dict", "enumerate", "float", "int", "len", "list", "max", "min", "open",
        "print", "range", "round", "set", "sorted", "str", "sum", "tuple", "type", "zip"
    ]

    private static let swiftKeywords: Set<String> = [
        "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
        "init", "internal", "is", "let", "nil", "private", "protocol", "public", "repeat",
        "return", "self", "some", "static", "struct", "switch", "throw", "throws", "true",
        "try", "typealias", "var", "where", "while"
    ]

    private static let bashKeywords: Set<String> = [
        "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "fi",
        "for", "function", "if", "in", "local", "return", "set", "source", "then", "unset",
        "until", "while"
    ]

    // MARK: - Colour helper

    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - Scanner

    /// A strictly linear tokenizer. No regular expressions: an editor buffer can be 60 000
    /// characters and a backtracking pattern over that is how a keystroke becomes a freeze.
    private struct Lexer {
        let characters: [Character]
        let offsets: [Int]
        let theme: CodeEditorTheme
        var tokens: [Token] = []
        private var index = 0

        init(characters: [Character], offsets: [Int], theme: CodeEditorTheme) {
            self.characters = characters
            self.offsets = offsets
            self.theme = theme
        }

        private mutating func emit(_ from: Int, _ to: Int, _ color: UIColor) {
            guard to > from else { return }
            let location = offsets[from]
            tokens.append(Token(range: NSRange(location: location, length: offsets[to] - location),
                                color: color))
        }

        private func matches(_ marker: String, at start: Int) -> Bool {
            let needle = Array(marker)
            guard !needle.isEmpty, start + needle.count <= characters.count else { return false }
            for offset in 0..<needle.count where characters[start + offset] != needle[offset] {
                return false
            }
            return true
        }

        private func lineEnd(from start: Int) -> Int {
            var cursor = start
            while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
            return cursor
        }

        // MARK: Script

        mutating func scanScript(_ spec: ScriptSpec) {
            index = 0
            while index < characters.count {
                let character = characters[index]

                if spec.blockComment, character == "/", matches("/*", at: index) {
                    var cursor = index + 2
                    while cursor + 1 < characters.count,
                          !(characters[cursor] == "*" && characters[cursor + 1] == "/") {
                        cursor += 1
                    }
                    let end = cursor + 1 < characters.count ? cursor + 2 : characters.count
                    emit(index, end, theme.comment)
                    index = end
                    continue
                }

                if let marker = spec.lineComment, matches(marker, at: index) {
                    let end = lineEnd(from: index)
                    emit(index, end, theme.comment)
                    index = end
                    continue
                }

                if spec.tripleQuote, character == "\"", matches("\"\"\"", at: index) {
                    var cursor = index + 3
                    while cursor < characters.count, !matches("\"\"\"", at: cursor) { cursor += 1 }
                    let end = min(cursor + 3, characters.count)
                    emit(index, end, theme.string)
                    index = end
                    continue
                }

                if character == "\"" || character == "'" || (spec.backtick && character == "`") {
                    index = scanQuoted(from: index, quote: character, multiline: character == "`")
                    continue
                }

                if isDigit(character), index == 0 || !isIdentifierPart(characters[index - 1]) {
                    var cursor = index
                    while cursor < characters.count, isNumberPart(characters[cursor]) { cursor += 1 }
                    emit(index, cursor, theme.number)
                    index = cursor
                    continue
                }

                if isIdentifierStart(character) {
                    var cursor = index
                    while cursor < characters.count, isIdentifierPart(characters[cursor]) { cursor += 1 }
                    let word = String(characters[index..<cursor])
                    if spec.keywords.contains(word) {
                        emit(index, cursor, theme.keyword)
                    } else if spec.builtins.contains(word) {
                        emit(index, cursor, theme.builtin)
                    } else if cursor < characters.count, characters[cursor] == "(" {
                        emit(index, cursor, theme.definition)
                    }
                    index = cursor
                    continue
                }

                index += 1
            }
        }

        private mutating func scanQuoted(from start: Int, quote: Character, multiline: Bool) -> Int {
            var cursor = start + 1
            while cursor < characters.count {
                if characters[cursor] == "\\" { cursor += 2; continue }
                if characters[cursor] == quote { cursor += 1; break }
                if !multiline, characters[cursor] == "\n" { break }
                cursor += 1
            }
            let end = min(cursor, characters.count)
            emit(start, end, theme.string)
            return max(end, start + 1)
        }

        // MARK: Markup

        mutating func scanMarkup() {
            index = 0
            while index < characters.count {
                if matches("<!--", at: index) {
                    var cursor = index + 4
                    while cursor + 2 < characters.count, !matches("-->", at: cursor) { cursor += 1 }
                    let end = cursor + 2 < characters.count ? cursor + 3 : characters.count
                    emit(index, end, theme.comment)
                    index = end
                    continue
                }

                if characters[index] == "<" {
                    var cursor = index + 1
                    if cursor < characters.count, characters[cursor] == "/" { cursor += 1 }
                    while cursor < characters.count, isTagNamePart(characters[cursor]) { cursor += 1 }
                    emit(index, cursor, theme.tag)
                    index = cursor
                    scanTagBody()
                    continue
                }

                index += 1
            }
        }

        private mutating func scanTagBody() {
            while index < characters.count, characters[index] != ">" {
                let character = characters[index]
                if character == "\"" || character == "'" {
                    index = scanQuoted(from: index, quote: character, multiline: false)
                    continue
                }
                if isTagNamePart(character) {
                    var cursor = index
                    while cursor < characters.count, isTagNamePart(characters[cursor]) { cursor += 1 }
                    emit(index, cursor, theme.attribute)
                    index = cursor
                    continue
                }
                index += 1
            }
            if index < characters.count {
                emit(index, index + 1, theme.tag)
                index += 1
            }
        }

        // MARK: Stylesheet

        mutating func scanStylesheet() {
            index = 0
            var insideBlock = false
            var afterColon = false

            while index < characters.count {
                let character = characters[index]

                if character == "/", matches("/*", at: index) {
                    var cursor = index + 2
                    while cursor + 1 < characters.count,
                          !(characters[cursor] == "*" && characters[cursor + 1] == "/") {
                        cursor += 1
                    }
                    let end = cursor + 1 < characters.count ? cursor + 2 : characters.count
                    emit(index, end, theme.comment)
                    index = end
                    continue
                }

                if character == "\"" || character == "'" {
                    index = scanQuoted(from: index, quote: character, multiline: false)
                    continue
                }

                if character == "@", !insideBlock {
                    var cursor = index + 1
                    while cursor < characters.count, isTagNamePart(characters[cursor]) { cursor += 1 }
                    emit(index, cursor, theme.keyword)
                    index = cursor
                    continue
                }

                if character == "{" { insideBlock = true; afterColon = false; index += 1; continue }
                if character == "}" { insideBlock = false; afterColon = false; index += 1; continue }
                if character == ":", insideBlock { afterColon = true; index += 1; continue }
                if character == ";" { afterColon = false; index += 1; continue }

                if isDigit(character), afterColon {
                    var cursor = index
                    while cursor < characters.count, isNumberPart(characters[cursor]) { cursor += 1 }
                    while cursor < characters.count, isLetter(characters[cursor]) || characters[cursor] == "%" {
                        cursor += 1
                    }
                    emit(index, cursor, theme.number)
                    index = cursor
                    continue
                }

                if isTagNamePart(character) || character == "." || character == "#" {
                    var cursor = index
                    while cursor < characters.count,
                          isTagNamePart(characters[cursor]) || characters[cursor] == "."
                            || characters[cursor] == "#" || characters[cursor] == "-" {
                        cursor += 1
                    }
                    if insideBlock {
                        emit(index, cursor, afterColon ? theme.string : theme.attribute)
                    } else {
                        emit(index, cursor, theme.tag)
                    }
                    index = cursor
                    continue
                }

                index += 1
            }
        }

        // MARK: Markdown

        mutating func scanMarkdown() {
            index = 0
            var atLineStart = true
            while index < characters.count {
                let character = characters[index]

                if atLineStart, character == "#" {
                    let end = lineEnd(from: index)
                    emit(index, end, theme.tag)
                    index = end
                    continue
                }

                if atLineStart, matches("```", at: index) {
                    var cursor = index + 3
                    while cursor < characters.count, !matches("```", at: cursor) { cursor += 1 }
                    let end = min(cursor + 3, characters.count)
                    emit(index, end, theme.string)
                    index = end
                    atLineStart = false
                    continue
                }

                if atLineStart, character == ">" || character == "-" || character == "*" {
                    emit(index, index + 1, theme.keyword)
                    index += 1
                    atLineStart = false
                    continue
                }

                if character == "`" {
                    var cursor = index + 1
                    while cursor < characters.count, characters[cursor] != "`",
                          characters[cursor] != "\n" {
                        cursor += 1
                    }
                    let end = min(cursor + 1, characters.count)
                    emit(index, end, theme.string)
                    index = end
                    continue
                }

                if character == "[" {
                    var cursor = index + 1
                    while cursor < characters.count, characters[cursor] != "\n",
                          characters[cursor] != ")" {
                        cursor += 1
                    }
                    let end = min(cursor + 1, characters.count)
                    emit(index, end, theme.definition)
                    index = end
                    continue
                }

                atLineStart = character == "\n"
                index += 1
            }
        }

        // MARK: Characters

        private func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        private func isLetter(_ c: Character) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
        }

        private func isIdentifierStart(_ c: Character) -> Bool {
            isLetter(c) || c == "_" || c == "$"
        }

        private func isIdentifierPart(_ c: Character) -> Bool {
            isIdentifierStart(c) || isDigit(c)
        }

        private func isTagNamePart(_ c: Character) -> Bool {
            isIdentifierPart(c) || c == "-" || c == ":"
        }

        private func isNumberPart(_ c: Character) -> Bool {
            isDigit(c) || c == "." || c == "_" || c == "x"
                || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
        }
    }
}
