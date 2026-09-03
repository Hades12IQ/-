import Foundation

/// The language tables: which fence tag maps to which scanner, the keyword sets those scanners
/// look words up in, and the human label the code box prints in its header.
///
/// Split out of `CodeHighlighter.swift` because the scanners and the vocabularies change for
/// different reasons — a new language is a table entry here and nothing else.
extension CodeHighlighter {

    // MARK: - Family resolution

    static func family(for language: String?) -> Family {
        switch normalized(language) {
        case "html", "htm", "xhtml", "xml", "svg", "vue", "svelte", "jsp", "aspx":
            return .markup
        case "css", "scss", "sass", "less":
            return .stylesheet
        case "json", "jsonc", "json5", "geojson":
            return .script(jsonSpec)
        case "js", "javascript", "jsx", "mjs", "cjs", "node":
            return .script(jsSpec)
        case "ts", "typescript", "tsx":
            return .script(tsSpec)
        case "swift":
            return .script(swiftSpec)
        case "py", "python", "python3", "py3":
            return .script(pythonSpec)
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "objectivec":
            return .script(cppSpec)
        case "java":
            return .script(javaSpec)
        case "kt", "kotlin":
            return .script(kotlinSpec)
        case "cs", "csharp", "c#":
            return .script(csharpSpec)
        case "sql", "mysql", "postgres", "postgresql", "sqlite", "plsql", "tsql":
            return .script(sqlSpec)
        case "sh", "bash", "zsh", "shell", "console", "terminal":
            return .script(bashSpec)
        case "go", "golang":
            return .script(goSpec)
        case "rs", "rust":
            return .script(rustSpec)
        case "php":
            return .script(phpSpec)
        case "rb", "ruby":
            return .script(rubySpec)
        case "dart":
            return .script(dartSpec)
        case "yml", "yaml", "toml", "ini":
            return .script(configSpec)
        default:
            return .plain
        }
    }

    /// A fence tag lowercased, with a leading dot and any `{…}` decoration removed.
    static func normalized(_ language: String?) -> String {
        var key = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        while key.hasPrefix(".") { key.removeFirst() }
        if let cut = key.firstIndex(where: { $0 == "{" || $0 == " " || $0 == ":" }) {
            key = String(key[key.startIndex..<cut])
        }
        return key
    }

    /// The header label — the casing a developer expects, never the raw fence tag.
    static func label(for language: String?) -> String {
        let key = normalized(language)
        switch key {
        case "": return "TEXT"
        case "html", "htm", "xhtml": return "HTML"
        case "xml": return "XML"
        case "svg": return "SVG"
        case "css": return "CSS"
        case "scss", "sass": return "SCSS"
        case "less": return "LESS"
        case "js", "javascript", "mjs", "cjs", "node": return "JavaScript"
        case "jsx": return "JSX"
        case "ts", "typescript": return "TypeScript"
        case "tsx": return "TSX"
        case "json", "jsonc", "json5", "geojson": return "JSON"
        case "py", "python", "python3", "py3": return "Python"
        case "c", "h": return "C"
        case "cpp", "c++", "cc", "cxx", "hpp", "hh": return "C++"
        case "objc", "objectivec": return "Objective-C"
        case "java": return "Java"
        case "kt", "kotlin": return "Kotlin"
        case "cs", "csharp", "c#": return "C#"
        case "swift": return "Swift"
        case "sql", "mysql", "postgres", "postgresql", "sqlite", "plsql", "tsql": return "SQL"
        case "sh", "bash", "zsh", "shell", "console", "terminal": return "Shell"
        case "go", "golang": return "Go"
        case "rs", "rust": return "Rust"
        case "php": return "PHP"
        case "rb", "ruby": return "Ruby"
        case "dart": return "Dart"
        case "yml", "yaml": return "YAML"
        case "toml": return "TOML"
        case "ini": return "INI"
        case "md", "markdown": return "Markdown"
        case "txt", "text", "plain": return "Text"
        case "diff", "patch": return "Diff"
        case "vue": return "Vue"
        case "svelte": return "Svelte"
        default: return key.uppercased()
        }
    }

    // MARK: - Specs

    /// The scanner an inline `<script>` inside a previewed page is read with.
    static let embeddedScriptSpec: Spec = jsSpec

    static let jsonSpec: Spec = Spec(
        keywords: ["true", "false", "null"],
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/"
    )

    static let jsSpec: Spec = Spec(
        keywords: jsKeywords,
        types: jsGlobals,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        backtick: true
    )

