import AVFoundation
import Foundation
import OSLog

/// Everything the graph can refuse to build. Nothing here is force-unwrapped: an
/// `AVAudioFormat` that comes back nil ends the attempt, it never crashes the app.
enum CallAudioGraphError: Error, Sendable {
    case formatUnavailable
    case converterUnavailable
    case engineUnavailable
    case decodeFailed
}

/// The one place in the app that owns an `AVAudioEngine`, an `AVAudioPlayerNode` and a microphone
/// tap (`ARCHITECTURE.md §2.13`, `audit-ios-voice.md §D4`).
///
/// Why this shape:
/// * **Voice processing before formats.** `setVoiceProcessingEnabled(true)` re-negotiates the input
///   format, so the hardware format is read *after* it — reading first is how the old controller
///   ended up with a converter for a format the tap never delivered.
/// * **Nothing plays unless the engine is running.** `AVAudioPlayerNode.play()` on a stopped engine
///   raises an Objective-C exception that Swift cannot catch, which is the single most likely cause
///   of "the call kicks me out". Every `scheduleBuffer` / `play` here is behind
///   `engine.isRunning && !isEnding`, and every one of them runs on one serial queue.
/// * **The stream never stops.** Gated and muted frames are replaced by silence of the same length,
///   because both server VADs need a continuous stream to decide anything.
///
/// Threading: `queue` owns the engine graph; `lock` owns the counters the render thread touches.
/// The class is `@unchecked Sendable` because that discipline is manual, not compiler-checked.
final class CallAudioGraph: @unchecked Sendable {

    // MARK: - Callbacks (assign before `prepare`, they are read from audio threads)

    var onConfigurationChange: (@Sendable () -> Void)?
    /// `true` when the current output is the built-in speaker/receiver, i.e. a speaker toggle makes
    /// sense; `false` on Bluetooth or wired headphones, where the toggle must be hidden.
    var onRouteChange: (@Sendable (Bool) -> Void)?
    /// `true` = interruption began, `false` = it ended (resume already attempted).
    var onInterruption: (@Sendable (Bool) -> Void)?
    /// Addition to the frozen interface: the orb level, already `sqrt`-shaped, ≤ 20 Hz.
    var onLevel: (@Sendable (Float) -> Void)?

    // MARK: - Queue-confined graph state

    private let queue = DispatchQueue(label: "org.firasai.voice.graph")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var inputFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var playFormat: AVAudioFormat?
    private var upConverter: AVAudioConverter?
    private var downConverters: [Int: AVAudioConverter] = [:]
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var playbackTapInstalled = false
    private var playerAttached = false
    private var targetRate: Double = 24_000

    // MARK: - Lock-guarded state (touched from the render thread)

    private let lock = NSLock()
    private var isEndingFlag = false
    private var isGatedFlag = false
    private var isMutedFlag = false
    private var speakerFlag = true
    private var pendingCapture = Data()
    private var frameByteCount = 4_800
    private var sink: AsyncStream<Data>.Continuation?
    private var scheduleGeneration = 0
    private var playedFrames: Int64 = 0
    private var scheduledFrames: Int64 = 0
    private var pendingSchedules = 0
    private var playbackLevelValue: Float = 0
    private var microphoneLevelValue: Float = 0
    private var speakingUntil: CFAbsoluteTime = 0
    private var lastLevelAt: CFAbsoluteTime = 0

    init() {}

    // MARK: - Read-only state

