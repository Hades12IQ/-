import Foundation

/// The Gemini echo guard, ported from the web's `liveBargeDecision` (`app.js:48479-48503`,
/// transcribed in `server-voice.md §7.4`).
///
/// The problem it solves: on the Gemini rung the microphone is a raw PCM tap, so while Firas is
/// speaking the loudspeaker leaks back into the capture. Voice-processing I/O removes most of it,
/// never all of it, and Gemini's server-side activity detection treats the leak as the caller
/// interrupting — the model stops mid-sentence and answers itself. The guard raises the bar for
/// what counts as speech *while playback is armed*: a frame must beat both an absolute floor and
/// three times the measured leak, three frames running, before it is forwarded.
///
/// Two rules that look like details and are not:
///
/// 1. A suppressed frame is replaced by **silence of the same length**, never dropped. The far
///    side's detector needs a continuous stream; a gap reads as the end of a turn.
/// 2. The floor is *seeded* from the first armed frame and then **frozen** while a loud run is in
///    progress, so a genuine interruption cannot raise the bar it is being measured against.
///
/// The decision itself is stateless on purpose: `CallEngine` owns the microphone pump, and with it
/// the echo floor, the loud-frame run and the playback-armed flag it reads from `CallAudioGraph`.
/// One running state machine, in one place — a second copy inside the Gemini transport would make
/// a genuine barge-in wait for two independent three-frame runs before a single word got through.
enum EchoGuard {

    // MARK: - Constants (`LIVE_BARGE_*`, app.js:48186-48192)

    /// `LIVE_BARGE_RMS` — the absolute floor a frame must clear to count as speech.
    static let rmsFloor: Float = 0.055

    /// `LIVE_BARGE_OVER_ECHO` — a frame must also be this many times the measured echo leak.
    static let overEcho: Float = 3.0

    /// `LIVE_BARGE_FRAMES` — consecutive loud frames required before anything is forwarded.
    static let requiredFrames: Int = 3

    /// `LIVE_ECHO_HANGOVER_MS` — how long the guard stays armed after playback drains.
    static let hangover: TimeInterval = 0.350

    /// The level above which a mic frame counts as "the caller is alive" for the idle hang-up
    /// clock (`server-voice.md §7.4`: `rms > 0.02` bumps `lastVoiceAt`).
    static let voiceFloor: Float = 0.02

    /// The decay applied to the echo floor on a quiet frame (`0.7·floor + 0.3·rms`).
    static let floorDecay: Float = 0.7

    // MARK: - Stateless decision

    /// `true` when this frame should be replaced by silence.
    ///
    /// - Parameters:
    ///   - rms: level of the captured frame, 0…1.
    ///   - playbackRms: level of what is being played back right now (the echo floor), 0…1.
    ///   - hangoverActive: whether playback is scheduled, a turn is open, or the 350 ms hangover
    ///     after either has not yet expired. When this is `false` nothing is ever muted.
    static func shouldMute(rms: Float, playbackRms: Float, hangoverActive: Bool) -> Bool {
        guard hangoverActive else { return false }
        let floor = max(playbackRms, 0.0001)
        let threshold = max(rmsFloor, floor * overEcho)
        return rms < threshold
    }

    // MARK: - Frame helpers

    /// Root-mean-square of a little-endian PCM16 mono frame, normalised to 0…1.
    ///
    /// Returns 0 for an empty or odd-length frame rather than trapping — a half sample at the end
    /// of a converted buffer is possible and is not worth a crash.
    static func rms(pcm16: Data) -> Float {
        let sampleCount = pcm16.count / 2
        guard sampleCount > 0 else { return 0 }
        let total: Double = pcm16.withUnsafeBytes { raw -> Double in
            var sum = 0.0
            var offset = 0
            while offset + 2 <= raw.count {
                let sample = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                let value = Double(sample) / 32_768.0
                sum += value * value
                offset += 2
            }
            return sum
        }
        let mean = total / Double(sampleCount)
        guard mean.isFinite, mean > 0 else { return 0 }
        return Float(mean.squareRoot())
    }

    /// A silent frame of exactly the same byte length — what a suppressed frame is replaced with.
    static func silence(matching frame: Data) -> Data {
        Data(count: frame.count)
    }
}
