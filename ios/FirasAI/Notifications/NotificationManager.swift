import Foundation
import Observation
import UserNotifications

/// Local notifications only — the app is sideloaded with a free certificate, so there is no
/// `aps-environment` entitlement and no APNs path at all. Every notification this app shows is
/// posted by `JobManager` from a watcher that observed a terminal read while the app was not
/// active (the background hold and `BackgroundRefresh` buy that time).
///
/// The copy lives in `Strings.Notify` and is the server's APNs table verbatim
/// (`server-auth-session-account.md §6.6`), so the two channels read identically if APNs is ever
/// enabled.
@MainActor
@Observable
final class NotificationManager {

    private let prefs: PreferencesStore

    /// Last known authorization status. Refreshed on `didBecomeActive` and before every post.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    // MARK: - Permission

    var isAuthorized: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    func refreshAuthorization() async {
        authorization = await Self.currentStatus()
    }

    /// Asks for `.alert` + `.sound` the first time, and only after the one-line explainer sheet has
    /// been shown (`prefs.notificationsExplained`). Returns whether notifications may be posted.
    @discardableResult
    func requestIfNeeded() async -> Bool {
        await refreshAuthorization()
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard prefs.notificationsExplained else { return false }
            let granted = await Self.requestAuthorization()
            await refreshAuthorization()
            return granted
        default:
            return false
        }
    }

    // MARK: - Posting

    /// Announces a finished job. Only `completed` and `failed` outcomes are announced — a job the
    /// user cancelled, a job that lost its owner (401/403) and an expired pointer stay silent,
    /// exactly like the server's `notifyDurableJobTerminal`.
    func postJobTerminal(_ pointer: JobPointer, terminal: JobTerminal, lang: AppLanguage) async {
        guard let phase = Self.phaseWire(for: terminal) else { return }
        if authorization == .notDetermined {
            await refreshAuthorization()
        }
        guard isAuthorized else { return }

        let copy = Strings.Notify.job(
            product: pointer.kind.product,
            mediaKind: pointer.kind.mediaKind,
            succeeded: terminal.isSuccess
        ).resolved(lang)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = Self.completionSound
        content.categoryIdentifier = NotificationRouter.categoryIdentifier
        content.threadIdentifier = NotificationRouter.threadIdentifier(for: pointer)
        content.userInfo = NotificationRouter.userInfo(for: pointer, phase: phase)
        /* A finished answer is why the reader left the app in the first place, so it is allowed to
           light the screen rather than wait in the shade — `.timeSensitive` does that without the
           entitlement a critical alert needs, and it is the honest level for "the thing you asked
           for is ready". A failure is not urgent, only informative, so it stays passive. The
           relevance score puts a fresh completion at the top of a stacked summary. */
        if #available(iOS 15.0, *) {
            content.interruptionLevel = terminal.isSuccess ? .timeSensitive : .passive
            content.relevanceScore = terminal.isSuccess ? 1.0 : 0.4
        }

        // The request id is the job id: a replayed post replaces the old banner instead of
        // stacking a second one, and `clearDelivered(jobID:)` can take it away again.
        await deliver(identifier: pointer.id, content: content)
    }

    /// A live call that ended while the app was in the background (the call keeps running under
    /// the `audio` background mode, so the user is told why it stopped).
    func postCallEnded(reason: String, lang: AppLanguage) async {
        if authorization == .notDetermined {
            await refreshAuthorization()
        }
        guard isAuthorized else { return }

        // `reason` is an engine key (`timelimit`, `guestcap`, …), never something a user reads:
        // `Strings.Notify.callEnded` maps it to copy and falls back to the plain line.
        let copy = Strings.Notify.callEnded(reason: reason).resolved(lang)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.categoryIdentifier = NotificationRouter.callCategoryIdentifier
        content.userInfo = [
            NotificationRouter.payloadKey: ["type": NotificationRouter.callEndedType]
        ]
        await deliver(identifier: Self.callEndedIdentifier, content: content)
    }

    /// Takes the banner away once the user has opened the result inside the app.
    func clearDelivered(jobID: String) {
        guard !jobID.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [jobID])
        center.removePendingNotificationRequests(withIdentifiers: [jobID])
    }

    /// Removes every Firas banner (used when the identity changes).
    func clearAllDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Plumbing

    private static let callEndedIdentifier = "firas-call-ended"

    /* ONE VOICE. `done.wav` is the app's own two-note bell, and it is the same file the in-app
       completion cue plays — so a job that finishes while you are looking and a job that finishes
       while you are away sound identical, which is what makes a tone belong to a product rather
       than to a screen. (`FirasComplete.wav` was the inherited placeholder.) */
    private static let completionSound = UNNotificationSound(
        named: UNNotificationSoundName("done.wav")
    )

    private func deliver(identifier: String, content: UNNotificationContent) async {
        let requestID = identifier.isEmpty ? UUID().uuidString : identifier
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        // A failure here is not actionable and has no UI: the result is still waiting in the app.
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// `phase` ∈ `"completed" | "failed"`; `nil` means "do not notify".
    private static func phaseWire(for terminal: JobTerminal) -> String? {
        switch terminal {
        case .completed:
            return "completed"
        case .failed, .refused:
            return "failed"
        default:
            return nil
        }
    }
}
