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
            var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
            if speaker {
                options.insert(.defaultToSpeaker)
            }
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
            try? session.overrideOutputAudioPort(speaker ? .speaker : .none)
        }
    }
}