    static let tsSpec: Spec = Spec(
        keywords: jsKeywords.union(tsKeywords),
        types: jsGlobals,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        backtick: true,
        capitalsAreTypes: true
    )

    static let swiftSpec: Spec = Spec(
        keywords: swiftKeywords,
        types: swiftTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        tripleQuote: true,
        capitalsAreTypes: true
    )

    static let pythonSpec: Spec = Spec(
        keywords: pythonKeywords,
        types: pythonBuiltins,
        lineComments: ["#"],
        blockOpen: nil,
        blockClose: nil,
        tripleQuote: true
    )

    static let cppSpec: Spec = Spec(
        keywords: cppKeywords,
        types: cppTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        preprocessor: true
    )

    static let javaSpec: Spec = Spec(
        keywords: javaKeywords,
        types: javaTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        capitalsAreTypes: true
    )

    static let kotlinSpec: Spec = Spec(
        keywords: kotlinKeywords,
        types: javaTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        tripleQuote: true,
        capitalsAreTypes: true
    )

    static let csharpSpec: Spec = Spec(
        keywords: csharpKeywords,
        types: javaTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        capitalsAreTypes: true
    )

    static let sqlSpec: Spec = Spec(
        keywords: sqlKeywords,
        types: sqlTypes,
        lineComments: ["--", "#"],
        blockOpen: "/*",
        blockClose: "*/",
        caseInsensitive: true
    )

    static let bashSpec: Spec = Spec(
        keywords: bashKeywords,
        lineComments: ["#"],
        blockOpen: nil,
        blockClose: nil,
        backtick: true
    )

    static let goSpec: Spec = Spec(
        keywords: goKeywords,
        types: goTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        backtick: true,
        capitalsAreTypes: true
    )

    static let rustSpec: Spec = Spec(
        keywords: rustKeywords,
        types: rustTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        capitalsAreTypes: true
    )

    static let phpSpec: Spec = Spec(
        keywords: phpKeywords,
        lineComments: ["//", "#"],
        blockOpen: "/*",
        blockClose: "*/"
    )

    static let rubySpec: Spec = Spec(
        keywords: rubyKeywords,
        lineComments: ["#"],
        blockOpen: nil,
        blockClose: nil
    )

    static let dartSpec: Spec = Spec(
        keywords: dartKeywords,
        types: javaTypes,
        lineComments: ["//"],
        blockOpen: "/*",
        blockClose: "*/",
        capitalsAreTypes: true
    )

    static let configSpec: Spec = Spec(
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        lineComments: ["#"],
        blockOpen: nil,
        blockClose: nil
    )

    // MARK: - Vocabularies

