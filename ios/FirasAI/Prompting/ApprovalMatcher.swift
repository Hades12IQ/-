//
//  ApprovalMatcher.swift
//  FirasAI
//
//  "Did the user just approve the plan?" — replacing the web's regex, which cannot answer it.
//
//  `precededByApproval` (app.js:29634) wraps every Arabic token in `\b`. JavaScript's `\b` is
//  defined on ASCII word characters, so Arabic letters are non-word characters on both sides and
//  the boundary can never occur: verified under node, `"ابدأ"`, `"ابدأ التنفيذ"`, `"نفّذ الخطة"`,
//  `"يلا ابدا"` and `"تمام"` ALL return false. The Start pill only works because of the exact
//  string comparison on the line above it. Typing the approval on the web does nothing
//  (web-plan-mode.md §6 D1); on iOS it must work.
//
//  So: normalise (tashkeel, tatweel, hamza/ya/ta-marbuta folding via `ArabicText.normalize`),
//  strip trailing `.!؟?…`, lower-case Latin, then match the vocabulary in web-plan-mode.md §7.6
//  with `(?![\p{L}\p{N}_])` semantics — implemented as a character check, so `ابدأها` is NOT an
//  approval while `ابدأ التنفيذ` is. English forms are WHOLE-MESSAGE only, which is what stops
//  "start with the basics" and "proceed to explain…" from being read as approvals (D10).
//
//  Consulted only while the cycle is in `awaitingApproval`.
//

import Foundation

enum ApprovalMatcher {

    static func isApproval(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        // 1. The two sentences the Start pill itself sends.
        for exact in exactApprovals where normalized == normalize(exact) { return true }

        // 2. Anything longer than six words is a revision, however approving it sounds.
        if wordCount(normalized) > 6 { return false }

        // 3. Arabic: token-prefixed, never `\b`-anchored.
        for token in arabicPrefixes {
            let needle = normalize(token)
            guard !needle.isEmpty else { continue }
            if normalized == needle { return true }
            if normalized.hasPrefix(needle) {
                guard let after = normalized.index(normalized.startIndex, offsetBy: needle.count, limitedBy: normalized.endIndex),
                      after < normalized.endIndex else { continue }
                let next = normalized[after]
                if !(next.isLetter || next.isNumber || next == "_") { return true }
            }
        }

        // 4. English: the whole message, or nothing.
        for phrase in englishWholeMessages where normalized == phrase { return true }
        return false
    }

    // MARK: - Normalisation

    /// Trim → `ArabicText.normalize` (tashkeel, tatweel, hamza/ya/ta-marbuta) → drop trailing
    /// terminators → lower-case → collapse inner whitespace.
    static func normalize(_ text: String) -> String {
        var s = ArabicText.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines))
        s = s.lowercased()
        while let last = s.last, trailingTerminators.contains(last) || last.isWhitespace {
            s.removeLast()
        }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func wordCount(_ normalized: String) -> Int {
        return normalized.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - Vocabulary (web-plan-mode.md §7.6)

    private static let trailingTerminators: Set<Character> = [".", "!", "؟", "?", "…", "،", ",", "؛", ";", ":"]

    /// `STR.ar.planApproval` / `STR.en.planApproval` — the literal text the pill sends.
    private static let exactApprovals: [String] = [
        "ابدأ التنفيذ ونفّذ الخطة.",
        "Go ahead and execute the plan.",
    ]

    /// Iraqi and Gulf colloquial included on purpose: this is how approval is actually typed.
    private static let arabicPrefixes: [String] = [
        "ابدأ التنفيذ",
        "ابدأ",
        "ابدا",
        "ابدي",
        "نفذ",
        "نفّذ",
        "نفذها",
        "نفذ الخطة",
        "كمل",
        "سوي",
        "سويها",
        "يلا",
        "يلا ابدا",
        "يالله",
        "تمام",
        "تمام ابدا",
        "تمام نفذ",
        "ممتاز نفذ",
        "ماشي",
        "موافق",
        "اوكي",
        "اوك",
        "اي",
        "ايه",
        "ايوه",
        "زين",
        "اكيد",
        "طبعا",
        "اتفقنا",
    ]

    private static let englishWholeMessages: [String] = [
        "go ahead",
        "go",
        "start",
        "start executing",
        "execute",
        "execute the plan",
        "proceed",
        "do it",
        "yes",
        "ok",
        "okay",
        "approved",
        "looks good",
        "lgtm",
        "build it",
    ]
}
