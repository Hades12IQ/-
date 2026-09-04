import Foundation
import Observation
import UIKit

/// Which rung of the ladder is carrying the call. Kept at file scope (not nested inside the
/// `@MainActor` engine) so the value stays a plain `Sendable` enum.
enum CallRung: String, Sendable {
    case none
    case openai
    case gemini
    case threeHop = "three-hop"

    var isLive: Bool { self == .openai || self == .gemini }
}

/// What the engine tells a signed-in user when the call did not land on OpenAI Realtime.
struct CallDiagnostics: Sendable, Equatable {
    let engine: String
    let model: String
    let reason: String
}

/// The voice-call state machine (`ARCHITECTURE.md §2.13`, `audit-ios-voice.md §D1–D6`).
///
/// The ladder is strict and never silently downgraded: OpenAI Realtime → Gemini Live (one free
/// re-mint with `prefer:"gemini"` inside the server's 90 s grace) → the three-hop rung. Every
/// network await is wrapped in `withDeadline`, so "Connecting…" can never be forever; every failed
/// rung tears its audio down completely before the next one opens a microphone.
///
/// Two clocks run for the whole call: the hard cap at `max(60 s, maxMs) − 1.5 s` (the only ceiling
/// that exists on the OpenAI leg) and a 45 s idle hang-up measured from the last voice event.
/// Nothing here ends the call when the app is backgrounded — `UIBackgroundModes: audio` keeps the
/// socket and the engine alive, and an end that happens off-screen posts a local notification.
@MainActor
@Observable
final class CallEngine {

    enum Phase: Equatable {
        case idle
        case preparing
        case minting
        case connecting
        case listening
        case thinking
        case speaking
        case ending
        case ended(String)
        case failed(String)
    }

    // MARK: - Published state

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    private(set) var caption: String = ""
    private(set) var elapsed: Int = 0
    private(set) var isMuted: Bool = false
    private(set) var speakerOn: Bool = true
    private(set) var speakerToggleAvailable: Bool = true
    private(set) var diagnostics: CallDiagnostics?
    private(set) var guestCapSeconds: Int?

    var onPause: (() -> Void)?
    var onResume: (() -> Void)?

    var isActive: Bool {
        switch phase {
        case .idle, .ended, .failed: return false
        default: return true
        }
    }

    // MARK: - Dependencies

    @ObservationIgnored let api: APIClient
    @ObservationIgnored let session: SessionStore
    @ObservationIgnored let prefs: PreferencesStore
    @ObservationIgnored let jobs: JobManager
    @ObservationIgnored let notifications: NotificationManager
    @ObservationIgnored let tts: TTSPlayer

    // MARK: - Internal state (shared with `CallEngine+ThreeHop.swift`, hence not private)

    @ObservationIgnored var graph: CallAudioGraph?
    @ObservationIgnored var transport: (any CallTransport)?
    @ObservationIgnored var rung: CallRung = .none
    @ObservationIgnored var isEnding = false
    @ObservationIgnored var isConnected = false
    @ObservationIgnored var micGated = false
    @ObservationIgnored var startedAt: Date?
    @ObservationIgnored var lastVoiceAt: Date = .distantPast
    @ObservationIgnored var hardDeadline: Date?
    @ObservationIgnored var currentToken: LiveToken?
    @ObservationIgnored var lastCloseCode: Int?
    @ObservationIgnored var lastCloseReason: String = ""
    @ObservationIgnored var threeHopHistory: [OutgoingMessage] = []
    @ObservationIgnored var echoFloor: Float = 0
    @ObservationIgnored var echoRun = 0
    @ObservationIgnored private var responseAudioDone = false

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var gateTask: Task<Void, Never>?
    @ObservationIgnored private var safetyTask: Task<Void, Never>?
    @ObservationIgnored var threeHopTask: Task<Void, Never>?

    init(
        api: APIClient,
        session: SessionStore,
        prefs: PreferencesStore,
        jobs: JobManager,
        notifications: NotificationManager,
        tts: TTSPlayer
    ) {
        self.api = api
        self.session = session
        self.prefs = prefs
        self.jobs = jobs
        self.notifications = notifications
        self.tts = tts
    }

