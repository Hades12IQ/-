import Foundation

/// Everything the two live engines can tell the call engine, in one vocabulary.
///
/// The point of this enum is that `CallEngine` never learns which engine it is driving: OpenAI's
/// GA event names and Gemini's `serverContent` shapes are both translated here, so the phase
/// machine, the mic gate and the two clocks are written once (`audit-ios-voice.md §D2–D3`).
///
/// `transcript(_:own:)` carries `own: true` for the **caller's** words (OpenAI's
/// `conversation.item.input_audio_transcription.completed`, Gemini's `inputTranscription`) and
/// `own: false` for Firas's own words. Both arrive as the complete text so far, never a bare
/// delta, so a caption line can assign rather than append.
enum CallEvent: Sendable {
    /// The channel is up both ways and the session config was verified. Emitted exactly once.
    case ready
    /// The server's turn detector heard the caller start.
    case speechStarted
    /// The server's turn detector heard the caller stop.
    case speechStopped
    /// A reply has begun generating — close the mic gate.
    case responseCreated
    /// PCM16 little-endian mono at 24 kHz, ready for the playback queue.
    case audio(Data)
    /// A caption. `own` is `true` for the caller's words, `false` for Firas's.
    case transcript(String, own: Bool)
    /// The reply finished (any status — a refusal ends a turn exactly like a completion does).
    case responseDone
    /// The caller talked over the reply and the server cancelled it: flush playback now.
    case interrupted
    /// The socket is gone. `code` is the WebSocket close code when the peer sent one.
    case closed(code: Int?, reason: String)
    /// A non-fatal protocol error. A fatal one is followed by `closed`.
    case error(String)
}

/// One live rung of the ladder. Implemented by `OpenAIRealtimeTransport` (primary, WebSocket with
/// the ephemeral `ek_…` secret) and `GeminiLiveTransport` (fallback).
///
/// Contract for every implementation:
///
/// - `events` is one stream, created in `init` and returned unchanged. It finishes when the
///   transport shuts down, so a `for await` loop over it always terminates.
/// - `connect` returns only once audio can flow both ways, and throws otherwise. It never returns
///   on a timeout, and it never leaves a socket behind after throwing — a failed attempt tears
///   itself down before the next rung opens a second microphone (`server-voice.md §7.5 item 7`).
/// - Every other method is a no-op before `.ready` and after shutdown, so the engine can call them
///   from a timer without holding a lock.
/// - Nothing here touches the audio session, the engine graph or any UI state.
protocol CallTransport: AnyObject, Sendable {
    var events: AsyncStream<CallEvent> { get }
    func connect(token: LiveToken, language: AppLanguage, allowTools: Bool, reducedSetup: Bool) async throws
    func send(pcm16: Data) async
    func requestGreeting() async
    func truncate(playedMs: Int) async
    func ping() async
    func close() async
}

/// Why a rung failed. The `reason` slug is what `CallDiagnostics` shows and what the ladder logs;
/// it is deliberately a short machine-ish token, never a sentence shown to a caller.
enum CallTransportError: Error, Sendable {
    /// The mint returned an empty secret, or one for a different provider.
    case badToken
    /// The endpoint could not be assembled (an unusable model or token string).
    case badURL
    /// No `session.created` / `setupComplete` inside the connect deadline.
    case handshakeTimeout
    /// The handshake arrived but carried the wrong session (no persona, no `semantic_vad`).
    case handshakeRejected(String)
    /// The socket closed before the session was ever up.
    case closedBeforeReady(code: Int?, reason: String)

    var reason: String {
        switch self {
        case .badToken: return "bad-token"
        case .badURL: return "bad-url"
        case .handshakeTimeout: return "handshake-timeout"
        case .handshakeRejected(let detail): return "handshake-rejected: " + detail
        case .closedBeforeReady(let code, let detail):
            let head = code.map { "close-" + String($0) } ?? "close"
            return detail.isEmpty ? head : head + ": " + detail
        }
    }
}

/// Tiny untyped-JSON helpers shared by the two transports.
///
/// Both wire protocols are open-ended maps whose shapes change between provider versions (the GA
/// rename of `response.audio.delta` to `response.output_audio.delta` is the standing example), so
/// they are read defensively key by key instead of through `Codable`. Nothing here ever throws.
enum CallJSON {

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
        return parsed as? [String: Any]
    }

    static func text(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func dict(_ object: [String: Any]?, _ key: String) -> [String: Any]? {
        object?[key] as? [String: Any]
    }

    /// The array at `key`, keeping only its dictionary elements.
    static func list(_ object: [String: Any]?, _ key: String) -> [[String: Any]] {
        guard let raw = object?[key] as? [Any] else { return [] }
        return raw.compactMap { $0 as? [String: Any] }
    }

    static func string(_ object: [String: Any]?, _ key: String) -> String? {
        if let value = object?[key] as? String { return value }
        return nil
    }

    static func bool(_ object: [String: Any]?, _ key: String) -> Bool? {
        if let value = object?[key] as? Bool { return value }
        if let value = object?[key] as? NSNumber { return value.boolValue }
        return nil
    }

    static func has(_ object: [String: Any]?, _ key: String) -> Bool {
        guard let value = object?[key] else { return false }
        return !(value is NSNull)
    }
}

