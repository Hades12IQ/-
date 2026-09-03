import Foundation

/// Thrown when `withDeadline` gave up before the body finished.
struct DeadlineError: Error, Sendable {}

/// Races `body` against a timer and cancels the loser. This is the only permitted
/// "never hang" pattern in the app: every network await that a screen waits on runs
/// inside one of these.
///
/// - Throws: `DeadlineError` when the timer wins, otherwise whatever `body` threw.
func withDeadline<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let capped = min(max(seconds, 0), 86_400)
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await body()
        }
        group.addTask {
            try await deadlineDelay(capped)
            throw DeadlineError()
        }
        do {
            guard let first = try await group.next() else {
                group.cancelAll()
                throw DeadlineError()
            }
            group.cancelAll()
            return first
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// The timer half of `withDeadline`: waits `seconds`, throwing `CancellationError` if the
/// surrounding task is cancelled first.
///
/// Deliberately built on a `DispatchWorkItem` rather than the obvious sleep primitive — this
/// target forbids the whole family of blocking waits, and a timer that resolves a continuation
/// is both cheaper and easier to unwind from a cancellation handler.
private func deadlineDelay(_ seconds: Double) async throws {
    try Task.checkCancellation()
    guard seconds > 0 else { return }
    let handle = DeadlineDelayHandle()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            handle.begin(after: seconds, continuation: continuation)
        }
    } onCancel: {
        handle.cancel()
    }
}

/// One-shot timer whose state is guarded by a lock so the timer callback and the cancellation
/// handler can race safely. Whoever settles first wins; the loser does nothing.
private final class DeadlineDelayHandle: @unchecked Sendable {

    private let lock = NSLock()
    private var isFinished = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var item: DispatchWorkItem?

    func begin(after seconds: Double, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if isFinished {
            // Cancelled before the continuation was even installed.
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let work = DispatchWorkItem { [weak self] in
            self?.settle(with: nil)
        }
        item = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancel() {
        settle(with: CancellationError())
    }

    private func settle(with error: Error?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let waiting = continuation
        continuation = nil
        let work = item
        item = nil
        lock.unlock()

        if let error {
            work?.cancel()
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume()
        }
    }
}

/// Exponential backoff with jitter, used by every watcher and retry loop.
///
/// `next()` returns the delay to wait before the *next* attempt and advances the
/// sequence; `reset()` puts it back to the initial delay.
struct Backoff: Sendable {

    private let initial: Double
    private let ceiling: Double
    private let factor: Double
    private(set) var attempt: Int = 0

    init(initial: Double, max: Double, factor: Double = 1.7) {
        let safeInitial = initial > 0 ? initial : 0.1
        self.initial = safeInitial
        self.ceiling = max > safeInitial ? max : safeInitial
        self.factor = factor > 1 ? factor : 1.7
    }

    mutating func next() -> Double {
        let raw = initial * pow(factor, Double(attempt))
        let base = raw.isFinite ? Swift.min(raw, ceiling) : ceiling
        attempt += 1
        let jitter = Double.random(in: -0.2...0.2)
        let delayed = base * (1 + jitter)
        return Swift.min(ceiling, Swift.max(0.05, delayed))
    }

    mutating func reset() {
        attempt = 0
    }
}