    // MARK: - Published-state mutators
    //
    // `phase`, `caption` and `diagnostics` are `private(set)`, and in Swift `private` reaches only
    // the extensions in the *same* file. `CallEngine+ThreeHop.swift` drives the third rung's phases,
    // so it goes through these instead of writing the properties directly.

    func setPhase(_ value: Phase) {
        phase = value
    }

    func setCaption(_ value: String) {
        caption = value
    }

    /// Signed-in users see `Live: <engine> — <reason>`; guests never see it. The screen reads
    /// `diagnostics` and decides — the engine only records what happened.
    func record(engine: String, model: String, reason: String) {
        diagnostics = CallDiagnostics(engine: engine, model: model, reason: reason)
    }

    // MARK: - Start

    func start() async {
        guard !isActive else { return }
        resetForStart()
        phase = .preparing
        jobs.callActive = true
        tts.callActive = true
        tts.stop()
        onPause?()
        startClock()

        guard await Self.requestMicrophonePermission() else {
            await finish(reason: "mic", failed: true)
            return
        }
        guard !isEnding else { return }
        await runLadder()
    }

    func retry() async {
        await end(reason: "retry")
        await start()
    }

    private func resetForStart() {
        responseAudioDone = false
        isEnding = false
        isConnected = false
        micGated = false
        rung = .none
        lastCloseCode = nil
        lastCloseReason = ""
        diagnostics = nil
        guestCapSeconds = nil
        currentToken = nil
        hardDeadline = nil
        threeHopHistory.removeAll()
        echoFloor = 0
        echoRun = 0
        caption = ""
        level = 0
        elapsed = 0
        isMuted = false
        speakerOn = true
        speakerToggleAvailable = true
        startedAt = Date()
        lastVoiceAt = Date()
    }

    /// OpenAI → (free re-mint) Gemini → three-hop. Nothing below is reached while `isEnding`.
    private func runLadder() async {
        phase = .minting
        var first: LiveToken?
        do {
            first = try await mint(prefer: nil)
        } catch {
            record(engine: "openai", model: "", reason: Self.reason(for: error))
        }
        guard !isEnding else { return }

        if let token = first, token.isOpenAI {
            if await connect(OpenAIRealtimeTransport(), token: token, rung: .openai, allowTools: false, reducedSetup: false) {
                return
            }
            guard !isEnding else { return }
            phase = .minting
            var second: LiveToken?
            do {
                second = try await mint(prefer: "gemini")
            } catch {
                record(engine: "gemini", model: "", reason: Self.reason(for: error))
            }
            guard !isEnding else { return }
            if let token = second, token.isGemini, await attemptGemini(token) {
                return
            }
        } else if let token = first, token.isGemini {
            if await attemptGemini(token) { return }
        }

        guard !isEnding else { return }
        await startThreeHop()
    }

    private func mint(prefer: String?) async throws -> LiveToken {
        let client = api
        let voice = prefs.callVoice.rawValue
        return try await withDeadline(seconds: 12) {
            try await client.liveToken(voice: voice, prefer: prefer)
        }
    }

    /// The Gemini rung and its two documented retries: search-entitlement (1008/1011 while tools
    /// were asked for) and a refused setup that closed early. Both need a **fresh** mint — a Gemini
    /// token that has opened one socket is spent.
    private func attemptGemini(_ token: LiveToken) async -> Bool {
        guard !Self.isGeminiCoolingDown() else {
            record(engine: "gemini", model: token.model, reason: "quota cooldown")
            return false
        }
        let allowTools = !Self.noSearchModels().contains(token.model)
        let attemptStart = Date()
        if await connect(GeminiLiveTransport(), token: token, rung: .gemini, allowTools: allowTools, reducedSetup: false) {
            return true
        }
        guard !isEnding else { return false }

        let code = lastCloseCode
        let refused = (code == 1008 || code == 1011)
        let closedEarly = Date().timeIntervalSince(attemptStart) < 8

        if refused && allowTools {
            Self.rememberNoSearch(model: token.model)
            if let fresh = try? await mint(prefer: "gemini"), !isEnding,
               await connect(GeminiLiveTransport(), token: fresh, rung: .gemini, allowTools: false, reducedSetup: false) {
                return true
            }
        } else if closedEarly && !refused {
            if let fresh = try? await mint(prefer: "gemini"), !isEnding,
               await connect(GeminiLiveTransport(), token: fresh, rung: .gemini, allowTools: false, reducedSetup: true) {
                return true
            }
        }
        if refused {
            Self.startGeminiCooldown()
        }
        return false
    }

