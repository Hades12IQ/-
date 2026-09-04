import Foundation

/// A content quantity, never a paper size or a guessed number of pages. Kept separate from the
/// page-count router so “100 integrals, three per group” cannot become a 100- or three-page job.
struct DocumentItemRequest: Equatable, Sendable {
    let count: Int
    let requiresSolutions: Bool
    let solutionsAtEnd: Bool

    static func parse(_ request: String) -> DocumentItemRequest? {
        let text = normalizedDigits(request).lowercased()
        let nouns = #"(?:integrals?|problems?|exercises?|questions?|equations?|تكامل(?:ات)?|مسائل|مسألة|مساله|تمارين|تمرين|أسئلة|اسئلة|سؤال|معادلات|معادلة)"#
        let modifiers = #"(?:(?:very|extremely|hard|difficult|challenging|advanced|distinct|unique|different|numbered|math|mathematical|definite|indefinite|improper)\s+){0,6}"#
        let pattern = #"(?<![\p{L}\p{N}.,])([0-9]{1,5})[ \t-]*"# + modifiers + nouns + #"(?!\p{L})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        var quantities: [Int] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let count = Int(ns.substring(with: match.range(at: 1))), (1...10_000).contains(count) else { continue }
            let before = ns.substring(with: NSRange(location: max(0, match.range.location - 48),
                length: min(48, match.range.location)))
            // Grouping is layout, and “problem 100” is an identifier rather than a quantity.
            if matches(#"(?:\b(?:every|each|per|groups?\s+of|sets?\s+of)|كل|بكل|لكل)\s*$"#, before) { continue }
            quantities.append(count)
        }
        // Multiple different quantities need the original request; guessing their sum changes it.
        guard let count = quantities.first, quantities.allSatisfy({ $0 == count }) else { return nil }
        let noSolutions = matches(#"\b(?:without|no|omit|exclude)\s+(?:(?:the|any|worked|full)\s+)*(?:solutions?|answers?)\b|(?:بدون|دون|بلا)\s*(?:ال)?(?:حلول|حل|اجوب[ةه]|أجوب[ةه])"#, text)
        let solutions = matches(#"\b(?:solutions?|answers?|answer\s+key)\b|حلول|الحل\b|حلها|حلهم|حل(?:\s+التكاملات|\s+المسائل)|أجوب[ةه]|اجوب[ةه]"#, text)
        let atEnd = matches(#"\bat\s+(?:the\s+)?end\b|\bat\s+the\s+back\b|بالنهاي[ةه]|في\s+النهاي[ةه]|بال[اأ]خير|في\s+نهاي[ةه]"#, text)
        return DocumentItemRequest(count: count, requiresSolutions: solutions && !noSolutions,
            solutionsAtEnd: solutions && !noSolutions && atEnd)
    }

    /// ASCII IDs remain stable while the document's visible language/numbering follows the reader.
    var htmlInstruction: String {
        var text = """
        EXACT CONTENT COUNT: the reader requested \(count) items. This is an item count, NOT a page
        count. Keep their requested language, difficulty, grouping and order. Three items on three
        lines means one item per line, not three columns. Use normal readable type and flowing pages.
        Put each complete problem/item in its own HTML element with data-firas-item="N", where N is
        its unique ASCII integer 1 through \(count). The element must contain the actual statement,
        not merely its number/title. Keep visible numbering too. Do not put these attributes on a
        contents list, summary, hidden element or metadata. Do not repeat a problem with a new number.
        """
        if requiresSolutions {
            text += """

            Include ALL \(count) matching worked solutions. When the reader asks for solutions at the
            end, finish the entire problem collection first, then a separate solutions section in
            the same numerical order. Each solution's element must carry data-firas-solution="N"
            and contain its actual result and reasoning, matched to problem N. State required
            domains/convergence conditions and constants of integration where applicable. Check
            integral answers by differentiating or an appropriate independent identity.
            """
        }
        text += """

        Before closing the HTML, check the actual elements contain every ID 1 through \(count)
        exactly once, with no empty, duplicate or placeholder statements\(requiresSolutions ? " or missing solutions" : "").
        A filename/card or a claim of completeness is not the deliverable. Do not shorten the
        requested collection to a sample to fit decoration; keep CSS concise and spend the output
        on the requested content. Never claim that absent items were completed.
        """
        return text
    }

    static func normalizedDigits(_ text: String) -> String {
        String(text.map { character in
            if let value = character.wholeNumberValue, (0...9).contains(value) { return Character(String(value)) }
            return character
        })
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
