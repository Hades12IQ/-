import Foundation
import Observation
import UIKit
import UserNotifications

/// Local notifications only — the app is sideloaded with a free certificate, so there is no
/// `aps-environment` entitlement and no APNs path at all. Every notification this app shows is
/// posted by `JobManager` from a watcher that observed a terminal read while the app was not
/// active (the background hold and `BackgroundRefresh` buy that time).
///
/// The copy lives in `Strings.Notify` and is the server's APNs table verbatim
/// (`server-auth-session-account.md §6.6`), so the two channels read identically if APNs is ever
/// enabled.
///
/// **When the app asks.** Never at launch. `JobManager.prepareCompletionChannels()` calls
/// `requestIfNeeded()` once per accepted job, and the first such call — on a device that has never
/// been asked — puts one sentence on screen explaining why before iOS shows its own one-shot
/// prompt. "Not now" costs nothing: the system prompt is never spent, and the explainer stands
/// down for `explainerDeferral` before it may appear again. Every other authorization state
/// (denied, provisional, ephemeral) is answered without a prompt, and `NotificationSettingsView`
/// carries the path into system settings for the denied case.
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
        let status = await Self.currentStatus()
        authorization = status
        registerCategoriesIfNeeded()
        if status == .authorized {
            // A device that said yes never needs the explainer again.
            Self.defaults.removeObject(forKey: Keys.explainerDeferredUntil)
        }
    }

    /// The one place the system prompt is ever asked for.
    ///
    /// - `authorized` / `provisional` / `ephemeral` → `true`, nothing shown.
    /// - `denied` → `false`, nothing shown; only system settings can undo that, and the
    ///   notification page offers the button that opens them.
    /// - `notDetermined` → the explainer runs first (unless Settings already showed it, which is
    ///   what `prefs.notificationsExplained` records), and the system prompt follows the tap on
    ///   "Turn on notifications". The call returns `false` in that case: permission is not granted
    ///   *yet*, and this call's answer is only used to decide whether a banner may be posted now.
    @discardableResult
    func requestIfNeeded() async -> Bool {
        await refreshAuthorization()
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            if prefs.notificationsExplained {
                return await askSystem()
            }
            presentExplainer()
            return false
        default:
            return false
        }
    }

    /// Shows the system prompt directly. Used by `NotificationSettingsView`, which is itself the
    /// explanation, and by the explainer alert's confirm action.
    @discardableResult
    func askSystem() async -> Bool {
        let granted = await Self.requestAuthorization()
        await refreshAuthorization()
        return granted
    }

    // MARK: - Posting

    /// Announces a finished job. Only `completed` and `failed` outcomes are announced — a job the
    /// user cancelled, a job that lost its owner (401/403) and an expired pointer stay silent,
    /// exactly like the server's `notifyDurableJobTerminal`.
    ///
    /// Three lines, in the shape iOS was built for: the **title** names the product and says it
    /// finished, the **subtitle** is the conversation this belongs to, and the **body** says what
    /// to do next. Without the subtitle a person with four missions running learns only that
    /// *something* is done, which is the complaint this shape answers.
    func postJobTerminal(_ pointer: JobPointer, terminal: JobTerminal, lang: AppLanguage) async {
        guard let phase = Self.phaseWire(for: terminal) else { return }
        // Read the live status rather than the cached one: a post happens while the app is in the
        // background, minutes or hours after the last `didBecomeActive` refresh, and the answer may
        // have changed in system settings in between. `notificationSettings()` is a cheap read.
        await refreshAuthorization()
        guard isAuthorized else { return }
        registerCategoriesIfNeeded()

        let copy = Strings.Notify.job(
            product: pointer.kind.product,
            mediaKind: pointer.kind.mediaKind,
            succeeded: terminal.isSuccess
        ).resolved(lang)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        if let name = Self.conversationName(for: pointer) {
            content.subtitle = name
        }
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
        content.interruptionLevel = terminal.isSuccess ? .timeSensitive : .passive
        content.relevanceScore = terminal.isSuccess ? 1.0 : 0.4

        // The request id is the job id: a replayed post replaces the old banner instead of
        // stacking a second one, and `clearDelivered(jobID:)` can take it away again.
        await deliver(identifier: pointer.id, content: content)
    }

    /// A live call that ended while the app was in the background (the call keeps running under
    /// the `audio` background mode, so the user is told why it stopped).
    func postCallEnded(reason: String, lang: AppLanguage) async {
        await refreshAuthorization()
        guard isAuthorized else { return }
        registerCategoriesIfNeeded()

        // `reason` is an engine key (`timelimit`, `guestcap`, …), never something a user reads:
        // `Strings.Notify.callEnded` maps it to copy and falls back to the plain line.
        let copy = Strings.Notify.callEnded(reason: reason).resolved(lang)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.categoryIdentifier = NotificationRouter.callCategoryIdentifier
        content.interruptionLevel = .active
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

    // MARK: - The explainer

    /// One sentence, two buttons, shown at most once per `explainerDeferral` and only while the
    /// app is on screen.
    ///
    /// It is a `UIAlertController` rather than a SwiftUI sheet on purpose: the moment it has to
    /// appear is decided inside a job watcher, not inside a view, and routing that decision back
    /// out to `Router` would make every store that starts a job a presenter. The copy is the same
    /// `Strings.Notify.permission*` table the notification page uses.
    private func presentExplainer() {
        guard !isPresentingExplainer else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard Date() >= explainerDeferredUntil else { return }
        guard let presenter = Self.topViewController() else { return }

        let lang = prefs.lang
        let alert = UIAlertController(
            title: Strings.Notify.permissionTitle(lang),
            message: Strings.Notify.permissionBody(lang),
            preferredStyle: .alert
        )
        let later = UIAlertAction(
            title: Strings.Settings.Notifications.notNow(lang),
            style: .cancel,
            handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPresentingExplainer = false
                    self.deferExplainer()
                }
            }
        )
        let allow = UIAlertAction(
            title: Strings.Notify.permissionAllow(lang),
            style: .default,
            handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPresentingExplainer = false
                    self.prefs.notificationsExplained = true
                    Task { [weak self] in
                        guard let self else { return }
                        await self.askSystem()
                    }
                }
            }
        )
        alert.addAction(later)
        alert.addAction(allow)
        alert.preferredAction = allow

        isPresentingExplainer = true
        presenter.present(alert, animated: true)
    }

    private func deferExplainer() {
        let until = Date().addingTimeInterval(Self.explainerDeferral)
        Self.defaults.set(until.timeIntervalSince1970, forKey: Keys.explainerDeferredUntil)
    }

    private var explainerDeferredUntil: Date {
        let stamp = Self.defaults.double(forKey: Keys.explainerDeferredUntil)
        guard stamp > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: stamp)
    }

    /// Three days: long enough that a refusal is respected, short enough that someone who starts
    /// leaving long jobs running is offered the thing that makes them useful again.
    private static let explainerDeferral: TimeInterval = 3 * 24 * 60 * 60

    @ObservationIgnored private var isPresentingExplainer = false

    /// The frontmost view controller of the active window scene, or `nil` when there is none —
    /// which is exactly when nothing should be presented anyway.
    private static func topViewController() -> UIViewController? {
        var window: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive else { continue }
            window = windowScene.windows.first(where: { $0.isKeyWindow })
                ?? windowScene.windows.first
            if window != nil { break }
        }
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: - Categories

    /// Registering the two categories is what gives a hidden-previews lock screen something
    /// better than the word "Notification" to show, and it groups a conversation's banners under
    /// one summary. The placeholder is language-dependent, so it is re-registered when the
    /// interface language changes.
    private func registerCategoriesIfNeeded() {
        let lang = prefs.lang
        guard registeredCategoryLanguage != lang else { return }
        registeredCategoryLanguage = lang

        let job = UNNotificationCategory(
            identifier: NotificationRouter.categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: Strings.Settings.Notifications.hiddenPreviewJob(lang),
            options: []
        )
        let call = UNNotificationCategory(
            identifier: NotificationRouter.callCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: Strings.Settings.Notifications.hiddenPreviewCall(lang),
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([job, call])
    }

    @ObservationIgnored private var registeredCategoryLanguage: AppLanguage?

    // MARK: - Plumbing

    private static let callEndedIdentifier = "firas-call-ended"

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let explainerDeferredUntil = "notificationExplainerDeferredUntil"
    }

    /* ONE VOICE. `done.wav` is the app's own two-note bell, and it is the same file the in-app
       completion cue plays — so a job that finishes while you are looking and a job that finishes
       while you are away sound identical, which is what makes a tone belong to a product rather
       than to a screen. (`FirasComplete.wav` was the inherited placeholder.) */
    private static let completionSound = UNNotificationSound(
        named: UNNotificationSoundName("done.wav")
    )

    /// The conversation this pointer belongs to, trimmed to something a subtitle can hold. An
    /// untitled conversation contributes nothing rather than an empty grey line.
    private static func conversationName(for pointer: JobPointer) -> String? {
        let name = pointer.title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name.count > 64 else { return name }
        return String(name.prefix(63)) + "…"
    }

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
