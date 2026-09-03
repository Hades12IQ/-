import Foundation
import Observation
import UIKit

/// The single toast queue for the whole app.
///
/// One toast is visible at a time (`design-brief.md §7.1`): 3.2 s plain, 7 s
/// when it carries an action (`تراجع` / `إعادة المحاولة` / `أرسلها الآن`). The host
/// view lives in `Features/Shell`; this type owns only the state, the timing and
/// the VoiceOver announcement, so a store can toast without importing a view.
///
/// Text arrives already localised — `ErrorPresenter` resolves `LText` before it
/// reaches here, which is why the API takes `String`.
@MainActor
@Observable
final class ToastCenter {

    struct Toast: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        let actionTitle: String?
        let isError: Bool
    }

    private(set) var current: Toast?

    @ObservationIgnored private var pending: [Entry] = []
    @ObservationIgnored private var currentAction: (@MainActor () -> Void)?

    init() {}

    // MARK: - Showing

    func show(_ text: String, isError: Bool = false, duration: TimeInterval = 3.2) {
        enqueue(text: text, actionTitle: nil, isError: isError, duration: duration, action: nil)
    }

    func show(
        _ text: String,
        actionTitle: String,
        duration: TimeInterval = 7,
        action: @escaping @MainActor () -> Void
    ) {
        enqueue(
            text: text,
            actionTitle: actionTitle,
            isError: false,
            duration: duration,
            action: action
        )
    }

    // MARK: - Reacting

    /// Runs the toast's button (undo, retry, send-now) and dismisses it.
    func performAction() {
        let action = currentAction
        currentAction = nil
        if let action {
            Haptics.undo()
            action()
        }
        dismiss()
    }

    func dismiss() {
        currentAction = nil
        current = nil
        showNext()
    }

    // MARK: - Queue

    private struct Entry {
        let toast: Toast
        let duration: TimeInterval
        let action: (@MainActor () -> Void)?
    }

    private static let maxQueued = 3
    private static let minimumDuration: TimeInterval = 1.5

    private func enqueue(
        text: String,
        actionTitle: String?,
        isError: Bool,
        duration: TimeInterval,
        action: (@MainActor () -> Void)?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The same sentence arriving twice (two watchers failing on the same
        // outage) must not queue two identical toasts.
        if let showing = current, showing.text == trimmed, showing.actionTitle == actionTitle {
            return
        }
        if pending.contains(where: {
            $0.toast.text == trimmed && $0.toast.actionTitle == actionTitle
        }) {
            return
        }

        let entry = Entry(
            toast: Toast(
                id: UUID(),
                text: trimmed,
                actionTitle: actionTitle,
                isError: isError
            ),
            duration: max(Self.minimumDuration, duration),
            action: action
        )

        guard current != nil else {
            present(entry)
            return
        }

        pending.append(entry)
        if pending.count > Self.maxQueued {
            pending.removeFirst(pending.count - Self.maxQueued)
        }
    }

    private func showNext() {
        guard !pending.isEmpty else { return }
        present(pending.removeFirst())
    }

    private func present(_ entry: Entry) {
        current = entry.toast
        currentAction = entry.action
        announce(entry.toast)
        scheduleDismissal(of: entry.toast.id, after: entry.duration)
    }

    private func announce(_ toast: Toast) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: toast.text)
    }

    private func scheduleDismissal(of id: UUID, after duration: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current?.id == id else { return }
                self.dismiss()
            }
        }
    }
}
