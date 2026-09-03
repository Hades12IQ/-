import SwiftUI

/// The house springs (`design-brief.md §3.1`). Critically damped by default; overshoot exists in
/// exactly one place, and only after a real gesture.
enum FirasMotion {
    /// Default state change: toggle, chip select, badge.
    static let standard: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    /// The custom compact drawer opening programmatically. System sheets animate themselves.
    static let sheet: Animation = .spring(response: 0.42, dampingFraction: 0.86)

    /// Composer grow/shrink and the send→stop morph. The field must never bounce.
    static let composer: Animation = .spring(response: 0.28, dampingFraction: 0.9)

    /// Tier pill pop, scale 1 → 1.06 → 1.
    static let tierPop: Animation = .spring(response: 0.3, dampingFraction: 0.7)

    /// Completion reveal: action row and quick replies, right after the completion haptic.
    static let reveal: Animation = .spring(response: 0.4, dampingFraction: 0.85)

    /// The one overshoot in the app: the drawer released with velocity.
    static let drawerFlick: Animation = .interactiveSpring(response: 0.32, dampingFraction: 0.78)

    /// What every entrance becomes when motion is off.
    static let fade: Animation = .easeOut(duration: 0.12)

    /// Two switches, one contract: the in-app toggle and the system Reduce Motion setting.
    @MainActor
    static func isOn(prefs: PreferencesStore, reduceMotion: Bool) -> Bool {
        prefs.motionEnabled && !reduceMotion
    }

    /// The spring when motion is on, the 120 ms cross-fade when it is not. Busy indicators must
    /// still move — they switch to `busyPulse`, never to nothing.
    static func gated(_ animation: Animation, motionOn: Bool) -> Animation {
        motionOn ? animation : fade
    }

    /// Reduce Motion replacement for spinners and sweeps: opacity 0.32 ↔ 1, 1.5 s, forever.
    static let busyPulse: Animation = .easeInOut(duration: 1.5).repeatForever(autoreverses: true)

    /// Entrance used with `reveal`.
    static var revealTransition: AnyTransition { .opacity.combined(with: .offset(y: 6)) }
}
