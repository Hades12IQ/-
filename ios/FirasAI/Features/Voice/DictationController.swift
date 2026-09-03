import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

/// The dictation flow shared by every composer (Chat, Agent, Code, Brain).
///
/// Permission → record → **live partials straight into the composer** → 700 ms / 1 500-byte
/// floor → `POST /api/transcribe` → the server transcript replaces the partial in place.
///
/// Two recognisers run over one take, and they have different jobs. Apple's `SFSpeechRecognizer`
/// listens to the same `AVAudioEngine` tap that builds the upload and reports what it has heard so
/// far, so the words appear while the user is still speaking. The server is still the authority on
/// the final text — it is the better transcription and it is what the website uses — so when the
/// take ends its answer *replaces* the partial rather than being appended to it. If the server
/// cannot answer, the last on-device partial stands: losing what someone just said is the worst
/// outcome available here (`web-voice-call-mic.md §7.3`, `server-voice.md §4`).
///
/// Live recognition is a bonus, never a dependency. No speech permission, no recogniser for the
/// dialect, an offline device with no on-device model — each of those silently drops the app back
/// to the record-then-transcribe take that has always worked.
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

    /// Everything the on-device recogniser has heard in this take. It is the **whole** utterance,
    /// not a delta, so it replaces its predecessor and is never appended to it.
    private(set) var partial: String = ""

    /// True from the moment a take really starts until it is resolved — the composers watch its
    /// falling edge so a take that ends by itself (the 300 s cap, backgrounding) closes the bar.
    private(set) var isActive: Bool = false

    /// True while partials are being written into a composer's own draft. The bar uses it to avoid
    /// printing the same sentence twice: when a composer is showing the words, the bar does not.
    private(set) var isWritingLive: Bool = false

    /// Called when a take finishes without a caller waiting for it — the 300 s cap and the
    /// backgrounding auto-finish. Only the record-then-transcribe callers need it: a live take has
    /// already written its text into the draft by the time this would fire.
    var onTranscript: ((String) -> Void)?

    // MARK: - Dependencies

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let network: NetworkMonitor

    @ObservationIgnored private let recorder = DictationRecorder()
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var partialTask: Task<Void, Never>?
    @ObservationIgnored private var live: LiveSpeechRun?
    @ObservationIgnored private var field: Binding<String>?
    @ObservationIgnored private var insertion: DictationInsertion?
    @ObservationIgnored private var tickGeneration = 0
    @ObservationIgnored private var failureGeneration = 0
    /// Bumped by every `start` and every `cancel`, so a transcription still in flight when the
    /// user hits Cancel cannot land its text in a composer that has already been put back.
    @ObservationIgnored private var takeGeneration = 0

    init(api: APIClient, prefs: PreferencesStore, toasts: ToastCenter, network: NetworkMonitor) {
        self.api = api
        self.prefs = prefs
        self.toasts = toasts
        self.network = network
    }

    // MARK: - Lifecycle

    /// Asks for the microphone once, then starts the engine.
    ///
    /// Pass `target` — the composer's own draft binding — for a live take: partials land in the
    /// draft as they arrive and the final transcript replaces them where they sit, so `finish()`
    /// returns `nil` and the caller appends nothing. `insertAt` is the character offset the words
    /// go in at; the default is the end of the draft. Calling `start()` with no target is the old
    /// take, where `finish()` hands the transcript back instead.
    ///
    /// A denial toasts and leaves the controller idle — the bar never opens on a permission the
    /// user refused. A live call owns the audio session, so dictation refuses politely instead of
    /// fighting it for the microphone.
    ///
    /// Returns whether the microphone actually opened, so a composer that put its bar up
    /// optimistically can take it straight back down instead of leaving it there forever.
    @discardableResult
    func start(into target: Binding<String>? = nil, insertAt offset: Int? = nil) async -> Bool {
        guard state == .idle || isFailed else { return false }
        clearFailure()
        partial = ""

        let granted = await Self.requestMicrophonePermission()
        guard granted else {
            fail(Strings.Voice.micDenied(prefs.lang))
            return false
        }

        // Asked before the engine starts, so the first words are not spoken into a system dialog.
        // A refusal is deliberately silent: dictation still works, it just stops being live.
        var run: LiveSpeechRun? = nil
        if await Self.authorizeSpeech() {
            run = startLive(dialect: prefs.dictationDialect)
        }

        field = target
        isWritingLive = target != nil
        insertion = target.map { DictationInsertion(draft: $0.wrappedValue, at: offset) }

        do {
            let levels = try await recorder.start(feed: run?.feed)
            seconds = 0
            level = 0
            takeGeneration &+= 1
            state = .recording
            isActive = true
            Haptics.recordStart()
            observe(levels)
            startTicking()
            return true
        } catch is AudioSessionBusyError {
            tearDownLive()
            clearTarget()
            fail(Strings.Voice.micBusyCall(prefs.lang))
            return false
        } catch {
            tearDownLive()
            clearTarget()
            fail(Strings.Voice.micUnsupported(prefs.lang))
            return false
        }
    }

    /// Stops the take and settles the text.
    ///
    /// A live take writes its final text into the draft and returns `nil`; a plain take returns
    /// what the user said, or `nil` when nothing usable came back.
    func finish() async -> String? {
        guard state == .recording else { return nil }
        let generation = takeGeneration

        stopTicking()
        Haptics.recordStop()

        let capturedSeconds = await recorder.duration

        // Flushed before the engine goes away, so the last words the recogniser was still chewing
        // on arrive while `recorder.stop()` is winding down rather than being thrown out with it.
        live?.endAudio()

        let pcm: Data
        do {
            pcm = try await recorder.stop()
        } catch {
            levelTask?.cancel()
            level = 0
            tearDownLive()
            restoreDraft()
            clearTarget()
            fail(Strings.Voice.micFail(prefs.lang))
            return nil
        }

        levelTask?.cancel()
        level = 0
        let rescue = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownLive()

        // The local floor exists so a stray tap never spends a quota unit on 90 ms of silence.
        guard capturedSeconds >= 0.7, pcm.count >= 1_500 else {
            restoreDraft()
            clearTarget()
            fail(Strings.Voice.micTooShort(prefs.lang))
            return nil
        }

        state = .transcribing
        let wav = WAVEncoder.wav(
            pcm16: pcm,
            sampleRate: Int(DictationRecorder.sampleRate),
            channels: 1
        )

        let outcome = await transcribe(wav: wav)

        // Cancel (or a fresh take) while the upload was in flight: this answer belongs to nobody.
        guard generation == takeGeneration else { return nil }

        switch outcome {
        case .text(let heard):
            return deliver(heard)

        case .quiet:
            if !rescue.isEmpty { return deliver(rescue) }
            state = .idle
            isActive = false
            restoreDraft()
            clearTarget()
            return nil

        case .failure(let message):
            // The server owed us a better transcription and did not pay. What the device heard is
            // worse — and infinitely better than an empty composer.
            if !rescue.isEmpty {
                toasts.show(Strings.Voice.micKeptDevice(prefs.lang), isError: false)
                return deliver(rescue)
            }
            restoreDraft()
            clearTarget()
            fail(message)
            return nil
        }
    }

    /// Drops the take entirely — nothing is uploaded, and the draft goes back to exactly what it
    /// was before the microphone opened.
    func cancel() async {
        takeGeneration &+= 1
        stopTicking()
        levelTask?.cancel()
        levelTask = nil
        tearDownLive()
        await recorder.cancel()
        level = 0
        seconds = 0
        restoreDraft()
        clearTarget()
        partial = ""
        state = .idle
        isActive = false
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

    /// The append rule the web uses (`app.js:47926`): one space, never a replacement. It is what
    /// the record-then-transcribe callers do with the string `finish()` hands them; a live take
    /// splices instead, through `DictationInsertion`.
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

    // MARK: - Live recognition

    /// Opens a recognition run and starts draining its partials. Returns `nil` — quietly — when
    /// this device has no recogniser for the chosen dialect.
    private func startLive(dialect: DictationDialect) -> LiveSpeechRun? {
        // `= nil` is load-bearing: the build closure below captures this variable, and Swift will
        // not let a closure capture a local that has not been initialised yet.
        var created: LiveSpeechRun? = nil
        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            created = LiveSpeechRun.make(
                locales: Self.liveLocales(for: dialect),
                continuation: continuation
            )
            if created == nil { continuation.finish() }
        }
        guard let run = created else { return nil }

        live = run
        partialTask?.cancel()
        partialTask = Task { [weak self] in
            for await heard in stream {
                guard let self else { return }
                self.receive(heard)
            }
        }
        return run
    }

    private func receive(_ heard: String) {
        guard state == .recording else { return }
        let clean = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        partial = clean
        writeLive(clean)
    }

    /// Rewrites the dictated run in the draft. `spoken` is always the whole utterance, so this is
    /// a replacement — the one rule that keeps a partial from being inserted twice.
    private func writeLive(_ spoken: String) {
        guard let target = field, var run = insertion else { return }
        let next = run.spliced(spoken, into: target.wrappedValue)
        insertion = run
        if target.wrappedValue != next {
            target.wrappedValue = next
        }
    }

    /// Takes the dictated run back out and leaves everything the user typed around it alone.
    private func restoreDraft() {
        guard field != nil else { return }
        writeLive("")
        partial = ""
    }

    private func clearTarget() {
        field = nil
        insertion = nil
        isWritingLive = false
    }

    private func tearDownLive() {
        partialTask?.cancel()
        partialTask = nil
        live?.stop()
        live = nil
    }

    /// Settles a finished take: a live one writes the text where the partial was, a plain one
    /// hands it back to its caller.
    private func deliver(_ text: String) -> String? {
        state = .idle
        isActive = false
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasLive = field != nil
        if wasLive {
            writeLive(clean)
        }
        partial = ""
        clearTarget()
        if wasLive { return nil }
        return clean.isEmpty ? nil : clean
    }

    /// The recogniser's locale follows the dictation dialect the user chose, and Arabic is the
    /// default. iOS ships one Arabic recogniser (`ar-SA`), so `عراقية` and `مصرية` fall back to it
    /// rather than silently giving up on live text — the server still gets the dialect hint.
    private static func liveLocales(for dialect: DictationDialect) -> [String] {
        var ladder: [String] = [dialect.bcp47]
        let language = String(dialect.bcp47.prefix(while: { $0 != "-" }))
        switch language {
        case "ar":
            ladder.append(contentsOf: ["ar-SA", "ar"])
        case "en":
            ladder.append(contentsOf: ["en-US", "en"])
        default:
            ladder.append(language)
        }
        var seen: Set<String> = []
        return ladder.filter { seen.insert($0).inserted }
    }

    // MARK: - Transcription

    private enum TranscriptOutcome {
        case text(String)
        /// Nothing to report and nothing to apologise for — the request was cancelled.
        case quiet
        /// A message the user should see, unless the on-device partial can rescue the take.
        case failure(String)
    }

    private func transcribe(wav: Data) async -> TranscriptOutcome {
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
                return .failure(Strings.Voice.micEmpty(lang))
            }
            return .text(text)
        } catch is DeadlineError {
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        } catch let error as APIError {
            return await handle(error, wav: wav, dialect: dialect, lang: lang)
        } catch {
            return .failure(Strings.Voice.micFail(lang))
        }
    }

    private func handle(
        _ error: APIError,
        wav: Data,
        dialect: DictationDialect,
        lang: AppLanguage
    ) async -> TranscriptOutcome {
        switch error {
        case .offline, .transport:
            // The device recogniser works with no network at all.
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        case .cancelled:
            return .quiet
        case .deadline:
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        case .http(let status, _, _) where status == 503:
            // "no stt engine" — the server has no Gemini key at all.
            return await deviceTranscribe(wav: wav, dialect: dialect, lang: lang)
        case .http(let status, _, _) where status == 429:
            return .failure(Strings.Errors.tooFast(lang))
        case .http, .invalidURL, .decoding:
            return .failure(Strings.Voice.micFail(lang))
        }
    }

    private func deviceTranscribe(
        wav: Data,
        dialect: DictationDialect,
        lang: AppLanguage
    ) async -> TranscriptOutcome {
        let heard = await Self.recognizeOnDevice(wav: wav, locales: Self.liveLocales(for: dialect))
        guard let heard else {
            return .failure(Strings.Voice.micFail(lang))
        }
        let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(Strings.Voice.micEmpty(lang))
        }
        return .text(trimmed)
    }

    // MARK: - On-device recognition of the finished take

    /// Recognition is bounded by its own timer rather than by `withDeadline`: a speech task does
    /// not answer task cancellation, and a task group will not return while a child is still
    /// suspended, so racing it would hang instead of timing out.
    nonisolated private static func recognizeOnDevice(wav: Data, locales: [String]) async -> String? {
        guard await authorizeSpeech() else { return nil }

        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("firas-dictation-" + UUID().uuidString + ".wav")
        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        let outcome = await recognize(url: url, locales: locales)
        try? FileManager.default.removeItem(at: url)
        return outcome
    }

    nonisolated private static func recognize(url: URL, locales: [String]) async -> String? {
        guard let recognizer = LiveSpeechRun.available(for: locales) else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
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

    // MARK: - Permissions

    /// The same shape `CallEngine+Support` uses, so both microphone owners ask identically.
    nonisolated private static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                continuation.resume(returning: granted)
            })
        }
    }

    /// The system dialog appears once, on the first take; afterwards this answers immediately.
    nonisolated private static func authorizeSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
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
        isActive = false
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