    // MARK: - Connecting one live rung

    private func connect(
        _ candidate: any CallTransport,
        token: LiveToken,
        rung candidateRung: CallRung,
        allowTools: Bool,
        reducedSetup: Bool
    ) async -> Bool {
        phase = .connecting
        currentToken = token
        guestCapSeconds = token.guest ? Int((Double(token.maxMs) / 1_000).rounded()) : nil
        hardDeadline = Date().addingTimeInterval(max(60, Double(token.maxMs) / 1_000) - 1.5)
        lastCloseCode = nil
        lastCloseReason = ""

        let rate: Double = candidateRung == .openai ? 24_000 : 16_000
        guard let frames = await prepareGraph(targetRate: rate) else {
            record(engine: candidateRung.rawValue, model: token.model, reason: "audio unavailable")
            return false
        }

        rung = candidateRung
        transport = candidate
        // Nothing may reach a socket that has not answered yet: the pump runs from the first frame,
        // but it feeds silence until the session is up.
        micGated = true
        graph?.setGated(true)
        startEventLoop(candidate)
        startMicrophonePump(frames, transport: candidate, guarded: candidateRung == .gemini)

        let language = prefs.language
        do {
            try await withDeadline(seconds: candidateRung == .openai ? 12 : 10) {
                try await candidate.connect(
                    token: token,
                    language: language,
                    allowTools: allowTools,
                    reducedSetup: reducedSetup
                )
            }
        } catch {
            let detail = lastCloseReason.isEmpty ? Self.reason(for: error) : lastCloseReason
            record(engine: candidateRung.rawValue, model: token.model, reason: detail)
            await teardownAttempt()
            return false
        }
        guard !isEnding else { return true }

        isConnected = true
        micGated = false
        graph?.setGated(false)
        lastVoiceAt = Date()
        phase = .listening
        Haptics.callConnected()
        record(engine: candidateRung.rawValue, model: token.model, reason: "connected")
        await candidate.requestGreeting()
        return true
    }

    /// Builds a graph, wires its callbacks and returns the microphone stream. Every audio failure
    /// is a rung failure, never a crash.
    func prepareGraph(targetRate: Double) async -> AsyncStream<Data>? {
        let built = CallAudioGraph()
        wire(built)
        do {
            let frames = try await withDeadline(seconds: 12) {
                try await built.prepare(targetRate: targetRate, speaker: true)
            }
            graph = built
            return frames
        } catch {
            await built.teardown()
            await AudioSessionArbiter.release(.call)
            return nil
        }
    }

