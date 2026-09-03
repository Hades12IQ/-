import AVFoundation
import Foundation
import Observation

/// "اسمع / Listen" — reads one assistant answer aloud.
///
/// One speaker token for the whole app: pressing Listen on a second message silently abandons the
/// first (`server-voice.md §7.8`). Chunks are ≤ 1 300 characters split on `.!?؟،؛\n`, cached by
/// `lang \0 text` for 16 entries, and a 429 mid-reading hands the **remaining** chunks to the
/// device voice from the failed index — never a restart, never a stop
/// (`web-voice-call-mic.md §8.1`).
@MainActor
@Observable
final class TTSPlayer {

    // MARK: - Published state

    private(set) var speakingMessageID: String?

    private(set) var isSpeaking: Bool = false

    /// Set by `CallEngine`. Reading aloud is refused while a call owns the audio session, and a
    /// call that starts mid-reading stops it.
    var callActive: Bool {
        get { storedCallActive }
        set {
            storedCallActive = newValue
            if newValue { stop() }
        }
    }

    // MARK: - Dependencies

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let toasts: ToastCenter

    @ObservationIgnored private let chunkPlayer = TTSChunkPlayer()
    @ObservationIgnored private let deviceSpeaker = TTSDeviceSpeaker()

    @ObservationIgnored private var storedCallActive = false
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var cache: [String: Data] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var holdsSession = false

    private static let cacheLimit = 16
    nonisolated static let chunkLimit = 1_300

    init(api: APIClient, prefs: PreferencesStore, toasts: ToastCenter) {
        self.api = api
        self.prefs = prefs
        self.toasts = toasts
    }

    // MARK: - Public

    func toggle(messageID: String, text: String, lang: AppLanguage) async {
        if storedCallActive {
            toasts.show(Strings.Voice.listenBusy(lang), isError: true)
            return
        }
        if speakingMessageID == messageID {
            stop()
            return
        }
        stop()
        await read(messageID: messageID, text: text, lang: lang)
    }

    func stop() {
        token &+= 1
        chunkPlayer.stop()
        deviceSpeaker.stop()
        isSpeaking = false
        speakingMessageID = nil
        releaseSession()
    }

    // MARK: - Reading

    private func read(messageID: String, text: String, lang: AppLanguage) async {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }

        let voiceLang = BidiText.isArabicDominant(clean) ? "ar" : "en"
        let pieces = Self.chunks(of: clean)
        guard !pieces.isEmpty else { return }

        token &+= 1
        let mine = token
        speakingMessageID = messageID
        isSpeaking = true

        do {
            try await AudioSessionArbiter.acquire(.playback)
        } catch {
            finish(mine)
            return
        }
        guard mine == token else { return }
        holdsSession = true

        var index = 0
        while index < pieces.count {
            guard mine == token, !storedCallActive else { return }
            let piece = pieces[index]
            let key = voiceLang + "\u{0}" + piece

            var audio = cache[key]
            if audio == nil {
                switch await fetch(chunk: piece, voiceLang: voiceLang) {
                case .success(let bytes):
                    remember(bytes, for: key)
                    audio = bytes
                case .quota:
                    toasts.show(Strings.Voice.listenLocal(lang))
                    await speakOnDevice(
                        Array(pieces[index...]),
                        voiceLang: voiceLang,
                        lang: lang,
                        mine: mine
                    )
                    finish(mine)
                    return
                case .failed:
                    toasts.show(Strings.Voice.listenFailed(lang), isError: true)
                    finish(mine)
                    return
                }
            }

            guard mine == token, let audio else { return }
            _ = await chunkPlayer.play(audio)
            index += 1
        }