    /// RMS of the most recently scheduled playback chunk (additions used by the echo guard).
    var playbackLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return playbackLevelValue
    }

    /// Playback is scheduled, or was within the 350 ms echo hangover.
    var isPlaybackArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSchedules > 0 || CFAbsoluteTimeGetCurrent() < speakingUntil
    }

    private var isEnding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEndingFlag
    }

    // MARK: - Lifecycle

    /// Acquires the session, builds the graph off the main thread and returns the microphone
    /// stream: ordered `Int16` mono frames of exactly 100 ms at `targetRate`.
    func prepare(targetRate rate: Double, speaker: Bool) async throws -> AsyncStream<Data> {
        try await AudioSessionArbiter.acquire(.call, speaker: speaker)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let stream = try build(rate: rate, speaker: speaker)
                    continuation.resume(returning: stream)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Idempotent, and safe to call from any state. Does **not** release the audio session: the
    /// call engine releases it after the socket is closed, which is the order `§2.13` specifies.
    func teardown() async {
        lock.lock()
        if isEndingFlag {
            lock.unlock()
            return
        }
        isEndingFlag = true
        pendingSchedules = 0
        scheduleGeneration &+= 1
        let continuation = sink
        sink = nil
        pendingCapture.removeAll(keepingCapacity: false)
        playbackLevelValue = 0
        speakingUntil = 0
        lock.unlock()

        continuation?.finish()

        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                removeObservers()
                player.stop()
                if tapInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                    tapInstalled = false
                }
                if playbackTapInstalled {
                    player.removeTap(onBus: 0)
                    playbackTapInstalled = false
                }
                if engine.isRunning {
                    engine.stop()
                }
                engine.reset()
                upConverter = nil
                downConverters.removeAll()
                resume.resume()
            }
        }
    }

    // MARK: - Controls

    func setGated(_ gated: Bool) {
        lock.lock()
        isGatedFlag = gated
        lock.unlock()
    }

    func setMuted(_ muted: Bool) {
        lock.lock()
        isMutedFlag = muted
        lock.unlock()
    }

    /// Re-acquires the session with the new route. Reconfiguring the category can post a
    /// configuration change, which the observer below repairs.
    func setSpeaker(_ on: Bool) async {
        lock.lock()
        speakerFlag = on
        lock.unlock()
        do {
            try await AudioSessionArbiter.acquire(.call, speaker: on)
        } catch {
            Log.call.error("speaker route change refused")
        }
    }

    // MARK: - Playback

    /// Queues one chunk of model audio. Ordering is the queue's; the generation counter makes every
    /// buffer scheduled before a flush a no-op afterwards.
    func schedule(pcm16: Data, sampleRate: Double) {
        guard !pcm16.isEmpty else { return }
        lock.lock()
        if isEndingFlag {
            lock.unlock()
            return
        }
        let generation = scheduleGeneration
        pendingSchedules += 1
        lock.unlock()
        queue.async { [self] in
            scheduleOnQueue(pcm16, sampleRate: sampleRate, generation: generation)
        }
    }

    /// Stops playback, drops everything queued, and returns how many milliseconds of the current
    /// response actually reached the speaker — the `audio_end_ms` an OpenAI truncate needs.
    func flushPlayback() -> Int {
        lock.lock()
        let played = playedFrames
        let scheduled = scheduledFrames
        scheduleGeneration &+= 1
        playedFrames = 0
        scheduledFrames = 0
        pendingSchedules = 0
        playbackLevelValue = 0
        speakingUntil = 0
        let ending = isEndingFlag
        lock.unlock()

        if !ending {
            queue.async { [self] in
                player.stop()
                if engine.isRunning && !isEnding {
                    player.play()
                }
            }
        }

        let frames = Swift.min(played, scheduled)
        guard frames > 0 else { return 0 }
        return Int((Double(frames) / 24_000.0) * 1_000.0)
    }

    // MARK: - Building

    private func build(rate: Double, speaker: Bool) throws -> AsyncStream<Data> {
        lock.lock()
        isEndingFlag = false
        speakerFlag = speaker
        frameByteCount = Swift.max(320, Int(rate * 0.1) * 2)
        pendingCapture.removeAll(keepingCapacity: true)
        playedFrames = 0
        scheduledFrames = 0
        playbackLevelValue = 0
        pendingSchedules = 0
        speakingUntil = 0
        lock.unlock()

        targetRate = rate

        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // No AEC on this device/route. The call still works; the echo guard carries it.
            Log.call.error("voice processing unavailable")
        }

        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CallAudioGraphError.formatUnavailable
        }
        guard let capture = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: true
        ) else {
            throw CallAudioGraphError.formatUnavailable
        }
        guard let converter = AVAudioConverter(from: hardware, to: capture) else {
            throw CallAudioGraphError.converterUnavailable
        }
        guard let play = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
            throw CallAudioGraphError.formatUnavailable
        }

        inputFormat = hardware
        captureFormat = capture
        upConverter = converter
        playFormat = play

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: play)
        installPlaybackTap()

        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            lock.lock()
            sink = continuation
            lock.unlock()
        }

        installTap(format: hardware)
        installObservers()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.call.error("audio engine refused to start")
            removeObservers()
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if playbackTapInstalled {
                player.removeTap(onBus: 0)
                playbackTapInstalled = false
            }
            lock.lock()
            let continuation = sink
            sink = nil
            lock.unlock()
            continuation?.finish()
            throw CallAudioGraphError.engineUnavailable
        }
        player.play()
        return stream
    }

    private func installTap(format: AVAudioFormat) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let size = AVAudioFrameCount(Swift.max(256, Int(format.sampleRate * 0.1)))
        engine.inputNode.installTap(onBus: 0, bufferSize: size, format: format) { [weak self] buffer, _ in
            self?.handleCapture(buffer)
        }
        tapInstalled = true
    }

    /// Re-reads the hardware format and rebuilds the converter + tap. Called after a configuration
    /// change or an interruption, both of which can hand back a different input format.
    private func rebuildCapture() {
        guard let capture = captureFormat else { return }
        let hardware = engine.inputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return }
        inputFormat = hardware
        upConverter = AVAudioConverter(from: hardware, to: capture)
        installTap(format: hardware)
    }
}

