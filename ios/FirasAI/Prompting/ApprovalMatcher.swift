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
//  Round 2 adds the mirror of D10 on the Arabic side. §7.6 lists `سوي` and `اي` as approval
//  tokens, and a bare prefix test makes "سوي لي موقع لمطعم" — a NEW request typed while a plan is
//  on screen — an approval, which routes the execute turn at the wrong deliverable. A prefix match
//  therefore only counts when what FOLLOWS the token is itself approval language ("الخطة",
//  "التنفيذ", "الحين", "من فضلك", another approval word) and no longer than two words. "ابدأ
//  التنفيذ", "يلا ابدا", "تمام نفذ" and "نفذ الخطة" still match; "سوي لي موقع" is a revision.
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
        let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 6 { return false }

        // 3. English: the whole message, or nothing.
        if englishWholeMessages.contains(normalized) { return true }

        // 4. Arabic: token-prefixed, never `\b`-anchored — and the tail has to agree.
        for token in arabicPrefixes {
            let needle = normalize(token)
            guard !needle.isEmpty else { continue }
            if normalized == needle { return true }
            guard normalized.hasPrefix(needle) else { continue }
            guard let after = normalized.index(
                normalized.startIndex,
                offsetBy: needle.count,
                limitedBy: normalized.endIndex
            ), after < normalized.endIndex else { continue }
            let next = normalized[after]
            // `(?![\p{L}\p{N}_])`: "ابدأها" is one word and is not an approval.
            guard !(next.isLetter || next.isNumber || next == "_") else { continue }
            let tail = String(normalized[after...])
            if tailIsApproving(tail) { return true }
        }

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

    /// What may follow an approval token and still be an approval: nothing, or up to two words
    /// that are themselves approval language or ordinary courtesy.
    private static func tailIsApproving(_ tail: String) -> Bool {
        let words = tail
            .split(whereSeparator: { $0.isWhitespace || $0 == "،" || $0 == "," })
            .map { word -> String in
                var trimmed = String(word)
                while let last = trimmed.last, trailingTerminators.contains(last) {
                    trimmed.removeLast()
                }
                return trimmed
            }
            .filter { !$0.isEmpty }

        if words.isEmpty { return true }
        if words.count > 2 { return false }
        return words.allSatisfy { continuationWords.contains($0) }
    }

    // MARK: - Vocabulary (web-plan-mode.md §7.6)

    private static let trailingTerminators: Set<Character> = [".", "!", "؟", "?", "…", "،", ",", "؛", ";", ":"]

    /// `STR.ar.planApproval` / `STR.en.planApproval` — the literal text the pill sends.
    private static let exactApprovals: [String] = [
        "ابدأ التنفيذ ونفّذ الخطة.",
        "Go ahead and execute the plan.",
    ]

    /// Iraqi and Gulf colloquial included on purpose: this is how approval is actually typed.
    /// Stored pre-normalisation for readability; `isApproval` normalises each one before use.
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

    /// Normalised words that may trail an approval token. Everything here is either an approval
    /// word in its own right or pure courtesy — never a noun that could name a new deliverable.
    private static let continuationWords: Set<String> = {
        var words: Set<String> = []
        let raw: [String] = [
            // approval words again, so "يلا ابدا", "تمام نفذ", "اي نفذ" all pass
            "ابدا", "ابدي", "نفذ", "نفذها", "كمل", "كملها", "سوي", "سويها", "يلا", "يالله",
            "تمام", "ماشي", "موافق", "اوكي", "اوك", "اي", "ايه", "ايوه", "زين", "اكيد",
            "طبعا", "اتفقنا", "ممتاز", "حلو", "ok", "okay", "go", "yes",
            // the objects of the approval
            "التنفيذ", "الخطة", "بالخطة", "الخطه", "خطتك", "المهمة", "المهمه", "العمل", "الشغل",
            // courtesy and pacing
            "الان", "الآن", "حالا", "الحين", "هسه", "بسرعة", "بسرعه", "لو", "سمحت", "فضلك",
            "من", "رجاء", "رجاءا", "شكرا", "يا", "فراس", "بس", "طيب", "هيا", "و",
        ]
        for word in raw { words.insert(ArabicText.normalize(word).lowercased()) }
        return words
    }()

    private static let englishWholeMessages: Set<String> = [
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
