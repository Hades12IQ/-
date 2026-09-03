//
//  AskSpec.swift
//  FirasAI
//
//  STEP 1 of plan mode: the model emits ONE ```firas-ask fence whose body is JSON, and the app
//  turns it into a wizard instead of showing the user raw JSON.
//
//  The web parser is fence-strict (web-plan-mode.md §6 D11): a ```json fence with the same body,
//  a missing closing fence, or an info string like ```firas-ask json all fall through to a code
//  block full of JSON — with a Start pill under it, because `parseFirasAsk` returned null. Here
//  the fence is tried first and the tolerant forms after it, exactly as §7.7 requires.
//
//  Normalisation is `normalizeAskSpec` (app.js:29298-29326) to the letter: at most 4 questions,
//  2…5 options each, options without a string label dropped, a question with fewer than two
//  surviving options dropped, and `nil` when nothing survives — a `nil` spec means "render the
//  raw markdown", never "show an empty panel".
//

import Foundation

struct AskSpec: Codable, Sendable, Equatable {

    struct Option: Codable, Sendable, Equatable {
        let id: String
        let label: String
    }

    struct Question: Codable, Sendable, Equatable {
        let id: String
        let text: String
        let options: [Option]
        let multi: Bool
        /// Option ids the model marked `"recommended": true`; the panel pre-selects them.
        let recommended: [String]
        /// Only the last step carries the free-text field, as on the web.
        let allowExtra: Bool
    }

    let questions: [Question]
    let intro: String?

    // MARK: - Parsing

    /// The first `firas-ask` block, or — when the phase expects an ask — a `json` fence or bare
    /// JSON whose top level has a `questions` array.
    static func parse(_ markdown: String) -> AskSpec? {
        for body in candidateBodies(markdown) {
            if let spec = normalize(body) { return spec }
        }
        return nil
    }

    /// An opening `firas-ask` fence with no closing fence yet — the streaming loader state.
    static func hasOpenAskFence(_ markdown: String) -> Bool {
        guard markdown.contains("firas-ask") else { return false }
        if RequestClassifier.matches(closedFencePattern, markdown) { return false }
        return RequestClassifier.matches(openFencePattern, markdown)
    }

    // MARK: - The answer summary (web-plan-mode.md §3.5)

    /// `answers` maps a question id to the chosen option ids (option labels are accepted too, so
    /// a caller that kept labels rather than ids still produces the right sentence).
    ///
    ///   `اختياراتي — نوع الموقع: متجر إلكتروني؛ الألوان: أزرق داكن، ذهبي\nأريد قسم للتقييمات`
    ///   `My choices — Site type: Online store; Colors: Navy, Gold\nAdd a reviews section`
    func summary(answers: [String: [String]], extra: String, lang: AppLanguage) -> String {
        let arabic = (lang == .arabic)
        let listSeparator = arabic ? "، " : ", "
        let partSeparator = arabic ? "؛ " : "; "
        let lead = arabic ? "اختياراتي" : "My choices"

        var parts: [String] = []
        for question in questions {
            let picked = answers[question.id] ?? []
            guard !picked.isEmpty else { continue }
            var labels: [String] = []
            for option in question.options where picked.contains(option.id) || picked.contains(option.label) {
                labels.append(option.label)
            }
            guard !labels.isEmpty else { continue }
            var label = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = label.last, last == "?" || last == "؟" || last.isWhitespace {
                label.removeLast()
            }
            parts.append(label + ": " + labels.joined(separator: listSeparator))
        }

        let trailing = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if parts.isEmpty && trailing.isEmpty { return "" }
        var out = ""
        if !parts.isEmpty { out = lead + " — " + parts.joined(separator: partSeparator) }
        if !trailing.isEmpty { out = out.isEmpty ? trailing : out + "\n" + trailing }
        return out
    }

    // MARK: - Private

    private static let closedFencePattern = "```[ \\t]*firas-ask[ \\t]*[^\\n]*\\r?\\n[\\s\\S]*?```"
    private static let openFencePattern = "```[ \\t]*firas-ask"
    private static let jsonFencePattern = "```[ \\t]*json[ \\t]*[^\\n]*\\r?\\n([\\s\\S]*?)```"

    /// Every JSON body worth trying, in order of trust.
    private static func candidateBodies(_ markdown: String) -> [String] {
        var bodies: [String] = []
        if markdown.contains("firas-ask") {
            if let body = firstFenceBody("firas-ask", in: markdown) { bodies.append(body) }
        }
        guard markdown.contains("questions") else { return bodies }
        if let body = RequestClassifier.firstCapture(jsonFencePattern, markdown) {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("questions") { bodies.append(trimmed) }
        }
        if let bare = firstBalancedObject(markdown), bare.contains("questions") {
            bodies.append(bare)
        }
        return bodies
    }

    /// The body of the first fence with `tag` as its info string. Tolerant of trailing words on
    /// the info line (```firas-ask json), CRLF, and leading spaces before the fence.
    private static func firstFenceBody(_ tag: String, in markdown: String) -> String? {
        let pattern = "```[ \\t]*" + tag + "[ \\t]*[^\\n]*\\r?\\n([\\s\\S]*?)```"
        guard let body = RequestClassifier.firstCapture(pattern, markdown) else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first brace-balanced object in the text, ignoring braces inside JSON strings.
    private static func firstBalancedObject(_ text: String) -> String? {
        var depth = 0
        var start: String.Index? = nil
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let from = start {
                        return String(text[from...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `normalizeAskSpec` (app.js:29298). Any JSON error, and any spec with no surviving
    /// question, is `nil`.
    private static func normalize(_ body: String) -> AskSpec? {
        guard let data = body.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let root = object as? [String: Any] else { return nil }
        guard let rawQuestions = root["questions"] as? [Any] else { return nil }

        var questions: [Question] = []
        for rawQuestion in rawQuestions.prefix(4) {
            guard let q = rawQuestion as? [String: Any] else { continue }
            let text = (q["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawOptions = q["options"] as? [Any] ?? []

            var options: [Option] = []
            var recommended: [String] = []
            for rawOption in rawOptions.prefix(5) {
                guard let o = rawOption as? [String: Any] else { continue }
                guard let rawLabel = o["label"] as? String else { continue }
                let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty { continue }
                let id = "o" + String(options.count)
                options.append(Option(id: id, label: label))
                if truthy(o["recommended"]) { recommended.append(id) }
            }

            if text.isEmpty || options.count < 2 { continue }
            let rawID = (q["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = rawID.isEmpty ? "q" + String(questions.count) : rawID
            questions.append(Question(
                id: id,
                text: text,
                options: options,
                multi: truthy(q["multi"]),
                recommended: recommended,
                allowExtra: false
            ))
        }

        guard !questions.isEmpty else { return nil }
        // The free-text field belongs to the last step only, as the web's wizard has it.
        let last = questions.count - 1
        questions[last] = Question(
            id: questions[last].id,
            text: questions[last].text,
            options: questions[last].options,
            multi: questions[last].multi,
            recommended: questions[last].recommended,
            allowExtra: true
        )

        let rawIntro = (root["intro"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AskSpec(questions: questions, intro: rawIntro.isEmpty ? nil : rawIntro)
    }

    /// JSON booleans arrive as `NSNumber`; a model that writes `1` means the same thing.
    private static func truthy(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" || s == "1" }
        return false
    }
}