        finish(mine)
    }

    private enum FetchOutcome {
        case success(Data)
        /// 429 — rate limit or quota, indistinguishable from here. Hand the rest to the device.
        case quota
        case failed
    }

    private func fetch(chunk: String, voiceLang: String) async -> FetchOutcome {
        let client = api
        var attempt = 0

        while attempt < 2 {
            do {
                let audio = try await withDeadline(seconds: 60) { () async throws -> TTSAudio in
                    let answer = try await client.tts(text: chunk, lang: voiceLang)
                    return TTSAudio(data: answer.data, mime: answer.mime)
                }
                // A 200 that is short or typed as JSON/text is a failure wearing a success code.
                guard audio.data.count > 64, Self.looksLikeAudio(audio.mime) else {
                    return .failed
                }
                return .success(audio.data)
            } catch let error as APIError {
                if case .http(let status, _, _) = error {
                    if status == 429 { return .quota }
                    if status < 500 { return .failed }
                }
                if case .cancelled = error { return .failed }
            } catch {
                // Deadline or anything else: one retry, then give up on the server voice.
            }

            attempt += 1
            if attempt >= 2 { return .failed }
            await Self.pause(0.5)
        }

        return .failed
    }

    // MARK: - Device voice

    private func speakOnDevice(
        _ pieces: [String],
        voiceLang: String,
        lang: AppLanguage,
        mine: Int
    ) async {
        guard let voice = Self.deviceVoice(for: voiceLang) else {
            let message = voiceLang == "ar"
                ? Strings.Voice.listenNoVoiceAr(lang)
                : Strings.Voice.listenNoVoice(lang)
            toasts.show(message, isError: true)
            return
        }
        for piece in pieces {
            guard mine == token, !storedCallActive else { return }
            await deviceSpeaker.speak(piece, voice: voice)
        }
    }

    /// The voice is chosen **before** the utterance is built, so "no Arabic voice" is a refusal
    /// with a sentence rather than four seconds of silence.
    nonisolated private static func deviceVoice(for voiceLang: String) -> AVSpeechSynthesisVoice? {
        let prefix = voiceLang == "ar" ? "ar" : "en"
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        if let male = matching.first(where: { $0.gender == .male }) { return male }
        if let any = matching.first { return any }
        return AVSpeechSynthesisVoice(language: prefix == "ar" ? "ar-SA" : "en-US")
    }

    // MARK: - Session and bookkeeping

    private func finish(_ mine: Int) {
        guard mine == token else { return }
        isSpeaking = false
        speakingMessageID = nil
        releaseSession()
    }

    private func releaseSession() {
        guard holdsSession else { return }
        holdsSession = false
        Task { await AudioSessionArbiter.release(.playback) }
    }

    private func remember(_ data: Data, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = data
        while cacheOrder.count > Self.cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    nonisolated private static func looksLikeAudio(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased() else { return true }
        if mime.contains("json") { return false }
        if mime.hasPrefix("text/") { return false }
        return true
    }

    nonisolated private static func pause(_ seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }
}

// MARK: - Wire shape

/// `(Data, String?)` from the endpoint, in a named `Sendable` box so it can cross `withDeadline`.
private struct TTSAudio: Sendable {
    let data: Data
    let mime: String?
}

// MARK: - Chunk playback

/// One `AVAudioPlayer` at a time, awaited to completion. Both WAV (Gemini) and MP3 (OpenAI/Edge)
/// arrive from the same endpoint, so the bytes are handed over untyped and never sniffed by us.
private final class TTSChunkPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var player: AVAudioPlayer?
    private var generation = 0

    func play(_ data: Data) async -> Bool {
        let made: AVAudioPlayer
        do {
            made = try AVAudioPlayer(data: data)
        } catch {
            return false
        }
        made.delegate = self
        made.prepareToPlay()

        let safety = max(6.0, made.duration + 3.0)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            generation &+= 1
            let mine = generation
            self.continuation = continuation
            self.player = made
            lock.unlock()

            if !made.play() {
                settle(false)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + safety) { [weak self] in
                self?.settleIfCurrent(mine)
            }
        }
    }

    func stop() {
        settle(false)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        settle(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        settle(false)
    }

    private func settleIfCurrent(_ mine: Int) {
        lock.lock()
        let stale = generation != mine
        lock.unlock()
        guard !stale else { return }
        settle(false)
    }

    private func settle(_ value: Bool) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        let running = player
        player = nil
        lock.unlock()

        running?.stop()
        waiting?.resume(returning: value)
    }
}

// MARK: - Device speech

/// `AVSpeechSynthesizer` behind the same await-to-completion shape, with a length-proportional
/// safety timer so a voice that never starts cannot hang the reading.
private final class TTSDeviceSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async {
        let safety = max(8.0, Double(text.count) * 0.16)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            generation &+= 1
            let mine = generation
            self.continuation = continuation
            lock.unlock()

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            synthesizer.speak(utterance)

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + safety) { [weak self] in
                self?.settleIfCurrent(mine)
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        settle()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        settle()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        settle()
    }

    private func settleIfCurrent(_ mine: Int) {
        lock.lock()
        let stale = generation != mine
        lock.unlock()
        guard !stale else { return }
        settle()
    }

    private func settle() {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}