// MARK: - Capture

extension CallAudioGraph {

    /// Runs on the audio render thread. Converts the hardware buffer to `Int16` mono at the target
    /// rate, publishes a level, and emits exact 100 ms frames — silence when gated or muted, never
    /// a gap.
    fileprivate func handleCapture(_ buffer: AVAudioPCMBuffer) {
        guard !isEnding else { return }
        guard let converter = upConverter, let capture = captureFormat else { return }
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }

        let ratio = capture.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: capture, frameCapacity: capacity) else { return }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else { return }

        let count = Int(output.frameLength)
        let samples = channel[0]
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index]) / 32_768.0
            sum += value * value
        }
        let rms = Float((sum / Double(count)).squareRoot())
        publishLevel(rms)

        let frame = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        enqueue(frame)
    }

    private func enqueue(_ frame: Data) {
        lock.lock()
        if isEndingFlag {
            lock.unlock()
            return
        }
        let silent = isGatedFlag || isMutedFlag
        pendingCapture.append(silent ? Data(count: frame.count) : frame)
        let size = frameByteCount
        var ready: [Data] = []
        while pendingCapture.count >= size {
            ready.append(Data(pendingCapture.prefix(size)))
            pendingCapture.removeFirst(size)
        }
        let continuation = sink
        lock.unlock()

        for chunk in ready {
            continuation?.yield(chunk)
        }
    }

    /// Observe the samples reaching the output, not the last network chunk queued ahead of it.
    /// Only the RMS scalar leaves this callback; audio content is neither retained nor logged.
    private func installPlaybackTap() {
        if playbackTapInstalled { player.removeTap(onBus: 0) }
        player.installTap(onBus: 0, bufferSize: 1_200, format: nil) { [weak self] buffer, _ in
            self?.publishLevel(Self.level(of: buffer), playback: true)
        }
        playbackTapInstalled = true
    }

    private func publishLevel(_ value: Float, playback: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard !isEndingFlag else { lock.unlock(); return }
        if playback { playbackLevelValue = value } else { microphoneLevelValue = value }
        guard now - lastLevelAt >= 0.05 else {
            lock.unlock()
            return
        }
        lastLevelAt = now
        let speaking = now < speakingUntil
        let raw = speaking ? playbackLevelValue : (isMutedFlag ? 0 : microphoneLevelValue)
        lock.unlock()

        onLevel?(Swift.min(1, raw.squareRoot() * 1.35))
    }
}

// MARK: - Playback

extension CallAudioGraph {

    fileprivate func scheduleOnQueue(_ pcm16: Data, sampleRate: Double, generation: Int) {
        defer {
            lock.lock()
            if generation == scheduleGeneration { pendingSchedules = Swift.max(0, pendingSchedules - 1) }
            lock.unlock()
        }
        lock.lock()
        let stale = generation != scheduleGeneration || isEndingFlag
        lock.unlock()
        guard !stale, engine.isRunning else { return }
        guard let buffer = makePlaybackBuffer(pcm16, sampleRate: sampleRate) else { return }

        let frames = Int64(buffer.frameLength)
        let seconds = Double(frames) / Swift.max(1, buffer.format.sampleRate)
        lock.lock()
        scheduledFrames += frames
        // One echo hangover per response, never an extra 350 ms for every network chunk.
        speakingUntil = Swift.max(speakingUntil - 0.35, CFAbsoluteTimeGetCurrent()) + seconds + 0.35
        lock.unlock()

        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferPlayed(frames: frames, generation: generation)
        }
        if !player.isPlaying && engine.isRunning && !isEnding {
            player.play()
        }
    }

    private func bufferPlayed(frames: Int64, generation: Int) {
        lock.lock()
        if generation == scheduleGeneration {
            playedFrames += frames
        }
        lock.unlock()
    }

    private func makePlaybackBuffer(_ pcm16: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let play = playFormat, sampleRate > 0 else { return nil }
        let sampleCount = pcm16.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }
        guard let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let destination = channel[0]
        pcm16.withUnsafeBytes { raw in
            for index in 0..<sampleCount {
                let value = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Int16>.size, as: Int16.self)
                destination[index] = Float(Int16(littleEndian: value)) / 32_768.0
            }
        }

        if abs(sampleRate - play.sampleRate) < 1 {
            return buffer
        }
        let key = Int(sampleRate.rounded())
        let converter: AVAudioConverter
        if let cached = downConverters[key] {
            converter = cached
        } else {
            guard let made = AVAudioConverter(from: source, to: play) else { return nil }
            downConverters[key] = made
            converter = made
        }
        let capacity = AVAudioFrameCount(Double(sampleCount) * play.sampleRate / sampleRate) + 1_024
        guard let resampled = AVAudioPCMBuffer(pcmFormat: play, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: resampled, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, resampled.frameLength > 0 else { return nil }
        return resampled
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum = 0.0
        for index in 0..<count {
            let value = Double(channel[0][index])
            sum += value * value
        }
        return Float((sum / Double(count)).squareRoot())
    }
}

