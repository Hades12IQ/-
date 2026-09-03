//
//  EngineFailureDetector.swift
//  FirasAI
//
//  When every engine fails, `/api/chat` still answers 200 and streams one of a handful of fixed
//  apology sentences as the whole answer (server-chat-jobs-chats.md §1.8). Those are not replies:
//  they must never be persisted as a turn, never counted as an answer, and never left on screen —
//  the web retries once automatically (`busyRe`, app.js:42778) and so does the native client.
//
//  An empty answer is the same failure: the web throws `"empty stream"` when `[DONE]` arrives
//  with no content, even if the model emitted only "thinking".
//

import Foundation

enum EngineFailureDetector {

    /// `true` when this whole answer is an engine apology or nothing at all.
    static func isFailure(_ answer: String) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        for sentence in verbatimFailures where trimmed == sentence { return true }
        return matchesBusyPattern(trimmed)
    }

    // MARK: - Private

    /// The web's `busyRe`, ported unchanged. It is anchored, so it only fires when the apology is
    /// the ENTIRE answer.
    private static let busyPattern =
        "^(The Firas AI (?:vision )?engine is (?:busy|unavailable|offline)[\\s\\S]{0,80}?"
        + "|Something went wrong with the Firas AI engine\\.) ?(Please )?[Tt]ry again\\.?\\s*(shortly\\.?)?\\s*$"

    /// The bilingual variants the server sends verbatim. `busyRe` is anchored at `^`, so the rows
    /// that lead with the Arabic half never match it — they are compared literally instead.
    private static let verbatimFailures: [String] = [
        "تعذّر الوصول إلى محرك Firas AI حالياً — يرجى المحاولة مرة أخرى بعد لحظات.\n\nThe Firas AI engine is unavailable right now. Please try again.",
        "محرك Firas AI مشغول حالياً — يرجى المحاولة مرة أخرى بعد لحظات.\n\nThe Firas AI engine is busy right now. Please try again.",
        "The Firas AI engine is busy right now. Please try again.",
        "Something went wrong with the Firas AI engine. Please try again.",
        "تعذّر إكمال القائمة بسرعة حالياً — أعد المحاولة بعد لحظات.\n\nThe list could not be completed quickly right now. Please try again in a moment.",
    ]

    private static func matchesBusyPattern(_ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: busyPattern, options: []) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
