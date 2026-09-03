import Foundation
import UIKit

/// The verbs behind the action row and the long-press menu.
///
/// Both surfaces offer the same actions in the same order (`web-chat-ux.md §9`), so the behaviour
/// lives here once instead of twice. Everything is `@MainActor`: these are called straight from a
/// button, and each one either mutates a store or hands work to one.
@MainActor
enum ChatTurnActions {

    // MARK: - Clipboard

    /// Copies and toasts on failure. Returns true when the pasteboard took it, so the caller can
    /// show `تم النسخ` in place for 1.4 s.
    @discardableResult
    static func copy(_ text: String, env: AppEnvironment) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            env.toasts.show(Strings.Chat.exportEmpty(env.prefs.lang), isError: true)
            return false
        }
        UIPasteboard.general.string = trimmed
        Haptics.select()
        return true
    }

    // MARK: - Speech

    static func listen(message: ChatMessage, env: AppEnvironment) {
        let lang = env.prefs.lang
        let body = TTSPlayer.speakable(message.visibleContent)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            env.toasts.show(Strings.Chat.exportEmpty(lang), isError: true)
            return
        }
        let messageLang: AppLanguage = AppLanguage(rawValue: message.lang ?? "") ?? lang
        let id = message.id
        Task { await env.tts.toggle(messageID: id, text: body, lang: messageLang) }
    }

    // MARK: - The model

    static func regenerate(
        messageID: String,
        conversationID: String,
        tier: ModelTier?,
        env: AppEnvironment
    ) {
        guard !isBusy(conversationID: conversationID, env: env) else {
            env.toasts.show(Strings.Chat.busyWait(env.prefs.lang))
            return
        }
        Haptics.select()
        Task { await env.chat.regenerate(messageID: messageID, in: conversationID, tier: tier) }
    }

    static func continueAnswer(messageID: String, conversationID: String, env: AppEnvironment) {
        guard !isBusy(conversationID: conversationID, env: env) else {
            env.toasts.show(Strings.Chat.busyWait(env.prefs.lang))
            return
        }
        Task { await env.chat.continueAnswer(messageID: messageID, in: conversationID) }
    }

    static func approvePlan(conversationID: String, env: AppEnvironment) {
        guard !isBusy(conversationID: conversationID, env: env) else {
            env.toasts.show(Strings.Chat.busyWait(env.prefs.lang))
            return
        }
        Haptics.send()
        Task { await env.chat.approvePlan(in: conversationID) }
    }

    /// Through `resolve`, never through the raw subscript: `states` is keyed by the local id, so a
    /// screen opened by server id found nothing and every one of the three guards above fell open —
    /// regenerate, continue and approve all fired into a conversation that was already answering.
    static func isBusy(conversationID: String, env: AppEnvironment) -> Bool {
        env.chat.states[env.chat.resolve(conversationID)]?.isBusy ?? false
    }

    // MARK: - Sharing

    /// Members get a server share link through the routed sheet; guests get the sign-up prompt
    /// (`web-chat-ux.md §9` row 11).
    static func share(message: ChatMessage, conversationID: String, env: AppEnvironment) {
        guard env.session.isMember else {
            env.router.showSignUp(feature: .share)
            return
        }
        env.router.sheet = .share(conversationID: conversationID, messageCID: message.cid)
    }

    // MARK: - Export text

    /// The answer as Markdown, exactly as it is stored.
    static func markdown(_ message: ChatMessage) -> String {
        message.visibleContent
    }

    /// The answer as plain text: math flattened to Unicode, the markdown furniture removed.
    static func plainText(_ message: ChatMessage) -> String {
        let source = message.visibleContent
        let protected = MathScanner.protect(source)
        let flattened = protected.spans.map { MathText.unicode($0) }
        let restored = MathScanner.restore(protected.text, spans: flattened)
        return strippedMarkdown(restored)
    }

    private static func strippedMarkdown(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { continue }
            if trimmed.hasPrefix("#") {
                line = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix(">") {
                line = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Gating

    /// The web only offers Continue when the answer looks cut off (`answerLooksTruncated`).
    static func looksTruncated(_ message: ChatMessage) -> Bool {
        let text = message.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 400 else { return false }
        if text.contains("```"), fenceCount(text).isMultiple(of: 2) == false { return true }
        guard let last = text.last else { return false }
        let closers: Set<Character> = [".", "!", "?", "؟", "،", ":", "؛", "»", ")", "]", "}", "\"", "…", "۔"]
        return !closers.contains(last)
    }

    private static func fenceCount(_ text: String) -> Int {
        var count = 0
        for line in text.components(separatedBy: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            count += 1
        }
        return count
    }

    /// A card turn (`firas-*` fence) never gets prose actions like Continue or Share.
    static func isCardTurn(_ message: ChatMessage) -> Bool {
        guard let fence = FirasFence.firstFence(in: message.visibleContent) else { return false }
        return fence.name.hasPrefix("firas-")
    }
}
