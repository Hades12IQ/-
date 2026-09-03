import UIKit
import UserNotifications

/// What the app delegate needs from the running app. `AppLifecycle` adopts this in Batch 2 — it
/// already declares `handleNotificationTap(userInfo:)`, and the other two requirements have
/// defaults, so the conformance is a one-line change with no new method bodies required.
///
/// The delegate is created by `@UIApplicationDelegateAdaptor` before any store exists, which is why
/// it holds a weak, late-bound host instead of naming `AppEnvironment` directly.
@MainActor
protocol FirasLifecycleHost: AnyObject {
    /// A notification the user tapped (including the one that launched the app).
    func handleNotificationTap(userInfo: [AnyHashable: Any])

    /// Whether a notification that arrived while the app is in the foreground should still be
    /// shown as a banner. Return `false` when the result is already on screen.
    func shouldPresentNotificationInForeground(userInfo: [AnyHashable: Any]) -> Bool

    /// The `BGAppRefreshTask` body: one status read per live job pointer inside `budgetSeconds`.
    /// Returns `true` when something is still live, which makes the task reschedule itself.
    func refreshJobsInBackground(budgetSeconds: Double) async -> Bool
}

extension FirasLifecycleHost {
    func shouldPresentNotificationInForeground(userInfo: [AnyHashable: Any]) -> Bool { true }
    func refreshJobsInBackground(budgetSeconds: Double) async -> Bool { false }
}

/// Local notifications and background refresh only — there is no APNs entitlement (free sideload
/// certificate), so the two remote-registration callbacks are deliberately absent: with an empty
/// entitlements file iOS answers `registerForRemoteNotifications()` with a permanent
/// "no valid 'aps-environment'" error that used to surface as a red banner in Settings.
@MainActor
final class FirasAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {

    /// Set by `FirasAIApp` once the environment exists. Assigning it flushes a notification that
    /// arrived (or launched the app) before the app was ready to route it.
    static weak var lifecycle: (any FirasLifecycleHost)? {
        didSet { FirasAppDelegate.drainPendingNotification() }
    }

    /// The wall-clock budget handed to a background refresh pass.
    static let backgroundRefreshBudgetSeconds: Double = 20

    private static var pendingUserInfo: [AnyHashable: Any]?

    // MARK: - Launch

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // `BGTaskScheduler.register` must happen before `didFinishLaunching` returns.
        BackgroundRefresh.register(handler: {
            await FirasAppDelegate.runBackgroundRefresh()
        })

        if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            FirasAppDelegate.deliverNotificationTap(userInfo: payload)
        }
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let shouldPresent = FirasAppDelegate.lifecycle?
            .shouldPresentNotificationInForeground(userInfo: userInfo) ?? true
        let silent: UNNotificationPresentationOptions = []
        let visible: UNNotificationPresentationOptions = [.banner, .list, .sound]
        return shouldPresent ? visible : silent
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        FirasAppDelegate.deliverNotificationTap(
            userInfo: response.notification.request.content.userInfo
        )
    }

    // MARK: - Routing hand-off

    /// Hands a payload to the host, or parks it until the host arrives (cold start).
    static func deliverNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let host = lifecycle else {
            pendingUserInfo = userInfo
            return
        }
        pendingUserInfo = nil
        host.handleNotificationTap(userInfo: userInfo)
    }

    private static func drainPendingNotification() {
        guard let host = lifecycle, let payload = pendingUserInfo else { return }
        pendingUserInfo = nil
        host.handleNotificationTap(userInfo: payload)
    }

    // MARK: - Background refresh

    /// The registered `BackgroundRefresh` handler. Returns `true` while anything is still live so
    /// the task resubmits itself.
    static func runBackgroundRefresh() async -> Bool {
        guard let host = lifecycle else { return false }
        return await host.refreshJobsInBackground(budgetSeconds: backgroundRefreshBudgetSeconds)
    }
}
