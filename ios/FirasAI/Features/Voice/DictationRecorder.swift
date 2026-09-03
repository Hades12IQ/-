import AVFoundation
import Foundation
import Speech

/// The one-way conduit from the audio tap to a live `SFSpeechRecognizer` request.
///
/// The tap runs on the render thread and must never touch an actor, so the request lives behind a
/// lock here and is dropped the moment the take ends: `SFSpeechAudioBufferRecognitionRequest`
/// treats an `append` after `endAudio` as a programmer error, and nilling the reference makes that
/// impossible rather than merely unlikely.
final class DictationAudioFeed: @unchecked Sendable {

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    /// Called from the audio thread, once per tap buffer.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let live = request
        lock.unlock()
        live?.append(buffer)
    }

    /// Tells the recogniser no more audio is coming and stops accepting buffers.
    func endAudio() {
        lock.lock()
        let live = request
        request = nil
        lock.unlock()
        live?.endAudio()
    }

    /// Drops the request without flushing it — the take was cancelled.
    func detach() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}

/// Records the microphone straight to 16 kHz mono PCM16 — the exact shape `/api/transcribe`
/// wants — and publishes an RMS level for the 32-bar waveform.
///
/// The web records Opus/WebM and re-renders it offline; natively there is no reason to decode
/// anything, so the tap converts once, on the audio thread, into the final byte layout
/// (`web-voice-call-mic.md §7.3`, `server-voice.md §4.1`).
///
/// All mutable state lives in a private actor, which is what makes the `Sendable` conformance
/// real rather than asserted. The audio tap never touches actor state: it hands every buffer to a
/// lock-guarded sink.
final class DictationRecorder: Sendable {

    enum Failure: Error, Sendable {
        /// No usable input format, no converter, or the engine refused to start.
        case unavailable
        /// `start()` twice, or `stop()` with nothing running.
        case notRecording
    }

    /// 16 kHz mono is what the server documents and the cheapest thing to upload.
    static let sampleRate: Double = 16_000

    /// `MIC_MAX_SECONDS` (app.js:47598). 300 s of 16 kHz PCM16 is 9.6 MB → ≈12.8 M base64
    /// characters, comfortably under the server's 20 M-character ceiling.
    static let maximumSeconds: Double = 300

    private let core = DictationRecorderCore()

    init() {}

    /// Acquires the session, starts the engine, and returns the level stream (0…1, ≤ 20 Hz).
    ///
    /// `feed` is the live recogniser's ear: when it is present the *same* tap that builds the
    /// upload also hands every raw buffer to `SFSpeechRecognizer`, so the words appear while the
    /// user is still speaking. A `nil` feed is the old record-then-transcribe take, unchanged.
    func start(feed: DictationAudioFeed? = nil) async throws -> AsyncStream<Float> {
        try await core.start(feed: feed)
    }

    /// Stops everything and returns the recorded little-endian PCM16.
    func stop() async throws -> Data {
        try await core.stop()
    }

    /// Stops everything and throws the audio away.
    func cancel() async {
        await core.cancel()
    }

    /// Seconds of audio actually captured so far.
    var duration: TimeInterval {
        get async { await core.duration }
    }
}

// MARK: - Core