    private func wire(_ built: CallAudioGraph) {
        built.onLevel = { [weak self, weak built] value in
            Task { @MainActor in
                guard let self, let built, self.graph === built, !self.isEnding else { return }
                self.level = value
                if self.responseAudioDone, self.phase == .speaking,
                   !built.isPlaybackArmed {
                    self.phase = .listening
                }
            }
        }
        built.onRouteChange = { [weak self] available in
            Task { @MainActor in
                guard let self else { return }
                self.speakerToggleAvailable = available
                if !available { self.speakerOn = false }
            }
        }
        built.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.micGated = false
                self.graph?.setGated(false)
                self.graph?.setMuted(self.isMuted)
            }
        }
        built.onInterruption = { [weak self] began in
            Task { @MainActor in
                guard let self, !self.isEnding else { return }
                if began {
                    _ = self.graph?.flushPlayback()
                    if self.isConnected { self.phase = .listening }
                } else {
                    self.lastVoiceAt = Date()
                }
            }
        }
    }

    // MARK: - Event loop

    private func startEventLoop(_ candidate: any CallTransport) {
        eventTask?.cancel()
        let events = candidate.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: CallEvent) {
        guard !isEnding else { return }
        switch event {
        case .ready:
            lastVoiceAt = Date()
            if phase == .connecting || phase == .minting { phase = .listening }

        case .speechStarted:
            lastVoiceAt = Date()
            if prefs.bargeInEnabled {
                bargeIn()
            }
            if phase != .speaking || prefs.bargeInEnabled { phase = .listening }

        case .speechStopped:
            lastVoiceAt = Date()
            phase = .thinking

        case .responseCreated:
            responseAudioDone = false
            lastVoiceAt = Date()
            phase = .thinking
            closeMicGate()

        case .audio(let data):
            responseAudioDone = false
            closeMicGate()
            if phase != .speaking { phase = .speaking }
            graph?.schedule(pcm16: data, sampleRate: 24_000)

        case .transcript(let text, own: _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { caption = String(trimmed.prefix(240)) }

        case .responseDone:
            responseAudioDone = true
            lastVoiceAt = Date()
            if graph?.isPlaybackArmed != true { phase = .listening }
            reopenMicGateSoon()

        case .interrupted:
            _ = graph?.flushPlayback()
            echoFloor = 0
            echoRun = 0
            phase = .listening

        case .closed(code: let code, reason: let reason):
            lastCloseCode = code
            lastCloseReason = reason
            if isConnected {
                Task { await self.end(reason: "disconnected") }
            }

        case .error(let message):
            lastCloseReason = message
            if isConnected {
                Task { await self.end(reason: "disconnected") }
            }
        }
    }

    /// Barge-in is a preference, ON by default since 2026-09-03. When it is on, the caller's voice stops
    /// playback locally and tells the server exactly how much audio was actually heard.
    private func bargeIn() {
        guard let graph, graph.isPlaybackArmed else { return }
        let playedMs = graph.flushPlayback()
        echoFloor = 0
        echoRun = 0
        /* The gate may still be shut from a `response.created` that arrived before the caller cut
           in. Opening it here rather than waiting for `response.done` is the difference between
           being interrupted and being interrupted a sentence late. */
        if micGated {
            micGated = false
            // `graph` is already unwrapped by the guard above; the optional chain was a leftover.
            graph.setGated(false)
        }
        gateTask?.cancel()
        safetyTask?.cancel()
        if let transport {
            Task { await transport.truncate(playedMs: playedMs) }
        }
    }

    // MARK: - Microphone gate

    /// While Firas speaks the microphone is silenced at the source (OpenAI's guard mode). Mute
    /// always wins, and the gate never rewrites the phase.
    private func closeMicGate() {
        guard rung == .openai else { return }
        /* THE GATE AND BARGE-IN CANNOT BOTH BE ON. Silencing the microphone at the source while
           Firas speaks means the server never receives the caller’s voice, so it never emits
           `input_audio_buffer.speech_started`, so `bargeIn()` is never reached — the caller talks,
           nothing happens, the answer runs to its end, and only then is the question heard. That is
           exactly what was reported: "من اقاطعه ما يتقاطع، يكمل كلامه، بعدين يرد على سوالي".
           With barge-in on the microphone stays open and `EchoGuard` does the harder job it was
           written for: telling the caller’s voice apart from the speaker’s. The gate remains for
           callers who deliberately turned barge-in off, where it is the right trade. */
        guard !prefs.bargeInEnabled else { return }
        if !micGated {
            micGated = true
            graph?.setGated(true)
        }
        startSafetyReopen()
    }

    private func reopenMicGateSoon() {
        guard rung == .openai else { return }
        gateTask?.cancel()
        gateTask = Task { [weak self] in
            await JobClock.rest(0.28)
            guard let self, !Task.isCancelled, !self.isEnding else { return }
            self.micGated = false
            self.graph?.setGated(false)
        }
    }

    /// `response.done` sometimes never arrives. Twenty seconds later the caller gets the mic back
    /// regardless — a call you cannot interrupt beats a call that cannot hear you at all.
    private func startSafetyReopen() {
        safetyTask?.cancel()
        safetyTask = Task { [weak self] in
            await JobClock.rest(20)
            guard let self, !Task.isCancelled, !self.isEnding, self.micGated else { return }
            self.micGated = false
            self.graph?.setGated(false)
        }
    }

    // MARK: - Microphone pump

    /// One ordered consumer. Frames reach the transport in capture order because each `send` is
    /// awaited before the next frame is read — the old controller spawned a task per frame and the
    /// model received scrambled audio.
    private func startMicrophonePump(_ frames: AsyncStream<Data>, transport candidate: any CallTransport, guarded: Bool) {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            var sinceLastPing = 0
            for await frame in frames {
                guard let self, !Task.isCancelled, !self.isEnding else { return }
                let payload = guarded ? self.echoGuarded(frame) : frame
                await candidate.send(pcm16: payload)

                sinceLastPing += 1
                if sinceLastPing >= 200 {
                    sinceLastPing = 0
                    if self.micGated || self.isMuted {
                        await candidate.ping()
                    }
                }
            }
        }
    }

    /// `server-voice.md §7.4`: seed an echo floor from the leak, require three consecutive frames
    /// above `max(0.055, floor × 3)`, and substitute silence — never a gap — for what is suppressed.
    private func echoGuarded(_ frame: Data) -> Data {
        guard let graph, graph.isPlaybackArmed else {
            echoFloor = 0
            echoRun = 0
            if Self.rms(of: frame) > EchoGuard.voiceFloor { lastVoiceAt = Date() }
            return frame
        }
        let rms = Self.rms(of: frame)
        if rms > EchoGuard.voiceFloor {
            lastVoiceAt = Date()
        }
        if echoFloor <= 0 {
            echoFloor = max(rms, 0.0001)
            return Data(count: frame.count)
        }
        let loud = !EchoGuard.shouldMute(rms: rms, playbackRms: echoFloor, hangoverActive: true)
        echoRun = loud ? echoRun + 1 : 0
        if !loud {
            echoFloor = echoFloor * 0.7 + rms * 0.3
        }
        return echoRun >= 3 ? frame : Data(count: frame.count)
    }

    // MARK: - Controls

    func toggleMute() {
        isMuted.toggle()
        graph?.setMuted(isMuted)
        Haptics.select()
    }

    func toggleSpeaker() async {
        speakerOn.toggle()
        await graph?.setSpeaker(speakerOn)
    }

    // MARK: - Clocks

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while true {
                await JobClock.rest(0.5)
                guard let self, !Task.isCancelled, !self.isEnding, self.isActive else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        if let startedAt {
            elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        }
        if let deadline = hardDeadline, Date() >= deadline {
            let guestCall = currentToken?.guest ?? false
            Task { await self.end(reason: guestCall ? "guestcap" : "timelimit") }
            return
        }
        if isConnected, Date().timeIntervalSince(lastVoiceAt) > 45 {
            Task { await self.end(reason: "idle") }
        }
    }

    // MARK: - Teardown

    func end(reason: String) async {
        guard !isEnding, isActive else { return }
        await finish(reason: reason, failed: false)
    }

    /// Between two rungs: everything the failed attempt owned goes away, including the session, so
    /// the next rung never opens a second microphone against a live one.
    private func teardownAttempt() async {
        pumpTask?.cancel()
        pumpTask = nil
        eventTask?.cancel()
        eventTask = nil
        gateTask?.cancel()
        gateTask = nil
        safetyTask?.cancel()
        safetyTask = nil
        if let graph {
            _ = graph.flushPlayback()
            await graph.teardown()
        }
        if let transport {
            await transport.close()
        }
        await AudioSessionArbiter.release(.call)
        graph = nil
        transport = nil
        rung = .none
        isConnected = false
        micGated = false
        level = 0
    }

    /// `§2.13` order, and idempotent: `isEnding` is set before anything else so a socket close or a
    /// route change arriving mid-teardown cannot re-enter.
    func finish(reason: String, failed: Bool) async {
        guard !isEnding else { return }
        isEnding = true
        phase = .ending

        clockTask?.cancel()
        clockTask = nil
        threeHopTask?.cancel()
        threeHopTask = nil

        let wasForeground = UIApplication.shared.applicationState == .active
        await teardownAttempt()

        currentToken = nil
        threeHopHistory.removeAll()
        echoFloor = 0
        echoRun = 0
        hardDeadline = nil
        caption = ""
        jobs.callActive = false
        tts.callActive = false
        onResume?()

        phase = failed ? .failed(reason) : .ended(reason)

        if wasForeground {
            Haptics.callEnded()
        } else {
            await notifications.postCallEnded(reason: reason, lang: prefs.language)
        }
    }
}
