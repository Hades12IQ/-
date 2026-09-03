import Foundation

/// The primary rung: OpenAI Realtime GA over a WebSocket, driven by the ephemeral `ek_…` secret
/// the server minted (`server-voice.md §3.7, §8`; `web-voice-call-mic.md §4.1`;
/// `audit-ios-voice.md §D2`).
///
/// The web client speaks WebRTC. A native client without a WebRTC dependency uses the WebSocket
/// transport with the *same secret and the same session* — the mint attached the whole session to
/// the secret — and carries the audio itself. Three consequences shape this file:
///
/// - **The persona is server-owned.** The only `session.update` ever sent pins the audio format,
///   which the mint deliberately leaves unset. `instructions`, `audio.output.voice` and
///   `audio.input.turn_detection` are never re-asserted from the device, and if `session.created`
///   comes back without them the secret was minted without a session: the rung fails rather than
///   patching the persona in locally.
/// - **No `OpenAI-Beta` header.** On the GA endpoint that header selects the beta vocabulary
///   (`response.audio.delta`, flat `session.modalities`). Without it we get the GA names. Audio
///   deltas are still matched on the substring `audio.delta`, exactly as the web does, so a rename
///   in either direction cannot silence the call.
/// - **Turn taking is the server's.** `semantic_vad` with `create_response` and
///   `interrupt_response` commits the buffer and starts the reply upstream. This transport never
///   sends `input_audio_buffer.commit`, and never `response.create` except for the greeting.
final class OpenAIRealtimeTransport: CallTransport, @unchecked Sendable {

    /// The `session.created` deadline (`audit-ios-voice.md §D2`, `server-voice.md §7.5 item 8`).
    private static let handshakeSeconds: Double = 12

    /// The one frame this client is allowed to push into the session: the audio format the mint
    /// does not pin. Nothing else here is client business.
    private static let sessionUpdateFrame = #"{"type":"session.update","session":{"type":"realtime","audio":{"input":{"format":{"type":"audio/pcm","rate":24000}},"output":{"format":{"type":"audio/pcm","rate":24000}}}}}"#

    let events: AsyncStream<CallEvent>

    private let continuation: AsyncStream<CallEvent>.Continuation
    private let socket = CallWebSocket()
    private let lock = NSLock()

    private var isReady = false
    private var isFinished = false
    private var handshake: CheckedContinuation<Void, Error>?
    private var handshakeResult: Result<Void, Error>?
    private var language: AppLanguage = .arabic
    private var assistantItemID: String?
    private var assistantTranscript = ""

