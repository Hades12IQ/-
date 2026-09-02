import AVFoundation
import Foundation
import Observation
import Speech

/// The dictation flow shared by every composer (Chat, Agent, Brain).
///
/// Permission → record → 700 ms / 1 500-byte floor → `POST /api/transcribe` → on-device
/// `SFSpeechRecognizer` when the server has no STT or the device is offline. The transcript is
/// **returned**, never inserted and never sent: the composer appends it with one space
/// (`web-voice-call-mic.md §7.3`, `server-voice.md §4`).
@MainActor
@Observable
final class DictationController {

    enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    // MARK: - Published state

    private(set) var state: State = .idle

    /// 0…1, refreshed ≤ 20 Hz — the waveform's only input.
    private(set) var level: Float = 0

    /// Whole seconds since recording started; the bar renders it as `m:ss`.
    private(set) var seconds: Int = 0

    /// Called when a take finishes without a caller waiting for it — the 300 s cap and the
    /// backgrounding auto-finish. The composer sets this so nothing the user said is lost.
    var onTranscript: ((String) -> Void)?

    // MARK: - Dependencies

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let network: NetworkMonitor

    @ObservationIgnored private let recorder = DictationRecorder()
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var tickGeneration = 0
    @ObservationIgnored private var failureGeneration = 0

    init(api: APIClient, prefs: PreferencesStore, toasts: ToastCenter, network: NetworkMonitor) {
        self.api = api
        self.prefs = prefs
        self.toasts = toasts
        self.network = network
    }

    // MARK: - Lifecycle

    /// Asks for the microphone once, then starts the engine. A denial toasts and leaves the
    /// controller idle — the bar never opens on a permission the user refused.
    func start() async {
        guard state == .idle || isFailed else { return }
        clearFailure()

        let granted = await Self.requestMicrophonePermission()
        guard granted else {
            fail(Strings.Voice.micDenied(prefs.lang))
            return
        }

        do {
            let levels = try await recorder.start()
            seconds = 0
            level = 0
            state = .recording
            Haptics.recordStart()
            observe(levels)
            startTicking()
        } catch {
            fail(Strings.Voice.micUnsupported(prefs.lang))
        }
    }

    /// Stops the take and returns what the user said, or `nil` when nothing usable came back.
    func finish() async -> String? {
        guard state == .recording else { return nil }

        stopTicking()
        Haptics.recordStop()

        let capturedSeconds = await recorder.duration
        let pcm: Data
        do {
            pcm = try await recorder.stop()
        } catch {
            levelTask?.cancel()
            level = 0
            fail(Strings.Voice.micFail(prefs.lang))
            return nil
        }

        levelTask?.cancel()
        level = 0

        // The local floor exists so a stray tap never spends a quota unit on 90 ms of silence.
        guard capturedSeconds >= 0.7, pcm.count >= 1_500 else {
            fail(Strings.Voice.micTooShort(prefs.lang))
            return nil
        }

        state = .transcribing
        let wav = WAVEncoder.wav(
            pcm16: pcm,
            sampleRate: Int(DictationRecorder.sampleRate),
            channels: 1
        )
        let transcript = await transcribe(wav: wav)
        if transcript != nil { state = .idle }
        return transcript
    }

    /// Drops the take entirely — nothing is uploaded and nothing is inserted.
    func cancel() async {
        stopTicking()
        levelTask?.cancel()
        levelTask = nil
        await recorder.cancel()
        level = 0
        seconds = 0
        state = .idle
    }

    /// Backgrounding finishes the take rather than losing it (the web does the same, for privacy:
    /// the microphone must not stay open behind another app).
    func applicationDidEnterBackground() {
        guard state == .recording else { return }
        Task { [weak self] in
            guard let self else { return }
            if let text = await self.finish() {
                self.onTranscript?(text)
            }
        }
    }

