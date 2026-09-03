import AVFoundation
import Foundation
import OSLog

/// Thrown by `AudioSessionArbiter.acquire` when a higher-priority owner already holds the shared
/// audio session. Listening or reading aloud must never steal the session from a live call.
struct AudioSessionBusyError: Error, Sendable {
    let holder: AudioSessionArbiter.Owner
}

/// The **only** object in the app that may call `setCategory` / `setActive` /
/// `overrideOutputAudioPort` on `AVAudioSession` (`ARCHITECTURE.md §2.13`, rule 15).
///
/// Everything routes through one private actor, so every configuration change happens off the main
/// thread: `setCategory` + `setActive(true)` regularly costs 50–400 ms and, on the old controller,
/// ran inside the call screen's presentation animation.
///
/// Priority is strictly `call > record > playback > uiSound`. A lower-priority owner asking while a
/// higher one holds is refused with `AudioSessionBusyError` — it never silently reconfigures the
/// session under a running call. A higher-priority owner always wins, and re-acquiring as the
/// current owner is how the call re-activates after an interruption or a speaker toggle.
enum AudioSessionArbiter {

    enum Owner: Int, Sendable {
        case uiSound = 0, playback, record, call
    }

    /// Configures and activates the session for `owner`. `speaker` applies to `.call` only.
    static func acquire(_ owner: Owner, speaker: Bool = false) async throws {
        try await state.acquire(owner, speaker: speaker)
    }

    /// Deactivates with `.notifyOthersOnDeactivation` — but only if `owner` is still the holder,
    /// so a finished `uiSound` cannot pull the session out from under a call.
    static func release(_ owner: Owner) async {
        await state.release(owner)
    }

    static var current: Owner? {
        get async { await state.holder }
    }

    private static let state = AudioSessionState()
}

/// The serialized owner of every `AVAudioSession` mutation.
private actor AudioSessionState {

    private var owner: AudioSessionArbiter.Owner?
    private var speakerRouted = false

    var holder: AudioSessionArbiter.Owner? { owner }

    func acquire(_ candidate: AudioSessionArbiter.Owner, speaker: Bool) throws {
        if let owner, owner.rawValue > candidate.rawValue {
            throw AudioSessionBusyError(holder: owner)
        }
        try configure(candidate, speaker: speaker)
        owner = candidate
        speakerRouted = speaker
    }

    func release(_ candidate: AudioSessionArbiter.Owner) {
        guard owner == candidate else { return }
        owner = nil
        speakerRouted = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // A session that refuses to deactivate (another process still holds the route) is not
            // a user-visible failure: the next `acquire` reconfigures it from scratch.
            Log.call.error("audio session deactivate failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Category recipes

    /// Anything a person listens through that is not the phone's own two speakers. Read from
    /// the LIVE route rather than remembered, because it changes while a call is running.
    static func isHeadsetAttached(_ session: AVAudioSession) -> Bool {
        for output in session.currentRoute.outputs {
            switch output.portType {
            case .headphones, .headsetMic, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                 .airPlay, .carAudio, .usbAudio:
                return true
            default:
                continue
            }
        }
        return false
    }

    private func configure(_ candidate: AudioSessionArbiter.Owner, speaker: Bool) throws {
        let session = AVAudioSession.sharedInstance()

        switch candidate {
        case .call:
            // `.voiceChat` is what pairs with `inputNode.setVoiceProcessingEnabled(true)` for
            // Apple's echo canceller; `.defaultToSpeaker` is added only when the user chose the
            // loudspeaker, so a headset call is not forced out of the earpiece.
            //
            // `.allowBluetooth` is the hands-free (HFP) option — the same 0x4 bit the newest SDK
            // spells `.allowBluetoothHFP`. The old spelling is deliberate: it exists in every SDK
            // this target can be built against, while the new one does not, and the deployment
            // target is iOS 18. An `#available` check cannot rescue a symbol the SDK lacks.
            /* THE ROUTE DECIDES, NOT THE FLAG. Without `.defaultToSpeaker` a call comes out
               of the EARPIECE, so the phone had to be held to the ear like a telephone call
               — and with it forced on, a call spoke through the loudspeaker while AirPods
               were in. A headset of any kind connected: leave the route the system already
               chose, and do not force anything. Nothing connected: the loudspeaker, always.
               The caller's `speaker` can still ask for the loudspeaker, but it can never take
               a call away from the headphones somebody is wearing. */
            /* NOT `.defaultToSpeaker`. THAT IS WHAT MADE THE CALL TALK TO ITSELF.
               `.voiceChat` exists to pair with `setVoiceProcessingEnabled(true)`, and Apple's
               echo canceller is negotiated against the route the I/O unit was built for. Adding
               `.defaultToSpeaker` to the CATEGORY moves that route out from under it: the
               loudspeaker plays the answer, the microphone hears the answer, the canceller no
               longer recognises it as its own output, and Firas replies to himself. Worse, this
               file already overrides the port after activation, so the two were fighting.
               The documented way to reach the loudspeaker while keeping voice processing is
               `overrideOutputAudioPort(.speaker)` AFTER `setActive`, which is what happens at
               the bottom of this function. The category stays clean. */
            var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try? session.setPreferredSampleRate(24_000)
            try? session.setPreferredIOBufferDuration(0.02)

        case .record:
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            try? session.setPreferredSampleRate(16_000)
            try? session.setPreferredIOBufferDuration(0.02)

        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio, options: [])

        case .uiSound:
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }

        try session.setActive(true)

        if candidate == .call {
            // Issued *after* activation; issuing it before start is one of the things that used to
            // post a configuration change and stop the engine mid-connect.
            //
            // THE ROUTE DECIDES. A headset of any kind is left exactly where the system put it;
            // with nothing plugged in the call goes to the loudspeaker, so the phone does not
            // have to be held against an ear. The caller may still ask for the loudspeaker, but
            // it can never take a call away from headphones somebody is wearing.
            let wearing = AudioSessionState.isHeadsetAttached(session)
            let wantsSpeaker = !wearing || speaker
            try? session.overrideOutputAudioPort(wantsSpeaker ? .speaker : .none)
        }
    }
}
