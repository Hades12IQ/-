import Foundation

/// The coalescer between an arriving answer and the screen.
///
/// Two sources feed it and they behave differently: the live SSE stream delivers *deltas* to be
/// appended, while a job poll delivers the whole answer *so far* — a snapshot that must replace
/// what we hold, and that must never shorten it (an older, slower read overtaking a newer one is
/// how a half-written answer suddenly loses its tail).
///
/// Both are published into `ConversationState` at **at most ten times a second**. That ceiling is
/// the fix for `audit-ios-chat.md §Critical C5`: the server writes its snapshot every 2.5 s and the
/// stream can deliver hundreds of frames a second, and repainting a 50 000-character `Text` on
/// every one of them is what made the app read as frozen.
///
/// It also owns the one transform the wire needs: some engines put their thinking inside
/// `<think>…</think>` in `content` instead of in `reasoning` (`server-chat-jobs-chats.md §1.7`), so
/// the split happens here, once, rather than in every renderer.
@MainActor
final class StreamBuffer {

    /// The publish ceiling: 10 Hz.
    private static let interval: TimeInterval = 0.1

    private weak var state: ConversationState?

    /// The raw answer as it arrived, before the `<think>` split.
    private var rawText: String = ""
    private var rawReasoning: String = ""

    private var publishTask: Task<Void, Never>?
    private var lastPublish: Date = .distantPast

    init(state: ConversationState) {
        self.state = state
    }

    // MARK: - Reading

    /// The answer text with any inline thinking removed.
    var text: String { Self.splitThink(rawText).text }

    /// Everything the model called thinking, from either channel.
    var reasoning: String {
        let inline = Self.splitThink(rawText).reasoning
        if inline.isEmpty { return rawReasoning }
        if rawReasoning.isEmpty { return inline }
        return rawReasoning + inline
    }

    var isEmpty: Bool { rawText.isEmpty && rawReasoning.isEmpty }

    /// How much text has been received — the cheap comparison a watcher uses to decide whether a
    /// snapshot is newer than what we already hold.
    var receivedCount: Int { rawText.count }

    // MARK: - Writing

    func reset() {
        publishTask?.cancel()
        publishTask = nil
        rawText = ""
        rawReasoning = ""
        lastPublish = .distantPast
        state?.liveText = ""
        state?.liveReasoning = ""
    }

    /// A live SSE delta.
    func append(content: String, reasoning: String) {
        guard !content.isEmpty || !reasoning.isEmpty else { return }
        rawText += content
        rawReasoning += reasoning
        schedulePublish()
    }

    /// A job snapshot: the whole answer so far. Shorter than what we hold means the read is stale,
    /// and a stale read is dropped rather than painted.
    func adopt(text: String, reasoning: String) {
        var changed = false
        if text.count > rawText.count {
            rawText = text
            changed = true
        }
        if reasoning.count > rawReasoning.count {
            rawReasoning = reasoning
            changed = true
        }
        guard changed else { return }
        schedulePublish()
    }

    /// Flushes whatever is pending and answers with the final pair. The caller writes these into
    /// the stored message; nothing else may.
    @discardableResult
    func finish() -> (text: String, reasoning: String) {
        publishTask?.cancel()
        publishTask = nil
        let split = Self.splitThink(rawText)
        let thinking: String
        if split.reasoning.isEmpty {
            thinking = rawReasoning
        } else if rawReasoning.isEmpty {
            thinking = split.reasoning
        } else {
            thinking = rawReasoning + split.reasoning
        }
        state?.liveText = split.text
        state?.liveReasoning = thinking
        lastPublish = Date()
        return (split.text, thinking)
    }

    // MARK: - Publishing

    private func schedulePublish() {
        let elapsed = Date().timeIntervalSince(lastPublish)
        if elapsed >= Self.interval {
            publish()
            return
        }
        guard publishTask == nil else { return }
        let wait = Self.interval - elapsed
        publishTask = Task { [weak self] in
            await JobClock.rest(wait)
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        lastPublish = Date()
        let split = Self.splitThink(rawText)
        guard let state else { return }
        if state.liveText != split.text { state.liveText = split.text }
        let thinking: String
        if split.reasoning.isEmpty {
            thinking = rawReasoning
        } else if rawReasoning.isEmpty {
            thinking = split.reasoning
        } else {
            thinking = rawReasoning + split.reasoning
        }
        if state.liveReasoning != thinking { state.liveReasoning = thinking }
    }

    // MARK: - Wire helpers

    /// One `data:` payload of `POST /api/chat` → its two deltas.
    ///
    /// The frame shape is `{"choices":[{"delta":{"content":"…","reasoning":"…"}}]}`; both keys may
    /// appear in one frame. `[DONE]` and anything malformed answer `nil` — the contract says the
    /// client must tolerate broken JSON rather than end the turn on it.
    nonisolated static func delta(fromData data: String) -> (content: String, reasoning: String)? {
        let payload = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let bytes = payload.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        guard let delta = first["delta"] as? [String: Any] else { return nil }
        let content = (delta["content"] as? String) ?? ""
        let reasoning = (delta["reasoning"] as? String) ?? ""
        if content.isEmpty && reasoning.isEmpty { return nil }
        return (content, reasoning)
    }

    /// Pulls every `<think>…</think>` block out of an answer.
    ///
    /// An unterminated opening tag means the model is still thinking: everything after it is
    /// reasoning until the closing tag arrives, so a half-streamed thought never flashes as answer
    /// text and then disappears.
    nonisolated static func splitThink(_ raw: String) -> (text: String, reasoning: String) {
        guard raw.contains("<think>") else { return (raw, "") }
        var text = ""
        var reasoning = ""
        var rest = Substring(raw)
        var scanning = true
        while scanning, let start = rest.range(of: "<think>") {
            text += String(rest[rest.startIndex..<start.lowerBound])
            let after = rest[start.upperBound...]
            if let end = after.range(of: "</think>") {
                reasoning += String(after[after.startIndex..<end.lowerBound])
                rest = after[end.upperBound...]
            } else {
                reasoning += String(after)
                scanning = false
                rest = Substring("")
            }
        }
        text += String(rest)
        return (text, reasoning)
    }
}
