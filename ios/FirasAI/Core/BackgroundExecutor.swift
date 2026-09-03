import Foundation
import UIKit

/// A live `UIApplication` background task. `end()` is idempotent and safe from any
/// thread; if iOS expires the task first it is ended for us and later calls do nothing.
struct BackgroundHold: Sendable {

    private let token: BackgroundHoldToken

    fileprivate init(token: BackgroundHoldToken) {
        self.token = token
    }

    func end() {
        token.end()
    }
}

/// The only place the app asks UIKit for extra background execution.
enum BackgroundExecutor {

    /// Begins a background task and returns the hold that ends it. Always pair the call
    /// with `end()`; the expiration handler ends the task itself so nothing ever leaks.
    @MainActor
    static func hold(name: String) -> BackgroundHold {
        let token = BackgroundHoldToken()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            token.end()
        }
        token.adopt(identifier)
        return BackgroundHold(token: token)
    }
}

/// Reference box shared by the hold and the expiration handler.
fileprivate final class BackgroundHoldToken: @unchecked Sendable {

    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    /// Stores the identifier UIKit handed back. If the task already expired before the
    /// identifier arrived, it is ended immediately.
    func adopt(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        if ended {
            lock.unlock()
            BackgroundHoldToken.endTask(identifier)
            return
        }
        self.identifier = identifier
        lock.unlock()
    }

    func end() {
        lock.lock()
        let pending = identifier
        ended = true
        identifier = .invalid
        lock.unlock()
        BackgroundHoldToken.endTask(pending)
    }

    private static func endTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
