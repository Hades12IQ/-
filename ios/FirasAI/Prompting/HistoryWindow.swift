//
//  HistoryWindow.swift
//  FirasAI
//
//  The web has NO client-side history window (web-prompt-builder.md §5): it maps every turn of
//  the conversation into the request and lets the server's ceilings decide. On a phone that is a
//  dead end — `POST /api/chat/job` refuses a body over `JOB_PAYLOAD_MAX = 600 000` bytes with a
//  413 the old iOS client treated as fatal, so a long chat could never send again
//  (audit-ios-chat.md §Critical C3).
//
//  So the native client windows the INFERENCE history — never what it stores or PUTs — from the
//  end, under a character budget, and always keeps the last user turn. `trimmed` is surfaced by
//  the UI as a one-line note so a dropped turn is visible rather than mysterious.
//

import Foundation

enum HistoryWindow {

    /// Walk backwards from the newest turn while the budget lasts.
    ///
    /// - Parameters:
    ///   - history: the turns before the message being answered, oldest first.
    ///   - budgetChars: the character ceiling for the turns kept. The system message is composed
    ///     by `PromptBuilder` and is deliberately NOT counted here.
    /// - Returns: the kept turns in their original order, and whether anything was dropped.
    static func window(_ history: [ChatMessage], budgetChars: Int = 400_000) -> (kept: [ChatMessage], trimmed: Bool) {
        guard !history.isEmpty else { return ([], false) }
        let budget = max(0, budgetChars)

        var startIndex = history.count
        var used = 0
        var index = history.count - 1
        while index >= 0 {
            let cost = characterCost(history[index])
            // The newest turn is always kept, however large: an empty request is worse than a
            // request the server itself will refuse.
            if startIndex < history.count, used + cost > budget { break }
            used += cost
            startIndex = index
            index -= 1
        }

        let trimmed = startIndex > 0
        var kept = Array(history[startIndex...])

        // The turn the answer is actually about must survive even when the assistant reply after
        // it swallowed the whole budget.
        if trimmed, let lastUser = history.last(where: { $0.role == .user }) {
            if !kept.contains(where: { $0.id == lastUser.id }) {
                kept.insert(lastUser, at: 0)
            }
        }
        return (kept, trimmed)
    }

    /// What one turn costs on the wire: its content plus the attached-file block that is merged
    /// into the content at send time. Reasoning, thumbnails and tier are never sent.
    private static func characterCost(_ m: ChatMessage) -> Int {
        var cost = m.content.count
        if let fileText = m.fileText { cost += fileText.count + 2 }
        return cost
    }
}