    static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "from",
        "function", "get", "if", "import", "in", "instanceof", "let", "new", "of", "return",
        "set", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
        "while", "with", "yield", "true", "false", "null", "undefined"
    ]

    static let jsGlobals: Set<String> = [
        "Array", "Boolean", "console", "Date", "document", "Error", "JSON", "Map", "Math",
        "Number", "Object", "Promise", "RegExp", "Set", "String", "Symbol", "window", "fetch"
    ]

    static let tsKeywords: Set<String> = [
        "abstract", "any", "as", "boolean", "declare", "enum", "implements", "interface", "is",
        "keyof", "namespace", "never", "number", "private", "protected", "public", "readonly",
        "satisfies", "string", "type", "unknown"
    ]

    static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
        "indirect", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
        "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "return",
        "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "weak", "where", "while"
    ]

    static let swiftTypes: Set<String> = [
        "Any", "Array", "Bool", "Character", "Dictionary", "Double", "Error", "Float", "Int",
        "Never", "Optional", "Result", "Set", "String", "Task", "UInt", "Void"
    ]

    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
        "True", "try", "while", "with", "yield", "match", "case"
    ]

    static let pythonBuiltins: Set<String> = [
        "abs", "bool", "dict", "enumerate", "float", "input", "int", "len", "list", "max",
        "min", "open", "print", "range", "round", "self", "set", "sorted", "str", "sum", "tuple",
        "type", "zip"
    ]

    static let cppKeywords: Set<String> = [
        "alignas", "alignof", "and", "asm", "auto", "break", "case", "catch", "class", "const",
        "constexpr", "const_cast", "continue", "decltype", "default", "delete", "do",
        "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false", "for", "friend",
        "goto", "if", "inline", "mutable", "namespace", "new", "noexcept", "not", "nullptr",
        "operator", "or", "override", "private", "protected", "public", "register",
        "reinterpret_cast", "return", "sizeof", "static", "static_assert", "static_cast",
        "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typeid",
        "typename", "union", "using", "virtual", "volatile", "while"
    ]

    static let cppTypes: Set<String> = [
        "bool", "char", "double", "float", "int", "long", "short", "signed", "size_t",
        "std", "string", "unsigned", "vector", "void", "wchar_t"
    ]

    static let javaKeywords: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default",
        "do", "else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements",
        "import", "instanceof", "interface", "native", "new", "package", "private", "protected",
        "public", "record", "return", "sealed", "static", "strictfp", "super", "switch",
        "synchronized", "this", "throw", "throws", "transient", "try", "var", "volatile",
        "while", "yield", "true", "false", "null"
    ]

    static let javaTypes: Set<String> = [
        "boolean", "byte", "char", "double", "float", "int", "long", "short", "void"
    ]

    static let kotlinKeywords: Set<String> = [
        "as", "break", "by", "catch", "class", "companion", "const", "constructor", "continue",
        "data", "do", "else", "enum", "false", "final", "finally", "for", "fun", "get", "if",
        "import", "in", "init", "interface", "internal", "is", "lateinit", "null", "object",
        "open", "override", "package", "private", "protected", "public", "return", "sealed",
        "set", "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var",
        "when", "while"
    ]

    static let csharpKeywords: Set<String> = [
        "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch",
        "char", "checked", "class", "const", "continue", "decimal", "default", "delegate", "do",
        "double", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed",
        "float", "for", "foreach", "get", "goto", "if", "implicit", "in", "int", "interface",
        "internal", "is", "lock", "long", "namespace", "new", "null", "object", "operator",
        "out", "override", "params", "private", "protected", "public", "readonly", "record",
        "ref", "return", "sealed", "set", "short", "sizeof", "static", "string", "struct",
        "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked",
        "unsafe", "ushort", "using", "var", "virtual", "void", "while", "yield"
    ]

    static let sqlKeywords: Set<String> = [
        "add", "all", "alter", "and", "any", "as", "asc", "begin", "between", "by", "case",
        "cast", "check", "column", "commit", "constraint", "create", "cross", "database",
        "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign",
        "from", "full", "group", "having", "if", "in", "index", "inner", "insert", "into", "is",
        "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order",
        "outer", "primary", "references", "right", "rollback", "select", "set", "table", "then",
        "transaction", "truncate", "union", "unique", "update", "using", "values", "view",
        "when", "where", "with"
    ]

    static let sqlTypes: Set<String> = [
        "bigint", "blob", "boolean", "char", "date", "datetime", "decimal", "double", "float",
        "int", "integer", "json", "numeric", "real", "serial", "smallint", "text", "time",
        "timestamp", "uuid", "varchar"
    ]

    static let bashKeywords: Set<String> = [
        "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "fi",
        "for", "function", "if", "in", "local", "read", "return", "set", "source", "sudo",
        "then", "unset", "until", "while"
    ]

    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var", "nil", "true", "false"
    ]

    static let goTypes: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
        "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
        "uint32", "uint64", "uintptr"
    ]

    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
        "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait",
        "true", "type", "unsafe", "use", "where", "while"
    ]

    static let rustTypes: Set<String> = [
        "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "isize", "str", "u8", "u16",
        "u32", "u64", "usize", "String", "Vec", "Option", "Result"
    ]

    static let phpKeywords: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
        "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
        "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
        "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if",
        "implements", "include", "instanceof", "insteadof", "interface", "isset", "list",
        "match", "namespace", "new", "or", "print", "private", "protected", "public",
        "require", "return", "static", "switch", "throw", "trait", "try", "unset", "use",
        "var", "while", "yield", "true", "false", "null"
    ]

    static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else",
        "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
        "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
        "unless", "until", "when", "while", "yield"
    ]

    static let dartKeywords: Set<String> = [
        "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class",
        "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else",
        "enum", "export", "extends", "extension", "external", "factory", "false", "final",
        "finally", "for", "get", "if", "implements", "import", "in", "is", "late", "library",
        "mixin", "new", "null", "on", "operator", "part", "required", "rethrow", "return",
        "set", "show", "static", "super", "switch", "sync", "this", "throw", "true", "try",
        "typedef", "var", "void", "while", "with", "yield"
    ]
}