    init() {
        let pipe = AsyncStream<CallEvent>.makeStream(
            of: CallEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        events = pipe.stream
        continuation = pipe.continuation
    }

    // MARK: - CallTransport

    /// `allowTools` and `reducedSetup` are Gemini's retry vocabulary; this session has no tools and
    /// no client-supplied setup at all, so both are accepted and ignored.
    func connect(token: LiveToken, language: AppLanguage, allowTools: Bool, reducedSetup: Bool) async throws {
        let secret = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw CallTransportError.badToken }

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")
        let model = token.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            components?.queryItems = [URLQueryItem(name: "model", value: model)]
        }
        guard let url = components?.url else { throw CallTransportError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3_600
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")

        lock.lock()
        self.language = language
        lock.unlock()

        socket.open(
            request: request,
            onOpen: {},
            onText: { [weak self] text in self?.handle(text) },
            onClose: { [weak self] code, reason in
                self?.shutdown(closeCode: .normalClosure, closedEvent: (code, reason))
            }
        )
        armHandshakeTimeout()

        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let settled = handshakeResult {
                lock.unlock()
                waiting.resume(with: settled)
            } else {
                handshake = waiting
                lock.unlock()
            }
        }
    }

    func send(pcm16: Data) async {
        lock.lock()
        let live = isReady && !isFinished
        lock.unlock()
        guard live, !pcm16.isEmpty else { return }
        socket.send(text: #"{"type":"input_audio_buffer.append","audio":""# + pcm16.base64EncodedString() + #""}"#)
    }

    /// The one response this client creates. Sent once the channel is up so Firas speaks first
    /// (`server-voice.md §8.5`, verbatim from `app.js:49089-49096`).
    func requestGreeting() async {
        lock.lock()
        let live = isReady && !isFinished
        let spoken = language
        lock.unlock()
        guard live else { return }
        let word = spoken.isArabic ? "Arabic" : "English"
        let instructions = "Greet the caller warmly in ONE short sentence in " + word + ", then stop and listen."
        let frame: [String: Any] = [
            "type": "response.create",
            "response": ["instructions": instructions]
        ]
        guard let text = CallJSON.text(frame) else { return }
        socket.send(text: text)
    }

    /// After a barge-in, tell the model how much of its reply the caller actually heard. WebRTC
    /// does this implicitly; a WebSocket client must do it itself or the transcript keeps words
    /// nobody ever heard.
    func truncate(playedMs: Int) async {
        lock.lock()
        let live = isReady && !isFinished
        let item = assistantItemID
        lock.unlock()
        guard live, let item, !item.isEmpty else { return }
        let frame: [String: Any] = [
            "type": "conversation.item.truncate",
            "item_id": item,
            "content_index": 0,
            "audio_end_ms": max(0, playedMs)
        ]
        guard let text = CallJSON.text(frame) else { return }
        socket.send(text: text)
    }

    func ping() async {
        lock.lock()
        let live = !isFinished
        lock.unlock()
        guard live else { return }
        socket.ping()
    }

    func close() async {
        shutdown(closeCode: .normalClosure, closedEvent: nil)
    }

    // MARK: - Handshake

    private func armHandshakeTimeout() {
        let deadline = DispatchTime.now() + OpenAIRealtimeTransport.handshakeSeconds
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadySettled = self.handshakeResult != nil
            self.lock.unlock()
            guard !alreadySettled else { return }
            self.settleHandshake(.failure(CallTransportError.handshakeTimeout))
            self.shutdown(closeCode: .goingAway, closedEvent: nil)
        }
    }

    /// Resolves `connect`, exactly once, whichever of the four paths gets here first.
    private func settleHandshake(_ result: Result<Void, Error>) {
        lock.lock()
        if handshakeResult != nil {
            lock.unlock()
            return
        }
        handshakeResult = result
        let waiting = handshake
        handshake = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    /// Idempotent teardown: closes the socket, publishes the close (when it came from the peer)
    /// and finishes the event stream so the engine's `for await` loop exits.
    private func shutdown(closeCode: URLSessionWebSocketTask.CloseCode, closedEvent: (code: Int?, reason: String)?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        isReady = false
        lock.unlock()

        socket.close(code: closeCode)
        settleHandshake(.failure(CallTransportError.closedBeforeReady(
            code: closedEvent?.code,
            reason: closedEvent?.reason ?? ""
        )))
        if let closedEvent {
            continuation.yield(.closed(code: closedEvent.code, reason: closedEvent.reason))
        }
        continuation.finish()
    }

    // MARK: - Incoming events

    private func handle(_ text: String) {
        guard let object = CallJSON.object(text), let type = CallJSON.string(object, "type") else { return }

        // GA renamed `response.audio.delta` to `response.output_audio.delta`; match the substring
        // both spellings share, exactly as the shipped web client does (app.js:48950-48957).
        if type.contains("audio.delta") {
            if let encoded = CallJSON.string(object, "delta"),
               let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
               !data.isEmpty {
                continuation.yield(.audio(data))
            }
            return
        }

        switch type {
        case "session.created":
            handleSessionCreated(object)
        case "input_audio_buffer.speech_started":
            continuation.yield(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            continuation.yield(.speechStopped)
        case "response.created":
            lock.lock()
            assistantTranscript = ""
            lock.unlock()
            continuation.yield(.responseCreated)
        case "response.done":
            continuation.yield(.responseDone)
        case "response.output_item.added", "conversation.item.added", "conversation.item.created":
            noteAssistantItem(object)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            appendAssistantTranscript(CallJSON.string(object, "delta"))
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            replaceAssistantTranscript(CallJSON.string(object, "transcript"))
        case "conversation.item.input_audio_transcription.completed":
            if let spoken = CallJSON.string(object, "transcript"),
               !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continuation.yield(.transcript(spoken, own: true))
            }
        case "error":
            continuation.yield(.error(errorDetail(object)))
        default:
            break
        }
    }

    /// Verifies the session the secret carried. This is the whole reason the rung can be trusted:
    /// the persona and the turn detector live on the server, and a session without them is a
    /// stranger's session.
    private func handleSessionCreated(_ object: [String: Any]) {
        let session = CallJSON.dict(object, "session")
        let instructions = CallJSON.string(session, "instructions") ?? ""
        let input = CallJSON.dict(CallJSON.dict(session, "audio"), "input")
        let detection = CallJSON.string(CallJSON.dict(input, "turn_detection"), "type") ?? ""

        guard instructions.hasPrefix("You are Firas") else {
            failHandshake("no persona in session")
            return
        }
        guard detection == "semantic_vad" else {
            failHandshake("turn_detection is " + (detection.isEmpty ? "missing" : detection))
            return
        }

        socket.send(text: OpenAIRealtimeTransport.sessionUpdateFrame)

        lock.lock()
        let alreadyFinished = isFinished
        if !alreadyFinished { isReady = true }
        lock.unlock()
        guard !alreadyFinished else { return }

        settleHandshake(.success(()))
        continuation.yield(.ready)
    }

    private func failHandshake(_ detail: String) {
        settleHandshake(.failure(CallTransportError.handshakeRejected(detail)))
        continuation.yield(.error("session rejected: " + detail))
        shutdown(closeCode: .goingAway, closedEvent: nil)
    }

    /// Remembers the assistant item id so a barge-in can truncate the right item.
    private func noteAssistantItem(_ object: [String: Any]) {
        guard let item = CallJSON.dict(object, "item") else { return }
        guard CallJSON.string(item, "role") == "assistant" else { return }
        guard let identifier = CallJSON.string(item, "id"), !identifier.isEmpty else { return }
        lock.lock()
        assistantItemID = identifier
        lock.unlock()
    }

    private func appendAssistantTranscript(_ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        lock.lock()
        assistantTranscript += delta
        let full = assistantTranscript
        lock.unlock()
        continuation.yield(.transcript(full, own: false))
    }

    private func replaceAssistantTranscript(_ full: String?) {
        guard let full, !full.isEmpty else { return }
        lock.lock()
        assistantTranscript = full
        lock.unlock()
        continuation.yield(.transcript(full, own: false))
    }

    /// `error.code` + `error.message`, clipped to 300 characters (app.js:48965-48967). An `error`
    /// event alone never tears the call down — a fatal one is followed by a socket close.
    private func errorDetail(_ object: [String: Any]) -> String {
        let detail = CallJSON.dict(object, "error")
        let code = CallJSON.string(detail, "code") ?? CallJSON.string(detail, "type") ?? "error"
        let message = CallJSON.string(detail, "message") ?? ""
        let joined = message.isEmpty ? code : code + ": " + message
        return String(joined.prefix(300))
    }
}
