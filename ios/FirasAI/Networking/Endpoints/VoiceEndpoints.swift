import Foundation

// Voice: the realtime session token, server transcription and text-to-speech.
// Wire shapes: server-voice.md §3–§5 (verified against server.mjs 5731-5848, 6212-6363).

// MARK: - Request bodies

private struct VoiceLiveTokenBody: Encodable, Sendable {
    let voice: String
    let prefer: String?
}

private struct VoiceTranscribeBody: Encodable, Sendable {
    let audio: String
    let format: String
    let lang: String
}

private struct VoiceTTSBody: Encodable, Sendable {
    let text: String
    let lang: String
    let gender: String
}

// MARK: - Endpoints

extension APIClient {

    /// `POST /api/live/token` — mints one session. `prefer` accepts only `"gemini"`: the ladder
    /// walks down, never up, so pass it exactly once, for the fallback leg of the same call.
    /// `voice` applies to the OpenAI session only. The call is charged before the mint, with a
    /// 90 s grace that makes the immediate Gemini retry free — never mint twice without `prefer`.
    func liveToken(voice: String, prefer: String?) async throws -> LiveToken {
        let body = VoiceLiveTokenBody(voice: voice, prefer: prefer)
        return try await json(
            .post,
            "/api/live/token",
            body: body,
            budget: .interactive,
            as: LiveToken.self
        )
    }

    /// `POST /api/transcribe` — the audio is standard-alphabet base64 with no line breaks and no
    /// data-URL prefix, at least 4 000 characters. `format` is `"wav"` (16 kHz mono PCM16 LE);
    /// only `"mp3"` is treated differently, everything else is read as WAV. `lang` is one of the
    /// server's hint keys. A `503` means "no server STT" — fall back to on-device recognition.
    func transcribe(wavBase64: String, lang: String) async throws -> TranscribeResponse {
        let body = VoiceTranscribeBody(audio: wavBase64, format: "wav", lang: lang)
        return try await json(
            .post,
            "/api/transcribe",
            body: body,
            budget: .upload,
            as: TranscribeResponse.self
        )
    }

    /// `POST /api/tts` — one complete file, never a stream. The engine ladder returns **either**
    /// `audio/wav` (Gemini) or `audio/mpeg` (OpenAI/Edge) for the same text, so the caller sniffs
    /// the bytes and never assumes the type of the previous reply. Only a male voice exists.
    /// Chunk the text at ≤ 1 300 characters: the server silently truncates at 1 400.
    func tts(text: String, lang: String) async throws -> (data: Data, mime: String?) {
        let body = VoiceTTSBody(text: text, lang: lang, gender: "male")
        let (data, response) = try await raw(
            .post,
            "/api/tts",
            body: body,
            budget: .upload
        )
        let mime = response.value(forHTTPHeaderField: "Content-Type")
        return (data, mime)
    }
}
