import Foundation
import UIKit

/// The pre-reveal cue: a soft double pulse (with the optional `done` sound on the same frame as the
/// first pulse) that marks the moment a job turns from "working" into "done", immediately before
/// the store paints the final state.
///
/// Timing is fixed at soft 0.32 → 160 ms → soft 0.48 → 140 ms → return, ≈ 300 ms in total. The
/// Codex implementation held the finished answer off screen for three seconds; that is the bug this
/// type exists to not repeat. The streamed text is already on screen when the cue starts — the cue
/// is a full stop, never a spinner.
///
/// Gates, in order: never during a call, never outside the foreground, never twice for the same
/// key. Reduce Motion (or the app's own motion preference) collapses the double pulse into a single
/// `.success` notification haptic so the moment is still marked.
@MainActor
enum CompletionCue {

    /// How many consumed keys are remembered before the oldest is dropped.
    private static let historyLimit = 64

    private static var consumedKeys: [String] = []
    private static var consumedLookup: Set<String> = []

    private static var impact: UIImpactFeedbackGenerator?
    private static var firm: UIImpactFeedbackGenerator?
    private static var notifier: UINotificationFeedbackGenerator?

    /// Warms the Taptic Engine. Called by a watcher the moment it sees the first terminal read, so
    /// the pulse lands without the ~100 ms cold-start delay.
    static func prepare() {
        impactGenerator().prepare()
        firmGenerator().prepare()
        notificationGenerator().prepare()
    }

    /// Fires the cue for `key` (the job id) and returns after ≤ 320 ms. The caller paints the final
    /// state on the frame after this returns.
    ///
    /// - Parameters:
    ///   - key: dedupe key; an empty key fires every time.
    ///   - success: `false` plays the error haptic and no sound.
    ///   - prefs: supplies the motion preference and the UI-sound switch.
    ///   - callActive: a live call owns the audio session and the user's attention — stay silent.
    static func fire(key: String, success: Bool, prefs: PreferencesStore, callActive: Bool) async {
        guard !callActive else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard consume(key) else { return }

        let reduced = !prefs.motionEnabled || UIAccessibility.isReduceMotionEnabled

        guard success else {
            let generator = notificationGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
            return
        }

        if reduced {
            let generator = notificationGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
            return
        }

        /* THE FULL STOP, MADE TO BE FELT. The old cue was two soft taps at 0.32 and 0.48 — polite
           to the point of being missed in a pocket, and the owner asked for the opposite:
           "قبل اكتمال الرد خلي الهزة اقوى و احلى". Three beats now, rising: a light lead-in, then two
           firm ones on a `.medium` engine, so it reads as an ending rather than a twitch. The
           rhythm is uneven on purpose — 120 ms then 90 ms — because an evenly spaced buzz feels
           mechanical and a closing cadence does not. Still under 320 ms in total: this is a full
           stop before the reveal, never a wait. */
        let light = impactGenerator()
        let firm = firmGenerator()
        light.prepare()
        firm.prepare()

        /* AND NO SOUND HERE EITHER. If you are looking at the screen when the answer lands you
           can see it land; the haptic marks the moment without making a noise in a classroom.
           The bell now belongs to ONE event and one only — the notification that reaches you
           when you are NOT looking. That is what a sound is for. */
        light.impactOccurred(intensity: 0.45)
        await pause(milliseconds: 120)

        firm.impactOccurred(intensity: 0.85)
        await pause(milliseconds: 90)

        firm.prepare()
        firm.impactOccurred(intensity: 1.0)
        await pause(milliseconds: 90)
    }

    /// Forgets every consumed key (identity change, or a test harness).
    static func resetHistory() {
        consumedKeys.removeAll()
        consumedLookup.removeAll()
    }

    // MARK: - Dedupe

    /// `true` when the cue may fire for this key; records it as consumed.
    private static func consume(_ key: String) -> Bool {
        guard !key.isEmpty else { return true }
        guard !consumedLookup.contains(key) else { return false }
        consumedLookup.insert(key)
        consumedKeys.append(key)
        while consumedKeys.count > historyLimit {
            let dropped = consumedKeys.removeFirst()
            consumedLookup.remove(dropped)
        }
        return true
    }

    // MARK: - Generators

    private static func impactGenerator() -> UIImpactFeedbackGenerator {
        if let existing = impact { return existing }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        impact = generator
        return generator
    }

    /// The two firm beats of the cue. A separate `.medium` engine because intensity scales the
    /// style it is asked of — asking `.soft` for 1.0 still produces a soft tap.
    private static func firmGenerator() -> UIImpactFeedbackGenerator {
        if let existing = firm { return existing }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        firm = generator
        return generator
    }

    private static func notificationGenerator() -> UINotificationFeedbackGenerator {
        if let existing = notifier { return existing }
        let generator = UINotificationFeedbackGenerator()
        notifier = generator
        return generator
    }

    // MARK: - Timing

    /// A main-actor pause that never blocks the thread and never touches `Thread`/`usleep`.
    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