// MARK: - Route, configuration and interruption

extension CallAudioGraph {

    fileprivate func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        )
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.handleRouteChange()
            }
        )
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let info = note.userInfo
                let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
                let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                self?.handleInterruption(typeValue: type, optionsValue: options)
            }
        )
    }

    fileprivate func removeObservers() {
        let center = NotificationCenter.default
        for token in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }

    /// The engine stops itself on a configuration change. Reconnect, re-tap, restart — then let the
    /// call engine reset whatever it was tracking.
    private func handleConfigurationChange() {
        queue.async { [self] in
            guard !isEnding else { return }
            rebuildCapture()
            if let play = playFormat {
                engine.connect(player, to: engine.mainMixerNode, format: play)
            }
            if !engine.isRunning {
                engine.prepare()
                do {
                    try engine.start()
                    player.play()
                } catch {
                    Log.call.error("engine restart after configuration change failed")
                }
            }
        }
        onConfigurationChange?()
    }

    private func handleRouteChange() {
        let available = Self.speakerToggleMakesSense()
        queue.async { [self] in
            guard !isEnding else { return }
            if !engine.isRunning {
                engine.prepare()
                do {
                    try engine.start()
                    player.play()
                } catch {
                    Log.call.error("engine restart after route change failed")
                }
            }
        }
        onRouteChange?(available)
    }

    private func handleInterruption(typeValue: UInt, optionsValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began {
            queue.async { [self] in
                player.stop()
                if engine.isRunning {
                    engine.stop()
                }
            }
            onInterruption?(true)
            return
        }
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        if shouldResume {
            Task { [weak self] in
                await self?.resumeAfterInterruption()
            }
        }
        onInterruption?(false)
    }

    private func resumeAfterInterruption() async {
        lock.lock()
        let ending = isEndingFlag
        let speaker = speakerFlag
        lock.unlock()
        guard !ending else { return }
        do {
            try await AudioSessionArbiter.acquire(.call, speaker: speaker)
        } catch {
            Log.call.error("session could not be re-acquired after an interruption")
            return
        }
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if !isEnding {
                    rebuildCapture()
                    if let play = playFormat {
                        engine.connect(player, to: engine.mainMixerNode, format: play)
                    }
                    engine.prepare()
                    do {
                        try engine.start()
                        player.play()
                    } catch {
                        Log.call.error("engine restart after an interruption failed")
                    }
                }
                resume.resume()
            }
        }
    }

    private static func speakerToggleMakesSense() -> Bool {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return true }
        switch port.portType {
        case .builtInSpeaker, .builtInReceiver:
            return true
        default:
            return false
        }
    }
}

// MARK: - Decoding a complete audio file into playable PCM

extension CallAudioGraph {

    /// The three-hop rung gets a finished WAV or MP3 body from `/api/tts`. It is decoded here — and
    /// played through this graph — so the call never opens a second player against the call session.
    nonisolated static func pcm16(fromAudioFileAt url: URL, sampleRate: Double) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let length = AVAudioFrameCount(Swift.max(0, file.length))
        guard length > 0, sourceFormat.sampleRate > 0,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: length) else {
            throw CallAudioGraphError.decodeFailed
        }
        try file.read(into: input)
        guard input.frameLength > 0 else { throw CallAudioGraphError.decodeFailed }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw CallAudioGraphError.converterUnavailable
        }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / sourceFormat.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CallAudioGraphError.decodeFailed
        }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else {
            throw CallAudioGraphError.decodeFailed
        }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
