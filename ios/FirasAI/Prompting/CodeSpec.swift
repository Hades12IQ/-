import Foundation

/// Which language a code request is asking for.
///
/// A port of the web's `codeSpecFromText` (`app.js:2775`), name for name and in its order. **The
/// app never had one.** `PromptCatalog.systemPrompt`'s short overload passes `codeLabel: "HTML",
/// codeLang: "html"` as literals, and every code turn in the app went through that overload — so
/// «اصنع لي كود بايثون» was handed the HTML brief, which opens with "put ALL your OWN HTML, CSS and
/// JavaScript INSIDE this one file", and the model did as it was told. The reader asked for Python
/// and got a web page, every time, in every language.
///
/// Explicit programming languages precede the HTML fallback. A Python script that produces an
/// HTML report still needs Python source; the report format must not override the requested runtime.
struct CodeSpec: Sendable, Equatable {

    /// The fence's language tag: `python`, `cpp`, `html`…
    let lang: String
    /// The file extension, without a dot.
    let ext: String
    /// What the card's header says: `Python`, `C++`, `HTML`…
    let label: String
    /// The name the file is offered under.
    let filename: String

    /// What a request that names no language gets. Also the fallback for an empty message.
    static let html = CodeSpec(lang: "html", ext: "html", label: "HTML", filename: "index.html")

    // MARK: - Detection

    /// A fallback hint when no explicit programming language was requested.
    private static let webbyPattern = ##"\bhtml\b|website|web\s*site|web\s*page|موقع|صفحة|<!doctype"##

    /// Each language, in the web's order, with the pattern that claims it.
    ///
    /// The Arabic spellings are the web's own and are not translations: they are what people
    /// actually type — «بايثون», «سي بلس بلس», «سي شارب», «جافا سكربت» — and the two Java entries
    /// have to stay in this order, since «جافا سكربت» contains «جافا».
    private static let ladder: [(pattern: String, spec: CodeSpec)] = [
        (##"\bpython\b|بايثون"##,
         CodeSpec(lang: "python", ext: "py", label: "Python", filename: "script.py")),
        (##"\bc\+\+|\bcpp\b|سي\s*بلس\s*بلس|سي\+\+"##,
         CodeSpec(lang: "cpp", ext: "cpp", label: "C++", filename: "main.cpp")),
        (##"\bc#|c\s*sharp|csharp|سي\s*شارب"##,
         CodeSpec(lang: "csharp", ext: "cs", label: "C#", filename: "Program.cs")),
        (##"\brust\b|راست"##,
         CodeSpec(lang: "rust", ext: "rs", label: "Rust", filename: "main.rs")),
        (##"\bgolang\b|\bgo\s+(?:code|program|script|api|service)\b|لغة\s*go"##,
         CodeSpec(lang: "go", ext: "go", label: "Go", filename: "main.go")),
        (##"\bkotlin\b|كوتلن"##,
         CodeSpec(lang: "kotlin", ext: "kt", label: "Kotlin", filename: "Main.kt")),
        (##"\bswift(?:ui)?\b|سويفت"##,
         CodeSpec(lang: "swift", ext: "swift", label: "Swift", filename: "main.swift")),
        (##"\bphp\b"##,
         CodeSpec(lang: "php", ext: "php", label: "PHP", filename: "index.php")),
        (##"\btypescript\b"##,
         CodeSpec(lang: "typescript", ext: "ts", label: "TypeScript", filename: "main.ts")),
        (##"\bpowershell\b|باورشل"##,
         CodeSpec(lang: "powershell", ext: "ps1", label: "PowerShell", filename: "script.ps1")),
        (##"\bbash\b|shell\s+script|سكربت\s+شل"##,
         CodeSpec(lang: "bash", ext: "sh", label: "Bash", filename: "script.sh")),
        (##"\bruby\b|روبي"##,
         CodeSpec(lang: "ruby", ext: "rb", label: "Ruby", filename: "script.rb")),
        (##"\bsql\b|استعلام\s+(?:قاعدة|قواعد)"##,
         CodeSpec(lang: "sql", ext: "sql", label: "SQL", filename: "query.sql")),
        (##"\bcss\b|stylesheet"##,
         CodeSpec(lang: "css", ext: "css", label: "CSS", filename: "styles.css")),
        (##"\bjavascript\b|vanilla\s*js|\bnode(?:\.js)?\b|جافا\s*سكر|جافاسكربت|\bjs\b"##,
         CodeSpec(lang: "javascript", ext: "js", label: "JavaScript", filename: "script.js")),
    ]

    /// Java is checked between C++ and C# in the web, but it needs a negative test of its own —
    /// «جافا سكربت» and "javascript" both contain it — so it is lifted out of the ladder rather
    /// than given a pattern nobody can read.
    private static let javaPattern = ##"\bjava\b|جافا"##
    private static let javaScriptPattern = ##"javascript|جافا\s*سكر|جافاسكربت"##

    /// The language `text` is asking for. `html` when it names none.
    static func detect(_ text: String) -> CodeSpec {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return html }
        for (pattern, spec) in ladder {
            // Java sits between C++ and C# in the web's order.
            if spec.lang == "csharp",
               RequestClassifier.matches(javaPattern, trimmed),
               !RequestClassifier.matches(javaScriptPattern, trimmed) {
                return CodeSpec(lang: "java", ext: "java", label: "Java", filename: "Main.java")
            }
            if RequestClassifier.matches(pattern, trimmed) { return spec }
        }
        if RequestClassifier.matches(webbyPattern, trimmed) { return html }
        return html
    }
}
