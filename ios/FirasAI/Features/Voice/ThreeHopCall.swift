import Foundation

/// Why a hop stopped. Neither case ends the call: the caller simply speaks again.
enum ThreeHopError: Error, Sendable {
    /// `/api/transcribe` answered 200 with an empty `text` — nothing clear was heard.
    case noSpeech
    /// The chat answered with nothing, or with one of the engine-failure sentences.
    case emptyReply
}

/// One turn of the fallback rung: record → `/api/transcribe` → `/api/chat` (SSE) → `/api/tts`
/// (`web-voice-call-mic.md §6`, `server-voice.md §7.1`).
///
/// The turn is stateless — the call engine owns the history and the audio — and every leg is
/// bounded, because a call that hangs on one of three requests looks exactly like a frozen app.
/// The reply is cleaned for speech before it is sent to TTS: no markdown, no LaTeX, no URLs, no
/// emoji, because the caller hears it rather than reads it.
final class ThreeHopCall: Sendable {

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func answer(
        wavBase64: String,
        dialect: DictationDialect,
        history: [OutgoingMessage],
        lang: AppLanguage,
        tier: ModelTier
    ) async throws -> (transcript: String, reply: String, audio: Data, mime: String?) {
        let client = api

        // 1 — speech to text.
        let hint = dialect.serverKey
        let transcription = try await withDeadline(seconds: 45) {
            try await client.transcribe(wavBase64: wavBase64, lang: hint)
        }
        let heard = (transcription.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { throw ThreeHopError.noSpeech }

        // 2 — an ordinary chat turn, in call mode: no plan clarifications, no thinking, tier ≤ pro.
        var messages: [OutgoingMessage] = [
            OutgoingMessage(role: "system", content: PromptCatalog.callSystemPrompt(lang: lang.rawValue))
        ]
        messages.append(contentsOf: history)
        messages.append(OutgoingMessage(role: "user", content: heard))

        let request = ChatStreamRequest(
            messages: messages,
            tier: tier.rawValue,
            think: false,
            cid: IDs.cid(),
            chatId: nil,
            product: "ai",
            nomem: false
        )
        let reply = try await collect(request)
        guard !reply.isEmpty, !EngineFailureDetector.isFailure(reply) else { throw ThreeHopError.emptyReply }

        // 3 — text to speech, on the cleaned line.
        let spoken = Self.speakable(reply)
        let text = spoken.isEmpty ? reply : spoken
        let speechLang = CallEngine.speechLanguage(for: text)
        let chunk = String(text.prefix(1_300))
        let speech: ThreeHopSpeech = try await withDeadline(seconds: 60) {
            let response = try await client.tts(text: chunk, lang: speechLang)
            return ThreeHopSpeech(data: response.data, mime: response.mime)
        }

        return (transcript: heard, reply: reply, audio: speech.data, mime: speech.mime)
    }

    /// Drains the SSE stream into one answer. `data: [DONE]` closes it; a malformed frame is
    /// skipped, never fatal; a stream that will not end is cut at 90 s.
    private func collect(_ request: ChatStreamRequest) async throws -> String {
        let stream = await api.chatStream(request)
        let cutoff = Date().addingTimeInterval(90)
        var reply = ""
        for try await frame in stream {
            if frame.isDone { break }
            reply += Self.deltaContent(from: frame.data)
            if Date() >= cutoff { break }
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deltaContent(from payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]] else { return "" }
        var text = ""
        for choice in choices {
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let content = delta["content"] as? String {
                text += content
            }
        }
        return text
    }
}

/// A `Sendable` box so the TTS leg can travel through `withDeadline` without relying on tuple
/// conformances.
private struct ThreeHopSpeech: Sendable {
    let data: Data
    let mime: String?
}

// MARK: - Speech cleaning (`callSpeakable`, app.js:49536)

extension ThreeHopCall {

    /// Strips everything that must never be spoken: code, LaTeX, markdown marks, links, URLs and
    /// emoji; `^2`/`^3` become words; blank lines become a spoken full stop.
    ///
    /// No regex here uses `\b` — a word boundary next to Arabic matches in the wrong places.
    static func speakable(_ markdown: String) -> String {
        var text = markdown

        text = replacing(text, pattern: #"```[\s\S]*?```"#, with: "")
        text = replacing(text, pattern: #"`([^`]*)`"#, with: "$1")
        text = replacing(text, pattern: #"!\[[^\]]*\]\([^)]*\)"#, with: "")
        text = replacing(text, pattern: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")

        text = replacing(text, pattern: #"\$\$([\s\S]*?)\$\$"#, with: "$1")
        text = replacing(text, pattern: #"\$([^$\n]*)\$"#, with: "$1")

        text = replacing(text, pattern: #"\\boxed\{([^{}]*)\}"#, with: "$1")
        text = replacing(text, pattern: #"\\text\{([^{}]*)\}"#, with: "$1")
        text = replacing(text, pattern: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "$1 over $2")
        text = replacing(text, pattern: #"\\sqrt\{([^{}]*)\}"#, with: "root $1")
        text = text.replacingOccurrences(of: "\\times", with: " x ")
        text = text.replacingOccurrences(of: "\\cdot", with: ".")
        text = text.replacingOccurrences(of: "\\pi", with: "pi")
        text = replacing(text, pattern: #"\\[a-zA-Z]+"#, with: "")
        text = text.replacingOccurrences(of: "{", with: "")
        text = text.replacingOccurrences(of: "}", with: "")

        text = text.replacingOccurrences(of: "^2", with: " squared")
        text = text.replacingOccurrences(of: "^3", with: " cubed")
        text = text.replacingOccurrences(of: "^", with: " to the power ")

        text = replacing(text, pattern: #"https?://\S+"#, with: "")
        text = replacing(text, pattern: #"[\*_~>#\|]"#, with: "")
        text = replacing(
            text,
            pattern: #"[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{2190}-\x{21FF}]"#,
            with: ""
        )

        text = replacing(text, pattern: #"\n[ \t]*\n"#, with: ". ")
        text = replacing(text, pattern: #"\s+"#, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
