import Foundation
import UIKit

/// The app's haptic vocabulary (`design-brief.md §5.1`).
///
/// Rules encoded here so no call site has to remember them:
/// - generators are created once and re-`prepare()`d after every fire, so the
///   Taptic engine is warm at the moment that matters;
/// - nothing fires while the app is not `.active` (a job finishing in the
///   background must not buzz the device — that is the notification's job);
/// - `attach()` coalesces within 120 ms so dropping ten files is one tap.
@MainActor
enum Haptics {

    // MARK: - Vocabulary

    /// Fired on the frame the user bubble is inserted, never on button release.
    static func send() {
        impact(.light, intensity: 0.6)
    }

    /// Stop / cancel a running generation.
    static func stop() {
        impact(.medium, intensity: 0.5)
    }

    /// Chip, tier, mode selection and drawer snap.
    static func select() {
        guard isActive else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// One per attachment, coalesced inside a 120 ms window.
    static func attach() {
        let now = Date()
        if let last = lastAttachAt, now.timeIntervalSince(last) < Self.attachCoalescingWindow {
            return
        }
        lastAttachAt = now
        impact(.light, intensity: 1.0)
    }

    /// A tool step was reached (search started, thinking opened, agent step done).
    static func toolStep() {
        impact(.light, intensity: 0.35)
    }

    /// Error, quota or refusal — fired alongside the red toast.
    static func error() {
        guard isActive else { return }
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }

    /// An undo was taken.
    static func undo() {
        guard isActive else { return }
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func callConnected() {
        impact(.rigid, intensity: 0.9)
    }

    static func callEnded() {
        impact(.soft, intensity: 0.75)
    }

    static func recordStart() {
        impact(.rigid, intensity: 0.7)
    }

    static func recordStop() {
        impact(.soft, intensity: 0.7)
    }

    /// Called by `CompletionCue` when a watcher sees the first terminal read, so
    /// the two-pulse cue lands without engine warm-up latency.
    static func prepareCompletion() {
        guard isActive else { return }
        generator(.soft).prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }

    // MARK: - Storage

    private static let attachCoalescingWindow: TimeInterval = 0.12

    private static var impactGenerators: [Int: UIImpactFeedbackGenerator] = [:]
    private static var lastAttachAt: Date?

    private static let selectionGenerator: UISelectionFeedbackGenerator = {
        let made = UISelectionFeedbackGenerator()
        made.prepare()
        return made
    }()

    private static let notificationGenerator: UINotificationFeedbackGenerator = {
        let made = UINotificationFeedbackGenerator()
        made.prepare()
        return made
    }()

    // MARK: - Plumbing

    private static var isActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    private static func generator(
        _ style: UIImpactFeedbackGenerator.FeedbackStyle
    ) -> UIImpactFeedbackGenerator {
        if let existing = impactGenerators[style.rawValue] {
            return existing
        }
        let made = UIImpactFeedbackGenerator(style: style)
        made.prepare()
        impactGenerators[style.rawValue] = made
        return made
    }

    private static func impact(
        _ style: UIImpactFeedbackGenerator.FeedbackStyle,
        intensity: CGFloat
    ) {
        guard isActive else { return }
        let made = generator(style)
        made.impactOccurred(intensity: intensity)
        made.prepare()
    }
}
