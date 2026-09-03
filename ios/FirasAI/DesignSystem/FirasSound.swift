import AVFoundation
import Foundation

/// The two optional UI sounds (`design-brief.md §5.2`).
///
/// `send.caf` (~60 ms tick) and `done.caf` (~180 ms soft chime) ship in
/// `Resources/Sounds/` and are **optional**: when an asset is missing every call
/// is a silent no-op, never a crash. Sounds are off by default
/// (`prefs.uiSoundsEnabled`) and are skipped outright while a call is active —
/// the call owns the audio session and this type never touches it.
@MainActor
final class FirasSound {

    static let shared = FirasSound()

    enum Sound: String, CaseIterable, Sendable {
        /* `send` no longer has a file and nothing plays it: a chime on every message was noise
           the owner asked to be rid of. The case stays so a future surface can ask for it
           without inventing a name; `load` simply finds nothing and `play` becomes a no-op. */
        case send
        case done
    }

    private var loaded: [String: AVAudioPlayer] = [:]

    private init() {
        for sound in Sound.allCases {
            if let ready = Self.load(sound) {
                loaded[sound.rawValue] = ready
            }
        }
    }

    /// Plays `s` when the user has UI sounds on and no call is running.
    ///
    /// The completion sound is meant to land on the same frame as the
    /// completion haptic, so callers fire both together.
    func play(_ s: Sound, prefs: PreferencesStore, callActive: Bool) {
        guard prefs.uiSoundsEnabled, !callActive else { return }
        guard let cue = loaded[s.rawValue] else { return }
        cue.currentTime = 0
        cue.volume = Self.volume
        _ = cue.play()
    }

    /// Stops anything still ringing — used when a call starts mid-chime.
    func stopAll() {
        for cue in loaded.values where cue.isPlaying {
            cue.stop()
            cue.currentTime = 0
        }
    }

    // MARK: - Loading

    private static let volume: Float = 0.6

    private static func load(_ sound: Sound) -> AVAudioPlayer? {
        let candidates: [URL?] = [
            Bundle.main.url(
                forResource: sound.rawValue,
                withExtension: "caf",
                subdirectory: "Sounds"
            ),
            Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"),
            Bundle.main.url(
                forResource: sound.rawValue,
                withExtension: "wav",
                subdirectory: "Sounds"
            ),
            Bundle.main.url(forResource: sound.rawValue, withExtension: "wav")
        ]
        for case let url? in candidates {
            guard let ready = try? AVAudioPlayer(contentsOf: url) else { continue }
            ready.volume = volume
            ready.prepareToPlay()
            return ready
        }
        return nil
    }
}