/// The WebSocket both transports run on.
///
/// It exists so the two protocol implementations contain protocol logic and nothing else: one
/// private `URLSession` per socket (never the app-wide shared session), invalidated on close so the
/// delegate cycle is broken; a receive loop that re-arms itself; and — the reason a delegate is
/// used at all — the peer's close **code and reason**, which is the only place Google explains a
/// refused setup (`server-voice.md §7.9`).
///
/// Sends are fire-and-forget on purpose. `URLSessionWebSocketTask` queues them and delivers them
/// in order, which is exactly the guarantee the mic stream needs, and awaiting each completion
/// would risk a continuation that never resumes when the socket dies mid-flight.
final class CallWebSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    typealias OpenHandler = @Sendable () -> Void
    typealias TextHandler = @Sendable (String) -> Void
    typealias CloseHandler = @Sendable (Int?, String) -> Void

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openHandler: OpenHandler?
    private var textHandler: TextHandler?
    private var closeHandler: CloseHandler?
    private var didFinish = false

    override init() {
        super.init()
    }

    /// Opens the socket and starts the receive loop. Safe to call once per instance.
    func open(
        request: URLRequest,
        onOpen: @escaping OpenHandler,
        onText: @escaping TextHandler,
        onClose: @escaping CloseHandler
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // A live call runs at most ten minutes and exchanges a frame every 100 ms; these ceilings
        // exist only so a wedged socket cannot outlive the app. The real connect deadline is the
        // transport's own handshake latch.
        configuration.timeoutIntervalForRequest = 3_600
        configuration.timeoutIntervalForResource = 3_600

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let newTask = newSession.webSocketTask(with: request)

        lock.lock()
        session = newSession
        task = newTask
        openHandler = onOpen
        textHandler = onText
        closeHandler = onClose
        lock.unlock()

        newTask.resume()
        receiveNext()
    }

    /// Queues one text frame. Ignored once the socket is gone.
    func send(text: String) {
        lock.lock()
        let stopped = didFinish
        let current = task
        lock.unlock()
        guard !stopped, let current else { return }
        current.send(.string(text)) { _ in }
    }

    /// Keeps a NAT from dropping an idle flow while the mic gate is closed.
    func ping() {
        lock.lock()
        let stopped = didFinish
        let current = task
        lock.unlock()
        guard !stopped, let current else { return }
        current.sendPing { _ in }
    }

    /// Closes locally. The close handler is **not** called — the caller already knows.
    func close(code: URLSessionWebSocketTask.CloseCode) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        let currentTask = task
        let currentSession = session
        task = nil
        session = nil
        openHandler = nil
        textHandler = nil
        closeHandler = nil
        lock.unlock()

        currentTask?.cancel(with: code, reason: nil)
        currentSession?.invalidateAndCancel()
    }

    // MARK: - Receive loop

    private func receiveNext() {
        lock.lock()
        let stopped = didFinish
        let current = task
        lock.unlock()
        guard !stopped, let current else { return }
        current.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.deliver(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.deliver(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNext()
            case .failure(let error):
                let info = self.peerCloseInfo()
                let reason = info.reason ?? error.localizedDescription
                self.finish(code: info.code, reason: reason)
            }
        }
    }

    private func peerCloseInfo() -> (code: Int?, reason: String?) {
        lock.lock()
        let current = task
        lock.unlock()
        guard let current else { return (nil, nil) }
        let raw = current.closeCode
        let code: Int? = raw == .invalid ? nil : raw.rawValue
        let reason = current.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        return (code, reason)
    }

    private func deliver(_ text: String) {
        lock.lock()
        let stopped = didFinish
        let handler = textHandler
        lock.unlock()
        guard !stopped, let handler else { return }
        handler(text)
    }

    /// The one path that reports a remote close, exactly once.
    private func finish(code: Int?, reason: String) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        let handler = closeHandler
        let currentSession = session
        openHandler = nil
        textHandler = nil
        closeHandler = nil
        task = nil
        session = nil
        lock.unlock()

        currentSession?.invalidateAndCancel()
        handler?(code, reason)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        lock.lock()
        let stopped = didFinish
        let handler = openHandler
        openHandler = nil
        lock.unlock()
        guard !stopped, let handler else { return }
        handler()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        finish(code: closeCode == .invalid ? nil : closeCode.rawValue, reason: text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(code: nil, reason: error.localizedDescription)
    }
}