// MARK: - Where the words go

/// The one run of dictated text inside a composer's draft.
///
/// A live take rewrites the same run over and over — `SFSpeechRecognizer` reports the whole
/// utterance every time, not a delta — so what is needed is a replaceable slice, not an append.
/// The user's own text lives in `prefix` and `suffix` and is never rewritten.
///
/// If the draft stops matching what was last written (the user reached in and edited it) the run
/// re-anchors around its own text before replacing it, and only falls back to "put it at the end"
/// when its text is gone entirely. Nothing the user typed is ever destroyed by a partial.
struct DictationInsertion: Equatable, Sendable {

    private(set) var prefix: String
    private(set) var suffix: String
    private(set) var inserted: String

    /// `offset` is a character offset into `draft`; `nil` means the end of it.
    init(draft: String, at offset: Int? = nil) {
        let limit = draft.count
        let cut = min(max(offset ?? limit, 0), limit)
        let index = draft.index(draft.startIndex, offsetBy: cut)
        self.prefix = String(draft[draft.startIndex..<index])
        self.suffix = String(draft[index...])
        self.inserted = ""
    }

    /// How the draft should read with `spoken` in place of the run. Pass the draft as it is *now*,
    /// not as it was: that is what makes an edit made mid-take survive.
    mutating func spliced(_ spoken: String, into current: String) -> String {
        reanchor(in: current)
        inserted = decorated(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
        return prefix + inserted + suffix
    }

    private mutating func reanchor(in current: String) {
        guard current != prefix + inserted + suffix else { return }
        if !inserted.isEmpty, let found = current.range(of: inserted, options: .backwards) {
            prefix = String(current[current.startIndex..<found.lowerBound])
            suffix = String(current[found.upperBound...])
            return
        }
        prefix = current
        suffix = ""
    }

    /// One space on each side that needs one, so dictating into "مرحبا" gives "مرحبا كيف حالك"
    /// and never "مرحباكيف حالك".
    private func decorated(_ body: String) -> String {
        guard !body.isEmpty else { return "" }
        var out = body
        if let last = prefix.last, !last.isWhitespace { out = " " + out }
        if let next = suffix.first, !next.isWhitespace { out += " " }
        return out
    }
}

// MARK: - The live run

/// One live on-device recognition run: created on the main actor when a take starts, fed from the
/// audio thread through `DictationAudioFeed`, and reporting partials into an `AsyncStream`.
///
/// It is deliberately incapable of breaking a take. Every failure just ends the stream; the
/// recorder keeps running towards the server transcript that is the real authority.
private final class LiveSpeechRun: @unchecked Sendable {

