//
//  AskSpec.swift
//  FirasAI
//
//  STEP 1 of plan mode: the model emits ONE ```firas-ask fence whose body is JSON, and the app
//  turns it into a wizard instead of showing the user raw JSON.
//
//  The owner's report this round is «ميزة البلان ما تطلعلي الخيارات، يكتب الحل و حط ستارت تحته» —
//  the questions never appear, an answer appears instead, with a Start pill under it. There are
//  only two ways that happens: the block was never asked for (the prompt side), or the block WAS
//  emitted and this parser said no. Every "said no" case the web has is a defect here:
//
//    * the web regex (app.js:29333) accepts ONLY ```firas-ask with exactly three backticks, an
//      empty rest-of-info-line and a closing fence (§6 D11) — a `~~~` fence, four backticks, a
//      ```json fence with the same body, `firas_ask`, or a stream that ended one fence short all
//      fall through to a code block full of JSON;
//    * `normalizeAskSpec` (app.js:29298) reads exactly `question`, `options`, `label`, `multi`,
//      `recommended` — a model that writes `text`/`choices`/`value`, or plain strings for the
//      options, produces a spec that normalises to nothing;
//    * a single trailing comma anywhere in the body makes `JSON.parse` throw and the whole block
//      is lost.
//
//  So: the strict fence is tried first, then the tolerant forms, then the same body after a
//  conservative repair pass (trailing commas, whole-line `//` comments, zero-width characters).
//  Key lookup is case-insensitive over a synonym list. Everything AFTER a body has parsed is
//  `normalizeAskSpec` to the letter (web-plan-mode.md §3.2): at most 4 questions, 2…5 options
//  each, options without a usable label dropped, a question with fewer than two surviving options
//  dropped, and `nil` when nothing survives — a `nil` spec means "render the raw markdown", never
//  "show an empty panel".
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
    /// JSON whose top level has a `questions` array. Also accepts the fence BODY on its own, which
    /// is how `FirasFence.parse` calls in.
    static func parse(_ markdown: String) -> AskSpec? {
        for body in candidateBodies(markdown) {
            if let spec = specFrom(body) { return spec }
        }
        return nil
    }

    /// An opening `firas-ask` fence with no closing fence yet — the streaming loader state.
    static func hasOpenAskFence(_ markdown: String) -> Bool {
        guard RequestClassifier.matches(fenceOpenPattern, markdown) else { return false }
        return !RequestClassifier.matches(fenceClosedPattern, markdown)
    }

    /// An opening `firas-ask` fence, closed or not. `PlanCycle` uses it to refuse to offer a Start
    /// pill under a turn that was TRYING to ask: a malformed ask block must never be mistaken for
    /// a finished plan (`web-plan-mode.md §7.7`).
    static func hasAskFence(_ markdown: String) -> Bool {
        RequestClassifier.matches(fenceOpenPattern, markdown)
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

    // MARK: - Fence patterns

    // `firas ask`, `firas_ask`, `firas-ask`, `firasask`; three or more backticks or tildes; any
    // trailing words on the info line; CRLF. Case-insensitive (`RequestClassifier.matches`).
    private static let tag = "firas[ _-]?ask"
    private static let fenceOpenPattern = "(?:`{3,}|~{3,})[ \\t]*" + tag
    private static let fenceClosedPattern =
        "(?:`{3,}|~{3,})[ \\t]*" + tag + "[ \\t]*[^\\n]*\\r?\\n[\\s\\S]*?(?:`{3,}|~{3,})"
    private static let fenceClosedBodyPattern =
        "(?:`{3,}|~{3,})[ \\t]*" + tag + "[ \\t]*[^\\n]*\\r?\\n([\\s\\S]*?)(?:`{3,}|~{3,})"
    private static let fenceOpenBodyPattern =
        "(?:`{3,}|~{3,})[ \\t]*" + tag + "[ \\t]*[^\\n]*\\r?\\n([\\s\\S]*)"
    private static let jsonFenceBodyPattern =
        "(?:`{3,}|~{3,})[ \\t]*json[ \\t]*[^\\n]*\\r?\\n([\\s\\S]*?)(?:`{3,}|~{3,})"

    // MARK: - Candidate bodies

    /// Every JSON body worth trying, in order of trust.
    private static func candidateBodies(_ markdown: String) -> [String] {
        var bodies: [String] = []
        func add(_ body: String?) {
            guard let body else { return }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !bodies.contains(trimmed) else { return }
            bodies.append(trimmed)
        }

        if hasAskFence(markdown) {
            add(RequestClassifier.firstCapture(fenceClosedBodyPattern, markdown))
            // A stream that stopped one fence short still carries a complete object more often
            // than not; the balanced-object scan below finishes the job.
            add(RequestClassifier.firstCapture(fenceOpenBodyPattern, markdown))
        }
        guard markdown.range(of: "questions", options: .caseInsensitive) != nil else { return bodies }
        if let json = RequestClassifier.firstCapture(jsonFenceBodyPattern, markdown),
           json.range(of: "questions", options: .caseInsensitive) != nil {
            add(json)
        }
        add(firstBalanced(markdown, open: "{", close: "}"))
        add(firstBalanced(markdown, open: "[", close: "]"))
        return bodies
    }

    /// The first brace- or bracket-balanced literal in the text, ignoring delimiters inside JSON
    /// strings. Used for a bare object, and for a fence the stream never closed.
    private static func firstBalanced(_ text: String, open: Character, close: Character) -> String? {
        var depth = 0
        var start: String.Index?
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
            } else if ch == open {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == close {
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

    // MARK: - Decoding one candidate

    private static func specFrom(_ body: String) -> AskSpec? {
        if let spec = decode(body) { return spec }
        let repaired = repairedJSON(body)
        guard repaired != body else { return nil }
        return decode(repaired)
    }

    private static func decode(_ body: String) -> AskSpec? {
        guard let data = body.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        if let root = object as? [String: Any] { return normalize(root) }
        if let array = object as? [Any] { return normalize(["questions": array]) }
        return nil
    }

    /// Conservative repair of the three ways a model breaks otherwise-valid JSON. Nothing here
    /// touches quoting, so a body that was already valid can never be changed into a different
    /// document.
    private static func repairedJSON(_ body: String) -> String {
        var text = body
        for junk in ["\u{FEFF}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}"] {
            text = text.replacingOccurrences(of: junk, with: "")
        }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let head = line.trimmingCharacters(in: .whitespaces)
            lines.append(head.hasPrefix("//") ? "" : line)
        }
        text = lines.joined(separator: "\n")
        if let re = try? NSRegularExpression(pattern: ",(\\s*[}\\]])", options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        }
        return text
    }

    // MARK: - Normalisation (web-plan-mode.md §3.2)

    private static func normalize(_ root: [String: Any]) -> AskSpec? {
        guard let rawQuestions = questionArray(in: root) else { return nil }

        var questions: [Question] = []
        var usedIDs: Set<String> = []
        for rawQuestion in rawQuestions.prefix(4) {
            guard let q = rawQuestion as? [String: Any] else { continue }
            guard let question = normalizeQuestion(q, index: questions.count) else { continue }
            // Two questions sharing an id would share one answer bucket in the panel, so the
            // second silently overwrites the first's selection. Ids are ours to keep unique.
            var id = question.id
            while usedIDs.contains(id) { id += "_" }
            usedIDs.insert(id)
            questions.append(Question(
                id: id,
                text: question.text,
                options: question.options,
                multi: question.multi,
                recommended: question.recommended,
                allowExtra: question.allowExtra
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

        let intro = string(root, ["intro", "lead", "introduction", "preamble", "summary"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AskSpec(questions: questions, intro: (intro?.isEmpty ?? true) ? nil : intro)
    }

    private static func normalizeQuestion(_ q: [String: Any], index: Int) -> Question? {
        let text = (string(q, ["question", "text", "title", "prompt", "label", "q", "ask", "name"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let rawOptions = array(q, ["options", "choices", "answers", "values", "opts", "items"]) ?? []
        var options: [Option] = []
        var recommended: [String] = []
        for rawOption in rawOptions.prefix(5) {
            guard let label = optionLabel(rawOption) else { continue }
            let id = "o" + String(options.count)
            options.append(Option(id: id, label: label))
            if let dict = rawOption as? [String: Any],
               truthy(value(dict, ["recommended", "recommend", "default", "isdefault", "preselected", "selected", "checked", "best"])) {
                recommended.append(id)
            }
        }
        guard options.count >= 2 else { return nil }

        // A model that marks the recommendation on the QUESTION ("recommended": "Online store",
        // or an index) instead of on the option.
        if recommended.isEmpty {
            recommended = questionLevelRecommendations(q, options: options)
        }

        let rawID = (string(q, ["id", "key", "slug"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Question(
            id: rawID.isEmpty ? "q" + String(index) : rawID,
            text: text,
            options: options,
            multi: truthy(value(q, ["multi", "multiple", "multiselect", "multi_select", "allowmultiple", "many"])),
            recommended: recommended,
            allowExtra: false
        )
    }

    /// An option may be an object, or simply its label.
    private static func optionLabel(_ raw: Any) -> String? {
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dict = raw as? [String: Any] else { return nil }
        guard let label = string(dict, ["label", "text", "title", "value", "name", "option", "choice"]) else {
            return nil
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func questionLevelRecommendations(_ q: [String: Any], options: [Option]) -> [String] {
        guard let raw = value(q, ["recommended", "recommend", "default", "defaults", "preselected", "suggested"]) else {
            return []
        }
        var wanted: [Any] = []
        if let list = raw as? [Any] { wanted = list } else { wanted = [raw] }

        var ids: [String] = []
        for item in wanted {
            if let label = item as? String {
                let needle = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !needle.isEmpty else { continue }
                if let match = options.first(where: { $0.label.lowercased() == needle }) {
                    ids.append(match.id)
                }
            } else if let number = item as? NSNumber {
                // A boolean here means nothing without an option to attach it to.
                let position = number.intValue
                if position >= 0, position < options.count, !(number.isBool) {
                    ids.append(options[position].id)
                }
            }
        }
        return ids
    }

    // MARK: - Lenient dictionary access

    /// The `questions` array, whether it sits at the top level or one wrapper deep
    /// (`{"ask": {"questions": […]}}`). Key comparison is case-insensitive.
    private static func questionArray(in root: [String: Any]) -> [Any]? {
        if let direct = array(root, ["questions"]) { return direct }
        for (_, nested) in root {
            if let dict = nested as? [String: Any], let inner = array(dict, ["questions"]) {
                return inner
            }
        }
        return nil
    }

    /// `keys` are compared lower-cased, so `Question`, `QUESTION` and `question` all hit.
    private static func value(_ dict: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let exact = dict[key] { return exact }
        }
        let wanted = Set(keys.map { $0.lowercased() })
        for (key, found) in dict where wanted.contains(key.lowercased()) {
            return found
        }
        return nil
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        guard let found = value(dict, keys) else { return nil }
        if let text = found as? String { return text }
        if let number = found as? NSNumber, !number.isBool { return number.stringValue }
        return nil
    }

    private static func array(_ dict: [String: Any], _ keys: [String]) -> [Any]? {
        value(dict, keys) as? [Any]
    }

    /// JSON booleans arrive as `NSNumber`; a model that writes `1` or `"true"` means the same.
    private static func truthy(_ raw: Any?) -> Bool {
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered == "true" || lowered == "1" || lowered == "yes"
        }
        return false
    }
}

private extension NSNumber {
    /// `JSONSerialization` bridges `true` and `1` to `NSNumber` alike; the concrete class is the
    /// portable way to tell a JSON boolean from a JSON number, and it costs one comparison.
    var isBool: Bool {
        type(of: self) == type(of: NSNumber(value: true))
    }
}
