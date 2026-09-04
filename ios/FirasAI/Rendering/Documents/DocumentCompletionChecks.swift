import Foundation

/// Structural completeness of a counted educational document. This verifies source content and
/// numbering, not mathematical truth. A closed </html> and a file-card claim cannot prove either.
enum DocumentCompletionChecks {
    struct Result: Equatable, Sendable {
        let expected: Int?
        let itemCount: Int
        let solutionCount: Int
        let missingItemIDs: [Int]
        let missingSolutionIDs: [Int]
        let issue: String?
        let verificationAvailable: Bool
        var isComplete: Bool { issue == nil }
        var isVerified: Bool { verificationAvailable && isComplete && expected != nil }

        func message(lang: AppLanguage) -> String? {
            guard !isComplete, let expected else { return nil }
            if issue == "duplicate-statements" || issue == "invalid-numbering" || issue == "solution-order" {
                return lang == .arabic
                    ? "الملف يحتاج إكمال المراجعة: توجد عناصر مكررة أو ترقيم أو ترتيب غير مكتمل. أكمِل تصحيح الملف قبل فتحه."
                    : "The document still contains repeated items or incomplete numbering/order. Finish correcting it before opening it."
            }
            return lang == .arabic
                ? "الملف بعده مو مكتمل: تحققنا من \(itemCount) من أصل \(expected) عنصر.\(missingSolutionIDs.isEmpty ? "" : " والحلول المكتملة \(solutionCount) من \(expected).") أكمِل إنشاء الملف قبل فتحه."
                : "The file is incomplete: \(itemCount) of \(expected) items were verified.\(missingSolutionIDs.isEmpty ? "" : " Complete solutions: \(solutionCount) of \(expected).") Finish generating the document before opening it."
        }
    }

    static func validate(markdown: String, request: String) -> Result {
        guard let requested = DocumentItemRequest.parse(request) else {
            return Result(expected: nil, itemCount: 0, solutionCount: 0, missingItemIDs: [],
                missingSolutionIDs: [], issue: nil, verificationAvailable: false)
        }
        let records: [Record]
        if let html = DocumentHTML.authored(in: markdown) {
            let parsed = htmlRecords(html)
            // Partial/malformed explicit markers cannot be made complete by an incidental list.
            records = parsed.hasMarkers ? parsed.records : legacyRecords(parsed.visibleText)
            if !parsed.hasMarkers, records.isEmpty, substantial(parsed.visibleText) {
                // Existing documents may number with CSS counters or LaTeX \tag. Unknown is not
                // evidence of missing content. Preserve their exportability without claiming that
                // a requested count was verified. New authored responses carry explicit markers.
                return Result(expected: requested.count, itemCount: 0, solutionCount: 0,
                    missingItemIDs: [], missingSolutionIDs: [], issue: nil, verificationAvailable: false)
            }
        } else if DocumentHTML.hasIncompleteAuthoredDocument(in: markdown) {
            records = []
        } else {
            // Skip all fenced metadata/code. Ordinary legacy Markdown numbered lists still work.
            records = legacyRecords(withoutFences(markdown))
        }
        let items = records.filter { !$0.solution && substantial($0.content) }
        let solutions = records.filter { $0.solution && substantial($0.content) }
        let itemIDs = items.map(\.id)
        let solutionIDs = solutions.map(\.id)
        let wanted = Set(1...requested.count)
        let foundItems = Set(itemIDs).intersection(wanted)
        let foundSolutions = Set(solutionIDs).intersection(wanted)
        let missingItems = wanted.subtracting(foundItems).sorted()
        let missingSolutions = requested.requiresSolutions ? wanted.subtracting(foundSolutions).sorted() : []
        let duplicateIDs = Set(itemIDs).count != itemIDs.count
            || (requested.requiresSolutions && Set(solutionIDs).count != solutionIDs.count)
        let extraIDs = !Set(itemIDs).isSubset(of: wanted)
            || (requested.requiresSolutions && !Set(solutionIDs).isSubset(of: wanted))
        let outOfOrder = itemIDs != itemIDs.sorted()
            || (requested.requiresSolutions && solutionIDs != solutionIDs.sorted())
        let fingerprints = items.map { canonical($0.content) }
        let repeatedStatements = Set(fingerprints).count != fingerprints.count
        let solutionOrderWrong = requested.solutionsAtEnd
            && (records.firstIndex(where: \.solution) ?? records.count) < (records.lastIndex(where: { !$0.solution }) ?? 0)
        var issue: String?
        if !missingItems.isEmpty { issue = "missing-items" }
        else if !missingSolutions.isEmpty { issue = "missing-solutions" }
        else if duplicateIDs || extraIDs || outOfOrder { issue = "invalid-numbering" }
        else if repeatedStatements { issue = "duplicate-statements" }
        else if solutionOrderWrong { issue = "solution-order" }
        return Result(expected: requested.count, itemCount: foundItems.count, solutionCount: foundSolutions.count,
            missingItemIDs: missingItems, missingSolutionIDs: missingSolutions, issue: issue, verificationAvailable: true)
    }