private actor DictationRecorderCore {

    private var engine: AVAudioEngine?
    private var sink: DictationLevelSink?
    private var isRunning = false

    var duration: TimeInterval {
        guard let sink else { return 0 }
        return Double(sink.byteCount) / (DictationRecorder.sampleRate * 2)
    }

    func start(feed: DictationAudioFeed?) async throws -> AsyncStream<Float> {
        guard !isRunning else { throw DictationRecorder.Failure.notRecording }

        try await AudioSessionArbiter.acquire(.record)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            await AudioSessionArbiter.release(.record)
            throw DictationRecorder.Failure.unavailable
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: DictationRecorder.sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            await AudioSessionArbiter.release(.record)
            throw DictationRecorder.Failure.unavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            await AudioSessionArbiter.release(.record)
            throw DictationRecorder.Failure.unavailable
        }

        let ceilingBytes = Int(DictationRecorder.maximumSeconds * DictationRecorder.sampleRate) * 2
        let sink = DictationLevelSink(
            converter: converter,
            targetFormat: target,
            maximumBytes: ceilingBytes
        )

        // 100 ms of input, the same frame size the call graph uses.
        //
        // The recogniser is fed the *untouched* tap buffer, not the 16 kHz PCM16 the upload gets:
        // `SFSpeechAudioBufferRecognitionRequest` wants the input node's own format and does its
        // own conversion, and giving it the downsampled copy is the classic way to get silence.
        let tapFrames = AVAudioFrameCount(max(1_024, Int(inputFormat.sampleRate * 0.1)))
        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { buffer, _ in
            sink.consume(buffer)
            feed?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            await AudioSessionArbiter.release(.record)
            throw DictationRecorder.Failure.unavailable
        }

        self.engine = engine
        self.sink = sink
        isRunning = true

        return AsyncStream<Float>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            sink.attach(continuation)
        }
    }

    func stop() async throws -> Data {
        guard isRunning, let sink else { throw DictationRecorder.Failure.notRecording }
        await teardown()
        let data = sink.finish()
        self.sink = nil
        return data
    }

    func cancel() async {
        guard isRunning else { return }
        await teardown()
        sink?.discard()
        sink = nil
    }

    /// Tap off first (nothing else stops the recording indicator), then the engine, then the
    /// session — the order `audit-ios-voice.md §D5` fixes for every audio owner in the app.
    private func teardown() async {
        isRunning = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        await AudioSessionArbiter.release(.record)
    }
}

// MARK: - Sink

/// Converts every tap buffer to 16 kHz mono PCM16, accumulates it, and emits a throttled level.
///
/// Called from the render thread, so every field is guarded by one lock and nothing here ever
/// touches SwiftUI or an actor.
private final class DictationLevelSink: @unchecked Sendable {

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let maximumBytes: Int

    private var pcm = Data()
    private var continuation: AsyncStream<Float>.Continuation?
    private var lastLevelAt: CFAbsoluteTime = 0
    private var closed = false

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat, maximumBytes: Int) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.maximumBytes = maximumBytes
        pcm.reserveCapacity(min(maximumBytes, 1_024 * 1_024))
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pcm.count
    }

    func attach(_ continuation: AsyncStream<Float>.Continuation) {
        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed { self.continuation = continuation }
        lock.unlock()
        if alreadyClosed { continuation.finish() }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let converted = convert(buffer) else { return }
        guard let channel = converted.int16ChannelData else { return }

        let frames = Int(converted.frameLength)
        guard frames > 0 else { return }
        let samples = channel[0]

        var sumOfSquares: Double = 0
        for index in 0..<frames {
            let value = Double(samples[index]) / 32_768.0
            sumOfSquares += value * value
        }
        let rms = Float((sumOfSquares / Double(frames)).squareRoot())
        let chunk = Data(bytes: UnsafeRawPointer(samples), count: frames * 2)

        var emitted: Float?

        lock.lock()
        if !closed, pcm.count < maximumBytes {
            let room = maximumBytes - pcm.count
            if chunk.count <= room {
                pcm.append(chunk)
            } else {
                pcm.append(chunk.prefix(room))
            }
        }
        let now = CFAbsoluteTimeGetCurrent()
        if !closed, now - lastLevelAt >= 0.05 {
            lastLevelAt = now
            emitted = rms
        }
        let sink = continuation
        lock.unlock()

        if let emitted, let sink {
            // sqrt before display, then a gentle gain so ordinary speech fills the bars.
            sink.yield(min(1, emitted.squareRoot() * 1.6))
        }
    }

    /// Ends the level stream and returns everything recorded.
    func finish() -> Data {
        lock.lock()
        closed = true
        let sink = continuation
        continuation = nil
        let out = pcm
        pcm = Data()
        lock.unlock()
        sink?.finish()
        return out
    }

    func discard() {
        lock.lock()
        closed = true
        let sink = continuation
        continuation = nil
        pcm = Data()
        lock.unlock()
        sink?.finish()
    }

    // MARK: Conversion

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : targetFormat.sampleRate
        let ratio = targetFormat.sampleRate / inputRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
}
