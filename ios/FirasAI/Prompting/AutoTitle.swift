//
//  AutoTitle.swift
//  FirasAI
//
//  The server never titles a chat (server-chat-jobs-chats.md §5.4). The sidebar shows a
//  provisional 42-character title the instant the first message is sent, and one Pro-tier,
//  `nomem` model call replaces it with a real one (web-chat-ux.md §11.1).
//
//  The call is deliberately cheap and disposable: no `cid`, no `chatId`, `nomem:true` (so it is
//  charged to the internal budget and gets neither the identity block nor the user's memory), and
//  a failure simply leaves the provisional title in place. The caller PUTs `{title}` only when
//  the user has not renamed the chat meanwhile.
//

import Foundation

enum AutoTitle {

    /// `titleFrom` (app.js:13327): whitespace collapsed, 42 characters, an ellipsis when cut.
    /// Returns "" for an empty message — the caller substitutes its localized "New chat".
    static func provisional(from text: String) -> String {
        let clean = RequestClassifier.replacingMatches("\\s+", in: text.trimmingCharacters(in: .whitespacesAndNewlines), with: " ")
        guard !clean.isEmpty else { return "" }
        if clean.count > 42 { return String(clean.prefix(42)) + "…" }
        return clean
    }

    /// `autoTitleChat` (app.js:13411): `POST /api/chat` with `{nomem:true, tier:"pro", think:false}`,
    /// the verbatim title prompt and the first 500 characters of the first user message. The
    /// stream is collected, cleaned and validated; anything odd returns `nil`.
    ///
    /// `firstAnswer` is accepted for symmetry with the rest of the pipeline — the web's prompt is
    /// built from the user's message alone and adding the answer would change the result.
    static func generate(api: APIClient, firstUser: String, firstAnswer: String, lang: AppLanguage) async -> String? {
        let seed = firstUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return nil }
        let prompt = PromptCatalog.autoTitlePrompt(lang: lang.rawValue)
        let request = ChatStreamRequest(
            messages: [
                OutgoingMessage(role: "system", content: prompt, images: nil),
                OutgoingMessage(role: "user", content: String(seed.prefix(500)), images: nil),
            ],
            tier: "pro",
            think: false,
            cid: "",
            chatId: nil,
            product: ProductKind.ai.wireValue,
            nomem: true,
            nokb: nil,
            agent: nil
        )

        let raw: String
        do {
            raw = try await withDeadline(seconds: 25) { () async throws -> String in
                var collected = ""
                let stream = await api.chatStream(request)
                for try await frame in stream {
                    let payload = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" { break }
                    if let piece = content(fromSSEPayload: payload) { collected += piece }
                    if collected.count > 400 { break }
                }
                return collected
            }
        } catch {
            return nil
        }

        let cleaned = clean(raw)
        guard isValid(cleaned) else { return nil }
        return cleaned
    }

    // MARK: - Cleaning and validation

    /// app.js:13439, in the web's order: trim → strip wrapping quotes → strip a `Title:` prefix →
    /// collapse whitespace → 60 characters.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = RequestClassifier.replacingMatches("^[\"'`«»]+", in: s, with: "")
        s = RequestClassifier.replacingMatches("[\"'`«».]+$", in: s, with: "")
        s = RequestClassifier.replacingMatches("^\\s*title\\s*[:：\\-]\\s*", in: s, with: "")
        s = RequestClassifier.replacingMatches("\\s+", in: s, with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(60))
    }

    /// `validAutoChatTitle` (app.js:13355): no newlines or markup, no code-ish tokens, not a wall
    /// of punctuation, and at least one real letter.
    static func isValid(_ title: String) -> Bool {
        let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.count > 60 { return false }
        if RequestClassifier.matches("[\\r\\n{}<>`]", s) { return false }
        if RequestClassifier.matches(codeishPattern, s) { return false }
        var punctuation = 0
        for ch in s where "=;()[]\\".contains(ch) { punctuation += 1 }
        if punctuation >= 3 { return false }
        return RequestClassifier.matches("[A-Za-z\u{0600}-\u{06FF}]", s)
    }

    // MARK: - Private

    private static let codeishPattern =
        "\\b(?:import|from\\s+(?:docx|pptx|openpyxl)|python-docx|python-pptx|openpyxl|pip\\s+install|npm\\s+(?:i|install)|pnpm\\s+(?:add|install)"
        + "|yarn\\s+add|bash|powershell|python\\s+-m|document\\s*=|def\\s+\\w+|const\\s+\\w+|function\\s+\\w+)\\b"

    /// One SSE payload → the `choices[0].delta.content` text, if any.
    /// `reasoning` deltas are ignored: a title is never made of thinking.
    private static func content(fromSSEPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let root = object as? [String: Any] else { return nil }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        guard let delta = first["delta"] as? [String: Any] else { return nil }
        guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
        return text
    }
}
