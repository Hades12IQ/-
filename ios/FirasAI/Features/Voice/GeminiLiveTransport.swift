import Foundation

/// The fallback rung: Gemini Live over a raw-PCM WebSocket (`server-voice.md §3.8, §7.9`;
/// `web-voice-call-mic.md §5`; `audit-ios-voice.md §D3`).
///
/// Where the OpenAI rung hands everything to a server-owned session, here the client owns the
/// session: the system instruction, the voice, the search tool and the activity detector are all
/// sent from the device in the first frame, and the echo problem is ours too.
///
/// Three things this transport must get right, all of them lessons the web client already paid
/// for:
///
/// - **The token is single-use.** Each attempt needs a freshly minted token; the ladder above
///   mints again before it retries, and this file never reuses one.
/// - **The retry vocabulary is the setup frame.** `allowTools == false` drops the search tool for a
///   model that has no search entitlement (a 1011 close with tools means exactly that);
///   `reducedSetup == true` additionally drops `speechConfig` and `realtimeInputConfig`, which is
///   the one retry that survives a setup the server refused outright.
/// - **A suppressed mic frame is silence, not a gap.** The echo guard runs here, on the way out,
///   because only this side knows how much audio is still playing.
final class GeminiLiveTransport: CallTransport, @unchecked Sendable {

    /// The `setupComplete` deadline (`server-voice.md §7.9`).
    private static let handshakeSeconds: Double = 10

    /// `LIVE_IN_RATE` — what the caller's audio is resampled to before it gets here.
    private static let inputRate = 16_000

    /// `LIVE_VOICES[0]`, the shipped default. The list is console-only on the web and has no
    /// settings surface, so there is nothing to read a preference from.
    private static let voiceName = "Charon"

    /// The model the server mints when it does not say otherwise (`server-voice.md §3.8`).
    private static let fallbackModel = "gemini-3.1-flash-live-preview"

    let events: AsyncStream<CallEvent>

    private let continuation: AsyncStream<CallEvent>.Continuation
    private let socket = CallWebSocket()
    private let lock = NSLock()

    private var isReady = false
    private var isFinished = false
    private var handshake: CheckedContinuation<Void, Error>?
    private var handshakeResult: Result<Void, Error>?
    private var pendingSetup: String?
    private var turnOpen = false

    init() {
        let pipe = AsyncStream<CallEvent>.makeStream(
            of: CallEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        events = pipe.stream
        continuation = pipe.continuation
    }

    // MARK: - CallTransport

    func connect(token: LiveToken, language: AppLanguage, allowTools: Bool, reducedSetup: Bool) async throws {
        let secret = token.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw CallTransportError.badToken }

        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
        )
        components?.queryItems = [URLQueryItem(name: "access_token", value: secret)]
        guard let url = components?.url else { throw CallTransportError.badURL }

