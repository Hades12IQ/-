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
    private static var notifier: UINotificationFeedbackGenerator?

    /// Warms the Taptic Engine. Called by a watcher the moment it sees the first terminal read, so
    /// the pulse lands without the ~100 ms cold-start delay.
    static func prepare() {
        impactGenerator().prepare()
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
            FirasSound.shared.play(.done, prefs: prefs, callActive: callActive)
            return
        }

        let generator = impactGenerator()
        generator.prepare()
        generator.impactOccurred(intensity: 0.32)
        FirasSound.shared.play(.done, prefs: prefs, callActive: callActive)
        await pause(milliseconds: 160)
        generator.prepare()
        generator.impactOccurred(intensity: 0.48)
        await pause(milliseconds: 140)
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