    private struct Record {
        let id: Int
        let solution: Bool
        var content: String
    }

    private struct Frame {
        let tag: String
        let record: Record?
        var content: String = ""
        var nextListID: Int?
        let hidden: Bool
    }

    /// A small non-executing HTML token walk. Quoted attributes, nested elements, list counters,
    /// comments, script/style/head and hidden nodes are handled without evaluating model code.
    private static func htmlRecords(_ source: String) -> (records: [Record], visibleText: String, hasMarkers: Bool) {
        let cleaned = replace(#"(?s)<!--.*?-->"#, in: source, with: "")
        guard let regex = try? NSRegularExpression(pattern: #"<(?:\"[^\"]*\"|'[^']*'|[^'\">])+>"#) else { return ([], "", false) }
        let ns = cleaned as NSString
        var stack: [Frame] = []
        var records: [Record] = []
        var text = ""
        var cursor = 0
        var hasMarkers = false
        let ignored: Set<String> = ["head", "script", "style", "template", "noscript"]
        let blocks: Set<String> = ["p", "div", "section", "article", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "br"]
        let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        func append(_ chunk: String) {
            guard !stack.contains(where: \.hidden) else { return }
            text += chunk
            for index in stack.indices where stack[index].record != nil { stack[index].content += chunk }
        }
        for token in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            cursor = NSMaxRange(token.range)
            let raw = ns.substring(with: token.range)
            guard let tag = capture(#"^<\s*/?\s*([a-zA-Z][a-zA-Z0-9]*)"#, raw)?.lowercased() else { continue }
            if raw.range(of: #"^<\s*/"#, options: .regularExpression) != nil {
                if let start = stack.lastIndex(where: { $0.tag == tag }) {
                    for frame in stack[start...] where !frame.hidden {
                        if var record = frame.record { record.content = frame.content; records.append(record) }
                    }
                    stack.removeSubrange(start...)
                }
                if blocks.contains(tag) { append("\n") }
                continue
            }
            if blocks.contains(tag) { append("\n") }
            let hidden = ignored.contains(tag) || stack.contains(where: \.hidden)
                || raw.range(of: #"\s(?:hidden|aria-hidden\s*=\s*[\"']true[\"'])(?:\s|=|/?>)"#, options: [.regularExpression, .caseInsensitive]) != nil
                || raw.range(of: #"(?:display\s*:\s*none|visibility\s*:\s*hidden)"#, options: [.regularExpression, .caseInsensitive]) != nil
            let item = attribute("data-firas-item", raw)
            let solution = attribute("data-firas-solution", raw)
            if item != nil || solution != nil { hasMarkers = true }
            var record: Record?
            if !hidden, let value = solution ?? item, let id = Int(DocumentItemRequest.normalizedDigits(value)), id > 0 {
                record = Record(id: id, solution: solution != nil, content: "")
            }
            if tag == "li", let list = stack.lastIndex(where: { $0.tag == "ol" }), let next = stack[list].nextListID {
                let number = attribute("value", raw).flatMap(Int.init) ?? next
                stack[list].nextListID = number + 1
                append("\(number). ")
            }
            if !voids.contains(tag), !raw.hasSuffix("/>") {
                stack.append(Frame(tag: tag, record: record,
                    nextListID: tag == "ol" ? (attribute("start", raw).flatMap(Int.init) ?? 1) : nil, hidden: hidden))
            }
        }
        if cursor < ns.length { append(ns.substring(from: cursor)) }
        // Unclosed marker elements are not completed records.
        return (records, text, hasMarkers)
    }

    private static func legacyRecords(_ source: String) -> [Record] {
        let normalized = DocumentItemRequest.normalizedDigits(source)
        let pattern = #"^\s*(?:#{1,6}\s*)?(?:(integral|problem|exercise|question|equation|solution|answer|تكامل|مسألة|مساله|تمرين|سؤال|معادلة|حل|الحل)\s*#?\s*)?([0-9]{1,5})(?:\s*[.)\]:：-]\s*|\s+|$)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        var records: [Record] = []
        var current: Record?
        var inSolutions = false
        for raw in normalized.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.range(of: #"^(?:#{1,6}\s*)?(?:worked\s+|full\s+|complete\s+)?(?:solutions?|answers?|answer\s+key|الحلول|حلول|الأجوبة|الاجوبة)\s*[:：]?$"#,
                options: [.regularExpression, .caseInsensitive]) != nil {
                if let current { records.append(current) }
                current = nil
                inSolutions = true
                continue
            }
            let ns = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let id = Int(ns.substring(with: match.range(at: 2))), id > 0 {
                if let current { records.append(current) }
                let label = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1)).lowercased()
                let solution = inSolutions || ["solution", "answer", "حل", "الحل"].contains(label)
                current = Record(id: id, solution: solution, content: ns.substring(with: match.range(at: 3)))
            } else if current != nil { current?.content += "\n" + line }
        }
        if let current { records.append(current) }
        return records
    }

    private static func canonical(_ source: String) -> String {
        let text = replace(#"^\s*(?:(?:Integral|Problem|Exercise|Question|Equation|Solution|Answer|تكامل|مسألة|تمرين|سؤال|معادلة|الحل|حل)\s*[#-]?\s*[0-9٠-٩۰-۹]+(?=\s|[.)\]:：-]|$)\s*[.)\]:：-]?\s*|[0-9٠-٩۰-۹]+\s*(?:[.)\]:：](?:\s+|(?=[$\\])|$)|-\s+))"#,
            in: source, with: "", insensitive: true)
        return replace(#"\s+|&(?:nbsp|#160);"#, in: text, with: "")
    }

    private static func substantial(_ source: String) -> Bool {
        let value = canonical(source)
        guard !value.isEmpty, value.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil else { return false }
        return value.range(of: #"^(?:todo|tbd|placeholder|comingsoon|tobecompleted|solutiongoeshere|\.\.\.|…)$"#,
            options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func withoutFences(_ source: String) -> String {
        var fence: Character?
        return source.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == nil { fence = trimmed.first }
                else if fence == trimmed.first { fence = nil }
                return nil
            }
            return fence == nil ? line : nil
        }.joined(separator: "\n")
    }

    private static func attribute(_ name: String, _ tag: String) -> String? {
        capture("\\s" + name + #"\s*=\s*[\"']([^\"']*)[\"']"#, tag)
            ?? capture("\\s" + name + #"\s*=\s*([^\s\"'=<>`]+)"#, tag)
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let found = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              found.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: found.range(at: 1))
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String, insensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: insensitive ? .caseInsensitive : []) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement)
    }
}