    /// The append rule the web uses (`app.js:47926`): one space, never a replacement.
    static func appending(_ transcript: String, to draft: String) -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return draft }
        let trimmedDraft = draft.replacingOccurrences(
            of: "\\s+$",
            with: "",
            options: .regularExpression
        )
        return trimmedDraft.isEmpty ? clean : trimmedDraft + " " + clean
    }

    // MARK: - Transcription

    private func transcribe(wav: Data) async -> String? {
        let lang = prefs.lang
        let dialect = prefs.dictationDialect

        guard network.isOnline else {
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        }

        let client = api
        let key = dialect.serverKey
        let base64 = WAVEncoder.base64(wav)

        do {
            let response = try await withDeadline(seconds: 90) {
                try await client.transcribe(wavBase64: base64, lang: key)
            }
            let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                fail(Strings.Voice.micEmpty(lang))
                return nil
            }
            return text
        } catch is DeadlineError {
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        } catch let error as APIError {
            return await handle(error, wav: wav, dialect: dialect, lang: lang)
        } catch {
            fail(Strings.Voice.micFail(lang))
            return nil
        }
    }

    private func handle(
        _ error: APIError,
        wav: Data,
        dialect: DictationDialect,
        lang: AppLanguage
    ) async -> String? {
        switch error {
        case .offline, .transport:
            // The device recogniser works with no network at all.
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        case .cancelled:
            state = .idle
            return nil
        case .deadline:
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        case .http(let status, _, _) where status == 503:
            // "no stt engine" — the server has no Gemini key at all.
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        case .http(let status, _, _) where status == 429:
            fail(Strings.Errors.tooFast(lang))
            return nil
        case .http, .invalidURL, .decoding:
            fail(Strings.Voice.micFail(lang))
            return nil
        }
    }

    private func deviceTranscribe(
        wav: Data,
        dialect: DictationDialect,
        lang: AppLanguage
    ) async -> String? {
        let heard = await Self.recognizeOnDevice(wav: wav, locale: dialect.bcp47)
        guard let heard else {
            fail(Strings.Voice.micFail(lang))
            return nil
        }
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(Strings.Voice.micEmpty(lang))
            return nil
        }
        return trimmed
    }

    // MARK: - On-device recognition

    /// Recognition is bounded by its own timer rather than by `withDeadline`: a speech task does
    /// not answer task cancellation, and a task group will not return while a child is still
    /// suspended, so racing it would hang instead of timing out.
    nonisolated private static func recognizeOnDevice(wav: Data, locale: String) async -> String? {
        guard await requestSpeechAuthorization() else { return nil }

        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("firas-dictation-" + UUID().uuidString + ".wav")
        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        let outcome = await recognize(url: url, locale: locale)
        try? FileManager.default.removeItem(at: url)
        return outcome
    }

    nonisolated private static func recognize(url: URL, locale: String) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else {
            return nil
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let box = SpeechResultBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            box.attach(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    box.settle(nil)
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    box.settle(result.bestTranscription.formattedString)
                }
            }
            box.hold(task)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 60) {
                box.settle(nil)
            }
        }
    }

    /// The same shape `CallEngine+Support` uses, so both microphone owners ask identically.
    nonisolated private static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                continuation.resume(returning: granted)
            })
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Level and timer

    private func observe(_ levels: AsyncStream<Float>) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            for await value in levels {
                guard let self else { return }
                self.level = value
            }
            if let self { self.level = 0 }
        }
    }

    private func startTicking() {
        tickGeneration &+= 1
        scheduleTick(tickGeneration)
    }

    private func stopTicking() {
        tickGeneration &+= 1
    }

    private func scheduleTick(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.tickGeneration == generation, self.state == .recording else {
                    return
                }
                self.seconds += 1
                if Double(self.seconds) >= DictationRecorder.maximumSeconds {
                    self.finishBecauseOfCap()
                    return
                }
                self.scheduleTick(generation)
            }
        }
    }

    private func finishBecauseOfCap() {
        Task { [weak self] in
            guard let self else { return }
            if let text = await self.finish() {
                self.onTranscript?(text)
            }
        }
    }

    // MARK: - Failure

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// One toast, one visible error state, and a self-clearing return to idle so the bar never
    /// gets stuck on a sentence nobody dismissed.
    private func fail(_ message: String) {
        stopTicking()
        state = .failed(message)
        toasts.show(message, isError: true)
        Haptics.error()

        failureGeneration &+= 1
        let generation = failureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.failureGeneration == generation else { return }
                if self.isFailed { self.state = .idle }
            }
        }
    }

    private func clearFailure() {
        failureGeneration &+= 1
        if isFailed { state = .idle }
    }
}

// MARK: - Continuation guard

/// `SFSpeechRecognitionTask` calls its handler more than once; a continuation may be resumed
/// exactly once. This box settles whichever callback arrives first and ignores the rest, and
/// keeps the task alive for as long as the caller is waiting.
private final class SpeechResultBox: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var task: SFSpeechRecognitionTask?
    private var settled = false

    func attach(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func hold(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { self.task = task }
        lock.unlock()
        if alreadySettled { task.cancel() }
    }

    func settle(_ value: String?) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let waiting = continuation
        continuation = nil
        let running = task
        task = nil
        lock.unlock()

        running?.finish()
        waiting?.resume(returning: value)
    }
}