    /// The ear the audio tap talks to.
    let feed: DictationAudioFeed

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<String>.Continuation?
    private var closed = false

    /// The first locale in `locales` this device actually has a recogniser for.
    static func available(for locales: [String]) -> SFSpeechRecognizer? {
        for identifier in locales {
            if let candidate = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               candidate.isAvailable {
                return candidate
            }
        }
        return nil
    }

    static func make(
        locales: [String],
        continuation: AsyncStream<String>.Continuation
    ) -> LiveSpeechRun? {
        guard let recognizer = available(for: locales) else { return nil }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            // No network, no one-minute ceiling, and nothing leaves the phone before the upload.
            request.requiresOnDeviceRecognition = true
        }

        let run = LiveSpeechRun(
            recognizer: recognizer,
            request: request,
            continuation: continuation
        )
        run.begin(request: request)
        return run
    }

    private init(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        continuation: AsyncStream<String>.Continuation
    ) {
        self.recognizer = recognizer
        self.feed = DictationAudioFeed(request: request)
        self.continuation = continuation
    }

    private func begin(request: SFSpeechAudioBufferRecognitionRequest) {
        let started = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let heard = result.bestTranscription.formattedString
                if !heard.isEmpty { self.emit(heard) }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.close()
            }
        }

        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed { task = started }
        lock.unlock()
        if alreadyClosed { started.cancel() }
    }

    /// The take is over: let the recogniser flush what it is still holding.
    func endAudio() {
        feed.endAudio()
    }

    /// Stop everything. Safe to call twice, and safe to call from inside the task's own handler.
    func stop() {
        feed.detach()
        close()
    }

    private func emit(_ heard: String) {
        lock.lock()
        let sink: AsyncStream<String>.Continuation? = closed ? nil : continuation
        lock.unlock()
        sink?.yield(heard)
    }

    private func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let sink = continuation
        continuation = nil
        let running = task
        task = nil
        lock.unlock()

        sink?.finish()
        running?.cancel()
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
