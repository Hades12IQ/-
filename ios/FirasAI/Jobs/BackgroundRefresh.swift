import BackgroundTasks
import Foundation
import OSLog

/// The only sanctioned wake-up this app has.
///
/// There is no Apple team behind this build, so there is no APNs: when the user leaves, the server
/// keeps working but nothing on the device is awake to notice. A `BGAppRefreshTask` is the answer —
/// iOS decides when (often much later than the 60 s we ask for), the handler takes one read per
/// pointer, posts a local notification for anything that finished, and asks for another slot if
/// something is still live. `audit-ios-shell-settings-design.md §2.1 F2` is the failure this closes.
///
/// `register` **must** run inside `application(_:didFinishLaunchingWithOptions:)`; registering later
/// throws inside `BGTaskScheduler` and the identifier is dead for the process. `schedule` swallows
/// its errors on purpose: a simulator or a sideloaded build without the entitlement refuses to
/// submit, and that must never be a crash or a visible failure.
enum BackgroundRefresh {

    /// Matches `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`, which spells it as
    /// `$(PRODUCT_BUNDLE_IDENTIFIER).jobs` so a signer rewriting the bundle id keeps them in step.
    static var identifier: String { AppConfiguration.bundleID + ".jobs" }

    @MainActor private static var handler: (@Sendable () async -> Bool)?
    @MainActor private static var didRegister = false

    /// `handler` returns whether anything is still live, which decides whether another slot is
    /// requested.
    @MainActor
    static func register(handler: @escaping @Sendable () async -> Bool) {
        Self.handler = handler
        guard !didRegister else { return }
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: DispatchQueue.main
        ) { task in
            MainActor.assumeIsolated {
                run(task)
            }
        }
        didRegister = accepted
        if !accepted {
            // Missing from the plist, or registered twice. The app still works; jobs are simply
            // only advanced while it is open.
            Log.jobs.error("background refresh identifier was refused")
        }
    }

    static func schedule(after seconds: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(Swift.max(1, seconds))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.jobs.debug("background refresh could not be scheduled")
        }
    }

    static func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    @MainActor
    private static func run(_ task: BGTask) {
        guard let handler else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            let stillLive = await handler()
            if Task.isCancelled {
                // Expired mid-flight. Ask for another slot: the pointers are still on disk.
                schedule(after: 60)
                task.setTaskCompleted(success: false)
                return
            }
            if stillLive { schedule(after: 60) }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