        guard let setup = GeminiLiveTransport.setupFrame(
            model: token.model,
            language: language,
            allowTools: allowTools,
            reducedSetup: reducedSetup
        ) else {
            throw CallTransportError.handshakeRejected("setup frame could not be encoded")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3_600

        lock.lock()
        pendingSetup = setup
        lock.unlock()

        socket.open(
            request: request,
            onOpen: { [weak self] in self?.sendPendingSetup() },
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

    /// One 100 ms frame of 16 kHz PCM16, sent as captured.
    ///
    /// The echo guard is **not** applied here. `CallEngine` runs it on the microphone pump, where
    /// the real playback state lives (`CallAudioGraph.isPlaybackArmed`), and it already substitutes
    /// silence for what it suppresses. Running a second copy of the same state machine on this side
    /// would make a genuine barge-in wait for two independent three-frame runs.
    func send(pcm16: Data) async {
        lock.lock()
        let live = isReady && !isFinished
        lock.unlock()
        guard live, !pcm16.isEmpty else { return }

        let mime = "audio/pcm;rate=" + String(GeminiLiveTransport.inputRate)
        let head = #"{"realtimeInput":{"audio":{"mimeType":""#
        let middle = #"","data":""#
        let tail = #""}}}"#
        socket.send(text: head + mime + middle + pcm16.base64EncodedString() + tail)
    }

    /// Gemini has no greeting event. The shipped web client sends nothing on this rung and lets
    /// the caller open the conversation; sending a synthetic turn here would put words in the
    /// caller's mouth and desynchronise the activity detector. Deliberately a no-op.
    func requestGreeting() async {}

    /// No equivalent exists on this protocol: `serverContent.interrupted` already tells the model
    /// what the caller heard. Deliberately a no-op.
    func truncate(playedMs: Int) async {}

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

    // MARK: - Setup

    /// The first frame, sent on open. `setup` is refused silently if anything in it is wrong, so
    /// the two retry shapes below are the only diagnosis available.
    private static func setupFrame(
        model rawModel: String,
        language: AppLanguage,
        allowTools: Bool,
        reducedSetup: Bool
    ) -> String? {
        var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = fallbackModel }
        if !model.hasPrefix("models/") { model = "models/" + model }

        var generationConfig: [String: Any] = ["responseModalities": ["AUDIO"]]
        if !reducedSetup {
            generationConfig["speechConfig"] = [
                "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]
            ]
        }

        var setup: [String: Any] = [
            "model": model,
            "generationConfig": generationConfig,
            "systemInstruction": ["parts": [["text": systemInstruction(language: language)]]]
        ]

        if !reducedSetup {
            if allowTools {
                setup["tools"] = [["googleSearch": [String: Any]()]]
            }
            setup["realtimeInputConfig"] = [
                "automaticActivityDetection": [
                    "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "prefixPaddingMs": 300,
                    "silenceDurationMs": 800
                ]
            ]
        }

        let frame: [String: Any] = ["setup": setup]
        return CallJSON.text(frame)
    }

    /// The client-supplied call persona, verbatim from `app.js:49288-49305`
    /// (`server-voice.md §7.9`). Unlike the OpenAI rung this one carries no identity block — only
    /// the mint does.
    private static func systemInstruction(language: AppLanguage) -> String {
        let named = language.isArabic ? "Arabic" : "the user language"
        return instructionHead + named + instructionTail
    }

    private static let instructionHead = #"You are Firas, on a live voice call. SPEAK, do not lecture: short conversational turns, the way a person actually talks on the phone. Never read markdown, never say asterisk or hash, never spell out punctuation, never list numbered points aloud unless asked. Answer in the SAME language and the SAME dialect the caller uses — if they speak Iraqi Arabic, answer in Iraqi Arabic, not Modern Standard. The interface language is "#

    private static let instructionTail = #", but the CALLER decides. If you are interrupted, stop immediately and listen. YOU CAN SEARCH THE WEB. When a question needs current information — news, prices, scores, what happened today, anything you are unsure of — first say WHAT you are about to look up, in one short sentence, in the caller's own language and dialect. NAME THE SUBJECT; do not just promise to check. In Iraqi Arabic something like لحظة، أدوّرلك على سعر الدولار اليوم, in English something like "one second, let me look up today's dollar rate". THE ANNOUNCEMENT AND THE ANSWER ARE ONE SINGLE TURN — never two. Do NOT stop speaking the moment you have announced it, and do NOT hand the turn back to the caller to wait: search, then keep going in the SAME turn and tell them what you found. The caller must NEVER have to prompt you, ask what you found, or say anything at all between your announcement and your answer. If you are about to end a turn having promised to look something up but not yet said what you found, do not end it — give the answer now. Never go silent while searching — a silent line sounds like a dropped call. Say the answer, not the URLs."#

    private func sendPendingSetup() {
        lock.lock()
        let stopped = isFinished
        let frame = pendingSetup
        pendingSetup = nil
        lock.unlock()
        guard !stopped, let frame else { return }
        socket.send(text: frame)
    }

    // MARK: - Handshake

    private func armHandshakeTimeout() {
        let deadline = DispatchTime.now() + GeminiLiveTransport.handshakeSeconds
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

    private func shutdown(closeCode: URLSessionWebSocketTask.CloseCode, closedEvent: (code: Int?, reason: String)?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        isReady = false
        turnOpen = false
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

    // MARK: - Incoming frames

    private func handle(_ text: String) {
        guard let object = CallJSON.object(text) else { return }

        if CallJSON.has(object, "setupComplete") {
            markReady()
            return
        }
        if let content = CallJSON.dict(object, "serverContent") {
            handleServerContent(content)
            return
        }
        if CallJSON.has(object, "goAway") {
            continuation.yield(.error("goAway"))
            shutdown(closeCode: .goingAway, closedEvent: (nil, "goAway"))
            return
        }
        if let detail = CallJSON.dict(object, "error") {
            let message = CallJSON.string(detail, "message") ?? CallJSON.string(detail, "status") ?? "error"
            continuation.yield(.error(String(message.prefix(300))))
        }
    }

    private func markReady() {
        lock.lock()
        let alreadyFinished = isFinished
        if !alreadyFinished { isReady = true }
        lock.unlock()
        guard !alreadyFinished else { return }
        settleHandshake(.success(()))
        continuation.yield(.ready)
    }

    private func handleServerContent(_ content: [String: Any]) {
        if CallJSON.bool(content, "interrupted") == true {
            lock.lock()
            turnOpen = false
            lock.unlock()
            // The engine flushes the player and zeroes its echo state on this event; without the
            // flush the caller's first words are swallowed by audio nobody is listening to.
            continuation.yield(.interrupted)
        }

        if let spoken = CallJSON.string(CallJSON.dict(content, "inputTranscription"), "text"), !spoken.isEmpty {
            continuation.yield(.transcript(spoken, own: true))
        }
        if let said = CallJSON.string(CallJSON.dict(content, "outputTranscription"), "text"), !said.isEmpty {
            continuation.yield(.transcript(said, own: false))
        }

        if let modelTurn = CallJSON.dict(content, "modelTurn") {
            handleModelTurn(modelTurn)
        }

        if CallJSON.bool(content, "turnComplete") == true || CallJSON.bool(content, "generationComplete") == true {
            lock.lock()
            turnOpen = false
            lock.unlock()
            continuation.yield(.responseDone)
        }
    }

    private func handleModelTurn(_ modelTurn: [String: Any]) {
        let parts = CallJSON.list(modelTurn, "parts")
        guard !parts.isEmpty else { return }

        lock.lock()
        let opening = !turnOpen
        turnOpen = true
        lock.unlock()
        if opening {
            continuation.yield(.responseCreated)
        }

        for part in parts {
            if let inline = CallJSON.dict(part, "inlineData"),
               let mime = CallJSON.string(inline, "mimeType"),
               mime.contains("audio"),
               let encoded = CallJSON.string(inline, "data"),
               let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
               !data.isEmpty {
                continuation.yield(.audio(data))
            } else if let spoken = CallJSON.string(part, "text"), !spoken.isEmpty {
                continuation.yield(.transcript(spoken, own: false))
            }
        }
    }
}
