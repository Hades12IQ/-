import Foundation

/// Everything the operating system tells the app, translated into store calls — in one place, in a
/// fixed order, so nobody has to guess which screen is responsible for waking the app up.
///
/// The two rules that matter:
///
/// * **Returning re-attaches, it never restarts.** A job started before the app was suspended is
///   still running on the server; coming back only means watching it again.
/// * **Leaving cancels nothing.** Backgrounding flushes drafts, closes the microphone and asks for
///   a `BGAppRefreshTask`; it never stops a watcher's server-side work.
///
/// `AppLifecycle` is also the app delegate's host (`FirasLifecycleHost`), which is how a tapped
/// notification — including the one that launched the app from cold — finds the router.
@MainActor
final class AppLifecycle: FirasLifecycleHost {

    private let env: AppEnvironment

    /// A launch delivers both a `.task` and a `scenePhase` transition to `.active`. The first pass
    /// does the work; a second arrival inside this window is the same event seen twice.
    private static let activationWindow: TimeInterval = 1.5

    private var isActivating = false
    private var lastActivation: Date?

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - Scene phase

    /// Boot and every return to the foreground. Ordered deliberately: identity first (everything
    /// below is keyed by owner), then the job spine, then the screens' own catch-up.
    func didBecomeActive() async {
        guard !isActivating else { return }
        if let last = lastActivation, Date().timeIntervalSince(last) < Self.activationWindow {
            return
        }
        isActivating = true
        defer {
            isActivating = false
            lastActivation = Date()
        }

        // Idempotent; the shell may or may not have reached its own `.task` yet.
        env.network.start()

        // `.booting` and `.unreachable` restore; a member older than ten minutes re-validates;
        // a guest does nothing at all.
        await env.session.applicationDidBecomeActive()

        // Re-attach the watchers for whoever is signed in now, then let every live watcher take
        // one immediate read instead of waiting out its cadence.
        await env.adoptCurrentIdentity()
        env.jobs.applicationDidBecomeActive()

        // A member's live conversations may have been finished by the server while we were away.
        await env.chat.applicationDidBecomeActive()
        /* Firas Code hands a live build to the server when the reader leaves and takes it back
           when they return. Both halves belong HERE, in the one place with a fixed order — the
           store registers its own notification observers as a fallback, but those only arm once
           the reader has opened Firas Code in this launch, so a build interrupted in a session
           that never visited it would wait for the next visit instead of the next foreground. */
        await env.code.resumeLiveBuilds()

        await env.drafts.restore()
        await env.announcements.load()
        /* THE MEDIA LIBRARY, at boot. It was loaded only by the Studio screens, so on a cold
           launch `creations` was empty and every image, video and song fence in a reopened
           conversation found no record: no file, no share, and — because the song card reads its
           playback through that record — a scrubber and a clock that could never move. */
        await env.media.reload()
        await env.notifications.refreshAuthorization()
    }

    /// Leaving. Nothing here stops work: the watchers take a short background hold, ask for a
    /// refresh slot and keep their pointers on disk.
    func didEnterBackground() {
        env.drafts.flush()

        // The microphone must not stay open behind another app; an in-flight take is finished,
        // not thrown away.
        env.dictation.applicationDidEnterBackground()

        // Doubles every cadence, takes a `BackgroundHold`, persists the pointer table and submits
        // `BackgroundRefresh.schedule(after: 60)` while the table is non-empty.
        // Hand any live Firas Code build to the server before the app is suspended; see above.
        env.code.handOffLiveBuilds()
        env.jobs.applicationDidEnterBackground()
    }

    // MARK: - URLs

    /// `onOpenURL`. `Router.handle` parks the destination in `pendingRoute`; the shell consumes it
    /// on the next frame.
    ///
    /// `?verify=` and `?reset=&uid=` are the exception: they need a screen that can ask for a
    /// password (reset) or report a verdict (verify), so this presents Auth and **leaves**
    /// `pendingRoute` set — `AuthView.consumePendingRoute()` is what actually spends it.
    func handle(url: URL) {
        guard env.router.handle(url: url) else { return }
        guard let route = env.router.pendingRoute else { return }
        switch route {
        case .verify, .reset:
            env.router.open(route)
        case .chat, .agent, .code, .brain, .studio, .settings, .auth, .sharedChat:
            break
        }
    }

    // MARK: - FirasLifecycleHost

    /// A tapped notification, including the one that launched the app: the payload becomes a
    /// pending route rather than an immediate navigation, because at cold start the shell has not
    /// been built yet.
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let route = NotificationRouter.route(userInfo: userInfo) else { return }
        env.router.pendingRoute = route
    }

    /// A banner for a result the user is already looking at is noise. Anything we cannot place —
    /// another product, another conversation, an unrecognised payload — is shown.
    func shouldPresentNotificationInForeground(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = NotificationRouter.route(userInfo: userInfo) else { return true }
        let router = env.router
        switch route {
        case .chat(let conversationID):
            return !isShowing(product: .ai, conversationID: conversationID)
        case .agent(let conversationID):
            guard let conversationID else { return router.product != .agent }
            return !isShowing(product: .agent, conversationID: conversationID)
        case .code(let projectID):
            guard let projectID else { return router.product != .code }
            return !isShowing(product: .code, conversationID: projectID)
        case .brain:
            return router.product != .brain
        case .studio:
            return router.product != .studio
        case .settings, .auth, .sharedChat, .verify, .reset:
            return true
        }
    }

    /// The `BGAppRefreshTask` body, reached through `FirasAppDelegate.runBackgroundRefresh()`.
    /// One status read per live pointer inside the budget; `true` asks for another slot.
    func refreshJobsInBackground(budgetSeconds: Double) async -> Bool {
        await env.jobs.refreshOnce(budgetSeconds: budgetSeconds)
    }

    // MARK: - Private

    private func isShowing(product: ProductKind, conversationID: String) -> Bool {
        guard env.router.product == product else { return false }
        guard let selected = env.router.selectedConversationID, !selected.isEmpty else { return false }
        return selected == conversationID
    }
}
